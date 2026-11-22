(in-package #:cl-stack-code/tests)

;;; H5a: preview mode (H5a plan mode, renamed in 0.15.0) in -p (src/headless.lisp header, "H5a").

(defun plan-run (project config steps &rest argv)
  "A stream-json plan run of PROJECT with prompt \"go\". → (values exit out
err backend)."
  (code project config (append '("-p" "--output-format" "stream-json" "--permission-mode" "preview")
                               argv '("go"))
        :steps steps))

(defun write-tool (file content)
  (list :tool "write" (json-args "file_path" file "content" content)))

(defun head-plan (project config session-id)
  "RECORD-PLAN of the head record of session SESSION-ID."
  (record-plan (revision-record (session-head (open-session (project-sessions project config)
                                                            session-id)))))

(defun the-plan-of (out)
  "The plan the stream-json run OUT opened or reopened, read from disk."
  (let ((opened (or (plan-event out "opened") (plan-event out "reopened"))))
    (find (jget opened "preview_id") (list-plans (uiop:ensure-directory-pathname
                                               (uiop:pathname-parent-directory-pathname
                                                (uiop:pathname-parent-directory-pathname
                                                 (uiop:parse-native-namestring (jget opened "area")
                                                                               :ensure-directory t)))))
          :key #'plan-id :test #'equal)))

;;; Flags.

(deftest-parametrize plan-cli-flag-errors
    ((argv needle)
     :ids ("apply-and-reject" "reject-with-prompt" "on-drift-alone" "apply-not-plan"
           "plan-area-not-plan" "bad-on-drift" "bad-plan-area")
     ('("--permission-mode" "preview" "--apply" "--reject" "x") "--apply and --reject cannot be used together")
     ('("--reject" "x") "--reject needs --resume or --continue and no prompt")
     ('("--permission-mode" "preview" "--on-drift" "rebase" "x") "--on-drift needs --apply")
     ('("--apply" "x") "--apply and --preview-area need --permission-mode preview")
     ('("--preview-area" "copy" "x") "--apply and --preview-area need --permission-mode preview")
     ('("--permission-mode" "preview" "--apply" "--on-drift" "maybe" "x") "unknown --on-drift \"maybe\"")
     ('("--permission-mode" "preview" "--preview-area" "zfs" "x") "unknown --preview-area \"zfs\""))
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config (cons "-p" argv) :steps '("unused")
                                                                               :input "from stdin")
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has needle err) err)
      (ok (null (project-plans project config)) "no plan was opened"))))

(deftest plan-cli-check-plan-flags
  (flet ((inv (&rest argv) (parse-arguments (cons "-p" argv))))
    (ok (check-plan-flags (inv "x") :default) "no plan flag")
    (ok (check-plan-flags (inv "--apply" "x") :preview))
    (ok (check-plan-flags (inv "--apply" "--on-drift" "rebase" "x") :preview))
    (ok (check-plan-flags (inv "--resume" "abcd" "--apply") :default) "action only needs no mode")
    (ok (check-plan-flags (inv "-c" "--reject") :default))
    (ok (typep (failure (check-plan-flags (inv "--apply" "x") :accept-edits)) 'code-usage-error))
    (ok (eq :rebase (invocation-on-drift (inv "--on-drift" "rebase" "x"))))
    (ok (eq :git (invocation-preview-area (inv "--preview-area" "git" "x"))))
    (ok (invocation-apply-p (inv "--apply" "x")))
    (ok (invocation-reject-p (inv "--reject" "x")))))

(deftest plan-cli-plan-area-git-needs-a-worktree
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--permission-mode" "preview" "--preview-area" "git" "x") :steps '("unused"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "--preview-area git" err))
      (ok (has "is not a git worktree" err)))))

;;; A plan run.

(deftest-parametrize plan-cli-text-output
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) '(("a.txt" "alpha
"))
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--permission-mode" "preview" "make it beta")
              :steps (list (write-tool "a.txt" (nl "beta")) "Done."))
      (ok (eql 0 exit))
      (ok (equal (nl "alpha") (read-file project "a.txt")) "the project is untouched")
      (let ((plan (only-plan project config)))
        (ok (eq kind (plan-kind plan)))
        (ok (eq :open (plan-status plan)))
        (ok (equal (nl "beta") (area-file plan "a.txt")) "the edit is in the area")
        (ok (equal (format nil "Done.~%~%~a"
                           (expected-diff (list (list "a.txt" (nl "alpha") (nl "beta")))))
                   out)
            "the answer, an empty line, the projected diff")
        (ok (has (format nil "preview ~a: 1 file changed, not applied" (plan-id plan)) err) err)
        (ok (has "--apply" err))))))

(deftest plan-cli-no-changes
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--permission-mode" "preview" "look") :steps '("Nothing to do."))
      (ok (eql 0 exit))
      (ok (equal (nl "Nothing to do.") out))
      (ok (has (format nil "preview ~a: no changes" (plan-id (only-plan project config))) err) err))))

(deftest-parametrize plan-cli-stream-json
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) '(("a.txt" "alpha
"))
    (multiple-value-bind (exit out) (plan-run project config (list (write-tool "a.txt" (nl "beta")) "Done."))
      (ok (eql 0 exit))
      (let* ((objects (json-lines out))
             (types (mapcar (lambda (o) (jget o "type")) objects))
             (plan (only-plan project config))
             (opened (plan-event out "opened"))
             (projected (plan-event out "projected"))
             (diff (expected-diff (list (list "a.txt" (nl "alpha") (nl "beta"))))))
        (ok (equal "system" (first types)))
        (ok (equal "preview" (second types)) "the preview event follows system init")
        (ok (equal "result" (car (last types))))
        (ok (equal "preview" (car (last types 2))) "projected comes right before the result")
        (ok (equal (plan-id plan) (jget opened "preview_id")))
        (ok (equal (string-downcase (string kind)) (jget opened "kind")))
        (ok (equal (native (plan-root plan)) (jget opened "area")))
        (ok (equal (plan-base plan) (jget opened "base")))
        (ok (equal '(("modified" "a.txt")) (json-changes (jget projected "changes"))))
        (ok (equal diff (jget projected "diff")))
        (let ((rp (result-plan out)))
          (ok (equal (plan-id plan) (jget rp "id")))
          (ok (equal "open" (jget rp "status")))
          (ok (equal (string-downcase (string kind)) (jget rp "kind")))
          (ok (equal diff (jget rp "diff")))
          (ok (equal '(("modified" "a.txt")) (json-changes (jget rp "changes"))))
          (ok (equalp #() (jget rp "conflicts"))))
        (ok (every (lambda (o) (equal (session-id-of out) (jget o "session_id"))) objects))))))

(deftest plan-cli-json
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (code project config '("-p" "--output-format" "json" "--permission-mode" "preview" "go")
              :steps (list (write-tool "b.txt" "new") "Done."))
      (ok (eql 0 exit))
      (ok (= 1 (length (lines out))))
      (let ((rp (jget (first (json-lines out)) "preview")))
        (ok (equal "open" (jget rp "status")))
        (ok (equal '(("added" "b.txt")) (json-changes (jget rp "changes"))))))))

(deftest plan-cli-other-modes-have-no-plan
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (code project config '("-p" "--output-format" "stream-json" "--permission-mode" "acceptEdits" "go")
              :steps (list (write-tool "a.txt" "beta") "Done."))
      (ok (eql 0 exit))
      (ok (equal "beta" (read-file project "a.txt")))
      (ok (null (plan-events out)))
      (ok (eq :absent (gethash "preview" (car (last (events out "result"))) :absent))
          "the result shape is unchanged")
      (ok (null (project-plans project config))))))

(deftest plan-cli-system-prompt
  (with-project (project config) '("sub/" ("AGENTS.md" "Rule one.
"))
    (multiple-value-bind (exit out err backend)
        (code project config '("-p" "--output-format" "stream-json" "--permission-mode" "preview" "go")
              :steps '("ok"))
      (declare (ignore exit err))
      (let* ((plan (the-plan-of out))
             (system (request-system (first-request backend))))
        (ok (has (format nil "- Working directory: ~a" (native (plan-root plan))) system))
        (ok (has (format nil "- Preview: ~a (copy), a copy of ~a" (plan-id plan) (native project)) system))
        (ok (has "- Permission mode: preview" system))
        (ok (has +preview-mode-feedback+ system))
        (ok (has "Rule one." system) "the instruction files are still read")))))

;;; Tools in the area.

(deftest plan-cli-tests-run-in-the-projection
  (if (not (unix-p))
      (skip "/bin/sh")
      (with-project (project config) '(("a.txt" "alpha"))
        (multiple-value-bind (exit out)
            (plan-run project config
                      (list (write-tool "a.txt" "beta")
                            (list :tool "bash" (json-args "command" "cat a.txt; echo; pwd"))
                            "Tested.")
                      "--allowed-tools" "bash")
          (ok (eql 0 exit))
          (let ((bash (find "bash" (events out "tool_result") :key (lambda (e) (jget e "name"))
                                                                :test #'equal))
                (plan (only-plan project config)))
            (ok (equal "done" (jget bash "status")))
            (ok (has "beta" (jget bash "content")) "the shell sees the area")
            (ok (has (dir-native (plan-root plan)) (jget bash "content")) "it runs in the area")
            (ok (equal "alpha" (read-file project "a.txt"))))))))

(deftest plan-cli-shell-needs-no-rule
  ;; 0.4.1 (was plan-cli-shell-still-asks): plan mode allows the shell in the
  ;; area without a rule, so -p runs it.
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (plan-run project config (list (list :tool "bash" (json-args "command" "echo hi")) "ok"))
      (ok (eql 0 exit))
      (let ((result (first (events out "tool_result"))))
        (ok (not (equal "denied" (jget result "status"))) "headless runs bash with no rule")
        (when (unix-p)
          (ok (equal "done" (jget result "status")))
          (ok (has "hi" (jget result "content"))))))))

(deftest plan-cli-shell-deny-and-ask-still-win
  (with-project (project config) '(("a.txt" "alpha")
                                   (".cl-stack-code/settings.json"
                                    "{\"permissions\": {\"ask\": [\"bash(git push *)\"]}}"))
    (multiple-value-bind (exit out)
        (plan-run project config (list (list :tools
                                             (list "bash" (json-args "command" "rm -rf build"))
                                             (list "bash" (json-args "command" "git push origin")))
                                       "ok")
                  "--disallowed-tools" "bash(rm *)")
      (ok (eql 0 exit))
      (let ((results (events out "tool_result")))
        (ok (= 2 (length results)))
        (ok (every (lambda (r) (equal "denied" (jget r "status"))) results)
            "a deny rule wins; an ask rule still asks, which -p refuses")))))

(deftest plan-cli-git-in-the-area
  (if (not (unix-p))
      (skip "/bin/sh")
      (with-git-project (project config) '(("a.txt" "alpha
"))
        (multiple-value-bind (exit out)
            (plan-run project config
                      (list (write-tool "a.txt" (nl "beta"))
                            (list :tool "bash" (json-args "command" "git status --porcelain"))
                            "ok")
                      "--allowed-tools" "bash")
          (ok (eql 0 exit))
          (ok (has " M a.txt" (jget (find "bash" (events out "tool_result")
                                          :key (lambda (e) (jget e "name")) :test #'equal)
                                    "content"))
              "the area is a git worktree")
          (ok (null (git-lines project "status" "--porcelain")) "the project is clean")))))

;;; --apply after the run.

(deftest-parametrize plan-cli-apply
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) '(("a.txt" "alpha
"))
    (multiple-value-bind (exit out err)
        (plan-run project config (list (write-tool "a.txt" (nl "beta")) "Done.") "--apply")
      (ok (eql 0 exit))
      (ok (equal (nl "beta") (read-file project "a.txt")) "applied")
      (let ((plan (only-plan project config)))
        (ok (eq :applied (plan-status plan)))
        (ok (not (uiop:directory-exists-p (plan-root plan))))
        (ok (equal '(("modified" "a.txt")) (json-changes (jget (plan-event out "applied") "changes"))))
        (ok (equal "applied" (jget (result-plan out) "status")))
        (ok (has (format nil "preview ~a: applied 1 file" (plan-id plan)) err) err)
        (ok (eq :applied (getf (head-plan project config (session-id-of out)) :status))
            "the turn record has the plan after --apply")))))

(deftest plan-cli-apply-needs-a-good-run
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (plan-run project config (list (write-tool "a.txt" "beta") (write-tool "a.txt" "gamma"))
                  "--apply" "--max-turns" "1")
      (ok (eql 1 exit))
      (ok (equal "error_max_turns" (jget (car (last (events out "result"))) "subtype")))
      (ok (null (plan-event out "applied")))
      (ok (equal "alpha" (read-file project "a.txt")) "nothing applied")
      (ok (eq :open (plan-status (only-plan project config)))))))

;;; Sessions.

(deftest-parametrize plan-cli-resume-reopens
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) '(("a.txt" "alpha"))
    (let* ((out1 (nth-value 1 (plan-run project config (list (write-tool "a.txt" "beta") "one"))))
           (session (session-id-of out1))
           (id (jget (plan-event out1 "opened") "preview_id")))
      (ok (equal id (getf (head-plan project config session) :id)) "the turn record names the plan")
      (ok (eq :open (getf (head-plan project config session) :status)))
      (ok (eq kind (getf (head-plan project config session) :kind)))
      (multiple-value-bind (exit out2 err backend)
          (plan-run project config (list (list :tool "read" (json-args "file_path" "a.txt")) "two")
                    "--resume" session)
        (declare (ignore err))
        (ok (eql 0 exit))
        (ok (equal id (jget (plan-event out2 "reopened") "preview_id")) "the same plan")
        (ok (null (plan-event out2 "opened")))
        (ok (has "beta" (result-content (car (last (tool-results-of backend)))))
            "the second turn sees the first turn's edit")
        (ok (= 1 (length (project-plans project config))))
        (ok (equal "alpha" (read-file project "a.txt")))))))

(deftest plan-cli-resume-after-apply-opens-a-new-plan
  (with-project (project config) '(("a.txt" "alpha"))
    (let* ((out1 (nth-value 1 (plan-run project config (list (write-tool "a.txt" "beta") "one") "--apply")))
           (old (jget (plan-event out1 "opened") "preview_id")))
      (multiple-value-bind (exit out2 err)
          (plan-run project config '("two") "--resume" (session-id-of out1))
        (ok (eql 0 exit))
        (ok (plan-event out2 "opened"))
        (ok (not (equal old (jget (plan-event out2 "opened") "preview_id"))))
        (ok (not (has "no longer open" err)) "an applied plan is not a lost one")))))

(deftest plan-cli-resume-lost-plan
  (with-project (project config) '(("a.txt" "alpha"))
    (let* ((out1 (nth-value 1 (plan-run project config (list (write-tool "a.txt" "beta") "one"))))
           (old (the-plan-of out1)))
      (uiop:delete-directory-tree (plan-root old) :validate t)
      (multiple-value-bind (exit out2 err)
          (plan-run project config '("two") "--resume" (session-id-of out1))
        (ok (eql 0 exit))
        (let ((new (jget (plan-event out2 "opened") "preview_id")))
          (ok new)
          (ok (has (format nil "preview ~a is no longer open; opened preview ~a" (plan-id old) new) err)
              err))))))

;;; Action only.

(deftest-parametrize plan-cli-action-apply
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) '(("a.txt" "alpha
"))
    (let* ((out1 (nth-value 1 (plan-run project config (list (write-tool "a.txt" (nl "beta")) "one"))))
           (session (session-id-of out1))
           (diff (jget (plan-event out1 "projected") "diff")))
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--resume" session "--apply")
                :steps '() :input "must not be read")
        (ok (eql 0 exit) err)
        (ok (equal diff out) "the applied diff")
        (ok (equal (nl "beta") (read-file project "a.txt")))
        (ok (null (scripted-requests backend)) "no LLM call")
        (ok (has "applied 1 file" err))
        (ok (eq :applied (plan-status (only-plan project config))))
        (ok (= 1 (length (session-records (open-session (project-sessions project config) session))))
            "no turn committed")))))

(deftest plan-cli-action-stream-json
  (with-project (project config) '(("a.txt" "alpha"))
    (let* ((out1 (nth-value 1 (plan-run project config (list (write-tool "a.txt" "beta") "one"))))
           (session (session-id-of out1)))
      (multiple-value-bind (exit out)
          (code project config (list "-p" "--output-format" "stream-json" "--continue" "--apply")
                :steps '())
        (ok (eql 0 exit))
        (ok (equal '("preview" "result") (mapcar (lambda (o) (jget o "type")) (json-lines out))))
        (ok (equal "applied" (jget (first (json-lines out)) "subtype")))
        (let ((result (second (json-lines out))))
          (ok (equal "success" (jget result "subtype")))
          (ok (eql 0 (jget result "num_turns")))
          (ok (equal "" (jget result "result")))
          (ok (equal session (jget result "session_id")))
          (ok (equal "applied" (jget result "preview" "status"))))))))

(deftest plan-cli-action-reject
  (with-project (project config) '(("a.txt" "alpha"))
    (let ((out1 (nth-value 1 (plan-run project config (list (write-tool "a.txt" "beta") "one")))))
      (multiple-value-bind (exit out err)
          (code project config (list "-p" "--resume" (session-id-of out1) "--reject") :steps '())
        (ok (eql 0 exit))
        (ok (equal "" out))
        (let ((plan (only-plan project config)))
          (ok (has (format nil "preview ~a: discarded" (plan-id plan)) err))
          (ok (eq :discarded (plan-status plan)))
          (ok (not (uiop:directory-exists-p (plan-root plan)))))
        (ok (equal "alpha" (read-file project "a.txt")))))))

(deftest plan-cli-action-without-an-open-plan
  (with-project (project config) '(("a.txt" "alpha"))
    (let ((out1 (nth-value 1 (code project config '("-p" "--output-format" "stream-json" "hi")
                                   :steps '("hello")))))
      (multiple-value-bind (exit out err)
          (code project config (list "-p" "--resume" (session-id-of out1) "--apply") :steps '())
        (ok (eql 2 exit))
        (ok (equal "" out))
        (ok (has "has no open preview" err))))))

;;; Drift on --apply.

(deftest-parametrize plan-cli-drift
    ((kind on-drift)
     :ids ("copy-abort" "git-abort" "copy-overwrite" "git-overwrite" "copy-rebase" "git-rebase")
     (:copy nil) (:git nil) (:copy "overwrite") (:git "overwrite") (:copy "rebase") (:git "rebase"))
  (with-kind-project (kind project config) (list (list "a.txt" +ten-lines+))
    (let* ((out1 (nth-value 1 (plan-run project config
                                        (list (write-tool "a.txt" (replace-line +ten-lines+ "1" "one"))
                                              "one"))))
           (session (session-id-of out1))
           (plan (the-plan-of out1))
           (user (replace-line +ten-lines+ "10" "ten")))
      (write-file project "a.txt" user)
      (multiple-value-bind (exit out err)
          (code project config (append (list "-p" "--output-format" "stream-json" "--resume" session "--apply")
                                       (and on-drift (list "--on-drift" on-drift)))
                :steps '())
        (cond
          ((null on-drift)
           (ok (eql 1 exit))
           (ok (has "a.txt" err) err)
           (ok (has "--on-drift rebase or --on-drift overwrite" err))
           (ok (equal '("a.txt") (coerce (jget (plan-event out "drift") "paths") 'list)))
           (ok (equal user (read-file project "a.txt")) "nothing applied")
           (ok (eq :open (plan-status (reopen-plan (project-plans-dir project config) (plan-id plan))))))
          ((equal on-drift "overwrite")
           (ok (eql 0 exit) err)
           (ok (equal (replace-line +ten-lines+ "1" "one") (read-file project "a.txt"))))
          (t
           (ok (eql 1 exit))
           (ok (has "rebased onto the working copy (no conflicts); review it and --apply again" err) err)
           (ok (plan-event out "rebased"))
           (ok (equal user (read-file project "a.txt")) "a rebase applies nothing")
           (let ((merged (replace-line (replace-line +ten-lines+ "1" "one") "10" "ten")))
             (ok (equal merged (area-file plan "a.txt")))
             (ok (eql 0 (code project config (list "-p" "--resume" session "--apply") :steps '()))
                 "apply again")
             (ok (equal merged (read-file project "a.txt"))))))))))
