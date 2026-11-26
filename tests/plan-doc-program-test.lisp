(in-package #:cl-stack-code/tests)

;;; H5c-0: plan mode in the interactive program (src/plan-docs.lisp header,
;;; INTERACTIVE), on the headless TUI driver with the scripted mock LLM.

(defun program-doc (program)
  (state-plan-document (code-program-state program)))

(defun doc-id8 (program)
  (subseq (getf (program-doc program) :id) 0 8))

(defmacro with-plan-doc-tui ((tui program backend &rest keys) (project config) &body body)
  `(with-code-tui (,tui ,program ,backend :argv '("--permission-mode" "plan") :cols 100 :rows 40 ,@keys)
       (,project ,config)
     ,@body))

(defun propose-turn (tui text)
  "Send TEXT and wait for the plan document dialog."
  (send-line tui text)
  (wait-screen tui "Approve, accept edits"))

(deftest program-plan-doc-dialog
  (with-project (project config) '(("hello.sh" ""))
    (with-plan-doc-tui (tui program backend :steps (list (propose-step))) (project config)
      (ok (propose-turn tui "add a greeting"))
      (ok (on-screen tui (format nil "Plan ~a r1: Add a greeting" (doc-id8 program))) "the dialog's title")
      (dolist (needle '("Approve, ask before edits" "Approve, run in preview" "Edit in $EDITOR"
                        "Revise" "Reject" "Save to workspace" "Add a test for it"))
        (ok (on-screen tui needle) needle))
      (ok (equal "" (read-file project "hello.sh")) "nothing is implemented")
      (ok (eq :proposed (plan-document-status (only-plan-doc project config)))))))

(deftest program-plan-doc-approve-runs-the-plan
  (with-project (project config) '(("hello.sh" ""))
    (with-plan-doc-tui (tui program backend
                        :steps (list* (propose-step) (execution-steps)))
        (project config)
      (ok (propose-turn tui "add a greeting"))
      (let ((id8 (doc-id8 program)))
        (h:tui-type tui "1")
        (ok (wait-screen tui (format nil "Plan ~a done" id8)) "the result dialog")
        (dolist (needle (list "☑ 1. Write the greeting into hello.sh" "☐ 2. Add a test for it"
                              "files: 2 planned, 1 changed" "M hello.sh  planned" "+echo hello"
                              "Keep the changes" "Rewind the files"))
          (ok (on-screen tui needle) needle))
        (ok (equal (nl "echo hello") (read-file project "hello.sh")) "it ran in the project")
        (ok (eq :accept-edits (state-permission-mode (code-program-state program))))
        (ok (has (plan-execution-prompt (only-plan-doc project config))
                 (request-texts (second (scripted-requests backend))))
            "the execution turn's instructions are the plan")
        (h:tui-type tui "1")
        (ok (wait-gone tui "Keep the changes"))))))

(deftest program-plan-doc-rewind-the-files
  (with-project (project config) '(("hello.sh" ""))
    (with-plan-doc-tui (tui program backend :steps (list* (propose-step) (execution-steps)))
        (project config)
      (ok (propose-turn tui "add a greeting"))
      (h:tui-type tui "1")
      (ok (wait-screen tui "Rewind the files"))
      (h:tui-type tui "2")
      (ok (wait-screen tui "rewound to turn"))
      (ok (equal "" (read-file project "hello.sh")) "H5b's files rewind undoes the execution"))))

(deftest program-plan-doc-revise
  (with-project (project config) '()
    (with-plan-doc-tui (tui program backend :steps (list (propose-step) (propose-step +plan-md-2+)))
        (project config)
      (ok (propose-turn tui "add a greeting"))
      (let ((id8 (doc-id8 program)))
        (h:tui-type tui "5")
        (ok (wait-screen tui "send your feedback to revise it"))
        (ok (propose-turn tui "in French"))
        (ok (on-screen tui (format nil "Plan ~a r2" id8)) "revision 2")
        (ok (on-screen tui "Mention it in the README"))
        (ok (eql 2 (plan-document-revision (only-plan-doc project config))))))))

(deftest program-plan-doc-reject
  (with-project (project config) '()
    (with-plan-doc-tui (tui program backend :steps (list (propose-step))) (project config)
      (ok (propose-turn tui "add a greeting"))
      (let ((id8 (doc-id8 program)))
        (h:tui-type tui "6")
        (ok (wait-screen tui (format nil "plan ~a rejected" id8)))
        (ok (eq :rejected (plan-document-status (only-plan-doc project config))))))))

(deftest program-plan-doc-edit
  (if (not (unix-p))
      (skip "/bin/sh editor")
      (with-project (project config) '()
        (let ((editor (editor-script config "4. Edited by hand")))
          (with-plan-doc-tui (tui program backend :steps (list (propose-step))
                                                  :getenv (env-lookup "EDITOR" editor "VISUAL" nil))
              (project config)
            (ok (propose-turn tui "add a greeting"))
            (let ((id8 (doc-id8 program)))
              (h:tui-type tui "4")
              (ok (wait-screen tui (format nil "Plan ~a r2" id8)) "the edit is a new revision")
              (ok (has "Edited by hand" (doc-md (only-plan-doc project config))))
              (ok (eq :user (plan-revision-author
                             (car (last (plan-document-revisions (only-plan-doc project config)))))))))))))

(deftest program-plan-doc-approve-in-preview
  (with-project (project config) '(("hello.sh" ""))
    (with-plan-doc-tui (tui program backend :steps (list* (propose-step) (execution-steps)))
        (project config)
      (ok (propose-turn tui "add a greeting"))
      (h:tui-type tui "3")
      (ok (wait-screen tui "Keep working") "the preview dialog (H5a) follows the execution")
      (ok (on-screen tui "Preview "))
      (ok (on-screen tui "files: 2 planned, 1 changed") "the plan next to the projected diff")
      (ok (equal "" (read-file project "hello.sh")) "nothing applied yet")
      (h:tui-type tui "1")
      (ok (wait-screen tui "applied: 1 file changed"))
      (ok (equal (nl "echo hello") (read-file project "hello.sh"))))))

(deftest program-plan-doc-ask-user
  (with-project (project config) '()
    (with-plan-doc-tui (tui program backend
                        :steps (list (ask-step "French or English?" "French" "English") (propose-step)))
        (project config)
      (send-line tui "add a greeting")
      (ok (wait-screen tui "French or English?"))
      (ok (on-screen tui "English"))
      (h:tui-type tui "1")
      (ok (wait-screen tui "Approve, accept edits"))
      (ok (has "The user answered: French"
               (result-content (first (request-tool-results (second (scripted-requests backend))))))))))

(deftest program-plan-doc-save
  (with-project (project config) '()
    (with-plan-doc-tui (tui program backend :steps (list (propose-step))) (project config)
      (ok (propose-turn tui "add a greeting"))
      (h:tui-type tui "7")
      (ok (wait-screen tui "saved to"))
      (ok (= 1 (length (directory (merge-pathnames "docs/plans/*.md" project)))))
      (ok (wait-screen tui "Approve, accept edits") "the dialog comes back"))))

(deftest program-plan-doc-record
  (with-project (project config) '()
    (with-plan-doc-tui (tui program backend :steps (list (propose-step))) (project config)
      (ok (propose-turn tui "add a greeting"))
      (let ((r (record-plan-document (head-record project config
                                                  (state-session-id (code-program-state program))))))
        (ok (equal (getf (program-doc program) :id) (getf r :id)) "the turn record names the plan")
        (ok (eql 1 (getf r :revision)))
        (ok (equal +plan-md+ (getf r :markdown)))))))

(deftest program-plan-doc-migration-notice
  (with-project (project config) '()
    (user-settings config "{\"permissionMode\": \"plan\"}")
    (with-code-tui (tui program backend :cols 100 :rows 40) (project config)
      (ok (wait-screen tui "now plans first")))
    (with-code-tui (tui program backend :cols 100 :rows 40) (project config)
      (ok (wait-screen tui "Message, @file, /help"))
      (ok (not (on-screen tui "now plans first")) "once"))))
