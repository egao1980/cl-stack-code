(in-package #:cl-stack-code)

;;; H3f (0.14.0) — resilience, part 1: settings, flags, conditions, the
;;; failure taxonomy and exit codes. Part 2 (src/resilience.lisp) holds the
;;; runtime: the agent extras, events, compaction records, tool-output caps,
;;; the TUI, SDK and RPC pieces.
;;;
;;; The product classifies and reports; the stack detects and retries:
;;; llm-protocol 0.7.0 types every provider failure (egao1980/llm-protocol#12),
;;; the backends map their wire errors onto those types (llm-protocol-openai
;;; #20, llm-protocol-anthropic #7), and ai-agent-protocol 0.16.0's loop
;;; retries, continues and compacts (egao1980/ai-agent-protocol, H3f
;;; contract). Nothing here parses a provider's error text.
;;;
;;; SETTINGS (keys of settings.json, merged per key across user, project,
;;; local and the flag layer, the later layer wins, like "checkpoints"):
;;;
;;;   "retry": {"maxAttempts": 4, "initialDelayMs": 1000, "maxDelayMs": 30000}
;;;       maxAttempts: integer 1..20 (attempts in all; 1 = never retry);
;;;       initialDelayMs: integer 0..600000; maxDelayMs: integer 0..3600000,
;;;       >= initialDelayMs after the merge (else the merged value is
;;;       raised to initialDelayMs). Each key merges on its own.
;;;   "requestTimeoutMs": integer >= 1000, or null (unset: the backend's own
;;;       default). The per-request model timeout, given to the backend
;;;       (APPLY-REQUEST-TIMEOUT, seconds = ms / 1000). The backend decides
;;;       what it means (llm-protocol-openai#13: an idle timeout for streams).
;;;   "turnTimeoutMs": integer >= 1000, or null (unset = no limit, the
;;;       default; cl-stack-code#19). A whole turn's wall-clock limit.
;;;   "contextWindow": integer >= 1024, or an object whose keys are model
;;;       designators ("openai:qwen3"), bare model ids ("qwen3"), provider
;;;       names ("openai") or "*", and whose values are integers >= 1024.
;;;       Objects merge key by key across layers.
;;;   "autoCompact": {"enabled": true, "thresholdPct": 80}; enabled boolean,
;;;       thresholdPct integer 50..95.
;;;   "maxContinuations": integer 0..10 (default 2).
;;;   "lengthRetryMaxTokens": integer >= 256, or null (unset: twice the
;;;       run's max tokens when one is set, capped at 65536; no retry when
;;;       the run sets none).
;;;   "maxToolResultChars": integer >= 1000 (default 50000, agent-tools'
;;;       own cap).
;;;
;;;   A wrong type signals SETTINGS-ERROR with the key path ("retry",
;;;   "retry.maxAttempts", "contextWindow", "contextWindow.openai:qwen3",
;;;   "autoCompact.thresholdPct", …) and the message "must be …". The layer
;;;   value is a plist in the SETTINGS's RESILIENCE slot: :RETRY-MAX-ATTEMPTS
;;;   :RETRY-INITIAL-DELAY-MS :RETRY-MAX-DELAY-MS :REQUEST-TIMEOUT-MS
;;;   :TURN-TIMEOUT-MS :CONTEXT-WINDOW (an integer, or an alist (key . n))
;;;   :AUTO-COMPACT-ENABLED (T or :FALSE) :AUTO-COMPACT-THRESHOLD-PCT
;;;   :MAX-CONTINUATIONS :LENGTH-RETRY-MAX-TOKENS :MAX-TOOL-RESULT-CHARS. A
;;;   JSON null sets the key to :NULL (unset again, as "env" does).
;;;
;;;   RESILIENCE-SETTINGS settings → a plist with every key, defaults filled
;;;   in (+DEFAULT-…+), :NULL and :FALSE resolved (unset → NIL; :FALSE →
;;;   NIL), the merged :CONTEXT-WINDOW kept as given.
;;;
;;; FLAGS (the flag layer, the same plist keys):
;;;   --max-retries N        N >= 0 → :RETRY-MAX-ATTEMPTS N+1 (0 = no retry)
;;;   --request-timeout S    seconds >= 1 → :REQUEST-TIMEOUT-MS S*1000
;;;   --turn-timeout S       seconds >= 1 → :TURN-TIMEOUT-MS S*1000
;;;   --context-window N     N >= 1024 → :CONTEXT-WINDOW N
;;;   --no-auto-compact      :AUTO-COMPACT-ENABLED :FALSE
;;;   A bad value is a CODE-USAGE-ERROR "--max-retries must be an integer >=
;;;   0, not \"x\"" (likewise "--request-timeout must be a number of seconds
;;;   >= 1", "--turn-timeout …", "--context-window must be an integer >=
;;;   1024"). Seconds may be decimals ("1.5" → 1500 ms). %RESILIENCE-FLAGS
;;;   builds the plist; PARSE-ARGUMENTS calls it only when one of these
;;;   flags is given.
;;;   --retry (an INVOCATION flag, INVOCATION-RETRY-P): with --continue or
;;;   --resume and no prompt, re-send the session's last turn when it
;;;   failed (src/resilience.lisp, "Retrying a failed turn"). Without
;;;   --continue / --resume: "--retry needs --continue or --resume"; with a
;;;   prompt: "--retry takes no prompt" (CHECK-RETRY-FLAGS, exit 2).
;;;
;;; FAILURE TAXONOMY. CLASSIFY-MODEL-FAILURE condition &key provider url
;;;   model attempts → a MODEL-ERROR (MAKE-CONDITION, not signalled) or NIL.
;;;   CONDITION is what the run failed with: an llm-protocol condition, an
;;;   AI-AGENT-PROTOCOL:AGENT-GENERATE-ERROR (its cause is classified), or
;;;   anything else (→ NIL: not a model failure). By type, first match:
;;;     LLM-CONTEXT-OVERFLOW     → MODEL-CONTEXT-LENGTH-EXCEEDED
;;;     LLM-RATE-LIMITED         → MODEL-RATE-LIMITED (retry-after copied)
;;;     LLM-OVERLOADED           → MODEL-OVERLOADED
;;;     LLM-AUTH-ERROR           → MODEL-AUTH-ERROR
;;;     LLM-NOT-FOUND            → MODEL-UNAVAILABLE
;;;     LLM-TRANSPORT-ERROR      → MODEL-TRANSPORT-ERROR (kind copied)
;;;     LLM-INCOMPLETE-RESPONSE  → MODEL-TRANSPORT-ERROR (kind :reset)
;;;     other LLM-HTTP-ERROR     → MODEL-HTTP-ERROR (status copied)
;;;   A raw http-protocol transport condition that a backend did not wrap is
;;;   classified through LLM-PROTOCOL:TRANSPORT-ERROR-KIND-FOR as
;;;   MODEL-TRANSPORT-ERROR too. PROVIDER, URL, MODEL default to the cause's
;;;   own (LLM-ERROR-PROVIDER …); ATTEMPTS is how many calls were made.
;;;
;;;   The message (MODEL-FAILURE-MESSAGE c, also the :report) names the
;;;   cause, the provider, the base URL and the model, and never a secret:
;;;     "anthropic (https://api.anthropic.com) rejected the API key for model
;;;      claude-x (HTTP 401): <provider text>; check ANTHROPIC_API_KEY"
;;;     "openai (http://127.0.0.1:1234/v1) has no model qwen9 (HTTP 404): …"
;;;     "openai (http://127.0.0.1:1234/v1) could not be reached after 4
;;;      attempts: connection failed: …"
;;;     "anthropic is overloaded (HTTP 529) after 4 attempts: …"
;;;     "openai rate-limited the request (HTTP 429) after 4 attempts; it
;;;      asked to wait 30 s: …"
;;;     "the conversation does not fit model qwen3's context window (65536
;;;      tokens) even after compacting: …; start a new session (/clear),
;;;      /compact with instructions, or set contextWindow"
;;;   The key hint names the provider's key variable (+PROVIDER-KEY-VARIABLES+).
;;;   REDACT-SECRETS text secrets → TEXT with each secret (strings of 8+
;;;   characters, from the effective env values of +PROVIDER-KEY-VARIABLES+)
;;;   replaced by "[redacted]", and so is any 8+ character prefix of one
;;;   that appears (providers echo "sk-ant-api03-ab…"). Every model-failure
;;;   message passes through it.
;;;
;;; EXIT CODES. 0 success; 1 the run failed (also MODEL-CONTEXT-LENGTH-
;;;   EXCEEDED and MODEL-HTTP-ERROR); 2 usage / configuration; **3** the
;;;   model provider failed: unreachable, rate-limited or overloaded after
;;;   the retries, auth rejected, model unavailable (MODEL-PROVIDER-ERROR and
;;;   its subtypes); **124** the turn timed out (TURN-TIMEOUT, the timeout(1)
;;;   convention); 130 interrupted.
;;;
;;; RESULT SUBTYPES (stream-json / json "result", -p, the SDK, RPC):
;;;   +MODEL-ERROR-SUBTYPES+ maps each condition type to its subtype; the
;;;   result has "is_error": true, "error" the message, and "error_class"
;;;   (the condition type name, lower case, e.g. "model-overloaded").
;;;
;;; RESTARTS. Where the product sees a generate failure (a HANDLER-BIND on
;;;   AI-AGENT-PROTOCOL:AGENT-GENERATE-ERROR around the run, on the loop),
;;;   it signals (SIGNAL, not ERROR) the classified MODEL-ERROR inside a
;;;   RESTART-CASE offering:
;;;     RETRY                  retry the step now (no backoff wait)
;;;     RETRY-AFTER-COMPACTION compact the conversation, then retry (only
;;;                            when a compaction memory is configured)
;;;     ABORT-TURN             end the turn now with the classified result
;;;     USE-VALUE (response)   use an LLM-RESPONSE as the step's answer
;;;   The restarts map onto the loop's own (RETRY, USE-VALUE, ABORT of
;;;   AGENT-GENERATE-ERROR). A handler that declines leaves the loop's retry
;;;   policy to decide. Headless and the SDK install no handler: the policy
;;;   (settings "retry") decides. The TUI installs none either; it offers
;;;   /retry after a failure (src/resilience.lisp).

(export '(;; settings and flags
          settings-resilience resilience-settings +resilience-setting-keys+
          +default-retry-max-attempts+ +default-retry-initial-delay-ms+
          +default-retry-max-delay-ms+ +retry-jitter+ +default-context-window+
          +default-auto-compact-threshold-pct+ +default-max-continuations+
          +default-max-tool-result-chars+ +max-length-retry-tokens+
          invocation-retry-p check-retry-flags
          ;; taxonomy
          model-error model-error-cause model-error-provider model-error-url
          model-error-model model-error-attempts
          model-provider-error model-transport-error model-transport-error-kind
          model-rate-limited model-rate-limited-retry-after model-overloaded
          model-auth-error model-unavailable model-http-error model-http-error-status
          model-context-length-exceeded model-context-length-window
          model-output-truncated model-output-truncated-tool-use-ids
          model-output-truncated-max-tokens
          turn-timeout turn-timeout-ms turn-timeout-source
          classify-model-failure model-failure-message redact-secrets
          +provider-key-variables+ +model-error-subtypes+
          +exit-model-failure+ +exit-turn-timeout+
          retry-after-compaction abort-turn
          apply-request-timeout))

;;; Constants (given).

(defparameter +resilience-setting-keys+
  '("retry" "requestTimeoutMs" "turnTimeoutMs" "contextWindow" "autoCompact"
    "maxContinuations" "lengthRetryMaxTokens" "maxToolResultChars")
  "The settings.json keys H3f reads.")

(defparameter +default-retry-max-attempts+ 4
  "Attempts in all per model call (Claude Code and Codex retry a few times).")
(defparameter +default-retry-initial-delay-ms+ 1000)
(defparameter +default-retry-max-delay-ms+ 30000)
(defparameter +retry-jitter+ 0.2
  "LLM-PROTOCOL:RETRY-POLICY :JITTER the product uses.")
(defparameter +default-context-window+ 65536
  "Tokens assumed when neither the settings nor the provider name a window.
Low on purpose: an unknown local server may run a small context; a too-large
guess is caught by the reactive compaction, a too-small one only costs an
early summary.")
(defparameter +default-auto-compact-threshold-pct+ 80)
(defparameter +default-max-continuations+ 2)
(defparameter +default-max-tool-result-chars+ 50000)
(defparameter +max-length-retry-tokens+ 65536)

(defparameter +provider-key-variables+
  '(("anthropic" . "ANTHROPIC_API_KEY") ("openai" . "OPENAI_API_KEY"))
  "Provider name → the environment variable holding its key.")

(defparameter +exit-model-failure+ 3)
(defparameter +exit-turn-timeout+ 124)

;;; Conditions (given).

(define-condition model-error (code-error)
  ((cause :initarg :cause :reader model-error-cause :initform nil)
   (provider :initarg :provider :reader model-error-provider :initform nil)
   (url :initarg :url :reader model-error-url :initform nil)
   (model :initarg :model :reader model-error-model :initform nil)
   (attempts :initarg :attempts :reader model-error-attempts :initform nil))
  (:documentation "The model call failed for good (after the loop's retries).
Exit 1, or 3 for a MODEL-PROVIDER-ERROR.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c) (model-failure-message c))))))

(define-condition model-provider-error (model-error) ()
  (:documentation "The provider failed (not the conversation). Exit 3."))

(define-condition model-transport-error (model-provider-error)
  ((kind :initarg :kind :reader model-transport-error-kind :initform :connect)))
(define-condition model-rate-limited (model-provider-error)
  ((retry-after :initarg :retry-after :reader model-rate-limited-retry-after :initform nil)))
(define-condition model-overloaded (model-provider-error) ())
(define-condition model-auth-error (model-provider-error) ())
(define-condition model-unavailable (model-provider-error) ()
  (:documentation "HTTP 404: no such model (or endpoint) at the provider.
Not MODEL-NOT-FOUND, which is an unknown provider in the designator."))

(define-condition model-http-error (model-error)
  ((status :initarg :status :reader model-http-error-status :initform nil))
  (:documentation "Any other HTTP failure (a 400 the provider refused). Exit 1."))

(define-condition model-context-length-exceeded (model-error)
  ((window :initarg :window :reader model-context-length-window :initform nil))
  (:documentation "The conversation does not fit even after compacting. Exit 1."))

(define-condition model-output-truncated (condition)
  ((tool-use-ids :initarg :tool-use-ids :reader model-output-truncated-tool-use-ids
                 :initform nil)
   (max-tokens :initarg :max-tokens :reader model-output-truncated-max-tokens
               :initform nil))
  (:documentation "Signalled (SIGNAL) when a reply was cut at the output
limit and the cut tool call was answered with a tool error. Informational.")
  (:report (lambda (c s)
             (format s "model output truncated at ~a max tokens"
                     (or (model-output-truncated-max-tokens c) "the")))))

(define-condition turn-timeout (code-error)
  ((ms :initarg :ms :reader turn-timeout-ms :initform nil)
   (source :initarg :source :reader turn-timeout-source :initform "turnTimeoutMs"
           :documentation "\"turnTimeoutMs\" or \"--turn-timeout\"."))
  (:documentation "The turn ran longer than turnTimeoutMs. Exit 124.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "the turn timed out after ~a s (~a)"
                                        (and (turn-timeout-ms c)
                                             (/ (turn-timeout-ms c) 1000))
                                        (turn-timeout-source c)))))))

(defmethod condition-exit-code ((condition model-provider-error)) +exit-model-failure+)
(defmethod condition-exit-code ((condition turn-timeout)) +exit-turn-timeout+)

(defparameter +model-error-subtypes+
  '((model-transport-error . "error_model_transport")
    (model-rate-limited . "error_rate_limited")
    (model-overloaded . "error_overloaded")
    (model-auth-error . "error_auth")
    (model-unavailable . "error_model_unavailable")
    (model-context-length-exceeded . "error_context_length")
    (model-http-error . "error_model_http")
    (turn-timeout . "error_turn_timeout"))
  "Condition type → result subtype; the first matching type wins.")

;;; Settings.

(defun %resilience-fail (file key control &rest args)
  (apply #'%settings-fail file key control args))

(defun %int-in-p (value low high)
  "VALUE is an integer in [LOW, HIGH] (HIGH NIL: no upper bound)."
  (and (integerp value) (>= value low) (or (null high) (<= value high))))

(defun %range-text (low high)
  (if high
      (format nil "an integer between ~d and ~d" low high)
      (format nil "an integer >= ~d" low)))

(defun %parse-int-key (file path value low high &key nullable)
  "VALUE (present in the object) checked for KEY PATH: :NULL when it is JSON
null and NULLABLE, else an integer in [LOW, HIGH]."
  (cond ((and nullable (eq value :null)) :null)
        ((%int-in-p value low high) value)
        (t (%resilience-fail file path "must be ~a~:[~;, or null~]"
                             (%range-text low high) nullable))))

(defun %parse-resilience (file object)
  "→ the RESILIENCE plist of the H3f keys present in the settings OBJECT."
  (let ((out '()))
    (flet ((put (key value) (setf out (list* value key out)))
           (entry (table key) (gethash key table)))
      ;; retry
      (multiple-value-bind (value present) (entry object "retry")
        (when present
          (cond ((eq value :null)
                 (put :retry-max-attempts :null)
                 (put :retry-initial-delay-ms :null)
                 (put :retry-max-delay-ms :null))
                ((not (hash-table-p value))
                 (%resilience-fail file "retry"
                                   "must be an object with maxAttempts, initialDelayMs and maxDelayMs"))
                (t
                 (loop for (json key low high) in '(("maxAttempts" :retry-max-attempts 1 20)
                                                    ("initialDelayMs" :retry-initial-delay-ms 0 600000)
                                                    ("maxDelayMs" :retry-max-delay-ms 0 3600000))
                       do (multiple-value-bind (v p) (entry value json)
                            (when p
                              (put key (%parse-int-key file (format nil "retry.~a" json) v
                                                       low high :nullable t)))))))))
      ;; timeouts
      (loop for (json key) in '(("requestTimeoutMs" :request-timeout-ms)
                                ("turnTimeoutMs" :turn-timeout-ms))
            do (multiple-value-bind (v p) (entry object json)
                 (when p (put key (%parse-int-key file json v 1000 nil :nullable t)))))
      ;; contextWindow
      (multiple-value-bind (value present) (entry object "contextWindow")
        (when present
          (put :context-window
               (cond ((eq value :null) :null)
                     ((integerp value) (%parse-int-key file "contextWindow" value 1024 nil))
                     ((hash-table-p value)
                      (let ((alist '()))
                        (maphash (lambda (k v)
                                   (push (cons k (%parse-int-key
                                                  file (format nil "contextWindow.~a" k)
                                                  v 1024 nil))
                                         alist))
                                 value)
                        (nreverse alist)))
                     (t (%resilience-fail
                         file "contextWindow"
                         "must be an integer >= 1024, or an object of model, provider or \"*\" keys with integers >= 1024"))))))
      ;; autoCompact
      (multiple-value-bind (value present) (entry object "autoCompact")
        (when present
          (cond ((eq value :null)
                 (put :auto-compact-enabled :null)
                 (put :auto-compact-threshold-pct :null))
                ((not (hash-table-p value))
                 (%resilience-fail file "autoCompact"
                                   "must be an object with enabled and thresholdPct"))
                (t
                 (multiple-value-bind (v p) (entry value "enabled")
                   (when p
                     (put :auto-compact-enabled
                          (cond ((eq v :null) :null)
                                ((eq v t) t)
                                ((null v) :false)
                                (t (%resilience-fail file "autoCompact.enabled"
                                                     "must be true or false"))))))
                 (multiple-value-bind (v p) (entry value "thresholdPct")
                   (when p
                     (put :auto-compact-threshold-pct
                          (%parse-int-key file "autoCompact.thresholdPct" v 50 95
                                          :nullable t))))))))
      ;; the rest
      (loop for (json key low high) in '(("maxContinuations" :max-continuations 0 10)
                                         ("lengthRetryMaxTokens" :length-retry-max-tokens 256 nil)
                                         ("maxToolResultChars" :max-tool-result-chars 1000 nil))
            do (multiple-value-bind (v p) (entry object json)
                 (when p (put key (%parse-int-key file json v low high :nullable t))))))
    (nreverse out)))

(defun %resilience-keys-present-p (object)
  "True when the settings OBJECT (a hash table) has one of +RESILIENCE-SETTING-KEYS+."
  (some (lambda (key) (nth-value 1 (gethash key object))) +resilience-setting-keys+))

(defun %merge-context-windows (old new)
  "Two :CONTEXT-WINDOW values: alists merge key by key (NEW wins), anything
else is replaced by NEW."
  (if (and (listp old) (listp new) old)
      (let ((out (copy-alist old)))
        (dolist (pair new out)
          (let ((cell (assoc (car pair) out :test #'string=)))
            (if cell
                (setf (cdr cell) (cdr pair))
                (setf out (append out (list (cons (car pair) (cdr pair)))))))))
      new))

(defun %merge-resilience (plists)
  "Per key, the later plist wins; :CONTEXT-WINDOW alists merge key by key."
  (let ((out '()))
    (dolist (plist plists out)
      (loop for (key value) on plist by #'cddr
            do (setf (getf out key)
                     (if (eq key :context-window)
                         (%merge-context-windows (getf out key) value)
                         value))))))

(defun resilience-settings (settings)
  "SETTINGS's H3f keys with the defaults filled in (see the header)."
  (let ((plist (and settings (settings-resilience settings))))
    (flet ((value (key default)
             (let ((v (getf plist key :absent)))
               (case v
                 (:absent default)
                 (:null default)
                 (:false nil)
                 (t v)))))
      (let ((initial (value :retry-initial-delay-ms +default-retry-initial-delay-ms+))
            (max-delay (value :retry-max-delay-ms +default-retry-max-delay-ms+)))
        (list :retry-max-attempts (value :retry-max-attempts +default-retry-max-attempts+)
              :retry-initial-delay-ms initial
              :retry-max-delay-ms (max initial max-delay)
              :request-timeout-ms (value :request-timeout-ms nil)
              :turn-timeout-ms (value :turn-timeout-ms nil)
              :context-window (value :context-window nil)
              :auto-compact-enabled (value :auto-compact-enabled t)
              :auto-compact-threshold-pct (value :auto-compact-threshold-pct
                                                 +default-auto-compact-threshold-pct+)
              :max-continuations (value :max-continuations +default-max-continuations+)
              :length-retry-max-tokens (value :length-retry-max-tokens nil)
              :max-tool-result-chars (value :max-tool-result-chars
                                            +default-max-tool-result-chars+))))))

;;; Flags.

(defun %flag-integer (text)
  "TEXT as a decimal integer (an optional sign, then digits), else NIL."
  (and (stringp text)
       (let ((s (string-trim " " text)))
         (and (plusp (length s))
              (let ((digits (if (member (char s 0) '(#\- #\+)) (subseq s 1) s)))
                (and (plusp (length digits))
                     (every #'digit-char-p digits)
                     (parse-integer s)))))))

(defun %flag-seconds-ms (text)
  "TEXT as decimal seconds (\"600\", \"1.5\") → milliseconds (an integer), or NIL."
  (and (stringp text)
       (let* ((s (string-trim " " text))
              (dot (position #\. s))
              (whole (subseq s 0 (or dot (length s))))
              (frac (if dot (subseq s (1+ dot)) "")))
         (and (plusp (length s))
              (or (plusp (length whole)) (plusp (length frac)))
              (every #'digit-char-p whole)
              (every #'digit-char-p frac)
              (or (null dot) (plusp (length frac)))
              (round (* 1000 (+ (if (plusp (length whole)) (parse-integer whole) 0)
                                (if (plusp (length frac))
                                    (/ (parse-integer frac) (expt 10 (length frac)))
                                    0))))))))

(defun %flag-fail (control &rest args)
  (error 'code-usage-error :message (apply #'format nil control args)))

(defun %resilience-flags (&key max-retries request-timeout turn-timeout context-window
                            no-auto-compact)
  "The flag layer's RESILIENCE plist (see the header)."
  (let ((out '()))
    (when max-retries
      (let ((n (%flag-integer max-retries)))
        (unless (and n (>= n 0))
          (%flag-fail "--max-retries must be an integer >= 0, not ~s" max-retries))
        (setf out (list* :retry-max-attempts (1+ n) out))))
    (loop for (text flag key) in (list (list request-timeout "--request-timeout" :request-timeout-ms)
                                       (list turn-timeout "--turn-timeout" :turn-timeout-ms))
          when text
            do (let ((ms (%flag-seconds-ms text)))
                 (unless (and ms (>= ms 1000))
                   (%flag-fail "~a must be a number of seconds >= 1, not ~s" flag text))
                 (setf out (list* key ms out))))
    (when context-window
      (let ((n (%flag-integer context-window)))
        (unless (and n (>= n 1024))
          (%flag-fail "--context-window must be an integer >= 1024, not ~s" context-window))
        (setf out (list* :context-window n out))))
    (when no-auto-compact
      (setf out (list* :auto-compact-enabled :false out)))
    out))

(defun check-retry-flags (invocation)
  "--retry needs --continue or --resume and takes no prompt (CODE-USAGE-ERROR,
exit 2). → T."
  (when (invocation-retry-p invocation)
    (unless (or (invocation-continue-p invocation) (invocation-resume invocation))
      (%flag-fail "--retry needs --continue or --resume"))
    (when (invocation-prompt invocation)
      (%flag-fail "--retry takes no prompt")))
  t)

;;; Classification.

(defun %cause-details (cause)
  "→ (values provider url model) of an llm-protocol CAUSE, when it has them."
  (typecase cause
    (llm:llm-http-error (values (llm:llm-error-provider cause) (llm:llm-error-url cause)
                                (llm:llm-error-model cause)))
    (llm:llm-transport-error (values (llm:llm-transport-error-provider cause)
                                     (llm:llm-transport-error-url cause)
                                     nil))
    (t (values nil nil nil))))

(defun classify-model-failure (condition &key provider url model attempts secrets)
  "→ the MODEL-ERROR (not signalled) for the run failure CONDITION, or NIL
when it is no model failure (see the header). SECRETS (strings): the message
is computed now and passed through REDACT-SECRETS."
  (let ((cause (if (typep condition 'agent:agent-generate-error)
                   (agent:agent-generate-error-cause condition)
                   condition)))
    (multiple-value-bind (cause-provider cause-url cause-model) (%cause-details cause)
      (let* ((common (list :cause cause
                           :provider (or provider cause-provider)
                           :url (or url cause-url)
                           :model (or model cause-model)
                           :attempts attempts))
             (classified
               (typecase cause
                 (llm:llm-context-overflow
                  (apply #'make-condition 'model-context-length-exceeded common))
                 (llm:llm-rate-limited
                  (apply #'make-condition 'model-rate-limited
                         :retry-after (llm:llm-http-error-retry-after cause) common))
                 (llm:llm-overloaded (apply #'make-condition 'model-overloaded common))
                 (llm:llm-auth-error (apply #'make-condition 'model-auth-error common))
                 (llm:llm-not-found (apply #'make-condition 'model-unavailable common))
                 (llm:llm-transport-error
                  (apply #'make-condition 'model-transport-error
                         :kind (llm:llm-transport-error-kind cause) common))
                 (llm:llm-incomplete-response
                  (apply #'make-condition 'model-transport-error :kind :reset common))
                 (llm:llm-http-error
                  (apply #'make-condition 'model-http-error
                         :status (llm:llm-http-error-status cause) common))
                 (t
                  (let ((kind (and cause (llm:transport-error-kind-for cause))))
                    (and kind
                         (apply #'make-condition 'model-transport-error :kind kind common)))))))
        (if (and classified secrets)
            (apply #'make-condition (type-of classified)
                   :message (redact-secrets (model-failure-message classified) secrets)
                   (append (typecase classified
                             (model-rate-limited
                              (list :retry-after (model-rate-limited-retry-after classified)))
                             (model-transport-error
                              (list :kind (model-transport-error-kind classified)))
                             (model-http-error
                              (list :status (model-http-error-status classified))))
                           common))
            classified)))))

(defun %cause-text (cause)
  "The provider's own text of CAUSE (its message, else its report)."
  (let ((*print-pretty* nil))
    (cond ((null cause) "unknown error")
          ((and (typep cause 'llm:llm-error) (llm:llm-error-message cause)))
          ((and (typep cause 'llm:llm-http-error) (stringp (llm:llm-http-error-body cause))
                (plusp (length (llm:llm-http-error-body cause))))
           (llm:llm-http-error-body cause))
          (t (princ-to-string cause)))))

(defun %cause-status (cause)
  (and (typep cause 'llm:llm-http-error) (llm:llm-http-error-status cause)))

(defun %transport-kind-text (kind)
  (case kind
    (:connect "connection failed")
    (:reset "connection reset")
    (:timeout "timed out")
    (:tls "TLS failed")
    (:canceled "canceled")
    (t "connection failed")))

(defun model-failure-message (condition)
  "The message of a MODEL-ERROR (see the header). Never names a secret: the
key variable, not its value."
  (let* ((cause (model-error-cause condition))
         (provider (or (model-error-provider condition) "the provider"))
         (url (model-error-url condition))
         (where (format nil "~a~@[ (~a)~]" provider url))
         (model (model-error-model condition))
         (attempts (model-error-attempts condition))
         ;; One call is no retry: "after N attempts" only when the loop retried.
         (after (if (and attempts (> attempts 1))
                    (format nil " after ~d attempts" attempts)
                    ""))
         (status (or (%cause-status cause)
                     (and (typep condition 'model-http-error) (model-http-error-status condition))))
         (http (if status (format nil " (HTTP ~a)" status) ""))
         (text (%cause-text cause)))
    (typecase condition
      (model-auth-error
       (format nil "~a rejected the API key~@[ for model ~a~]~a: ~a~@[; check ~a~]"
               where model http text
               (cdr (assoc (model-error-provider condition) +provider-key-variables+
                           :test #'equal))))
      (model-unavailable
       (format nil "~a has no model ~a~a: ~a" where (or model "(unknown)") http text))
      (model-transport-error
       (format nil "~a could not be reached~a: ~a: ~a"
               where after (%transport-kind-text (model-transport-error-kind condition)) text))
      (model-overloaded
       (format nil "~a is overloaded~a~a: ~a" provider http after text))
      (model-rate-limited
       (let ((wait (model-rate-limited-retry-after condition)))
         (format nil "~a rate-limited the request~a~a~@[; it asked to wait ~a s~]: ~a"
                 provider http after
                 (and (realp wait) (if (integerp wait) wait (float wait)))
                 text)))
      (model-context-length-exceeded
       (let ((window (model-context-length-window condition)))
         (format nil "the conversation does not fit ~:[the model~;model ~:*~a~]'s context window~@[ (~a tokens)~] even after compacting: ~a; start a new session (/clear), /compact with instructions, or set contextWindow"
                 model window text)))
      (model-http-error
       (format nil "~a refused the request~@[ for model ~a~]~a: ~a" where model http text))
      (t (format nil "~a failed~@[ for model ~a~]~a: ~a" where model after text)))))

(defun redact-secrets (text secrets)
  "TEXT with each secret of 8+ characters, and any 8+ character prefix of one,
replaced by \"[redacted]\"."
  (let ((secrets (remove-if-not (lambda (s) (and (stringp s) (>= (length s) 8))) secrets)))
    (if (or (null secrets) (not (stringp text)))
        text
        (with-output-to-string (out)
          (let ((i 0) (n (length text)))
            (loop while (< i n)
                  do (let ((best 0))
                       (dolist (secret secrets)
                         (let ((len (or (mismatch secret text :start2 i)
                                        (length secret))))
                           (when (and (>= len 8) (> len best))
                             (setf best len))))
                       (if (plusp best)
                           (progn (write-string "[redacted]" out) (incf i best))
                           (progn (write-char (char text i) out) (incf i))))))))))

(defgeneric apply-request-timeout (backend seconds)
  (:documentation "Give BACKEND (an LLM-BACKEND) the per-request timeout
SECONDS (requestTimeoutMs / 1000). Methods for the built-in openai and
anthropic backends set the request-timeout initarg's accessor that
llm-protocol-openai#13 adds (PLACEHOLDER: its name is that fix's; see
.team-solve/task.md). The default method does nothing and returns NIL, so a
custom provider's backend is left alone. → BACKEND when applied.")
  (:method (backend seconds)
    (declare (ignore backend seconds))
    nil))

(defmethod apply-request-timeout ((backend llm-protocol-openai:openai-compat-backend) seconds)
  (setf (llm-protocol-openai:openai-request-timeout backend) seconds)
  backend)

(defmethod apply-request-timeout ((backend llm-protocol-anthropic:anthropic-backend) seconds)
  (setf (llm-protocol-anthropic:anthropic-request-timeout backend) seconds)
  backend)
