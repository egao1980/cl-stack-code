(in-package #:cl-stack-code/tests)

;;; RUN-CLI end to end against the scripted backend: text output, exit codes,
;;; the model and settings reaching the run, max turns, failures.

(defun first-request (backend) (first (scripted-requests backend)))

(deftest cli-text-answer
  (with-project (project config) '()
    (multiple-value-bind (exit out err backend)
        (code project config '("-p" "say" "hi") :steps '("Hello brave new world"))
      (ok (eql 0 exit))
      (ok (equal (nl "Hello brave new world") out))
      (ok (equal "" err))
      (ok (= 1 (length (scripted-requests backend))))
      (ok (has "say hi" (request-text (first-request backend)))))))

(deftest cli-text-trims-trailing-newlines
  (with-project (project config) '()
    (ok (equal (nl "line one" "line two")
               (nth-value 1 (code project config '("-p" "x")
                                  :steps (list (nl "line one" "line two" ""))))))))

(deftest cli-prompt-from-input
  (with-project (project config) '()
    (multiple-value-bind (exit out err backend)
        (code project config '("-p") :steps '("ok") :input (nl "the prompt from stdin"))
      (declare (ignore err))
      (ok (eql 0 exit))
      (ok (equal (nl "ok") out))
      (ok (has "the prompt from stdin" (request-text (first-request backend)))))))

(deftest cli-requires-print
  (with-project (project config) '()
    (multiple-value-bind (exit out err backend) (code project config '("hi") :steps '("x"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "-p" err))
      (ok (has "cl-stack-code: " err))
      (ok (null (scripted-requests backend))))))

(deftest cli-blank-prompt
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("-p") :steps '("x") :input (nl "  "))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "prompt" err)))))

(deftest cli-usage-errors-print-nothing-on-output
  (with-project (project config) '()
    (multiple-value-bind (exit out) (code project config '("--output-format" "json" "hi"))
      (ok (eql 2 exit))
      (ok (equal "" out) "no result object before a run"))
    (multiple-value-bind (exit out err) (code project config '("-p" "--frobnicate" "x"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "frobnicate" err)))))

(deftest cli-bad-cwd
  (with-project (project config) '(("file.txt" "x"))
    (let ((missing (native (merge-pathnames "no/such/dir/" project))))
      (multiple-value-bind (exit out err)
          (code project config (list "--cwd" missing "-p" "hi") :cwd nil :steps '("x"))
        (ok (eql 2 exit))
        (ok (equal "" out))
        (ok (has missing err))))
    (ok (eql 2 (code project config (list "--cwd" (native (merge-pathnames "file.txt" project))
                                          "-p" "hi")
                     :cwd nil :steps '("x")))
        "a file is not a directory")))

(deftest cli-bad-settings-file
  (with-project (project config) '((".cl-stack-code/settings.json" "{\"model\": "))
    (multiple-value-bind (exit out err backend) (code project config '("-p" "hi") :steps '("x"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "settings.json" err))
      (ok (null (scripted-requests backend))))))

(deftest cli-unknown-provider
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("-p" "hi") :model "nope:x")
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "nope" err)))))

(deftest cli-model-from-flag
  (with-project (project config) '((".cl-stack-code/settings.json" "{\"model\": \"mock:from-settings\"}"))
    (let ((backend (nth-value 3 (code project config '("-p" "hi") :model "mock:big" :steps '("x")))))
      (ok (equal "big" (scripted-model backend)) "the flag beats the settings")
      (ok (equal "big" (request-model (first-request backend)))
          "the model reaches GENERATE as :model (agent :model)")
      (ok (= 1 (scripted-factory-calls backend)) "one backend per run"))))

(deftest cli-model-from-settings
  (with-project (project config) '((".cl-stack-code/settings.local.json" "{\"model\": \"mock:local\"}"))
    (write-file config "settings.json" "{\"model\": \"mock:user\"}")
    (multiple-value-bind (exit out err backend) (code project config '("-p" "hi") :model nil :steps '("x"))
      (declare (ignore out err))
      (ok (eql 0 exit))
      (ok (equal "local" (scripted-model backend))))))

(deftest cli-user-settings
  (with-project (project config) '()
    (write-file config "settings.json" "{\"model\": \"mock:user\"}")
    (ok (equal "user" (scripted-model (nth-value 3 (code project config '("-p" "hi")
                                                         :model nil :steps '("x"))))))))

(deftest cli-env-reaches-the-provider
  (with-project (project config)
      '((".cl-stack-code/settings.json" "{\"env\": {\"MOCK_KEY\": \"from-settings\", \"DROPPED\": null}}"))
    (let* ((backend (nth-value 3 (code project config '("-p" "hi") :steps '("x")
                                       :getenv (env-lookup "MOCK_KEY" "from-process"
                                                           "DROPPED" "from-process"
                                                           "OTHER" "other"))))
           (env (scripted-env backend)))
      (ok (equal "from-settings" (funcall env "MOCK_KEY")) "settings env beats the process")
      (ok (null (funcall env "DROPPED")) "null unsets")
      (ok (equal "other" (funcall env "OTHER")) "the rest comes from GETENV"))))

(deftest cli-system-prompt-reaches-the-model
  (with-project (project config) '(("AGENTS.md" "Project rule: use tabs.
"))
    (let* ((backend (nth-value 3 (code project config '("-p" "--append-system-prompt" "Tail text." "hi")
                                       :steps '("x"))))
           (system (request-system (first-request backend))))
      (ok (has "Project rule: use tabs." system))
      (ok (has "# Environment" system))
      (ok (has "Tail text." system))
      (ok (< (search "Project rule" system) (search "Tail text." system))))))

(deftest cli-max-turns
  (with-project (project config) '(("a.txt" "a"))
    (multiple-value-bind (exit out err backend)
        (code project config '("-p" "--max-turns" "2" "loop")
              :steps (loop repeat 5 collect (list :tool "ls" "{}")))
      (ok (eql 1 exit))
      (ok (equal "" out))
      (ok (has "max turns (2)" err))
      (ok (= 2 (length (scripted-requests backend))) "exactly N model calls, no wrap-up"))))

(deftest cli-max-turns-from-settings
  (with-project (project config) '((".cl-stack-code/settings.json" "{\"maxTurns\": 1}"))
    (let ((backend (nth-value 3 (code project config '("-p" "loop")
                                      :steps (loop repeat 3 collect (list :tool "ls" "{}"))))))
      (ok (= 1 (length (scripted-requests backend)))))))

(deftest cli-backend-failure
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("-p" "hi") :steps '((:error "backend exploded")))
      (ok (eql 1 exit))
      (ok (equal "" out))
      (ok (has "backend exploded" err)))))

(deftest cli-help
  (with-project (project config) '()
    (multiple-value-bind (exit out) (code project config '("--help") :cwd nil :model nil)
      (ok (eql 0 exit))
      (dolist (flag '("--print" "--output-format" "--model" "--max-turns" "--cwd"
                      "--allowed-tools" "--disallowed-tools" "--permission-mode"
                      "--append-system-prompt"))
        (ok (has flag out) flag)))))

(deftest cli-version
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("--version") :cwd nil :model nil)
      (ok (eql 0 exit))
      (ok (equal (nl "cl-stack-code 0.13.1") out))
      (ok (equal "" err)))))

(deftest cli-model-params-reach-generate
  (with-project (project config)
      '((".cl-stack-code/settings.json"
         "{\"modelParams\": {\"temperature\": 1.0, \"top_p\": 0.95, \"top_k\": 20}}"))
    (let* ((backend (nth-value 3 (code project config
                                       '("-p" "--model-param" "temperature=0.7"
                                         "--model-param" "chat_template_kwargs={\"enable_thinking\":false}"
                                         "hi")
                                       :steps '("x"))))
           (llm (request-settings (first-request backend))))
      (ok (llm:llm-settings-p llm) "the agent's LLM settings reach GENERATE")
      (ok (= 0.7d0 (llm:llm-settings-temperature llm)) "the flag beats the settings file")
      (ok (= 0.95d0 (llm:llm-settings-top-p llm)))
      (ok (equal '("top_k" "chat_template_kwargs")
                 (loop for k in (llm:llm-settings-extra llm) by #'cddr collect k)))))
  (testing "no modelParams → no LLM settings"
    (with-project (project config) '()
      (let ((backend (nth-value 3 (code project config '("-p" "hi") :steps '("x")))))
        (ok (null (request-settings (first-request backend))))))))
