(in-package #:cl-stack-code/tests)

;;; H5b: checkpoints and rewind in the interactive program (src/program.lisp
;;; header, "H5b"), on the headless TUI driver with the scripted mock LLM.
;;; acceptEdits, so the scripted writes need no approval.

(defmacro with-edit-tui ((tui program backend &rest keys) (project config) &body body)
  `(with-code-tui (,tui ,program ,backend :argv '("--permission-mode" "acceptEdits")
                        :cols 100 :rows 30 ,@keys)
       (,project ,config)
     ,@body))

(defun program-store (program project config)
  "The program's session, read from disk."
  (open-session (project-sessions project config) (state-session-id (code-program-state program))))

(defun edit-turn-on (tui program text answer)
  "Send TEXT and wait until ANSWER shows and the program is idle."
  (send-line tui text)
  (and (wait-screen tui answer) (wait-idle tui program)))

(defun two-edit-steps ()
  (list (list :tool "write" (write-args "a.txt" "one")) "Wrote one."
        (list :tool "write" (write-args "a.txt" "two")) "Wrote two."))

(deftest program-turn-records-checkpoints
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (list (list :tool "write" (write-args "a.txt" "one"))
                                                    "Wrote one."))
        (project config)
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (let* ((s (program-store program project config))
             (ks (session-checkpoints s)))
        (ok (equal '(:before :turn) (reasons ks)) "recorded before the UI went idle")
        (ok (equal (rev:revision-id (session-head s)) (checkpoint-turn-id (second ks))))
        (send-line tui "/checkpoints")
        (ok (wait-screen tui (format nil "~a turn 1 after write one" (short-id (second ks)))))
        (ok (on-screen tui (format nil "~a turn 0 before session start" (short-id (first ks)))))))))

(deftest program-tree-marks-checkpointed-turns
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (list "Just looking."
                                                    (list :tool "write" (write-args "a.txt" "one"))
                                                    "Wrote one."))
        (project config)
      (ok (edit-turn-on tui program "look" "Just looking."))
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (let* ((s (program-store program project config))
             (line (session-line s)))
        (send-line tui "/tree")
        (ok (wait-screen tui "(head)"))
        (ok (on-screen tui (format nil "● ~a look ◆" (short-id (first line))))
            "turn 1 holds the :before checkpoint")
        (ok (on-screen tui (format nil "● ~a write one ◆  (head)" (short-id (second line)))))))))

(deftest program-rewind-dialog-both
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (two-edit-steps)) (project config)
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (ok (edit-turn-on tui program "write two" "Wrote two."))
      (send-line tui "/rewind")
      (ok (wait-screen tui "Rewind to turn 1"))
      (dolist (needle '("Conversation and files" "Conversation only" "Files only" "Cancel"
                        "Files to restore: a.txt"))
        (ok (on-screen tui needle) needle))
      (ok (equal "two" (read-file project "a.txt")) "nothing restored before the answer")
      (h:tui-type tui "1")
      (ok (wait-screen tui "rewound to turn 1: conversation and files (1 file changed)"))
      (ok (equal "one" (read-file project "a.txt")))
      (ok (not (on-screen tui "Wrote two.")) "the transcript is the head's")
      (ok (on-screen tui "Wrote one."))
      (let ((s (program-store program project config)))
        (ok (equal '("write one") (line-prompts s)))
        (ok (eq :rewind (checkpoint-reason (tip-checkpoint s))))))))

(deftest program-rewind-dialog-files-only
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (two-edit-steps)) (project config)
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (ok (edit-turn-on tui program "write two" "Wrote two."))
      (send-line tui "/rewind")
      (ok (wait-screen tui "Rewind to turn 1"))
      (h:tui-type tui "3")
      (ok (wait-screen tui "rewound to turn 1: files (1 file changed)"))
      (ok (equal "one" (read-file project "a.txt")))
      (ok (on-screen tui "Wrote two.") "the conversation stays")
      (ok (equal '("write one" "write two") (line-prompts (program-store program project config)))))))

(deftest program-rewind-dialog-cancel
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (two-edit-steps)) (project config)
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (ok (edit-turn-on tui program "write two" "Wrote two."))
      (send-line tui "/rewind")
      (ok (wait-screen tui "Rewind to turn 1"))
      (h:tui-press tui :escape)
      (ok (wait-screen tui "rewind canceled"))
      (ok (equal "two" (read-file project "a.txt")))
      (ok (equal '("write one" "write two") (line-prompts (program-store program project config)))))))

(deftest program-rewind-with-a-part
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (two-edit-steps)) (project config)
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (ok (edit-turn-on tui program "write two" "Wrote two."))
      (send-line tui "/rewind 2 files")
      (ok (wait-screen tui "rewound to turn 0: files (1 file changed)"))
      (ok (not (on-screen tui "Rewind to turn")) "no dialog")
      (ok (equal "zero" (read-file project "a.txt")))
      (send-line tui "/rewind 1 conversation")
      (ok (wait-screen tui "rewound to turn 1: conversation"))
      (ok (not (on-screen tui "Wrote two.")))
      (ok (equal "zero" (read-file project "a.txt")) "the files stay"))))

(deftest program-rewind-drift-dialog
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (two-edit-steps)) (project config)
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (ok (edit-turn-on tui program "write two" "Wrote two."))
      (write-file project "a.txt" "user")
      (send-line tui "/rewind 1 files")
      (ok (wait-screen tui "Rewind: the working copy changed"))
      (dolist (needle '("Rebase onto the working copy" "Overwrite" "Cancel" "Changed in both: a.txt"
                        "the working copy changed since the last checkpoint: a.txt"))
        (ok (on-screen tui needle) needle))
      (ok (equal "user" (read-file project "a.txt")) "nothing written yet")
      (h:tui-type tui "2")
      (ok (wait-screen tui "rewound to turn 1: files (1 file changed)"))
      (ok (equal "one" (read-file project "a.txt")) "overwrite: the checkpoint wins"))))

(deftest program-rewind-without-file-changes-is-h3c
  (with-project (project config) '(("a.txt" "zero"))
    (with-edit-tui (tui program backend :steps (list (list :tool "write" (write-args "a.txt" "one"))
                                                    "Wrote one."
                                                    "Only talk."))
        (project config)
      (ok (edit-turn-on tui program "write one" "Wrote one."))
      (ok (edit-turn-on tui program "talk" "Only talk."))
      (send-line tui "/rewind")
      (ok (wait-screen tui "rewound 1 turn") "turn 1's files are the tip's: no dialog")
      (ok (not (on-screen tui "Rewind to turn")))
      (ok (equal "one" (read-file project "a.txt"))))))
