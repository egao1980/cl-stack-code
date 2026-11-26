(in-package #:cl-stack-code)

;;; H3f (0.14.0) — resilience, part 2: the runtime. Settings, flags, the
;;; failure taxonomy and exit codes are in src/resilience-config.lisp.
;;;
;;; AGENT EXTRAS. RESILIENCE-AGENT-EXTRA settings backend &key model
;;;   → a plist appended to the agent settings' :EXTRA (%AGENT-SETTINGS, the
;;;   client's and the program's sessions alike):
;;;     :RETRY-POLICY  (MAKE-SETTINGS-RETRY-POLICY settings)
;;;     :COMPACTION    a conversation-protocol SUMMARY-MEMORY on BACKEND
;;;                    (:tail-tokens = min(15000, window / 4)), always (the
;;;                    reactive compaction needs it even when autoCompact is
;;;                    off)
;;;     :COMPACT-AT    floor(window × thresholdPct / 100) when autoCompact is
;;;                    enabled; absent otherwise
;;;     :MAX-CONTINUATIONS          maxContinuations
;;;     :LENGTH-RETRY-MAX-TOKENS    lengthRetryMaxTokens, else 2 × the run's
;;;                                 max tokens (capped +MAX-LENGTH-RETRY-
;;;                                 TOKENS+), absent when neither is known
;;;   window = EFFECTIVE-CONTEXT-WINDOW.
;;;   MAKE-SETTINGS-RETRY-POLICY settings → LLM-PROTOCOL:MAKE-RETRY-POLICY
;;;   :max-attempts retry.maxAttempts :base-delay initialDelayMs/1000
;;;   :max-delay maxDelayMs/1000 :jitter +RETRY-JITTER+ (the classes are
;;;   llm-protocol's default: rate-limit, overloaded, transient).
;;;   The backend gets requestTimeoutMs through APPLY-REQUEST-TIMEOUT right
;;;   after the provider factory made it (-p, sessions, /model).
;;;
;;; CONTEXT WINDOW. EFFECTIVE-CONTEXT-WINDOW settings backend designator
;;;   → (values tokens source). The settings' contextWindow: an integer →
;;;   it (:settings); an object → the first of its keys DESIGNATOR as given
;;;   ("openai:qwen3"), the model part ("qwen3"), the provider part
;;;   ("openai"), "*" (:settings). Else LLM-PROTOCOL:CONTEXT-WINDOW of
;;;   BACKEND and the model (:provider). Else +DEFAULT-CONTEXT-WINDOW+
;;;   (:default). Never signals: a provider lookup that signals counts as
;;;   unknown.
;;;   Prompt tokens are read from each response's usage (input + cache read +
;;;   cache write). CONTEXT-USAGE-PCT used window → the integer percentage,
;;;   rounded down, capped at 999.
;;;
;;; EVENTS (stream-json lines, SDK events and RPC notifications; all
;;;   "type": "system", so +EVENT-TYPES+ does not change):
;;;   init gains "context_window" (tokens), "context_window_source"
;;;     ("settings" "provider" "default"), "auto_compact" {"enabled",
;;;     "threshold_pct"}, "retry" {"max_attempts", "initial_delay_ms",
;;;     "max_delay_ms"}, "request_timeout_ms" and "turn_timeout_ms" (null when
;;;     unset). Always present.
;;;   RETRY-EVENT-OBJECT plist → {"type":"system","subtype":"retry",
;;;     "step", "attempt" (the failed one), "max_attempts", "delay_ms"
;;;     (integer), "reason" ("rate_limit" "overloaded" "transient"
;;;     "context_overflow" "output_truncated"), "status" (or null),
;;;     "retry_after_ms" (or null), "error" (the condition's text, through
;;;     REDACT-SECRETS)} — from the loop's :retry event, before the wait.
;;;   COMPACT-EVENT-OBJECT plist → {"subtype":"compact", "reason"
;;;     ("threshold" "overflow" "manual"), "turns_before", "turns_after",
;;;     "tokens_before" (or null), "context_window"}.
;;;   CONTINUATION-EVENT-OBJECT plist → {"subtype":"continuation", "step",
;;;     "count", "max"}.
;;;   TRUNCATED-EVENT-OBJECT plist → {"subtype":"truncated", "step",
;;;     "tool_use_ids": [...], "max_tokens"}.
;;;   Each object also carries "session_id" like every event. The result
;;;   object gains "retries" (the :retry events of the turn),
;;;   "compactions" (the :compacted events), "continuations", and on a model
;;;   failure "error_class" (src/resilience-config.lisp). The assistant
;;;   event gains "context_tokens" (its prompt tokens) and "context_pct".
;;;
;;; FAILURE AT THE END. When the loop gives up, the run's failure goes
;;;   through CLASSIFY-MODEL-FAILURE; the result has that subtype, is_error
;;;   true and the MODEL-FAILURE-MESSAGE; text mode writes
;;;   "cl-stack-code: <message>" to stderr; the exit code is
;;;   CONDITION-EXIT-CODE of the classified condition (3, 1 or 124). The
;;;   turn is committed (H3c) with finish :FAILED and everything up to the
;;;   failure: the user turn and each completed step (assistant turns, tool
;;;   results). The partial assistant text of the failed step is not in it
;;;   (the loop dropped it). Nothing else is lost.
;;;
;;; RETRYING A FAILED TURN. FAILED-TURN-P store → T when the head record's
;;;   finish is :FAILED. -p --continue/--resume --retry, the TUI's /retry,
;;;   RPC turn/retry and CLIENT-RETRY-TURN continue the conversation from
;;;   the session as recorded without adding a user turn (the failed turn's
;;;   user turn and completed steps are already in it), so no completed tool
;;;   runs again. The new record's prompt is the failed one's, RETRY-OF its
;;;   revision id. Head not failed → NOTHING-TO-RETRY ("the last turn did
;;;   not fail; nothing to retry", exit 2, RPC -32031).
;;;
;;; TURN TIMEOUT (cl-stack-code#19). No fixed cap anywhere in the product:
;;;   a turn ends on its result, an interrupt or max turns. turnTimeoutMs /
;;;   --turn-timeout, when set, arms one loop timer per turn; when it fires
;;;   the run is canceled and the turn ends with TURN-TIMEOUT (subtype
;;;   "error_turn_timeout", message naming the setting or the flag that set
;;;   it, exit 124), committed as :FAILED.
;;;
;;; COMPACTION RECORDS. A compaction changes what the model sees, not the
;;;   history. MAKE-COMPACTION-MARKER &key summary keep at reason
;;;   tokens-before instructions → a plist (:summary TURNS :keep K :at N
;;;   :reason R :tokens-before T :instructions REV). AT is the number of
;;;   turns of the full conversation (SESSION-FULL-TURNS) before the
;;;   compaction point; the model's context from there on is SUMMARY then
;;;   the last KEEP of those AT turns, then every later turn. INSTRUCTIONS is
;;;   the id of the session's instruction-set revision current at the
;;;   compaction: H3e-1's INSTRUCTION-SET-CURRENT of the session's
;;;   INSTRUCTION-SET (reached through %INSTRUCTION-SET-REVISION, a
;;;   placeholder until H3e-1 lands; see .team-solve/task.md). A compaction
;;;   never commits the instruction set, so that revision does not change.
;;;   Each turn record carries its turn's markers (RECORD-COMPACTIONS). A
;;;   manual /compact while idle commits a record of its own: prompt "",
;;;   no turns, one marker, finish :STOP, provenance (:kind :compaction),
;;;   message "/compact".
;;;   SESSION-TURNS (what a resume sends) on a line with markers →
;;;   COMPACTED-SESSION-TURNS records: the latest marker applied (summary
;;;   turns, which are :SYSTEM turns starting "[summary]", are kept; other
;;;   :SYSTEM turns are dropped as before). SESSION-FULL-TURNS store
;;;   &optional designator → the whole history, markers ignored (export,
;;;   /tree, session entries, rewinds and session/load use it). A rewind to
;;;   before a compacting turn drops its marker with it.
;;;   Session entries show a marker as a notice "compacted: N turns
;;;   summarized (REASON)"; continuation turns (AGENT:CONTINUATION-TURN-P)
;;;   are hidden.
;;;
;;; INSTRUCTIONS AFTER COMPACTION. The summary replaces lazily injected
;;;   instruction turns (nested AGENTS.md, path-scoped rules) with the rest.
;;;   The next model call re-injects the ones the summary covered, verbatim,
;;;   from the instruction-set revision current at the compaction: H3e-1's
;;;   INSTRUCTION-SET-LOADED-RULES store id, each rule's text through
;;;   INSTRUCTION-TEXT (%INSTRUCTION-SET-REINJECTION, a placeholder until
;;;   H3e-1 lands). Not re-discovery, and not H3e-1's interim
;;;   FORGET-INSTRUCTIONS, which commits a :FORGET revision: H3f replaces it
;;;   (the code-instruction-discovery keeps the rules loaded; nothing is
;;;   committed).
;;;   The system prompt (base prompt, AGENTS.md chain, always-on rules, the
;;;   skill listing) is the :SYSTEM turn, which compaction keeps.
;;;
;;; TOOL OUTPUT CAP. MAKE-CAPPED-TOOL-SOURCE source &key max-chars
;;;   output-dir → a tool source (ai-agent-protocol 0.15.0's wrapper source)
;;;   whose results longer than MAX-CHARS (maxToolResultChars) are cut by
;;;   CAP-TOOL-RESULT. It wraps every source after the agent-tools ones
;;;   (lisp, MCP, skills, units, which have no cap of their own); file and
;;;   shell results are already capped by agent-tools. CAP-TOOL-RESULT text
;;;   max-chars &key ref → TEXT when it fits; else the head and tail as
;;;   AGENT-TOOLS:TRUNCATE-SHELL-OUTPUT cuts them, then a line
;;;   "[truncated: N characters; the full output is in REF]" (REF NIL →
;;;   "[truncated: N characters]"). The full text goes to
;;;   <session directory>/tool-output/<tool-use id>.txt (written atomically,
;;;   created with the session's first write) and REF is its native
;;;   namestring. The session record keeps the capped text (what the model
;;;   saw).
;;;
;;; TUI. Core events (:retry PLIST) (:compacted PLIST) (:continuation PLIST)
;;;   (:truncated PLIST); effects (:compact TEXT-OR-NIL) and (:retry-turn).
;;;   While a retry waits, the spinner row reads RETRY-NOTICE-TEXT plist
;;;   seconds-left: "retrying in 4 s (503 overloaded) · attempt 2 of 4 · Esc
;;;   to stop" (status in parentheses only when known; reason words:
;;;   "rate limited", "overloaded", "connection", "context overflow",
;;;   "output truncated"). Esc cancels the wait and the turn (H3b's
;;;   interrupt: the queue goes back to the input). A compaction adds the
;;;   notice "compacted the conversation (N → M turns, REASON)". A failed
;;;   turn's error entry ends with " — /retry to send it again" when the
;;;   failure is a MODEL-ERROR or TURN-TIMEOUT. /compact [TEXT] (idle only;
;;;   busy → H3b's "not available while a turn runs" error): compacts now,
;;;   TEXT appended to the summary prompt. /retry (idle only): NOTHING-TO-
;;;   RETRY as an error entry when the last turn did not fail. The status
;;;   line's right side becomes "<in> in · <out> out · ctx P%" (P the last
;;;   response's CONTEXT-USAGE-PCT; no " · ctx" part before the first
;;;   response). CONTEXT-STATUS-TEXT used window → "ctx P%".
;;;
;;; SDK. CLIENT-COMPACT session &key instructions → the compact event object
;;;   or NIL when nothing was compacted (busy → TURN-BUSY). CLIENT-RETRY-TURN
;;;   session → a CODE-TURN, like CLIENT-TURN (NOTHING-TO-RETRY when the
;;;   head did not fail).
;;; RPC. "session/compact" {session_id, instructions?} → {"compacted": bool,
;;;   "event": the compact object or null}; "turn/retry" {session_id} → as
;;;   turn/start. Codes: MODEL-ERROR -32030 (data: "error_class", "status",
;;;   "retry_after_ms"), NOTHING-TO-RETRY -32031, TURN-TIMEOUT -32032.

(export '(resilience-agent-extra make-settings-retry-policy
          effective-context-window context-usage-pct context-status-text
          retry-event-object compact-event-object continuation-event-object
          truncated-event-object
          failed-turn-p nothing-to-retry
          make-compaction-marker compacted-session-turns session-full-turns
          record-compactions record-retry-of
          make-capped-tool-source cap-tool-result
          retry-notice-text client-compact client-retry-turn))

(define-condition nothing-to-retry (code-usage-error) ()
  (:documentation "--retry, /retry or turn/retry when the last turn did not fail. Exit 2.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                "the last turn did not fail; nothing to retry")))))

;;; Compaction markers (given).

(defun make-compaction-marker (&key summary keep at reason tokens-before instructions)
  "A compaction marker plist (see the header)."
  (check-type keep (integer 0 *))
  (check-type at (integer 0 *))
  (check-type reason (member :threshold :overflow :manual))
  (list :summary (copy-list summary) :keep keep :at at :reason reason
        :tokens-before tokens-before :instructions instructions))

(defun %compaction-marker-content (marker)
  "MARKER with its summary turns as LLM:TURN-STATEs (record content)."
  (let ((copy (copy-list marker)))
    (setf (getf copy :summary) (mapcar #'llm:turn-state (getf marker :summary)))
    copy))

(defun %content-compaction-marker (content)
  "The inverse of %COMPACTION-MARKER-CONTENT."
  (let ((copy (copy-list content)))
    (setf (getf copy :summary) (mapcar #'llm:state-turn (getf content :summary)))
    copy))

;;; H3e-1's instruction-set API (the placeholders of the contract, filled).

(defun %instruction-set-revision (set)
  "The id of the session's current instruction-set revision: H3e-1's
INSTRUCTION-SET-CURRENT of SET (the session's INSTRUCTION-SET), or NIL."
  (and set (instruction-set-current set)))

(defun %instruction-set-reinjection (store revision &key rules)
  "The instruction directives to re-inject after a compaction: the rules in
context at REVISION of the INSTRUCTION-STORE STORE (H3e-1's
INSTRUCTION-SET-LOADED-RULES), each with the body its revision recorded
(INSTRUCTION-TEXT), in load order. RULES are the discovery's path-scoped rule
directives, which give each path its pattern; a path no rule knows, or a text
that is missing, is skipped (a re-injection never fails the run)."
  (when (and store revision)
    (let ((loaded (handler-case (instruction-set-loaded-rules store revision)
                    (instruction-set-error () nil)))
          (texts (handler-case (%revision-rule-texts store revision)
                   (instruction-set-error () nil))))
      (loop for native in loaded
            for rule = (find native rules :key #'%rule-native :test #'string=)
            for hash = (cdr (assoc native texts :test #'string=))
            for body = (and hash (handler-case (instruction-text store hash)
                                   (instruction-set-error () nil)))
            when rule
              collect (let ((directive (%rule-directive rule)))
                        (when (and body (string/= body (steer:steer-directive-body directive)))
                          (setf directive
                                (steer:make-steer-directive
                                 :kind :rule
                                 :name (steer:steer-directive-name directive)
                                 :body body
                                 :path (steer:steer-directive-path directive)
                                 :extra (list* :hash hash
                                               (let ((extra (copy-list (steer:steer-directive-extra directive))))
                                                 (remf extra :hash)
                                                 extra)))))
                        directive)))))

(defun %revision-rule-texts (store revision)
  "→ alist (native path . text hash) of the rules REVISION recorded."
  (loop for entry in (getf (cdr (assoc :rules (read-instruction-set store revision))) :found)
        when (and (getf entry :path) (getf entry :text))
          collect (cons (getf entry :path) (getf entry :text))))

;;; Instructions after compaction: a run's copy of the session's discovery.
;;; Inside a run only the loop's compaction (%INSTRUCTIONS-COMPACTED) forgets
;;; all instructions; it first collects LIST-DIRECTIVES' paths to re-inject.

(defmethod steer:list-directives :around ((discovery code-instruction-discovery) &key)
  ;; A run copy also names its loaded rules, so the turn after a compaction
  ;; calls DISCOVER-INSTRUCTIONS (and gets them from PENDING).
  (if (%discovery-run-copy-p discovery)
      (append (call-next-method)
              (loop for native in (discovery-loaded-rules discovery)
                    for rule = (find native (discovery-rules discovery)
                                     :key #'%rule-native :test #'string=)
                    when (and rule (not (rule-always-p rule)))
                      collect (%rule-directive rule)))
      (call-next-method)))

(defmethod steer:forget-instructions :around ((discovery code-instruction-discovery) &key path)
  (if (and (%discovery-run-copy-p discovery) (null path))
      (let* ((set (car (%discovery-link discovery)))
             (store (and set (instruction-set-store set))))
        ;; The rules stay loaded and the set is not committed; the loaded
        ;; ones come back verbatim from the current revision.
        (setf (%discovery-pending discovery)
              (%instruction-set-reinjection store (%instruction-set-revision set)
                                            :rules (discovery-rules discovery)))
        (let ((*%keep-loaded-rules* t))
          (call-next-method)))
      (call-next-method)))

(defmethod steer:discover-instructions :around ((discovery code-instruction-discovery) path
                                                &key (mark t))
  (declare (ignore path mark))
  (if (and (%discovery-run-copy-p discovery) (%discovery-pending discovery)
           (not *%rule-pass*))
      (append (shiftf (%discovery-pending discovery) '()) (call-next-method))
      (call-next-method)))

;;; Agent extras and windows.

(defun %resilience (settings)
  "RESILIENCE-SETTINGS of SETTINGS (a SETTINGS, or already such a plist)."
  (if (and (listp settings) (keywordp (first settings)))
      settings
      (resilience-settings settings)))

(defun make-settings-retry-policy (settings)
  (let ((r (%resilience settings)))
    (llm:make-retry-policy :max-attempts (getf r :retry-max-attempts)
                           :base-delay (/ (getf r :retry-initial-delay-ms) 1000)
                           :max-delay (/ (getf r :retry-max-delay-ms) 1000)
                           :jitter +retry-jitter+)))

(defun %designator-parts (designator)
  "\"openai:qwen3\" → (values \"qwen3\" \"openai\"); \"mock\" → (values NIL NIL)."
  (let ((colon (and (stringp designator) (position #\: designator))))
    (if colon
        (values (subseq designator (1+ colon)) (subseq designator 0 colon))
        (values nil nil))))

(defun effective-context-window (settings backend designator)
  "→ (values tokens source); see the header. Never signals."
  (let ((given (getf (%resilience settings) :context-window)))
    (multiple-value-bind (model provider) (%designator-parts designator)
      (cond ((integerp given) (values given :settings))
            ((and (consp given)
                  (some (lambda (key)
                          (and key (cdr (assoc key given :test #'string=))))
                        (list designator model provider "*")))
             (values (some (lambda (key)
                             (and key (cdr (assoc key given :test #'string=))))
                           (list designator model provider "*"))
                     :settings))
            (t
             (let ((n (and backend
                           (handler-case (llm:context-window backend (or model designator))
                             (error () nil)))))
               (if (and (integerp n) (plusp n))
                   (values n :provider)
                   (values +default-context-window+ :default))))))))

(defun %run-max-tokens (settings)
  (let ((llm (and (typep settings 'settings) (model-params-llm-settings settings))))
    (and llm (llm:llm-settings-max-tokens llm))))

(defun resilience-agent-extra (settings backend &key model)
  "The H3f keys of the agent settings' :EXTRA (see the header). MODEL is the
designator the window is looked up for."
  (let* ((r (%resilience settings))
         (window (effective-context-window settings backend model))
         (length-retry (or (getf r :length-retry-max-tokens)
                           (let ((max (%run-max-tokens settings)))
                             (and (integerp max) (min +max-length-retry-tokens+ (* 2 max)))))))
    (append
     (list :retry-policy (make-settings-retry-policy r)
           :compaction (conversation-protocol:make-summary-memory
                        :backend backend :tail-tokens (min 15000 (floor window 4)))
           :max-continuations (getf r :max-continuations))
     (and (getf r :auto-compact-enabled)
          (list :compact-at (floor (* window (getf r :auto-compact-threshold-pct)) 100)))
     (and length-retry (list :length-retry-max-tokens length-retry)))))

(defun context-usage-pct (used window)
  (if (and (realp window) (plusp window))
      (min 999 (floor (* 100 (or used 0)) window))
      0))

(defun context-status-text (used window)
  (format nil "ctx ~d%" (context-usage-pct used window)))

;;; Events.

(defun %reason-name (reason)
  (substitute #\_ #\- (string-downcase (string reason))))

(defun %ms (seconds)
  (if (realp seconds) (round (* 1000 seconds)) :null))

(defun %or-null (x) (if (null x) :null x))

(defun %retry-event-keys (plist &optional secrets)
  (let ((c (getf plist :condition)))
    (list "subtype" "retry"
          "step" (%or-null (getf plist :step))
          "attempt" (%or-null (getf plist :attempt))
          "max_attempts" (%or-null (getf plist :max-attempts))
          "delay_ms" (%ms (or (getf plist :delay) 0))
          "reason" (%reason-name (or (getf plist :reason) :transient))
          "status" (%or-null (getf plist :status))
          "retry_after_ms" (%ms (getf plist :retry-after))
          "error" (if c
                      (redact-secrets (let ((*print-pretty* nil)) (princ-to-string c))
                                      (or secrets (getf plist :secrets)))
                      :null))))

(defun %compact-event-keys (plist)
  (list "subtype" "compact"
        "reason" (%reason-name (or (getf plist :reason) :threshold))
        "turns_before" (%or-null (getf plist :before))
        "turns_after" (%or-null (getf plist :after))
        "tokens_before" (%or-null (getf plist :tokens-before))
        "context_window" (%or-null (getf plist :context-window))))

(defun %continuation-event-keys (plist)
  (list "subtype" "continuation"
        "step" (%or-null (getf plist :step))
        "count" (%or-null (getf plist :count))
        "max" (%or-null (getf plist :max))))

(defun %truncated-event-keys (plist)
  (list "subtype" "truncated"
        "step" (%or-null (getf plist :step))
        "tool_use_ids" (coerce (getf plist :calls) 'vector)
        "max_tokens" (%or-null (getf plist :max-tokens))))

(defun retry-event-object (plist)
  (apply #'%json-object "type" "system" (%retry-event-keys plist)))

(defun compact-event-object (plist)
  (apply #'%json-object "type" "system" (%compact-event-keys plist)))

(defun continuation-event-object (plist)
  (apply #'%json-object "type" "system" (%continuation-event-keys plist)))

(defun truncated-event-object (plist)
  (apply #'%json-object "type" "system" (%truncated-event-keys plist)))

(defun %resilience-init-keys (settings window source)
  "The init event's H3f keys (always present)."
  (let ((r (%resilience settings)))
    (list "context_window" window
          "context_window_source" (string-downcase (string source))
          "auto_compact" (%json-object "enabled" (and (getf r :auto-compact-enabled) t)
                                       "threshold_pct" (getf r :auto-compact-threshold-pct))
          "retry" (%json-object "max_attempts" (getf r :retry-max-attempts)
                                "initial_delay_ms" (getf r :retry-initial-delay-ms)
                                "max_delay_ms" (getf r :retry-max-delay-ms))
          "request_timeout_ms" (%or-null (getf r :request-timeout-ms))
          "turn_timeout_ms" (%or-null (getf r :turn-timeout-ms)))))

(defun %reason-words (reason)
  (case reason
    (:rate-limit "rate limited")
    (:overloaded "overloaded")
    (:transient "connection")
    (:context-overflow "context overflow")
    (:output-truncated "output truncated")
    (t (string-downcase (string (or reason "retry"))))))

(defun retry-notice-text (plist seconds-left)
  (let ((status (getf plist :status))
        (attempt (getf plist :attempt))
        (max (getf plist :max-attempts)))
    (format nil "retrying in ~d s (~@[~a ~]~a)~@[ · attempt ~d~]~@[ of ~d~] · Esc to stop"
            (max 0 (ceiling (or seconds-left 0)))
            status (%reason-words (getf plist :reason))
            (and attempt (1+ attempt)) (and attempt max))))

(defun compaction-notice-text (marker)
  "A session entry's notice for a compaction MARKER."
  (format nil "compacted: ~d turns summarized (~(~a~))"
          (max 0 (- (getf marker :at 0) (getf marker :keep 0)))
          (getf marker :reason)))

(defun compact-notice-text (plist)
  "The TUI's notice for a :COMPACTED payload."
  (format nil "compacted the conversation (~a → ~a turns, ~(~a~))"
          (getf plist :before) (getf plist :after) (getf plist :reason)))

;;; Failed turns, compaction records.

(defun failed-turn-p (store)
  (let ((head (session-head store)))
    (and head (eq :failed (record-finish (revision-record head))) t)))

(defun %fold-record-turns (records)
  "The full conversation of RECORDS (root first), markers ignored, no :SYSTEM turns."
  (let ((turns '()))
    (dolist (record records)
      (setf turns (if (record-replace-p record)
                      (copy-list (record-turns record))
                      (append turns (record-turns record)))))
    (remove :system turns :key #'llm:llm-turn-role)))

(defun compacted-session-turns (records)
  "The conversation of RECORDS with the latest compaction marker applied."
  (let ((full (%fold-record-turns records))
        (marker (loop for record in (reverse records)
                      for markers = (record-compactions record)
                      when markers return (car (last markers)))))
    (if (null marker)
        full
        (let ((at (min (getf marker :at) (length full))))
          (append (copy-list (getf marker :summary))
                  (last (subseq full 0 at) (getf marker :keep))
                  (nthcdr at full))))))

(defun session-full-turns (store &optional (designator +head-ref+))
  (%fold-record-turns (session-records store designator)))

;;; Tool output cap.

(defun cap-tool-result (text max-chars &key ref)
  (if (or (not (stringp text)) (null max-chars) (<= (length text) max-chars))
      text
      (let* ((n (length text))
             (head-max (floor max-chars 2))
             (lf (position #\Newline text :end head-max :from-end t))
             (head-end (if lf (1+ lf) head-max))
             (tail-start (- n (- max-chars head-end))))
        (unless (and (> tail-start 0) (char= (char text (1- tail-start)) #\Newline))
          (let ((next (position #\Newline text :start tail-start)))
            (when next (setf tail-start (1+ next)))))
        (with-output-to-string (s)
          (write-string text s :end head-end)
          (unless (or (zerop head-end) (char= (char text (1- head-end)) #\Newline))
            (terpri s))
          (write-string text s :start tail-start)
          (unless (char= (char text (1- n)) #\Newline)
            (terpri s))
          (format s "[truncated: ~d characters~@[; the full output is in ~a~]]" n ref)))))

(defclass capped-tool-source (agent:wrapper-tool-source)
  ((max-chars :initarg :max-chars :reader capped-tool-source-max-chars)
   (output-dir :initarg :output-dir :initform nil :reader capped-tool-source-output-dir))
  (:documentation "H3f: a wrapper whose long results are cut by CAP-TOOL-RESULT."))

(defun make-capped-tool-source (source &key (max-chars +default-max-tool-result-chars+)
                                         output-dir)
  (make-instance 'capped-tool-source :inner source :max-chars max-chars
                                     :output-dir output-dir))

(defun %safe-file-name (id)
  (let ((name (map 'string (lambda (c) (if (or (alphanumericp c) (member c '(#\- #\_))) c #\_))
                   (or id ""))))
    (if (plusp (length name)) name (format nil "out-~36r" (random (expt 36 8))))))

(defun %save-full-output (dir id text)
  "TEXT into DIR/<id>.txt (atomic). → its native namestring, or NIL."
  (when dir
    (handler-case
        (let ((file (merge-pathnames (make-pathname :name (%safe-file-name id) :type "txt")
                                     (uiop:ensure-directory-pathname dir))))
          (ensure-directories-exist file)
          (p:write-text file text :atomic t)
          (uiop:native-namestring file))
      (error () nil))))

(defun %cap-result (source result context)
  (let ((max (capped-tool-source-max-chars source)))
    (flet ((cap (text)
             (if (and (stringp text) max (> (length text) max))
                 (let* ((inv (and (listp context) (getf context :invocation)))
                        (id (and inv (agent:agent-invocation-id inv)))
                        (ref (%save-full-output (capped-tool-source-output-dir source) id text)))
                   (cap-tool-result text max :ref ref))
                 text)))
      (typecase result
        (string (cap result))
        (agent:agent-tool-output
         (let ((text (agent:agent-tool-output-text result)))
           (if (and (stringp text) max (> (length text) max))
               (agent:make-agent-tool-output :text (cap text)
                                             :parts (agent:agent-tool-output-parts result)
                                             :structured (agent:agent-tool-output-structured result))
               result)))
        (t result)))))

(defmethod agent:invoke-tool-async ((source capped-tool-source) name arguments
                                    &key context callback error-callback)
  (agent:invoke-tool-async (agent:tool-source-inner source) name arguments
                           :context context
                           :callback (lambda (result)
                                       (when callback
                                         (funcall callback (%cap-result source result context))))
                           :error-callback error-callback))

;; WRAPPER-TOOL-SOURCE delegates only the four core generic functions; the
;; permission resources and the instruction paths of the inner source must
;; hold for the capped one too (skill(NAME) rules, path-scoped rules).
(defmethod agent:tool-permission-resources ((source capped-tool-source) name arguments
                                            &key context)
  (agent:tool-permission-resources (agent:tool-source-inner source) name arguments
                                   :context context))

(defmethod agent:tool-permission-always-resources ((source capped-tool-source) name arguments
                                                   &key context)
  (agent:tool-permission-always-resources (agent:tool-source-inner source) name arguments
                                          :context context))

(defmethod agent:tool-instruction-paths ((source capped-tool-source) name arguments
                                         &key context)
  (agent:tool-instruction-paths (agent:tool-source-inner source) name arguments
                                :context context))

(defun %capped-sources (sources settings output-dir)
  "SOURCES for the agent: the first two (agent-tools' files and shell, capped
already) as they are, every later one wrapped by MAKE-CAPPED-TOOL-SOURCE."
  (let ((max (getf (%resilience settings) :max-tool-result-chars)))
    (append (subseq sources 0 (min 2 (length sources)))
            (mapcar (lambda (s) (make-capped-tool-source s :max-chars max :output-dir output-dir))
                    (nthcdr 2 sources)))))

(defun %tool-output-dir (store)
  (and store (merge-pathnames "tool-output/" (session-directory store))))

;;; The idle /compact record.

(defun commit-compaction-record (store marker &key model (permission-mode :default)
                                                   instructions)
  "Commit an idle compaction's record on STORE: prompt \"\", no turns, MARKER,
finish :STOP, provenance (:kind :compaction), message \"/compact\". → (values
revision store-it-went-to); a conflict forks as a turn's commit does."
  (let ((record (make-turn-record :prompt "" :compactions (list marker) :finish :stop
                                  :model model :permission-mode (or permission-mode :default)
                                  :instructions instructions)))
    (handler-bind ((session-conflict
                     (lambda (c)
                       (let ((restart (find-restart 'fork-session c)))
                         (when restart (invoke-restart restart))))))
      (commit-turn store record :message "/compact"
                                :provenance (list :kind :compaction :version +version+)))))
