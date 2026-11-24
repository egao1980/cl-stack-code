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

;;; PLACEHOLDERS for H3e-1's amended instruction-set API (see task.md).

(defun %instruction-set-revision (store)
  "PLACEHOLDER(H3e-1): the id of STORE's current instruction-set revision,
i.e. H3e-1's (INSTRUCTION-SET-CURRENT <the session's INSTRUCTION-SET>)."
  (declare (ignore store))
  (%h3f-pending '%instruction-set-revision))

(defun %instruction-set-reinjection (store revision)
  "PLACEHOLDER(H3e-1): the instruction directives to re-inject after a
compaction: H3e-1's (INSTRUCTION-SET-LOADED-RULES store REVISION), each rule's
body read with INSTRUCTION-TEXT, in load order."
  (declare (ignore store revision))
  (%h3f-pending '%instruction-set-reinjection))

;;; Stubs.

(defun resilience-agent-extra (settings backend &key model)
  (declare (ignore settings backend model))
  (%h3f-pending 'resilience-agent-extra))

(defun make-settings-retry-policy (settings)
  (declare (ignore settings))
  (%h3f-pending 'make-settings-retry-policy))

(defun effective-context-window (settings backend designator)
  (declare (ignore settings backend designator))
  (%h3f-pending 'effective-context-window))

(defun context-usage-pct (used window)
  (declare (ignore used window))
  (%h3f-pending 'context-usage-pct))

(defun context-status-text (used window)
  (declare (ignore used window))
  (%h3f-pending 'context-status-text))

(defun retry-event-object (plist)
  (declare (ignore plist))
  (%h3f-pending 'retry-event-object))

(defun compact-event-object (plist)
  (declare (ignore plist))
  (%h3f-pending 'compact-event-object))

(defun continuation-event-object (plist)
  (declare (ignore plist))
  (%h3f-pending 'continuation-event-object))

(defun truncated-event-object (plist)
  (declare (ignore plist))
  (%h3f-pending 'truncated-event-object))

(defun failed-turn-p (store)
  (declare (ignore store))
  (%h3f-pending 'failed-turn-p))

(defun compacted-session-turns (records)
  (declare (ignore records))
  (%h3f-pending 'compacted-session-turns))

(defun session-full-turns (store &optional (designator +head-ref+))
  (declare (ignore store designator))
  (%h3f-pending 'session-full-turns))

(defun make-capped-tool-source (source &key max-chars output-dir)
  (declare (ignore source max-chars output-dir))
  (%h3f-pending 'make-capped-tool-source))

(defun cap-tool-result (text max-chars &key ref)
  (declare (ignore text max-chars ref))
  (%h3f-pending 'cap-tool-result))

(defun retry-notice-text (plist seconds-left)
  (declare (ignore plist seconds-left))
  (%h3f-pending 'retry-notice-text))

(defun client-compact (session &key instructions)
  (declare (ignore session instructions))
  (%h3f-pending 'client-compact))

(defun client-retry-turn (session)
  (declare (ignore session))
  (%h3f-pending 'client-retry-turn))
