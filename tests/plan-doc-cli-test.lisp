(in-package #:cl-stack-code/tests)

;;; H5c-0: plan mode in -p (src/plan-docs.lisp header, HEADLESS), with the
;;; scripted mock LLM. The exploration shell runs through the suite's model
;;; confinement backend (or a RECORDING-BACKEND), as in tests/sandbox-cli-test.

(defun doc-area (project config doc)
  "The exploration area (an H5a PLAN) of DOC, or NIL."
  (find (plan-document-area-id doc) (project-plans project config) :key #'plan-id :test #'equal))

(defun proposed-run (project config &rest argv)
  "A plan run that proposes +PLAN-MD+. → (values exit out err backend)."
  (apply #'plan-doc-run project config (list (propose-step)) argv))

;;; Exploring.

(deftest plan-doc-cli-edit-refused
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (plan-doc-run project config (list (write-tool "a.txt" "beta") (propose-step)))
      (ok (eql 0 exit))
      (let ((write (doc-tool-result out "write")))
        (ok (equal "denied" (jget write "status")) "the edit is refused")
        (ok (has "plan mode" (jget write "content")))
        (ok (has "propose_plan" (jget write "content")) "with feedback: propose instead"))
      (ok (equal "alpha" (read-file project "a.txt")) "the project is untouched")
      (let ((area (doc-area project config (only-plan-doc project config))))
        (ok area "the plan has an exploration area")
        (ok (equal "alpha" (area-file area "a.txt")) "the copy is untouched too")))))

(deftest plan-doc-cli-edit-refused-despite-an-allow-rule
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (plan-doc-run project config (list (write-tool "a.txt" "beta") (propose-step))
                      "--allowed-tools" "write")
      (ok (eql 0 exit))
      (ok (equal "denied" (jget (doc-tool-result out "write") "status"))
          "the policy only tightens: an allow rule does not lift it")
      (ok (equal "alpha" (read-file project "a.txt"))))))

(deftest plan-doc-cli-scratch-write
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out)
        (plan-doc-run project config (list (write-tool ".plan-scratch/try.sh" "echo try") (propose-step)))
      (ok (eql 0 exit))
      (ok (equal "done" (jget (doc-tool-result out "write") "status")) "scratch is writable")
      (let ((area (doc-area project config (only-plan-doc project config))))
        (ok (equal "echo try" (area-file area ".plan-scratch/try.sh"))))
      (ok (not (probe-file (merge-pathnames ".plan-scratch/" project))) "nothing in the project"))))

(deftest plan-doc-cli-exploratory-bash-is-confined
  (with-project (project config) '(("a.txt" "alpha"))
    (with-plan-backend (b)
      (multiple-value-bind (exit out)
          (plan-doc-run project config (list (bash-step "cat a.txt; echo made > made.txt") (propose-step)))
        (ok (eql 0 exit))
        (let* ((area (doc-area project config (only-plan-doc project config)))
               (launch (first (command-launches b))))
          (ok (equal "done" (jget (doc-tool-result out "bash") "status")) "no approval needed while confined")
          (ok launch "bash ran through the confining backend")
          (when launch
            (ok (equal (dir-key (plan-root area)) (dir-key (recorded-launch-directory launch)))
                "in the exploration area")
            (ok (eq :none (sc:confinement-network (recorded-launch-confinement launch))) "network off")
            (ok (member (dir-key (plan-root area))
                        (dir-keys (sc:confinement-writable (recorded-launch-confinement launch)))
                        :test #'equal)))
          (when (unix-p)
            (ok (has "alpha" (jget (doc-tool-result out "bash") "content")))
            (ok (equal (nl "made") (area-file area "made.txt")) "the experiment wrote into the copy")))
        (ok (not (probe-file (merge-pathnames "made.txt" project))) "the project is unchanged")))))

(deftest plan-doc-cli-no-sandbox-asks
  (with-project (project config) '()
    (with-plan-backend (b nil)
      (multiple-value-bind (exit out err)
          (plan-doc-run project config (list (bash-step "echo hi") (propose-step)))
        (ok (eql 0 exit))
        (ok (equal "denied" (jget (doc-tool-result out "bash") "status"))
            "unconfined, bash asks and -p refuses (R4d-4b)")
        (ok (has "no sandbox" err))))))

;;; Proposing.

(deftest plan-doc-cli-propose-text
  (with-project (project config) '(("hello.sh" ""))
    (multiple-value-bind (exit out err backend)
        (code project config '("-p" "--permission-mode" "plan" "add a greeting")
              :steps (list (propose-step) "never reached"))
      (ok (eql 0 exit))
      (let* ((doc (only-plan-doc project config))
             (id (plan-document-id doc)))
        (ok (eq :proposed (plan-document-status doc)))
        (ok (equal +plan-md+ (doc-md doc)) "plan.md is the proposal")
        (ok (equal (format nil "~%~a" +plan-md+) out) "an empty line, then the plan")
        (ok (has (format nil "plan ~a r1: proposed; review ~a" id (native (plan-document-path doc))) err) err)
        (ok (has "--approve-plan" err))
        (ok (has "--reject-plan" err))
        (ok (= 1 (length (scripted-requests backend))) "the run ends with propose_plan")
        (ok (equal "" (read-file project "hello.sh")) "nothing is implemented")))))

(deftest plan-doc-cli-propose-stream-json
  (with-project (project config) '()
    (multiple-value-bind (exit out) (proposed-run project config)
      (ok (eql 0 exit))
      (let* ((doc (only-plan-doc project config))
             (types (mapcar (lambda (o) (jget o "type")) (json-lines out)))
             (opened (doc-event out "opened"))
             (proposed (doc-event out "proposed"))
             (rp (result-doc out)))
        (ok (equal "system" (first types)))
        (ok (equal "plan" (second types)) "opened follows system init")
        (ok (equal "result" (car (last types))))
        (ok (equal (plan-document-id doc) (jget opened "plan_id")))
        (ok (eql 0 (jget opened "revision")))
        (ok (equal (native (plan-root (doc-area project config doc))) (jget opened "area")))
        (ok (hash-table-p (jget opened "sandbox")))
        (ok (eql 1 (jget proposed "revision")))
        (ok (equal "Add a greeting" (jget proposed "title")))
        (ok (equal +plan-md+ (jget proposed "markdown")))
        (ok (equal "Add a test for it" (jget proposed "steps" 1 "text")))
        (ok (equalp #("hello.sh" "tests/hello-test.sh") (jget proposed "files")))
        (ok (equal (plan-document-id doc) (jget rp "id")))
        (ok (equal "proposed" (jget rp "status")))
        (ok (equal (native (plan-document-path doc)) (jget rp "path")))
        (ok (null (events out "preview")) "no preview events in plan mode")))))

(deftest plan-doc-cli-no-proposal
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--output-format" "stream-json" "--permission-mode" "plan" "what is a.txt?")
              :steps (list (list :tool "read" (json-args "file_path" "a.txt")) "It says alpha."))
      (ok (eql 0 exit) "answering without a plan is fine")
      (ok (eq :null (result-doc out)) "the result's plan is null")
      (let ((doc (only-plan-doc project config)))
        (ok (eq :drafting (plan-document-status doc)))
        (ok (has (format nil "plan ~a: no plan proposed yet" (plan-document-id doc)) err))))))

(deftest plan-doc-cli-result-plan-only-in-plan-runs
  (with-project (project config) '()
    (let ((out (nth-value 1 (code project config '("-p" "--output-format" "stream-json" "hi") :steps '("hello")))))
      (ok (eq :absent (result-doc out)))
      (ok (null (doc-events out))))))

(deftest plan-doc-cli-bad-plan-is-a-tool-error
  (with-project (project config) '()
    (multiple-value-bind (exit out)
        (plan-doc-run project config (list (propose-step "## Goal
only a goal
") (propose-step)))
      (ok (eql 0 exit))
      (let ((first-result (first (remove-if-not (lambda (e) (equal "propose_plan" (jget e "name")))
                                                (events out "tool_result")))))
        (ok (equal "error" (jget first-result "status")))
        (ok (has "missing Steps" (jget first-result "content")))
        (ok (has "## Steps" (jget first-result "content")) "the template is shown"))
      (ok (eql 1 (plan-document-revision (only-plan-doc project config))) "the retry is revision 1"))))

(deftest plan-doc-cli-system-prompt
  (with-project (project config) '()
    (multiple-value-bind (exit out err backend) (proposed-run project config)
      (declare (ignore exit err))
      (let* ((doc (only-plan-doc project config))
             (system (request-system (first-request backend))))
        (ok (has +plan-mode-section+ system))
        (ok (has +default-plan-template+ system))
        (ok (has (format nil "- Working directory: ~a" (native (plan-root (doc-area project config doc)))) system))
        (ok (has "- Permission mode: plan" system))
        (ok (not (has +preview-mode-feedback+ system)))
        (ok (null (jget (first (json-lines out)) "plan")) "init is unchanged")
        (ok (member "propose_plan" (request-tool-names (first-request backend)) :test #'equal))
        (ok (member "ask_user" (request-tool-names (first-request backend)) :test #'equal))
        (ok (not (member "update_plan" (request-tool-names (first-request backend)) :test #'equal)))))))

(deftest plan-doc-cli-spec-template
  (with-project (project config) '()
    (project-settings project "{\"planTemplate\": \"spec\"}")
    (multiple-value-bind (exit out err backend)
        (plan-doc-run project config (list (propose-step +spec-md+)))
      (declare (ignore err))
      (ok (eql 0 exit))
      (ok (has +spec-plan-template+ (request-system (first-request backend))))
      (ok (equal "proposed" (jget (result-doc out) "status")))
      (ok (equal '("Write the script" "Test it")
                 (mapcar #'plan-step-text (plan-document-steps (only-plan-doc project config))))))))

(deftest plan-doc-cli-ask-user-headless
  (with-project (project config) '()
    (multiple-value-bind (exit out)
        (plan-doc-run project config (list (ask-step "French or English?" "French" "English") (propose-step)))
      (ok (eql 0 exit))
      (let ((ask (doc-tool-result out "ask_user")))
        (ok (equal "done" (jget ask "status")))
        (ok (equal +ask-user-unavailable+ (jget ask "content")) "nobody can answer in -p")))))

(deftest plan-doc-cli-propose-only
  (with-project (project config) '()
    (multiple-value-bind (exit out)
        (code project config '("-p" "--output-format" "stream-json" "--propose-only" "go")
              :steps (list (propose-step)))
      (ok (eql 0 exit))
      (ok (equal "plan" (jget (first (json-lines out)) "permission_mode")))
      (ok (equal "proposed" (jget (result-doc out) "status"))))))

;;; Flags.

(deftest-parametrize plan-doc-cli-flag-errors
    ((argv needle)
     :ids ("approve-and-reject" "approve-no-resume" "reject-no-resume" "save-no-resume"
           "reject-with-prompt" "save-with-prompt" "approve-in-plan" "propose-only-other-mode"
           "propose-only-approve" "apply-in-plan")
     ('("--continue" "--approve-plan" "--reject-plan") "--approve-plan and --reject-plan cannot be used together")
     ('("--approve-plan" "x") "--approve-plan needs --resume or --continue")
     ('("--reject-plan") "--reject-plan needs --resume or --continue")
     ('("--save-plan") "--save-plan needs --resume or --continue")
     ('("--continue" "--reject-plan" "x") "--reject-plan takes no prompt")
     ('("--continue" "--save-plan" "x") "--save-plan takes no prompt")
     ('("--continue" "--approve-plan" "--permission-mode" "plan") "--approve-plan runs the plan: --permission-mode must be default, acceptEdits, bypassPermissions or preview")
     ('("--propose-only" "--permission-mode" "acceptEdits" "x") "--propose-only is --permission-mode plan")
     ('("--continue" "--propose-only" "--approve-plan") "--propose-only and --approve-plan cannot be used together")
     ('("--permission-mode" "plan" "--apply" "x") "--apply and --reject act on a preview: use --permission-mode preview"))
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config (cons "-p" argv) :steps '("unused"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has needle err) err)
      (ok (null (project-plan-docs project config)) "no plan was opened"))))

(deftest plan-doc-cli-flags-parse
  (flet ((inv (&rest argv) (parse-arguments (cons "-p" argv))))
    (ok (invocation-approve-plan-p (inv "--continue" "--approve-plan")))
    (ok (invocation-reject-plan-p (inv "--continue" "--reject-plan")))
    (ok (invocation-save-plan-p (inv "--continue" "--save-plan")))
    (ok (invocation-propose-only-p (inv "--propose-only" "x")))
    (ok (eq :copy (invocation-preview-area (inv "--preview-area" "copy" "x"))))))

(deftest plan-doc-cli-plan-area-alias
  (with-project (project config) '(("a.txt" "alpha"))
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--permission-mode" "preview" "--plan-area" "copy" "go")
              :steps (list (write-tool "a.txt" "beta") "Done."))
      (declare (ignore out))
      (ok (eql 0 exit) "--plan-area still works in 0.15.x")
      (ok (eq :copy (plan-kind (only-plan project config))))
      (ok (= 1 (count-substring "cl-stack-code: --plan-area is deprecated; use --preview-area" err)) "once"))))

;;; Approving and executing.

(defun proposed-session (project config &rest argv)
  "Propose +PLAN-MD+ in a plan run. → its session id."
  (session-id-of (nth-value 1 (apply #'proposed-run project config argv))))

(defun execution-steps ()
  (list (update-step 1 "in_progress")
        (write-tool "hello.sh" (nl "echo hello"))
        (update-step 1 "done")
        "Done."))

;;; #66: headless --approve-plan (acceptEdits) cannot ask, so the commands
;;; the approved plan's "Test plan" quotes are allowed for its execution run;
;;; any other command still asks, which -p refuses.

(deftest plan-doc-cli-approve-runs-the-test-plan-commands
  (with-project (project config) '(("hello.sh" "") ("tests/hello-test.sh" "echo ran > ran.txt"))
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out err)
          (code project config (list "-p" "--output-format" "stream-json" "--resume" session "--approve-plan")
                :steps (list (write-tool "hello.sh" (nl "echo hello"))
                             (bash-step "sh tests/hello-test.sh")
                             (bash-step "touch other.txt")
                             "Done."))
        (ok (eql 0 exit))
        (let ((bashes (tool-results out "bash")))
          (ok (= 2 (length bashes)))
          (ok (not (equal "denied" (jget (first bashes) "status")))
              (format nil "the Test plan's command runs: ~a" (jget (first bashes) "content")))
          (ok (equal "denied" (jget (second bashes) "status")) "another command still asks, which -p refuses")
          (ok (has +headless-denial-feedback+ (jget (second bashes) "content"))))
        (ok (file-exists project "ran.txt") "the test ran in the project")
        (ok (not (file-exists project "other.txt")))
        (ok (has "sh tests/hello-test.sh" err) "stderr names the allowed commands")))))

(deftest plan-test-commands-from-the-test-plan
  (with-project (project config) '()
    (let* ((session (proposed-session project config))
           (doc (only-plan-doc project config))
           (policy (plan-test-command-policy doc)))
      (declare (ignore session))
      (ok (equal '("sh tests/hello-test.sh") (plan-test-commands doc)))
      (ok (plan-test-command-permits-p policy "sh tests/hello-test.sh"))
      (ok (plan-test-command-permits-p policy "  sh tests/hello-test.sh ") "trimmed")
      (ok (not (plan-test-command-permits-p policy "sh tests/hello-test.sh; rm -rf ~")) "exactly the command")
      (ok (not (plan-test-command-permits-p policy "touch other.txt")))
      (ok (not (plan-test-command-permits-p nil "sh tests/hello-test.sh")) "no policy, no approval"))))

(deftest-parametrize plan-test-commands-of-markdown
    ((test-plan expected)
     :ids ("code-spans" "code-block" "compound-as-quoted" "glob-skipped" "none" "duplicates")
     ("Run `make test` and `sh t.sh -v`." '("make test" "sh t.sh -v"))
     ((format nil "Run:~%~%```sh~%# the suite~%make test~%~%./run-tests --fast~%```~%")
      '("make test" "./run-tests --fast"))
     ("`sh greet.sh; sh greet.sh Ada`" '("sh greet.sh; sh greet.sh Ada"))
     ("`rm *.o` then `make`" '("make"))
     ("Read the output by hand." '())
     ("`make` - `make`" '("make")))
  (let ((got (test-plan-commands
              (format nil "# T~%~%## Goal~%g~%~%## Steps~%1. s~%~%## Test plan~%~a~%~%## Notes~%`not this`~%"
                      test-plan))))
    (ok (equal expected got) (format nil "~s" got))))

(deftest plan-doc-cli-approve-executes-in-the-project
  (with-project (project config) '(("hello.sh" ""))
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--output-format" "stream-json" "--resume" session "--approve-plan")
                :steps (execution-steps))
        (declare (ignore err))
        (ok (eql 0 exit))
        (ok (equal (nl "echo hello") (read-file project "hello.sh")) "the edit lands in the project")
        (ok (equal "acceptEdits" (jget (first (json-lines out)) "permission_mode")) "acceptEdits by default")
        (let ((doc (only-plan-doc project config))
              (first-request (first (scripted-requests backend))))
          (ok (has (plan-execution-prompt doc) (request-texts first-request)) "the plan is the turn's instructions")
          (ok (member "update_plan" (request-tool-names first-request) :test #'equal))
          (ok (not (member "propose_plan" (request-tool-names first-request) :test #'equal)))
          (ok (eq :executed (plan-document-status doc)))
          (ok (equal '(:done :pending) (step-statuses doc)))
          (ok (null (doc-area project config doc)) "the exploration area is gone"))
        (let ((approved (doc-event out "approved")))
          (ok approved)
          (ok (equal "acceptEdits" (jget approved "mode")))
          (ok (eql 1 (jget approved "revision"))))
        (let ((steps (doc-events-of out "step")))
          (ok (equal '((1 "in_progress") (1 "done"))
                     (mapcar (lambda (e) (list (jget e "step") (jget e "status"))) steps)))
          (ok (equal "done" (jget (second steps) "steps" 0 "status")) "the whole checklist each time"))
        (let ((executed (doc-event out "executed")))
          (ok (equal "executed" (jget executed "status")))
          (ok (equal '(("modified" "hello.sh")) (json-changes (jget executed "changes"))))
          (ok (equal "tests/hello-test.sh" (jget executed "rows" 1 "path")))
          (ok (eq :null (gethash "change" (jget executed "rows" 1))) "planned, unchanged")
          (ok (eq t (jget executed "rows" 0 "planned")))
          (ok (has "+echo hello" (jget executed "diff"))))
        (ok (equal "executed" (jget (result-doc out) "status")))))))

(deftest plan-doc-cli-approve-text-shows-plan-versus-diff
  (with-project (project config) '(("hello.sh" ""))
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out)
          (code project config (list "-p" "--resume" session "--approve-plan") :steps (execution-steps))
        (ok (eql 0 exit))
        (let ((doc (only-plan-doc project config)))
          (ok (has (format nil "Done.~%~%~{~a~%~}" (plan-versus-diff-lines doc '((:modified "hello.sh")))) out)
              "the answer, then the plan next to the diff")
          (ok (has (expected-diff (list (list "hello.sh" "" (nl "echo hello")))) out) "then the diff"))))))

(deftest plan-doc-cli-approve-with-extra-instructions
  (with-project (project config) '(("hello.sh" ""))
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--resume" session "--approve-plan" "use printf")
                :steps (list "ok"))
        (declare (ignore out err))
        (ok (eql 0 exit))
        (ok (has (plan-execution-prompt (only-plan-doc project config) "use printf")
                 (request-texts (first (scripted-requests backend)))))))))

(deftest plan-doc-cli-approve-default-mode-still-asks
  (with-project (project config) '(("hello.sh" ""))
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out)
          (code project config (list "-p" "--output-format" "stream-json" "--resume" session
                                     "--approve-plan" "--permission-mode" "default")
                :steps (list (write-tool "hello.sh" "x") "Could not write."))
        (ok (eql 0 exit))
        (ok (equal "denied" (jget (doc-tool-result out "write") "status"))
            "default mode asks before edits, and -p refuses")
        (ok (equal "" (read-file project "hello.sh")))
        (ok (equal "default" (jget (doc-event out "approved") "mode")))))))

(deftest plan-doc-cli-approve-in-preview
  (with-project (project config) '(("hello.sh" ""))
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out err)
          (code project config (list "-p" "--output-format" "stream-json" "--resume" session
                                     "--approve-plan" "--permission-mode" "preview")
                :steps (execution-steps))
        (ok (eql 0 exit))
        (ok (equal "" (read-file project "hello.sh")) "a preview: the project is untouched")
        (let ((preview (only-plan project config)))
          (ok (equal (nl "echo hello") (area-file preview "hello.sh")) "the change is in the preview")
          (ok (plan-event out "projected") "the preview's events")
          (ok (has (format nil "preview ~a: 1 file changed, not applied" (plan-id preview)) err)))
        (ok (equal "preview" (jget (doc-event out "approved") "mode")))
        (ok (equal '(("modified" "hello.sh"))
                   (json-changes (jget (doc-event out "executed") "changes")))
            "plan versus the projected changes")))))

(deftest plan-doc-cli-approve-in-preview-then-apply
  (with-project (project config) '(("hello.sh" ""))
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out err)
          (code project config (list "-p" "--resume" session "--approve-plan"
                                     "--permission-mode" "preview" "--apply")
                :steps (execution-steps))
        (declare (ignore out err))
        (ok (eql 0 exit))
        (ok (equal (nl "echo hello") (read-file project "hello.sh")) "applied after the run")))))

(deftest plan-doc-cli-approve-without-a-plan
  (with-project (project config) '()
    (let ((session (session-id-of (nth-value 1 (code project config '("-p" "--output-format" "stream-json" "hi")
                                                     :steps '("hello"))))))
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--resume" session "--approve-plan") :steps '("unused"))
        (declare (ignore out))
        (ok (eql 2 exit))
        (ok (has (format nil "session ~a has no plan to approve" session) err))
        (ok (null (scripted-requests backend)))))))

(deftest plan-doc-cli-approve-the-users-edit
  (with-project (project config) '(("hello.sh" ""))
    (let* ((session (proposed-session project config))
           (doc (only-plan-doc project config)))
      (write-file (plan-document-directory doc) "plan.md" +plan-md-2+)
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--resume" session "--approve-plan") :steps (list "ok"))
        (declare (ignore out err))
        (ok (eql 0 exit))
        (ok (has "bonjour" (request-texts (first (scripted-requests backend)))) "the edited plan runs")
        (let ((records (line-plan-records project config session)))
          (ok (equal '(1 2) (remove-duplicates (mapcar (lambda (r) (getf r :revision)) records))))
          (ok (find :user records :key (lambda (r) (getf r :author))) "the user's revision is recorded"))))))

;;; Revise and reject.

(deftest plan-doc-cli-revise
  (with-project (project config) '()
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--output-format" "stream-json" "--resume" session
                                     "--permission-mode" "plan" "in French, and the README too")
                :steps (list (propose-step +plan-md-2+)))
        (declare (ignore err))
        (ok (eql 0 exit))
        (ok (equal "reopened" (jget (first (doc-events out)) "subtype")) "the same plan")
        (ok (eql 2 (jget (doc-event out "proposed") "revision")))
        (ok (has "in French" (request-texts (first (scripted-requests backend)))))
        (let ((doc (only-plan-doc project config)))
          (ok (eql 2 (plan-document-revision doc)))
          (ok (equal +plan-md-2+ (doc-md doc)))
          (ok (equal "in French, and the README too"
                     (plan-revision-feedback (second (plan-document-revisions doc))))))
        (let ((records (line-plan-records project config session)))
          (ok (equal '(1 2) (mapcar (lambda (r) (getf r :revision)) records)) "each revision in the record")
          (ok (equal (list +plan-md+ +plan-md-2+) (mapcar (lambda (r) (getf r :markdown)) records))))))))

(deftest plan-doc-cli-reject
  (with-project (project config) '()
    (let* ((session (proposed-session project config))
           (doc (only-plan-doc project config))
           (area (doc-area project config doc)))
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--output-format" "stream-json" "--resume" session "--reject-plan")
                :steps '())
        (declare (ignore backend))
        (ok (eql 0 exit))
        (ok (equal "rejected" (jget (doc-event out "rejected") "subtype")))
        (ok (has (format nil "plan ~a: rejected" (plan-document-id doc)) err))
        (ok (eq :rejected (plan-document-status (only-plan-doc project config))))
        (ok (not (uiop:directory-exists-p (plan-root area))) "the exploration area is discarded"))
      (ok (eql 2 (code project config (list "-p" "--resume" session "--approve-plan") :steps '("x")))
          "a rejected plan cannot run"))))

(deftest plan-doc-cli-save
  (with-project (project config) '()
    (let ((session (proposed-session project config)))
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--resume" session "--save-plan") :steps '())
        (declare (ignore err))
        (ok (eql 0 exit))
        (ok (null (scripted-requests backend)) "no LLM call")
        (let ((path (uiop:parse-native-namestring (string-trim '(#\Newline) out))))
          (ok (uiop:subpathp path (merge-pathnames "docs/plans/" project)))
          (ok (equal +plan-md+ (uiop:read-file-string path))))))))

;;; Records.

(deftest plan-doc-cli-tree-and-export
  (with-project (project config) '()
    (let* ((session (proposed-session project config))
           (store (open-session (project-sessions project config) session)))
      (ok (some (lambda (line) (has " ✎ r1" line)) (session-tree-lines store)) "/tree marks the revision")
      (let ((md (with-output-to-string (s) (export-session store s :format :markdown))))
        (ok (has (format nil "### Plan ~a revision 1" (subseq (plan-document-id (only-plan-doc project config)) 0 8)) md))
        (ok (has "## Steps" md) "the export carries the plan")))))

(deftest plan-doc-cli-rewind-restores-the-revision
  (with-project (project config) '()
    (let ((session (proposed-session project config)))
      (code project config (list "-p" "--resume" session "--permission-mode" "plan" "more")
            :steps (list (propose-step +plan-md-2+)))
      (ok (equal +plan-md-2+ (doc-md (only-plan-doc project config))))
      (multiple-value-bind (exit out err)
          (code project config (list "-p" "--resume" session "--rewind" "1" "--rewind-mode" "conversation")
                :steps '())
        (declare (ignore out))
        (ok (eql 0 exit) err)
        (let ((doc (only-plan-doc project config)))
          (ok (eql 1 (plan-document-revision doc)) "back to the revision on the rewound line")
          (ok (equal +plan-md+ (doc-md doc)))
          (ok (eq :proposed (plan-document-status doc))))))))

;;; Migration.

(deftest plan-doc-cli-migration-notice-once
  (with-project (project config) '()
    (user-settings config "{\"permissionMode\": \"plan\"}")
    (let ((err1 (nth-value 2 (code project config '("-p" "go") :steps (list (propose-step)))))
          (err2 (nth-value 2 (code project config '("-p" "again") :steps (list (propose-step))))))
      (ok (has (format nil "cl-stack-code: ~a" +plan-mode-migration-notice+) err1) err1)
      (ok (not (has +plan-mode-migration-notice+ err2)) "only the first time")
      (ok (probe-file (merge-pathnames "notices/plan-mode-0.15" (data-dir-of config))) "the marker"))
    (ok (eq :plan (settings-permission-mode (load-settings project :user-config-dir config)))
        "permissionMode plan is the new plan mode")))

(deftest plan-doc-cli-preview-mode-gives-no-notice
  (with-project (project config) '()
    (let ((err (nth-value 2 (code project config '("-p" "--permission-mode" "preview" "go") :steps '("ok")))))
      (ok (not (has +plan-mode-migration-notice+ err))))))
