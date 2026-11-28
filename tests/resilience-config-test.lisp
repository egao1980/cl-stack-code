(in-package #:cl-stack-code/tests)

;;; H3f settings, flags, conditions, classification, messages, exit codes
;;; (src/resilience-config.lisp). No runs here.

(defun rs (&rest layers)
  "RESILIENCE-SETTINGS of LAYERS (JSON strings or SETTINGS) merged."
  (resilience-settings
   (apply #'merge-settings
          (mapcar (lambda (l) (if (stringp l) (parse-settings l) l)) layers))))

(deftest resilience-constants
  (ok (equal '("retry" "requestTimeoutMs" "turnTimeoutMs" "contextWindow" "autoCompact"
               "maxContinuations" "lengthRetryMaxTokens" "maxToolResultChars")
             +resilience-setting-keys+))
  (ok (eql 4 +default-retry-max-attempts+))
  (ok (eql 1000 +default-retry-initial-delay-ms+))
  (ok (eql 30000 +default-retry-max-delay-ms+))
  (ok (eql 65536 +default-context-window+))
  (ok (eql 80 +default-auto-compact-threshold-pct+))
  (ok (eql 2 +default-max-continuations+))
  (ok (eql 50000 +default-max-tool-result-chars+))
  (ok (eql 3 +exit-model-failure+))
  (ok (eql 124 +exit-turn-timeout+))
  (ok (equal "error_overloaded" (cdr (assoc 'model-overloaded +model-error-subtypes+))))
  (ok (member "session/compact" +rpc-methods+ :test #'equal))
  (ok (member "turn/retry" +rpc-methods+ :test #'equal))
  (ok (eql -32030 (cdr (assoc 'model-error +rpc-error-codes+))))
  (ok (eql -32031 (cdr (assoc 'nothing-to-retry +rpc-error-codes+))))
  (ok (eql -32032 (cdr (assoc 'turn-timeout +rpc-error-codes+)))))

(deftest resilience-defaults
  (let ((r (rs "{}")))
    (ok (eql 4 (getf r :retry-max-attempts)))
    (ok (eql 1000 (getf r :retry-initial-delay-ms)))
    (ok (eql 30000 (getf r :retry-max-delay-ms)))
    (ok (null (getf r :request-timeout-ms)))
    (ok (null (getf r :turn-timeout-ms)) "no turn limit by default (#19)")
    (ok (null (getf r :context-window)))
    (ok (eq t (getf r :auto-compact-enabled)))
    (ok (eql 80 (getf r :auto-compact-threshold-pct)))
    (ok (eql 2 (getf r :max-continuations)))
    (ok (null (getf r :length-retry-max-tokens)))
    (ok (eql 50000 (getf r :max-tool-result-chars)))))

(deftest resilience-settings-parse-every-key
  (let ((r (rs "{\"retry\":{\"maxAttempts\":6,\"initialDelayMs\":250,\"maxDelayMs\":5000},
                 \"requestTimeoutMs\":600000,\"turnTimeoutMs\":3600000,
                 \"contextWindow\":{\"openai:qwen3\":32768,\"*\":131072},
                 \"autoCompact\":{\"enabled\":false,\"thresholdPct\":70},
                 \"maxContinuations\":0,\"lengthRetryMaxTokens\":8192,
                 \"maxToolResultChars\":20000}")))
    (ok (eql 6 (getf r :retry-max-attempts)))
    (ok (eql 250 (getf r :retry-initial-delay-ms)))
    (ok (eql 5000 (getf r :retry-max-delay-ms)))
    (ok (eql 600000 (getf r :request-timeout-ms)))
    (ok (eql 3600000 (getf r :turn-timeout-ms)))
    (ok (equal '(("openai:qwen3" . 32768) ("*" . 131072)) (getf r :context-window)))
    (ok (null (getf r :auto-compact-enabled)))
    (ok (eql 70 (getf r :auto-compact-threshold-pct)))
    (ok (eql 0 (getf r :max-continuations)))
    (ok (eql 8192 (getf r :length-retry-max-tokens)))
    (ok (eql 20000 (getf r :max-tool-result-chars)))))

(deftest-parametrize resilience-settings-wrong-types
    ((json key)
     :ids ("retry-array" "max-attempts-zero" "max-attempts-big" "initial-negative"
           "max-delay-string" "request-small" "turn-string" "window-small" "window-bool"
           "window-entry" "auto-compact-array" "enabled-string" "pct-low" "pct-high"
           "continuations-high" "length-small" "tool-chars-small")
     ("{\"retry\": [1]}" "retry")
     ("{\"retry\": {\"maxAttempts\": 0}}" "retry.maxAttempts")
     ("{\"retry\": {\"maxAttempts\": 21}}" "retry.maxAttempts")
     ("{\"retry\": {\"initialDelayMs\": -1}}" "retry.initialDelayMs")
     ("{\"retry\": {\"maxDelayMs\": \"1s\"}}" "retry.maxDelayMs")
     ("{\"requestTimeoutMs\": 999}" "requestTimeoutMs")
     ("{\"turnTimeoutMs\": \"1h\"}" "turnTimeoutMs")
     ("{\"contextWindow\": 1000}" "contextWindow")
     ("{\"contextWindow\": true}" "contextWindow")
     ("{\"contextWindow\": {\"openai:qwen3\": \"big\"}}" "contextWindow.openai:qwen3")
     ("{\"autoCompact\": [true]}" "autoCompact")
     ("{\"autoCompact\": {\"enabled\": \"yes\"}}" "autoCompact.enabled")
     ("{\"autoCompact\": {\"thresholdPct\": 40}}" "autoCompact.thresholdPct")
     ("{\"autoCompact\": {\"thresholdPct\": 96}}" "autoCompact.thresholdPct")
     ("{\"maxContinuations\": 11}" "maxContinuations")
     ("{\"lengthRetryMaxTokens\": 100}" "lengthRetryMaxTokens")
     ("{\"maxToolResultChars\": 10}" "maxToolResultChars"))
  (let ((c (failure (parse-settings json))))
    (ok (typep c 'settings-error))
    (ok (equal key (and (typep c 'settings-error) (settings-error-key c))))))

(deftest resilience-merge-per-key
  (let ((r (rs "{\"retry\":{\"maxAttempts\":6,\"initialDelayMs\":250}}"
               "{\"retry\":{\"maxAttempts\":2},\"contextWindow\":{\"a\":4096}}"
               "{\"contextWindow\":{\"b\":8192},\"turnTimeoutMs\":5000}"
               "{\"turnTimeoutMs\":null}")))
    (ok (eql 2 (getf r :retry-max-attempts)) "the later layer wins per key")
    (ok (eql 250 (getf r :retry-initial-delay-ms)) "keys merge on their own")
    (ok (equal '(("a" . 4096) ("b" . 8192)) (getf r :context-window)))
    (ok (null (getf r :turn-timeout-ms)) "null unsets")))

(deftest resilience-max-delay-raised-to-initial
  (let ((r (rs "{\"retry\":{\"initialDelayMs\":5000,\"maxDelayMs\":100}}")))
    (ok (eql 5000 (getf r :retry-max-delay-ms)))))

(deftest resilience-old-settings-untouched
  (ok (null (settings-resilience (parse-settings "{\"model\":\"x\"}"))))
  (ok (null (settings-resilience (merge-settings (parse-settings "{}") nil)))))

(deftest resilience-flags
  (let ((s (invocation-settings
            (parse-arguments '("-p" "--max-retries" "0" "--request-timeout" "1.5"
                               "--turn-timeout" "600" "--context-window" "32768"
                               "--no-auto-compact" "x")))))
    (ok (equal '(1 1500 600000 32768 :false)
               (list (getf (settings-resilience s) :retry-max-attempts)
                     (getf (settings-resilience s) :request-timeout-ms)
                     (getf (settings-resilience s) :turn-timeout-ms)
                     (getf (settings-resilience s) :context-window)
                     (getf (settings-resilience s) :auto-compact-enabled)))))
  (ok (null (settings-resilience (invocation-settings (parse-arguments '("-p" "x")))))))

(deftest-parametrize resilience-bad-flags
    ((argv needle)
     :ids ("retries-negative" "retries-word" "request-zero" "turn-word" "window-small")
     ('("--max-retries" "-1") "--max-retries must be an integer >= 0")
     ('("--max-retries" "many") "--max-retries must be an integer >= 0")
     ('("--request-timeout" "0") "--request-timeout must be a number of seconds >= 1")
     ('("--turn-timeout" "soon") "--turn-timeout must be a number of seconds >= 1")
     ('("--context-window" "512") "--context-window must be an integer >= 1024"))
  (let ((c (failure (parse-arguments (append '("-p") argv '("x"))))))
    (ok (typep c 'code-usage-error))
    (ok (has needle (princ-to-string c)) (princ-to-string c))))

(deftest resilience-retry-flag-checks
  (ok (invocation-retry-p (parse-arguments '("-p" "--continue" "--retry"))))
  (ok (check-retry-flags (parse-arguments '("-p" "--continue" "--retry"))))
  (ok (has "--retry needs --continue or --resume"
           (princ-to-string (failure (check-retry-flags (parse-arguments '("-p" "--retry")))))))
  (ok (has "--retry takes no prompt"
           (princ-to-string (failure (check-retry-flags
                                      (parse-arguments '("-p" "--continue" "--retry" "hi"))))))))

;;; Classification.

(defun %llm (name &rest initargs)
  "An llm-protocol condition by NAME (0.7.0 types are looked up at run time)."
  (apply #'make-condition (or (find-symbol name '#:llm-protocol)
                              (error "llm-protocol has no ~a (needs 0.7.0)" name))
         initargs))

(deftest-parametrize classify-model-failures
    ((name initargs expected)
     :ids ("overflow" "rate" "overloaded" "auth" "not-found" "transport" "incomplete" "http")
     ("LLM-CONTEXT-OVERFLOW" '(:status 400 :message "prompt is too long")
      'model-context-length-exceeded)
     ("LLM-RATE-LIMITED" '(:status 429 :retry-after 30) 'model-rate-limited)
     ("LLM-OVERLOADED" '(:status 529) 'model-overloaded)
     ("LLM-AUTH-ERROR" '(:status 401) 'model-auth-error)
     ("LLM-NOT-FOUND" '(:status 404) 'model-unavailable)
     ("LLM-TRANSPORT-ERROR" '(:kind :connect) 'model-transport-error)
     ("LLM-INCOMPLETE-RESPONSE" '() 'model-transport-error)
     ("LLM-HTTP-ERROR" '(:status 400 :message "tools[0] invalid") 'model-http-error))
  (let ((c (classify-model-failure (apply #'%llm name initargs)
                                   :provider "openai" :url "http://h/v1" :model "q"
                                   :attempts 4)))
    (ok (eq expected (type-of c)))
    (ok (typep c 'model-error))
    (ok (eql 4 (model-error-attempts c)))))

(deftest classify-keeps-details
  (let ((c (classify-model-failure (%llm "LLM-RATE-LIMITED" :status 429 :retry-after 30))))
    (ok (eql 30 (model-rate-limited-retry-after c))))
  (let ((c (classify-model-failure (%llm "LLM-TRANSPORT-ERROR" :kind :timeout))))
    (ok (eq :timeout (model-transport-error-kind c))))
  (let ((c (classify-model-failure (%llm "LLM-INCOMPLETE-RESPONSE"))))
    (ok (eq :reset (model-transport-error-kind c))))
  (let ((c (classify-model-failure (make-condition 'http-protocol:http-connection-error
                                                   :message "Connection refused"))))
    (ok (typep c 'model-transport-error) "an unwrapped transport condition"))
  (ok (null (classify-model-failure (make-condition 'simple-error :format-control "bug"
                                                                  :format-arguments nil))))
  (let ((c (classify-model-failure (make-condition 'a:agent-generate-error
                                                   :cause (%llm "LLM-OVERLOADED" :status 529)))))
    (ok (typep c 'model-overloaded) "an agent-generate-error is classified by its cause")))

(deftest-parametrize model-failure-messages
    ((name initargs needles)
     :ids ("auth" "not-found" "transport" "overloaded" "rate" "overflow")
     ("LLM-AUTH-ERROR" '(:status 401 :message "invalid x-api-key")
      '("anthropic (https://api.anthropic.com)" "rejected the API key" "model claude-x"
        "HTTP 401" "invalid x-api-key" "ANTHROPIC_API_KEY"))
     ("LLM-NOT-FOUND" '(:status 404 :message "no such model")
      '("anthropic (https://api.anthropic.com) has no model claude-x" "HTTP 404"))
     ("LLM-TRANSPORT-ERROR" '(:kind :connect :message "Connection refused")
      '("could not be reached after 4 attempts" "Connection refused"))
     ("LLM-OVERLOADED" '(:status 529 :message "Overloaded")
      '("anthropic is overloaded (HTTP 529) after 4 attempts"))
     ("LLM-RATE-LIMITED" '(:status 429 :retry-after 30 :message "slow down")
      '("rate-limited the request (HTTP 429) after 4 attempts" "wait 30 s"))
     ("LLM-CONTEXT-OVERFLOW" '(:status 400 :message "prompt is too long")
      '("does not fit model claude-x's context window" "/compact" "contextWindow")))
  (let ((text (model-failure-message
               (classify-model-failure (apply #'%llm name initargs)
                                       :provider "anthropic" :url "https://api.anthropic.com"
                                       :model "claude-x" :attempts 4))))
    (dolist (n needles)
      (ok (has n text) (format nil "~s in ~s" n text)))))

(deftest redact-secrets-rules
  (ok (equal "key [redacted] bad" (redact-secrets "key sk-ant-api03-SECRET bad"
                                                  '("sk-ant-api03-SECRET"))))
  (ok (equal "Incorrect API key provided: [redacted]***"
             (redact-secrets "Incorrect API key provided: sk-ant-a***"
                             '("sk-ant-api03-SECRET")))
      "an 8+ character prefix is redacted too")
  (ok (equal "short abc stays" (redact-secrets "short abc stays" '("abc"))))
  (ok (equal "nothing" (redact-secrets "nothing" '()))))

(deftest model-error-exit-codes
  (ok (eql 3 (condition-exit-code (make-condition 'model-overloaded))))
  (ok (eql 3 (condition-exit-code (make-condition 'model-transport-error))))
  (ok (eql 3 (condition-exit-code (make-condition 'model-auth-error))))
  (ok (eql 3 (condition-exit-code (make-condition 'model-unavailable))))
  (ok (eql 1 (condition-exit-code (make-condition 'model-context-length-exceeded))))
  (ok (eql 1 (condition-exit-code (make-condition 'model-http-error))))
  (ok (eql 124 (condition-exit-code (make-condition 'turn-timeout :ms 5000))))
  (ok (eql 2 (condition-exit-code (make-condition 'nothing-to-retry))))
  (ok (has "the turn timed out after 5 s (turnTimeoutMs)"
           (princ-to-string (make-condition 'turn-timeout :ms 5000))))
  (ok (has "(--turn-timeout)"
           (princ-to-string (make-condition 'turn-timeout :ms 5000 :source "--turn-timeout")))))

(deftest-parametrize turn-timeout-report-seconds
    ((ms text)
     :ids ("whole" "half" "hundredths" "float")
     (4000 "after 4 s (")
     (1500 "after 1.5 s (")
     (1250 "after 1.25 s (")
     (1500.0 "after 1.5 s ("))
  ;; #60: a decimal, never a ratio ("3/2 s").
  (let ((report (princ-to-string (make-condition 'turn-timeout :ms ms :source "--turn-timeout"))))
    (ok (has text report) report)))

(deftest apply-request-timeout-default-is-a-no-op
  (ok (null (apply-request-timeout (llm:make-mock-llm-backend) 30)))
  (let ((b (make-scripted-backend '())))
    (ok (eq b (apply-request-timeout b 30)))
    (ok (eql 30 (scripted-request-timeout b)))))

;;; #58: the agent loop always streams, and a stream's limit is the backend's
;;; idle timeout, not its request timeout. requestTimeoutMs sets both, on the
;;; real backend classes (not only the mock's own method).
(deftest apply-request-timeout-reaches-streaming-requests
  (let ((openai (llm-protocol-openai:make-openai-compat-backend
                 :base-url "http://127.0.0.1:1/v1" :api-key "k" :default-model "m"))
        (anthropic (llm-protocol-anthropic:make-anthropic-backend
                    :base-url "http://127.0.0.1:1" :api-key "k" :default-model "m")))
    (ok (eq openai (apply-request-timeout openai 1)))
    (ok (eql 1 (llm-protocol-openai:openai-request-timeout openai)) "openai: non-streaming")
    (ok (eql 1 (llm-protocol-openai:openai-stream-idle-timeout openai))
        (format nil "openai: streaming idle timeout (got ~S)"
                (llm-protocol-openai:openai-stream-idle-timeout openai)))
    (ok (eq anthropic (apply-request-timeout anthropic 1)))
    (ok (eql 1 (llm-protocol-anthropic:anthropic-request-timeout anthropic)) "anthropic: non-streaming")
    (ok (eql 1 (llm-protocol-anthropic:anthropic-stream-idle-timeout anthropic))
        (format nil "anthropic: streaming idle timeout (got ~S)"
                (llm-protocol-anthropic:anthropic-stream-idle-timeout anthropic)))))
