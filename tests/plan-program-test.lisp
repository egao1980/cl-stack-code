(in-package #:cl-stack-code/tests)

;;; H5a: plan mode in the interactive program (src/program.lisp header,
;;; "H5a"), on the headless TUI driver with the scripted mock LLM.

(defun program-plan (program)
  "STATE-PLAN of PROGRAM's core."
  (state-plan (code-program-state program)))

(defun id8 (program)
  (subseq (getf (program-plan program) :id) 0 8))

(defmacro with-plan-tui ((tui program backend &rest keys) (project config) &body body)
  `(with-code-tui (,tui ,program ,backend :argv '("--permission-mode" "plan") :cols 100 :rows 30 ,@keys)
       (,project ,config)
     ,@body))

(defun plan-turn (tui text)
  "Send TEXT and wait for the plan dialog."
  (send-line tui text)
  (wait-screen tui "Keep planning"))

(deftest program-plan-turn-shows-the-projection
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-plan-tui (tui program backend :steps (list (list :tool "write" (write-args "a.txt" (nl "beta")))
                                                    "Done."))
        (project config)
      (ok (plan-turn tui "make it beta"))
      (ok (on-screen tui (format nil "Plan ~a" (id8 program))) "the dialog's title")
      (dolist (needle '("Approve" "Keep planning" "Reject" "+beta" "-alpha"
                        "1 file changed. Approve to apply them to the project."))
        (ok (on-screen tui needle) needle))
      (ok (on-screen tui (format nil "● plan ~a: 1 file changed" (id8 program))) "the transcript entry")
      (ok (on-screen tui "edits go to a copy of the project"))
      (ok (equal (nl "alpha") (read-file project "a.txt")) "the project is untouched")
      (let ((plan (only-plan project config)))
        (ok (equal (nl "beta") (area-file plan "a.txt")))
        (ok (equal (getf (program-plan program) :id) (plan-id plan)))))))

(deftest program-plan-approve
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-plan-tui (tui program backend :steps (list (list :tool "write" (write-args "a.txt" (nl "beta")))
                                                    "Done."))
        (project config)
      (ok (plan-turn tui "make it beta"))
      (let ((id8 (id8 program)))
        (h:tui-type tui "1")
        (ok (wait-screen tui (format nil "plan ~a applied: 1 file changed" id8)))
        (ok (equal (nl "beta") (read-file project "a.txt")))
        (ok (not (on-screen tui "Keep planning")) "the dialog is gone")
        (ok (null (program-plan program)))
        (ok (eq :applied (plan-status (only-plan project config))))))))

(deftest program-plan-reject
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-plan-tui (tui program backend :steps (list (list :tool "write" (write-args "a.txt" (nl "beta")))
                                                    "Done."))
        (project config)
      (ok (plan-turn tui "make it beta"))
      (let ((id8 (id8 program)))
        (h:tui-type tui "3")
        (ok (wait-screen tui (format nil "plan ~a discarded" id8)))
        (ok (equal (nl "alpha") (read-file project "a.txt")))
        (let ((plan (only-plan project config)))
          (ok (eq :discarded (plan-status plan)))
          (ok (not (uiop:directory-exists-p (plan-root plan)))))))))

(deftest program-plan-continue
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-plan-tui (tui program backend
                        :steps (list (list :tool "write" (write-args "a.txt" (nl "beta")))
                                     "Done."
                                     (list :tool "read" (json-args "file_path" "a.txt"))
                                     "Still beta."))
        (project config)
      (ok (plan-turn tui "make it beta"))
      (h:tui-type tui "2")
      (ok (wait-screen tui "stays open"))
      (send-line tui "check it")
      (ok (wait-screen tui "Still beta."))
      (ok (wait-idle tui program))
      (ok (has "beta" (result-content (car (last (tool-results-of backend)))))
          "the next turn works in the same area")
      (ok (= 1 (length (project-plans project config))))
      (send-line tui "/approve")
      (ok (wait-screen tui "applied: 1 file changed"))
      (ok (equal (nl "beta") (read-file project "a.txt"))))))

(deftest program-plan-drift-dialog
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-plan-tui (tui program backend :steps (list (list :tool "write" (write-args "a.txt" (nl "beta")))
                                                    "Done."))
        (project config)
      (ok (plan-turn tui "make it beta"))
      (write-file project "a.txt" (nl "user"))
      (h:tui-type tui "1")
      (ok (wait-screen tui "the working copy changed"))
      (dolist (needle '("Rebase onto the working copy" "Overwrite" "Cancel" "Changed in both: a.txt"))
        (ok (on-screen tui needle) needle))
      (ok (equal (nl "user") (read-file project "a.txt")) "nothing written yet")
      (h:tui-type tui "2")
      (ok (wait-screen tui "applied: 1 file changed"))
      (ok (equal (nl "beta") (read-file project "a.txt")) "overwrite: the plan wins"))))

(deftest program-plan-turn-record
  (with-project (project config) '(("a.txt" "alpha"))
    (with-plan-tui (tui program backend :steps (list (list :tool "write" (write-args "a.txt" "beta"))
                                                    "Done."))
        (project config)
      (ok (plan-turn tui "make it beta"))
      (let* ((s (open-session (project-sessions project config)
                              (state-session-id (code-program-state program))))
             (plan (record-plan (revision-record (session-head s)))))
        (ok (equal (getf (program-plan program) :id) (getf plan :id)) "the turn record names the plan")
        (ok (eq :open (getf plan :status)))))))
