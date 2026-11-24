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

(defun %h3f-pending (name)
  (error "cl-stack-code 0.14.0: ~a is not implemented yet (H3f contract)" name))

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

;;; Stubs.

(defun %parse-resilience (file object)
  "→ the RESILIENCE plist of the H3f keys present in the settings OBJECT."
  (declare (ignore file object))
  (%h3f-pending '%parse-resilience))

(defun %resilience-keys-present-p (object)
  "True when the settings OBJECT (a hash table) has one of +RESILIENCE-SETTING-KEYS+."
  (some (lambda (key) (nth-value 1 (gethash key object))) +resilience-setting-keys+))

(defun %merge-resilience (plists)
  "Per key, the later plist wins; :CONTEXT-WINDOW alists merge key by key."
  (declare (ignore plists))
  (%h3f-pending '%merge-resilience))

(defun resilience-settings (settings)
  (declare (ignore settings))
  (%h3f-pending 'resilience-settings))

(defun %resilience-flags (&key max-retries request-timeout turn-timeout context-window
                            no-auto-compact)
  (declare (ignore max-retries request-timeout turn-timeout context-window no-auto-compact))
  (%h3f-pending '%resilience-flags))

(defun check-retry-flags (invocation)
  (declare (ignore invocation))
  (%h3f-pending 'check-retry-flags))

(defun classify-model-failure (condition &key provider url model attempts)
  (declare (ignore condition provider url model attempts))
  (%h3f-pending 'classify-model-failure))

(defun model-failure-message (condition)
  (declare (ignore condition))
  (%h3f-pending 'model-failure-message))

(defun redact-secrets (text secrets)
  (declare (ignore text secrets))
  (%h3f-pending 'redact-secrets))

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
