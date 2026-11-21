(in-package #:cl-stack-code/tests)

;;; The agent-tools sources inside headless runs: what is offered, rooted at
;;; the working directory, and how rules, modes and headless approval decide.

(defun tool-results-of (backend)
  "Tool result parts the last request carried."
  (request-tool-results (last-request backend)))

(defun result-named (out name)
  "The stream-json tool_result for tool NAME."
  (find name (events out "tool_result") :key (lambda (e) (jget e "name")) :test #'equal))

(defun streamed (project config steps &rest argv)
  "→ (values exit stdout backend) of a stream-json run."
  (multiple-value-bind (exit out err backend)
      (code project config (append '("-p" "--output-format" "stream-json") argv '("go"))
            :steps steps)
    (declare (ignore err))
    (values exit out backend)))

(defun write-step (file content)
  (list :tool "write" (json-args "file_path" file "content" content)))

(defun bash-step (command)
  (list :tool "bash" (json-args "command" command)))

(deftest tools-offered
  (with-project (project config) '()
    (let ((backend (nth-value 3 (code project config '("-p" "hi") :steps '("x")))))
      (ok (equal (append at:+file-tool-names+ at:+shell-tool-names+ at:+unit-tool-names+)
                 (request-tool-names (first (scripted-requests backend))))))))

(deftest tools-make-code-tools
  (with-project (project config) '()
    (let ((sources (make-code-tools project :settings (make-settings :env '(("A" . "b"))))))
      (unwind-protect
           (progn
             (ok (= 2 (length sources)))
             (ok (at:file-tools-p (first sources)))
             (ok (at:shell-tools-p (second sources)))
             (ok (at:shell-tools-needs-approval (second sources)))
             (ok (equal '(("A" . "b")) (at:shell-tools-env (second sources)))))
        (ignore-errors (at:close-shell-tools (second sources)))))))

(deftest tools-read-result-reaches-the-model
  (with-project (project config) '(("a.txt" "alpha
"))
    (multiple-value-bind (exit out err backend)
        (code project config '("-p" "read") :steps (list (list :tool "read" (json-args "file_path" "a.txt"))
                                                         "done"))
      (declare (ignore out err))
      (ok (eql 0 exit))
      (let ((r (first (tool-results-of backend))))
        (ok (has "alpha" (result-content r)))
        (ok (not (result-error-p r)))))))

(deftest tools-rooted-at-cwd
  (with-project (project config :base base) '()
    (write-file base "outside.txt" "secret")
    (multiple-value-bind (exit out err backend)
        (code project config '("-p" "x") :steps (list (list :tool "read" (json-args "file_path" "../outside.txt"))
                                                      "done"))
      (declare (ignore out err))
      (ok (eql 0 exit) "a refused path is a tool result, not a failure")
      (let ((r (first (tool-results-of backend))))
        (ok (result-error-p r))
        (ok (has "outside" (result-content r)))
        (ok (not (has "secret" (result-content r))))))))

(deftest tools-headless-denies-write
  (with-project (project config) '()
    (multiple-value-bind (exit out err backend)
        (code project config '("-p" "--output-format" "json" "write")
              :steps (list (write-step "new.txt" "x") "gave up"))
      (declare (ignore err))
      (ok (eql 0 exit))
      (ok (null (probe-file (merge-pathnames "new.txt" project))))
      (let ((r (first (tool-results-of backend))))
        (ok (result-error-p r))
        (ok (has +headless-denial-feedback+ (result-content r)))
        (ok (has "no one can be asked" (result-content r)) "#5: unattended, not rejected")
        (ok (not (has "the user rejected" (result-content r)))))
      (let* ((result (first (json-lines out)))
             (denial (jget result "permission_denials" 0)))
        (ok (= 1 (length (jget result "permission_denials"))))
        (ok (equal "call-1-1" (jget denial "id")))
        (ok (equal "write" (jget denial "name")))
        (ok (equal "new.txt" (jget denial "input" "file_path")))
        (ok (equal "headless" (jget denial "reason")))))))

(deftest tools-accept-edits
  (with-project (project config) '()
    (multiple-value-bind (exit out) (streamed project config (list (write-step "new.txt" "made") "ok")
                                              "--permission-mode" "acceptEdits")
      (ok (eql 0 exit))
      (ok (equal "made" (read-file project "new.txt")))
      (ok (equal "done" (jget (result-named out "write") "status"))))))

(deftest tools-allowed-tools-flag
  (with-project (project config) '()
    (streamed project config (list (write-step "new.txt" "made") "ok") "--allowed-tools" "write")
    (ok (equal "made" (read-file project "new.txt")))))

(deftest tools-settings-scoped-rule
  (with-project (project config) '(("src/a.txt" "old") ("b.txt" "old")
                                   (".cl-stack-code/settings.json"
                                    "{\"permissions\": {\"allow\": [\"edit(src/*)\"]}}"))
    (streamed project config
              (list (list :tools
                          (list "edit" (json-args "file_path" "src/a.txt" "old_string" "old" "new_string" "new"))
                          (list "edit" (json-args "file_path" "b.txt" "old_string" "old" "new_string" "new")))
                    "ok"))
    (ok (equal "new" (read-file project "src/a.txt")))
    (ok (equal "old" (read-file project "b.txt")) "outside src/ it still asks, so headless denies")))

(deftest tools-deny-beats-allow-across-layers
  (with-project (project config) '((".cl-stack-code/settings.local.json"
                                    "{\"permissions\": {\"allow\": [\"write\"]}}"))
    (write-file config "settings.json"
                "{\"permissions\": {\"deny\": [{\"tool\": \"write\", \"resource\": \"path:secret/*\", \"feedback\": \"No secrets.\"}]}}")
    (multiple-value-bind (exit out)
        (streamed project config (list (list :tools
                                             (list "write" (json-args "file_path" "secret/k.txt" "content" "x"))
                                             (list "write" (json-args "file_path" "ok.txt" "content" "y")))
                                       "ok"))
      (ok (eql 0 exit))
      (ok (null (probe-file (merge-pathnames "secret/k.txt" project))) "the user's deny wins")
      (ok (equal "y" (read-file project "ok.txt")))
      (let ((denied (find "call-1-1" (events out "tool_result") :key (lambda (e) (jget e "id"))
                                                                :test #'equal)))
        (ok (equal "denied" (jget denied "status")))
        (ok (has "No secrets." (jget denied "content"))))
      (ok (equal "denied" (jget (car (last (json-lines out))) "permission_denials" 0 "reason"))))))

(deftest tools-bash-headless-denied
  (with-project (project config) '()
    (multiple-value-bind (exit out) (streamed project config (list (bash-step "echo hi") "ok"))
      (ok (eql 0 exit))
      (let ((r (result-named out "bash")))
        (ok (equal "denied" (jget r "status")))
        (ok (eq t (jget r "is_error")))
        (ok (has "cannot ask for approval" (jget r "content")))))))

(deftest tools-bash-allowed-by-rule
  (with-project (project config) '()
    (let* ((out (nth-value 1 (streamed project config (list (bash-step "echo hi") "ok")
                                       "--allowed-tools" "bash(echo *)")))
           (r (result-named out "bash")))
      (ok (equal "done" (jget r "status")))
      (ok (has "hi" (jget r "content")))
      (ok (has "[exit code 0]" (jget r "content"))))))

(deftest tools-bypass-permissions
  (with-project (project config) '()
    (let* ((out (nth-value 1 (streamed project config
                                       (list (list :tools
                                                   (list "bash" (json-args "command" "echo hi"))
                                                   (list "write" (json-args "file_path" "w.txt" "content" "w")))
                                             "ok")
                                       "--permission-mode" "bypassPermissions"))))
      (ok (equal "done" (jget (result-named out "bash") "status")))
      (ok (equal "w" (read-file project "w.txt"))))))

(deftest tools-bypass-keeps-denies
  (with-project (project config) '(("x.txt" "keep"))
    (let* ((out (nth-value 1 (streamed project config (list (bash-step (pick "rm x.txt" "del x.txt")) "ok")
                                       "--permission-mode" "bypassPermissions"
                                       "--disallowed-tools" (pick "bash(program:rm)" "bash(del *)")))))
      (ok (equal "denied" (jget (result-named out "bash") "status")))
      (ok (equal "keep" (read-file project "x.txt"))))))

(deftest tools-plan-mode
  ;; H5a: plan mode writes into the plan's area, never the project.
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (streamed project config
                  (list (list :tools
                              (list "read" (json-args "file_path" "a.txt"))
                              (list "write" (json-args "file_path" "a.txt" "content" "beta")))
                        "ok")
                  "--permission-mode" "plan")
      (ok (eql 0 exit))
      (ok (equal "done" (jget (result-named out "read") "status")))
      (ok (equal "done" (jget (result-named out "write") "status")) "edits are allowed")
      (ok (equal "alpha" (read-file project "a.txt")) "the project is untouched")
      (ok (equal "plan" (jget (first (json-lines out)) "permission_mode"))))))

(deftest tools-hidden-by-bare-deny
  (with-project (project config) '()
    (let ((backend (nth-value 3 (code project config '("-p" "--disallowed-tools" "bash" "hi") :steps '("x")))))
      (ok (equal (append at:+file-tool-names+ (remove "bash" at:+shell-tool-names+ :test #'equal)
                         at:+unit-tool-names+)
                 (request-tool-names (first (scripted-requests backend))))))))

(deftest tools-settings-env-in-shell
  (with-project (project config) '((".cl-stack-code/settings.json"
                                    "{\"env\": {\"CL_STACK_CODE_TEST_VAR\": \"from-settings\"}}"))
    (let* ((out (nth-value 1 (streamed project config
                                       (list (bash-step (pick "echo $CL_STACK_CODE_TEST_VAR"
                                                              "echo %CL_STACK_CODE_TEST_VAR%"))
                                             "ok")
                                       "--permission-mode" "bypassPermissions"))))
      (ok (has "from-settings" (jget (result-named out "bash") "content"))))))

(deftest tools-lazy-agents-md
  (with-project (project config) '(("sub/AGENTS.md" "Sub rules: be careful.
") ("sub/x.txt" "x
"))
    (let* ((backend (nth-value 3 (code project config '("-p" "go")
                                       :steps (list (list :tool "read" (json-args "file_path" "sub/x.txt"))
                                                    "done"))))
           (requests (scripted-requests backend)))
      (ok (= 2 (length requests)))
      (ok (not (has "Sub rules" (request-text (first requests)))) "not at startup: below the cwd")
      (ok (has "Sub rules: be careful." (request-text (second requests)))
          "injected once a tool touched sub/"))))
