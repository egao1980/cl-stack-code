(in-package #:cl-stack-code/tests)

;;; H3f end to end in -p (src/resilience.lisp header): retries and their
;;; events, exhaustion, --retry, compaction (threshold, overflow, records),
;;; continuation, truncated tool calls, timeouts. Retries use millisecond
;;; delays, so nothing here waits more than a second or two.

(defparameter +fast-retry+
  "{\"retry\":{\"maxAttempts\":3,\"initialDelayMs\":10,\"maxDelayMs\":20}}")

(defun h3f-settings (config json)
  (write-file config "settings.json" json))

(defun h3f-stream (project config argv &rest keys)
  "CODE with -p --output-format stream-json. → (values exit lines stderr backend)."
  (multiple-value-bind (exit out err backend)
      (apply #'code project config (append '("-p" "--output-format" "stream-json") argv) keys)
    (values exit (ignore-errors (json-lines out)) err backend)))

(defun system-events (lines subtype)
  (remove-if-not (lambda (e) (and (equal "system" (jget e "type"))
                                  (equal subtype (jget e "subtype"))))
                 lines))

(defun result-line (lines)
  (find "result" lines :key (lambda (e) (jget e "type")) :test #'equal))

(defun head-record (project config session-id)
  "The head turn record of SESSION-ID, or NIL when there is no such session."
  (and (stringp session-id)
       (ignore-errors
        (revision-record (session-head (open-session (project-sessions project config)
                                                     session-id))))))

(defun head-finish (project config session-id)
  (let ((r (head-record project config session-id)))
    (and r (record-finish r))))

(deftest retry-then-success
  (with-project (project config) '()
    (h3f-settings config +fast-retry+)
    (multiple-value-bind (exit lines err backend)
        (h3f-stream project config '("hi") :steps '((:fail :overloaded) (:fail :rate-limit) "back"))
      (ok (eql 0 exit) err)
      (ok (= 3 (length (scripted-requests backend))))
      (let ((retries (system-events lines "retry")))
        (ok (= 2 (length retries)))
        (ok (equal '("overloaded" "rate_limit") (mapcar (lambda (e) (jget e "reason")) retries)))
        (ok (equal '(1 2) (mapcar (lambda (e) (jget e "attempt")) retries)))
        (ok (every (lambda (e) (eql 3 (jget e "max_attempts"))) retries))
        (ok (eql 529 (jget (first retries) "status")))
        (let ((d1 (jget (first retries) "delay_ms")) (d2 (jget (second retries) "delay_ms")))
          (ok (and (integerp d1) (<= 16 d1 20)) (format nil "first delay ~a in [16, 20]" d1))
          (ok (and (integerp d2) (<= 16 d2 20)) (format nil "second delay ~a in [16, 20]" d2))))
      (let ((r (result-line lines)))
        (ok (equal "success" (jget r "subtype")))
        (ok (equal "back" (jget r "result")))
        (ok (eql 2 (jget r "retries")))
        (ok (eql 0 (jget r "compactions")))))))

(deftest retry-after-is-honoured
  (with-project (project config) '()
    (h3f-settings config "{\"retry\":{\"maxAttempts\":2,\"initialDelayMs\":10,\"maxDelayMs\":5000}}")
    (multiple-value-bind (exit lines) (h3f-stream project config '("hi")
                                                  :steps '((:fail :rate-limit :retry-after 0.3) "ok"))
      (ok (eql 0 exit))
      (let ((e (first (system-events lines "retry"))))
        (ok (eql 300 (jget e "delay_ms")))
        (ok (eql 300 (jget e "retry_after_ms")))))))

(deftest retries-exhausted-is-a-typed-error
  (with-project (project config) '()
    (h3f-settings config +fast-retry+)
    (multiple-value-bind (exit lines err backend)
        (h3f-stream project config '("hi")
                    :steps '((:fail :overloaded) (:fail :overloaded) (:fail :overloaded)))
      (ok (eql 3 exit) "exit 3: the provider failed")
      (ok (= 3 (length (scripted-requests backend))))
      (ok (= 2 (length (system-events lines "retry"))))
      (let ((r (result-line lines)))
        (ok (equal "error_overloaded" (jget r "subtype")))
        (ok (eq t (jget r "is_error")))
        (ok (equal "model-overloaded" (jget r "error_class")))
        (ok (has "overloaded" (jget r "error")))
        (ok (has "after 3 attempts" (jget r "error")))
        (ok (eq :failed (head-finish project config (jget r "session_id")))))
      (ok (equal "" err) "stream-json writes the error into the result only"))))

(deftest-parametrize not-retried-classes
    ((step subtype exit)
     :ids ("auth" "not-found" "bad-request")
     ('(:fail :auth) "error_auth" 3)
     ('(:fail :not-found) "error_model_unavailable" 3)
     ('(:fail :http :status 400) "error_model_http" 1))
  (with-project (project config) '()
    (h3f-settings config +fast-retry+)
    (multiple-value-bind (code lines err backend) (h3f-stream project config '("hi") :steps (list step))
      (declare (ignore err))
      (ok (eql exit code))
      (ok (= 1 (length (scripted-requests backend))) "never retried")
      (ok (null (system-events lines "retry")))
      (ok (equal subtype (jget (result-line lines) "subtype"))))))

(deftest auth-error-message-has-no-secret
  (with-project (project config) '()
    (multiple-value-bind (exit out err)
        (code project config '("-p" "hi") :steps '((:fail :auth :message "invalid key sk-ant-api03-TOPSECRET"))
                                          :getenv (env-lookup "ANTHROPIC_API_KEY" "sk-ant-api03-TOPSECRET"))
      (ok (eql 3 exit))
      (ok (equal "" out))
      (ok (has "cl-stack-code: " err))
      (ok (has "rejected the API key" err) err)
      (ok (not (has "TOPSECRET" err)) "the key never reaches the message"))))

(deftest transport-error-retried
  (with-project (project config) '()
    (h3f-settings config +fast-retry+)
    (multiple-value-bind (exit lines) (h3f-stream project config '("hi") :steps '((:fail :connect) "ok"))
      (ok (eql 0 exit))
      (ok (equal "transient" (jget (first (system-events lines "retry")) "reason"))))))

(deftest mid-stream-failure-before-a-tool
  (with-project (project config) '()
    (h3f-settings config +fast-retry+)
    (multiple-value-bind (exit lines) (h3f-stream project config '("hi")
                                                  :steps '((:stream-fail "half an ans" :reset)
                                                           "a whole answer"))
      (ok (eql 0 exit))
      (let ((r (result-line lines)))
        (ok (equal "a whole answer" (jget r "result")) "the partial text is not part of the answer"))
      (let ((record (head-record project config (jget (result-line lines) "session_id"))))
        (ok (and record
                 (notany (lambda (turn) (search "half an ans" (turn-text* turn)))
                         (record-turns record)))
            "nor of the record")))))

(deftest mid-stream-failure-after-a-tool-runs-it-once
  (with-project (project config) '()
    (h3f-settings config +fast-retry+)
    (let ((cmd (pick "echo x >> log.txt" "echo x>>log.txt")))
      (multiple-value-bind (exit lines err backend)
          (h3f-stream project config '("--permission-mode" "bypassPermissions" "go")
                      :steps (list (list :tool "bash" (json-args "command" cmd))
                                   '(:stream-fail "Done, I app" :reset)
                                   "Done."))
        (declare (ignore err))
        (ok (eql 0 exit))
        (ok (= 3 (length (scripted-requests backend))))
        (ok (equal (nl "x") (remove #\Return (read-file project "log.txt"))) "one line: the tool ran once")
        (ok (= 1 (length (events-of-type lines "tool_result"))))))))

(defun events-of-type (lines type)
  (remove-if-not (lambda (e) (equal type (jget e "type"))) lines))

;;; --retry: re-send a failed turn.

(deftest retry-flag-resends-the-failed-turn
  (with-project (project config) '()
    (h3f-settings config "{\"retry\":{\"maxAttempts\":1}}")
    (let ((cmd (pick "echo x >> log.txt" "echo x>>log.txt"))
          (backend (make-scripted-backend nil)))
      (multiple-value-bind (exit lines) (h3f-stream project config
                                                    '("--permission-mode" "bypassPermissions" "go")
                                                    :backend (make-scripted-backend
                                                              (list (list :tool "bash" (json-args "command" cmd))
                                                                    '(:fail :overloaded))))
        (ok (eql 3 exit))
        (let ((sid (jget (result-line lines) "session_id")))
          (setf backend (make-scripted-backend '("recovered")))
          (multiple-value-bind (exit2 lines2) (h3f-stream project config
                                                          '("--permission-mode" "bypassPermissions"
                                                            "--continue" "--retry")
                                                          :backend backend)
            (ok (eql 0 exit2))
            (ok (equal "recovered" (jget (result-line lines2) "result")))
            (ok (equal sid (jget (result-line lines2) "session_id")))
            (let ((req (first (scripted-requests backend))))
              (ok (and req (equal '("go") (request-user-texts req))) "no new user turn")
              (ok (and req (= 1 (length (request-tool-results req))))
                  "the completed tool step is kept"))
            (ok (equal (nl "x") (remove #\Return (read-file project "log.txt"))) "and not run again")
            (let ((record (head-record project config sid)))
              (ok (and record (equal "go" (record-prompt record))))
              (ok (and record (stringp (record-retry-of record)))))))))))

(deftest retry-flag-needs-a-failed-turn
  (with-project (project config) '()
    (code project config '("-p" "hi") :steps '("fine"))
    (multiple-value-bind (exit out err) (code project config '("-p" "--continue" "--retry") :steps '())
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "nothing to retry" err)))))

;;; Timeouts (#19).

(deftest no-turn-cap-by-default
  (with-project (project config) '()
    (multiple-value-bind (exit out) (code project config '("-p" "hi") :steps '((:stall 1.5 "slow but fine")))
      (ok (eql 0 exit))
      (ok (equal (nl "slow but fine") out)))))

(deftest turn-timeout-setting-ends-the-turn
  (with-project (project config) '()
    (h3f-settings config "{\"turnTimeoutMs\":1000}")
    (multiple-value-bind (exit lines) (h3f-stream project config '("hi") :steps '((:stall 3 "late")))
      (ok (eql 124 exit))
      (let ((r (result-line lines)))
        (ok (equal "error_turn_timeout" (jget r "subtype")))
        (ok (has "turnTimeoutMs" (jget r "error")))
        (ok (eq :failed (head-finish project config (jget r "session_id"))))))))

(deftest turn-timeout-flag-is-named
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("-p" "--turn-timeout" "1" "hi")
                                              :steps '((:stall 3 "late")))
      (declare (ignore out))
      (ok (eql 124 exit))
      (ok (has "--turn-timeout" err)))))

(deftest turn-timeout-does-not-wait-for-the-request
  ;; #59: the turn ends when the timer fires, not when the silent request does.
  (with-project (project config) '()
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (exit out err) (code project config '("-p" "--turn-timeout" "1" "hi")
                                                :steps '((:stall 15 "late")))
        (declare (ignore out))
        (let ((elapsed (/ (- (get-internal-real-time) start)
                          internal-time-units-per-second)))
          (ok (eql 124 exit))
          (ok (has "--turn-timeout" err))
          (ok (< elapsed 8) (format nil "run-cli returned after ~,1f s" elapsed)))))))

(deftest request-timeout-reaches-the-backend
  (with-project (project config) '()
    (h3f-settings config "{\"requestTimeoutMs\":900000}")
    (multiple-value-bind (exit out err backend) (code project config '("-p" "hi") :steps '("ok"))
      (declare (ignore out err))
      (ok (eql 0 exit))
      (ok (let ((n (scripted-request-timeout backend))) (and (realp n) (= 900 n))))))
  (with-project (project config) '()
    (multiple-value-bind (exit out err backend) (code project config '("-p" "--request-timeout" "2.5" "hi")
                                                      :steps '("ok"))
      (declare (ignore out err))
      (ok (eql 0 exit))
      (ok (let ((n (scripted-request-timeout backend))) (and (realp n) (= 2.5 n))))))
  (with-project (project config) '()
    (multiple-value-bind (exit out err backend) (code project config '("-p" "hi") :steps '("ok"))
      (declare (ignore exit out err))
      (ok (null (scripted-request-timeout backend)) "unset: the backend's own default"))))

;;; The init event.

(deftest init-event-shows-limits
  (with-project (project config) '()
    (h3f-settings config "{\"contextWindow\":{\"mock\":32768},\"turnTimeoutMs\":60000}")
    (let ((init (first (system-events (nth-value 1 (h3f-stream project config '("hi") :steps '("ok")))
                                      "init"))))
      (ok (eql 32768 (jget init "context_window")))
      (ok (equal "settings" (jget init "context_window_source")))
      (ok (eq t (jget init "auto_compact" "enabled")))
      (ok (eql 80 (jget init "auto_compact" "threshold_pct")))
      (ok (eql 4 (jget init "retry" "max_attempts")))
      (ok (eql 60000 (jget init "turn_timeout_ms")))
      (ok (eq :null (jget init "request_timeout_ms"))))))

(deftest init-context-window-from-provider-and-default
  (with-project (project config) '()
    (let ((backend (make-scripted-backend '("ok"))))
      (setf (scripted-context-window backend) 200000)
      (let ((init (first (system-events (nth-value 1 (h3f-stream project config '("hi") :backend backend))
                                        "init"))))
        (ok (eql 200000 (jget init "context_window")))
        (ok (equal "provider" (jget init "context_window_source"))))))
  (with-project (project config) '()
    (let ((init (first (system-events (nth-value 1 (h3f-stream project config '("hi") :steps '("ok")))
                                      "init"))))
      (ok (eql 65536 (jget init "context_window")))
      (ok (equal "default" (jget init "context_window_source"))))))

;;; Compaction. summary-memory keeps the newest turns that fit in
;;; min(15000, window / 4) tokens verbatim, so the tests read a large file
;;; under a 2000-token window: the big tool result is the kept tail and the
;;; user turn before it is summarized.

(defparameter +big-file+ (list "big.txt" (format nil "~{~a~%~}"
                                                 (loop for i below 80
                                                       collect (format nil "line ~d of a large file with words" i)))))

(defun read-big ()
  (list :tool "read" (json-args "file_path" "big.txt")))

(deftest proactive-compaction-at-the-threshold
  (with-project (project config) (list +big-file+)
    (h3f-settings config "{\"contextWindow\":2000,\"autoCompact\":{\"thresholdPct\":80}}")
    (multiple-value-bind (exit lines err backend)
        (h3f-stream project config '("work")
                    :steps (list (list :usage 1900 (read-big))
                                 "## Objective\nsummary of the work"
                                 "finished"))
      (ok (eql 0 exit) err)
      (let ((c (first (system-events lines "compact"))))
        (ok c "a compact event")
        (ok (equal "threshold" (jget c "reason")))
        (ok (eql 2000 (jget c "context_window"))))
      (let ((last (last-request backend)))
        (ok (and last (search "summary of the work" (request-system last)))
            "the model sees the summary"))
      (let* ((sid (jget (result-line lines) "session_id"))
             (store (if (stringp sid)
                        (open-session (project-sessions project config) sid)
                        (create-session (project-sessions project config))))
             (record (or (and (session-head store) (revision-record (session-head store)))
                         (make-turn-record))))
        (ok (eql 1 (jget (result-line lines) "compactions")))
        (ok (= 1 (length (record-compactions record))))
        (let ((m (first (record-compactions record))))
          (ok (eq :threshold (getf m :reason)))
          (ok (integerp (getf m :at)))
          (ok (integerp (getf m :keep))))
        (ok (find "work" (mapcar #'turn-text* (session-full-turns store)) :test #'equal)
            "the full history keeps the first user turn")
        (ok (some #'conversation-protocol:summary-turn-p (session-turns store))
            "a resume sends the compacted context")))))

(deftest no-auto-compact-flag
  (with-project (project config) (list +big-file+)
    (h3f-settings config "{\"contextWindow\":2000}")
    (multiple-value-bind (exit lines)
        (h3f-stream project config '("--no-auto-compact" "work")
                    :steps (list (list :usage 1900 (read-big))
                                 "finished"))
      (ok (eql 0 exit))
      (ok (null (system-events lines "compact"))))))

(defparameter +small-window-fast-retry+
  "{\"contextWindow\":2000,\"retry\":{\"maxAttempts\":3,\"initialDelayMs\":10,\"maxDelayMs\":20}}")

(deftest reactive-compaction-then-retry
  (with-project (project config) (list +big-file+)
    (h3f-settings config +small-window-fast-retry+)
    (multiple-value-bind (exit lines err backend)
        (h3f-stream project config '("hi")
                    :steps (list (read-big) '(:fail :overflow) "## Objective\nthe summary" "it fits now"))
      (ok (eql 0 exit) err)
      (ok (= 4 (length (scripted-requests backend))))
      (ok (equal "overflow" (jget (first (system-events lines "compact")) "reason")))
      (ok (equal "context_overflow" (jget (first (system-events lines "retry")) "reason")))
      (ok (equal "it fits now" (jget (result-line lines) "result"))))))

(deftest second-overflow-ends-cleanly
  (with-project (project config) (list +big-file+)
    (h3f-settings config +small-window-fast-retry+)
    (multiple-value-bind (exit lines)
        (h3f-stream project config '("hi")
                    :steps (list (read-big) '(:fail :overflow) "## Objective\nthe summary"
                                 '(:fail :overflow)))
      (ok (eql 1 exit))
      (let ((r (result-line lines)))
        (ok (equal "error_context_length" (jget r "subtype")))
        (ok (has "context window" (jget r "error")))
        (ok (has "/compact" (jget r "error")))))))

;;; Output limit.

(deftest length-continues-the-answer
  (with-project (project config) '()
    (multiple-value-bind (exit lines) (h3f-stream project config '("write")
                                                  :steps '((:length "part one, ") "part two."))
      (ok (eql 0 exit))
      (ok (equal "part one, part two." (jget (result-line lines) "result")))
      (ok (eql 1 (jget (result-line lines) "continuations")))
      (let ((c (first (system-events lines "continuation"))))
        (ok (eql 1 (jget c "count")))
        (ok (eql 2 (jget c "max")))))))

(deftest length-continuations-are-bounded
  (with-project (project config) '()
    (h3f-settings config "{\"maxContinuations\":1}")
    (multiple-value-bind (exit lines) (h3f-stream project config '("write")
                                                  :steps '((:length "a") (:length "b")))
      (ok (eql 0 exit) "a cut answer is still an answer")
      (ok (equal "ab" (jget (result-line lines) "result")))
      (ok (= 1 (length (system-events lines "continuation")))))))

(deftest truncated-tool-call-reported-to-the-model
  (with-project (project config) '()
    (multiple-value-bind (exit lines err backend)
        (h3f-stream project config '("--permission-mode" "acceptEdits" "write it")
                    :steps '((:length-tool "write" "{\"path\":\"a.txt\",\"content\":\"aaa")
                             "I will split it."))
      (ok (eql 0 exit) err)
      (ok (null (probe-file (merge-pathnames "a.txt" project))) "the cut call did not run")
      (let ((tr (first (system-events lines "truncated"))))
        (ok tr)
        (ok (equal '("call-1-1") (coerce (jget tr "tool_use_ids") 'list))))
      (let ((result (and (last-request backend)
                         (first (request-tool-results (last-request backend))))))
        (ok (and result (result-error-p result)))
        (ok (and result (has "cut off at the output limit" (result-content result))))))))

(deftest truncated-tool-call-retried-with-more-tokens
  (with-project (project config) '()
    (h3f-settings config "{\"lengthRetryMaxTokens\":2000}")
    (multiple-value-bind (exit lines err backend)
        (h3f-stream project config '("--permission-mode" "acceptEdits" "write it")
                    :steps (list '(:length-tool "write" "{\"path\":\"a.txt\",\"content\":\"aa")
                                 (list :tool "write" (json-args "file_path" "a.txt" "content" "aaaa"))
                                 "done"))
      (ok (eql 0 exit) err)
      (ok (equal "aaaa" (read-file project "a.txt")))
      (ok (equal "output_truncated" (jget (first (system-events lines "retry")) "reason")))
      (let ((second (second (scripted-requests backend))))
        (ok (and second (request-settings second)
                 (eql 2000 (llm:llm-settings-max-tokens (request-settings second)))))))))

;;; Tool output cap.

(deftest cap-tool-result-rules
  (ok (equal "short" (cap-tool-result "short" 1000)))
  (let* ((text (make-string 5000 :initial-element #\a))
         (capped (cap-tool-result text 1000 :ref "/tmp/x.txt")))
    (ok (<= (length capped) 1200))
    (ok (has "[truncated: 5000 characters; the full output is in /tmp/x.txt]" capped)))
  (ok (has "[truncated: 5000 characters]"
           (cap-tool-result (make-string 5000 :initial-element #\b) 1000))))
