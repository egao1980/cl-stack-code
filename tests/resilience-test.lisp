(in-package #:cl-stack-code/tests)

;;; H3f runtime pieces without a run: windows, events, markers, notices,
;;; the SDK, RPC and the TUI (src/resilience.lisp header).

(deftest-parametrize effective-context-window-rows
    ((json designator expected source)
     :ids ("integer" "designator" "model" "provider" "star" "provider-metadata" "default")
     ("{\"contextWindow\":40000}" "openai:qwen3" 40000 :settings)
     ("{\"contextWindow\":{\"openai:qwen3\":30000,\"qwen3\":20000,\"*\":9000}}" "openai:qwen3" 30000 :settings)
     ("{\"contextWindow\":{\"qwen3\":20000,\"openai\":15000}}" "openai:qwen3" 20000 :settings)
     ("{\"contextWindow\":{\"openai\":15000,\"*\":9000}}" "openai:qwen3" 15000 :settings)
     ("{\"contextWindow\":{\"other\":15000,\"*\":9000}}" "openai:qwen3" 9000 :settings)
     ("{}" "mock" 123456 :provider)
     ("{\"contextWindow\":{\"other\":15000}}" "openai:qwen3" 65536 :default))
  (let ((backend (make-scripted-backend '())))
    (when (eq source :provider)
      (setf (scripted-context-window backend) 123456))
    (multiple-value-bind (n src)
        (effective-context-window (parse-settings json) backend designator)
      (ok (eql expected n))
      (ok (eq source src)))))

(deftest context-usage-and-status
  (ok (eql 45 (context-usage-pct 45000 100000)))
  (ok (eql 0 (context-usage-pct 0 100000)))
  (ok (eql 999 (context-usage-pct 10000000 1000)))
  (ok (equal "ctx 45%" (context-status-text 45000 100000))))

(deftest retry-event-object-shape
  (let ((e (retry-event-object (list :reason :overloaded :attempt 2 :max-attempts 4 :delay 1.5
                                     :status 529 :retry-after nil :step 3
                                     :condition (make-condition 'simple-error
                                                                :format-control "Overloaded"
                                                                :format-arguments nil)))))
    (ok (equal "system" (jget e "type")))
    (ok (equal "retry" (jget e "subtype")))
    (ok (equal "overloaded" (jget e "reason")))
    (ok (eql 2 (jget e "attempt")))
    (ok (eql 4 (jget e "max_attempts")))
    (ok (eql 1500 (jget e "delay_ms")))
    (ok (eql 529 (jget e "status")))
    (ok (eq :null (jget e "retry_after_ms")))
    (ok (eql 3 (jget e "step")))
    (ok (equal "Overloaded" (jget e "error")))))

(deftest other-event-objects
  (let ((c (compact-event-object (list :reason :threshold :before 12 :after 4 :tokens-before 1700
                                       :context-window 2000))))
    (ok (equal '("compact" "threshold" 12 4 1700 2000)
               (mapcar (lambda (k) (jget c k))
                       '("subtype" "reason" "turns_before" "turns_after" "tokens_before"
                         "context_window")))))
  (let ((c (continuation-event-object (list :step 2 :count 1 :max 2))))
    (ok (equal '("continuation" 2 1 2) (mapcar (lambda (k) (jget c k))
                                               '("subtype" "step" "count" "max")))))
  (let ((c (truncated-event-object (list :step 1 :calls '("c1") :max-tokens 100))))
    (ok (equal "truncated" (jget c "subtype")))
    (ok (equalp #("c1") (jget c "tool_use_ids")))
    (ok (eql 100 (jget c "max_tokens")))))

(deftest-parametrize retry-notice-rows
    ((plist seconds expected)
     :ids ("overloaded" "rate" "transport-no-status")
     ('(:reason :overloaded :status 503 :attempt 1 :max-attempts 4) 4
      "retrying in 4 s (503 overloaded) · attempt 2 of 4 · Esc to stop")
     ('(:reason :rate-limit :status 429 :attempt 2 :max-attempts 4) 30
      "retrying in 30 s (429 rate limited) · attempt 3 of 4 · Esc to stop")
     ('(:reason :transient :status nil :attempt 1 :max-attempts 3) 1
      "retrying in 1 s (connection) · attempt 2 of 3 · Esc to stop"))
  (ok (equal expected (retry-notice-text plist seconds))))

(deftest compaction-marker-round-trip
  (let* ((summary (list (llm:make-llm-turn :role :system
                                           :parts (list (llm:make-llm-text-part
                                                         :text "[summary] all of it")))))
         (marker (make-compaction-marker :summary summary :keep 2 :at 5 :reason :manual
                                         :tokens-before 1800 :instructions "rev-1"))
         (record (make-turn-record :prompt "" :compactions (list marker)))
         (back (content-record (record-content record))))
    (ok (eql 2 (getf (first (record-compactions back)) :keep)))
    (ok (eql 5 (getf (first (record-compactions back)) :at)))
    (ok (eq :manual (getf (first (record-compactions back)) :reason)))
    (ok (equal "rev-1" (getf (first (record-compactions back)) :instructions)))
    (ok (equal "[summary] all of it"
               (llm:turn-text (first (getf (first (record-compactions back)) :summary))))))
  (ok (null (getf (record-content (make-turn-record :prompt "x")) :compactions))
      "absent when empty: older records read unchanged")
  (ok (signals (make-compaction-marker :keep 1 :at 1 :reason :whenever) 'type-error)))

(defun %turns (&rest texts)
  (loop for text in texts for i from 0
        collect (if (evenp i) (llm:user-turn text) (llm:assistant-turn text))))

(deftest compacted-session-turns-applies-the-latest-marker
  (let* ((summary (list (llm:make-llm-turn :role :system
                                           :parts (list (llm:make-llm-text-part :text "[summary] s")))))
         (r1 (make-turn-record :prompt "a" :turns (%turns "a" "A")))
         (r2 (make-turn-record :prompt "b" :turns (%turns "b" "B")
                               :compactions (list (make-compaction-marker :summary summary
                                                                          :keep 1 :at 4
                                                                          :reason :threshold))))
         (r3 (make-turn-record :prompt "c" :turns (%turns "c" "C")))
         (turns (compacted-session-turns (list r1 r2 r3))))
    (ok (equal '("[summary] s" "B" "c" "C") (mapcar #'llm:turn-text turns)))))

(deftest session-turns-and-full-turns
  (let ((dir (uiop:ensure-directory-pathname (merge-pathnames "h3f-sessions/" (temp-base)))))
    (unwind-protect
         (let* ((store (create-session dir :project-dir dir))
                (summary (list (llm:make-llm-turn :role :system
                                                  :parts (list (llm:make-llm-text-part
                                                                :text "[summary] s"))))))
           (commit-turn store (make-turn-record :prompt "a" :turns (%turns "a" "A")))
           (commit-turn store (make-turn-record :prompt ""
                                                :compactions (list (make-compaction-marker
                                                                    :summary summary :keep 0 :at 2
                                                                    :reason :manual))))
           (commit-turn store (make-turn-record :prompt "b" :turns (%turns "b" "B")))
           (ok (equal '("[summary] s" "b" "B") (mapcar #'llm:turn-text (session-turns store))))
           (ok (equal '("a" "A" "b" "B") (mapcar #'llm:turn-text (session-full-turns store))))
           (ok (find-if (lambda (e) (and (eq :notice (entry-kind e))
                                         (has "compacted: " (entry-text e))))
                        (session-entries store))
               "entries show the compaction"))
      (uiop:delete-directory-tree (uiop:pathname-parent-directory-pathname dir)
                                  :validate t :if-does-not-exist :ignore))))

;;; SDK and RPC.

(defparameter +slow-retry+
  "{\"retry\":{\"maxAttempts\":3,\"initialDelayMs\":30000,\"maxDelayMs\":30000}}")

(deftest client-retry-events-and-result
  (with-project (project config) '()
    (write-file config "settings.json" +fast-retry+)
    (with-test-client (c backend events project config :steps '((:fail :overloaded) "ok"))
      (let* ((s (client-new-session c))
             (result (client-query s "hi" :timeout 30)))
        (ok (equal "success" (event-value result "subtype")))
        (ok (eql 1 (event-value result "retries")))
        (let ((e (find-if (lambda (e) (equal "retry" (event-value e "subtype")))
                          (events-of events "system"))))
          (ok e)
          (ok (equal "overloaded" (and e (event-value e "reason")))))))))

(deftest client-interrupt-during-backoff
  (with-project (project config) '()
    (write-file config "settings.json" +slow-retry+)
    (with-test-client (c backend events project config :steps '((:fail :overloaded) "never"))
      (let* ((s (client-new-session c))
             (turn (client-turn s "hi"))
             (start (get-internal-real-time)))
        (ok (wait-event events (lambda (e) (equal "retry" (event-value e "subtype"))) :timeout 20))
        (client-interrupt s)
        (let ((result (client-wait turn :timeout 10)))
          (ok result "the turn ended well before the 30 s backoff")
          (ok (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 10))
          (ok (= 1 (length (scripted-requests backend))) "no request after the interrupt"))))))

(deftest client-compact-and-retry-turn
  (with-project (project config) (list +big-file+)
    (write-file config "settings.json" "{\"contextWindow\":2000,\"retry\":{\"maxAttempts\":1}}")
    (with-test-client (c backend events project config
                         :steps (list (read-big) "read it" "## Objective\nthe summary"
                                      '(:fail :overloaded) "second try"))
      (let ((s (client-new-session c)))
        (client-query s "first" :timeout 30)
        (let ((e (client-compact s :instructions "keep big.txt")))
          (ok e)
          (ok (equal "manual" (event-value e "reason"))))
        (ok (search "keep big.txt" (request-text (third (scripted-requests backend))))
            "the instructions reach the summarizer")
        (let ((failed (client-query s "second" :timeout 30)))
          (ok (equal "error_overloaded" (event-value failed "subtype"))))
        (let ((retried (client-wait (client-retry-turn s) :timeout 30)))
          (ok (equal "second try" (event-value retried "result"))))
        (ok (typep (failure (client-retry-turn s)) 'nothing-to-retry))))))

(deftest rpc-compact-and-retry
  (with-project (project config) '()
    (write-file config "settings.json" "{\"retry\":{\"maxAttempts\":1}}")
    (with-rpc (rpc backend project config :steps '((:fail :overloaded) "again"))
      (let* ((init (call rpc "session/new"))
             (sid (jget init "session_id")))
        (call rpc "turn/start" "session_id" sid "prompt" "hi")
        (ok (equal "error_overloaded" (jget (rpc-result rpc sid) "subtype")))
        (call rpc "turn/retry" "session_id" sid)
        (ok (equal "again" (jget (rpc-result rpc sid :n 1) "result")))
        (multiple-value-bind (code data message) (fault rpc "turn/retry" "session_id" sid)
          (declare (ignore data))
          (ok (eql -32031 code))
          (ok (has "nothing to retry" message)))
        (let ((r (call rpc "session/compact" "session_id" sid)))
          (ok (member (jget r "compacted") '(t nil))))))))

;;; TUI.

(deftest program-retry-notice-and-esc
  (with-project (project config) '()
    (write-file config "settings.json" +slow-retry+)
    (with-code-tui (tui program backend :steps '((:fail :overloaded) "never")) (project config)
      (send-line tui "hi")
      (ok (wait-screen tui "retrying in "))
      (ok (wait-screen tui "529 overloaded"))
      (ok (wait-screen tui "Esc to stop"))
      (h:tui-press tui :escape)
      (ok (wait-idle tui program :timeout 10))
      (ok (= 1 (length (scripted-requests backend)))))))

(deftest program-failure-offers-retry
  (with-project (project config) '()
    (write-file config "settings.json" "{\"retry\":{\"maxAttempts\":1}}")
    (with-code-tui (tui program backend :steps '((:fail :overloaded) "it worked")) (project config)
      (send-line tui "hi")
      (ok (wait-screen tui "/retry to send it again"))
      (send-line tui "/retry")
      (ok (wait-screen tui "it worked"))
      (send-line tui "/retry")
      (ok (wait-screen tui "nothing to retry")))))

(deftest program-compact-command
  (with-project (project config) (list +big-file+)
    (write-file config "settings.json" "{\"contextWindow\":2000}")
    (with-code-tui (tui program backend :steps (list (read-big) "read" "## Objective\nsum"))
        (project config)
      (send-line tui "read big.txt")
      (ok (wait-screen tui "read"))
      (ok (wait-idle tui program))
      (send-line tui "/compact keep the file names")
      (ok (wait-screen tui "compacted the conversation"))
      (ok (search "keep the file names" (request-text (third (scripted-requests backend))))))))

(deftest program-status-line-shows-context
  (with-project (project config) '()
    (write-file config "settings.json" "{\"contextWindow\":2000}")
    (with-code-tui (tui program backend :steps '((:usage 900 "hello"))) (project config)
      (ok (not (has "ctx " (last-row tui))) "no ctx before the first response")
      (send-line tui "hi")
      (ok (wait-screen tui "hello"))
      (ok (wait-for* tui (lambda () (has "ctx 45%" (last-row tui))))))))

(deftest program-help-lists-h3f-commands
  (ok (has "/compact [TEXT]" +help-text+))
  (ok (has "/retry" +help-text+)))
