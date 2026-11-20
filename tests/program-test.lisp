(in-package #:cl-stack-code/tests)

;;; The interactive program end to end (src/program.lisp header): a
;;; CODE-PROGRAM on tui-backend-terminal's headless driver, the pure-Lisp
;;; emulator and the scripted mock LLM. Screen checks look for text on rows;
;;; exact rows are checked where the layout fixes them (the bottom rows).

(defun edit-args (path old new)
  (json-args "file_path" path "old_string" old "new_string" new))

(defun write-args (path content)
  (json-args "file_path" path "content" content))

(defun trimmed (row) (string-right-trim " " row))

;;; Layout.

(deftest program-first-screen
  (with-project (project config) '()
    (with-code-tui (tui program backend :cols 120 :rows 12) (project config)
      (ok (wait-screen tui "Message, @file, /help"))
      (let ((rows (screen tui)))
        (ok (= 12 (length rows)))
        (multiple-value-bind (left right) (status-line-text (code-program-state program))
          (ok (equal (trimmed (concatenate 'string left
                                           (make-string (- 120 (length left) (length right))
                                                        :initial-element #\Space)
                                           right))
                     (trimmed (nth 11 rows)))
              "the status line is the last row")
          (ok (uiop:string-prefix-p " mock · default · " left)))
        (ok (equal "> Message, @file, /help" (trimmed (nth 10 rows))) "the input")
        (ok (rule-row-p (nth 9 rows)) "a rule above the input")
        (ok (every (lambda (row) (string= "" (trimmed row))) (subseq rows 0 9))
            "an empty transcript")))))

(deftest program-status-line-keeps-the-project-directory
  ;; #4: at 60 columns the temp project path does not fit; its end stays.
  (with-project (project config) '()
    (with-code-tui (tui program backend :cols 60 :rows 8) (project config)
      (ok (wait-screen tui "Message, @file"))
      (let ((status (trimmed (nth 7 (screen tui)))))
        (ok (uiop:string-prefix-p " mock · default · " status))
        (ok (search (format nil "project~c" (char (native project) (1- (length (native project)))))
                    status)
            "the project directory name is on the status line")
        (ok (search " in · " status) "usage still shown")))))

(deftest program-layout-follows-resize
  (with-project (project config) '()
    (with-code-tui (tui program backend :cols 100 :rows 20) (project config)
      (ok (wait-screen tui "Message, @file"))
      (h:tui-resize tui 90 14)
      (ok (wait-for* tui (lambda () (= 14 (length (screen tui))))))
      (ok (wait-for* tui (lambda () (search "Message, @file" (nth 12 (screen tui))))))
      (ok (wait-for* tui (lambda () (search " in · " (nth 13 (screen tui)))))
          "the status line is still last"))))

;;; Turns.

(deftest program-runs-a-turn
  (with-project (project config) '()
    (with-code-tui (tui program backend :steps '("Hello **brave** world")) (project config)
      (ok (wait-screen tui "Message, @file"))
      (send-line tui "hi")
      (ok (wait-screen tui "Hello brave world") "markdown rendered: no asterisks")
      (ok (wait-idle tui program))
      (ok (on-screen tui "> hi"))
      (ok (not (on-screen tui "**")))
      (ok (has "hi" (request-text (first-request backend))))
      (ok (wait-screen tui "10 in · 5 out") "usage on the status line")
      (ok (equal '(:user :assistant) (kinds (code-program-state program))))
      (ok (equal "" (w:text-input-value (code-program-input program))) "the input is cleared"))))

(deftest program-markdown-blocks
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :steps (list (format nil "# Plan~%~%- read the file~%- fix `greet`~%")))
        (project config)
      (send-line tui "plan")
      (ok (wait-screen tui "- fix greet"))
      (ok (on-screen tui "Plan"))
      (ok (not (on-screen tui "# Plan")) "a level-1 heading drops its marker"))))

(deftest program-shows-tool-calls
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-code-tui (tui program backend
                        :steps (list (list :tool "read" (json-args "file_path" "a.txt")) "Read it."))
        (project config)
      (send-line tui "read a.txt")
      (ok (wait-screen tui "Read it."))
      (ok (on-screen tui "● read a.txt"))
      (ok (on-screen tui "⎿") "the result's first line")
      (ok (has "alpha" (request-text (second (scripted-requests backend))))))))

(deftest program-usage-adds-up
  (with-project (project config) '(("a.txt" "x"))
    (with-code-tui (tui program backend
                        :steps (list (list :tool "read" (json-args "file_path" "a.txt")) "ok"))
        (project config)
      (send-line tui "go")
      (ok (wait-screen tui "20 in · 10 out"))
      (ok (equal '(20 10 4 2) (state-usage (code-program-state program)))))))

(deftest program-initial-prompt
  (with-project (project config) '()
    (with-code-tui (tui program backend :steps '("Hi!") :argv '("hello" "there")) (project config)
      (ok (wait-screen tui "Hi!"))
      (ok (on-screen tui "> hello there"))
      (ok (has "hello there" (request-text (first-request backend)))))))

(deftest program-uses-agents-md
  (with-project (project config) '(("AGENTS.md" "Always answer in haiku."))
    (with-code-tui (tui program backend :steps '("ok")) (project config)
      (send-line tui "hi")
      (ok (wait-screen tui "ok"))
      (ok (has "Always answer in haiku." (request-system (first-request backend)))))))

(deftest program-scrolls-the-transcript
  (with-project (project config) '()
    (let ((answer (format nil "~{line ~2,'0d~^~%~%~}" (loop for i from 1 to 30 collect i))))
      (with-code-tui (tui program backend :steps (list answer) :rows 12) (project config)
        (send-line tui "long")
        (ok (wait-screen tui "line 30") "the tail is followed")
        (ok (wait-idle tui program))
        (h:tui-press tui :page-up)
        (ok (wait-gone tui "line 30") "PgUp scrolls back")
        (h:tui-press tui :page-down)
        (h:tui-press tui :page-down)
        (h:tui-press tui :page-down)
        (ok (wait-screen tui "line 30") "PgDn returns to the tail")))))

;;; Approvals.

(deftest program-approve-once
  (with-project (project config) '(("a.txt" "alpha
beta
"))
    (with-code-tui (tui program backend
                        :steps (list (list :tool "edit" (edit-args "a.txt" "beta" "BETA")) "Edited."))
        (project config)
      (send-line tui "change it")
      (ok (wait-screen tui "Permission"))
      (dolist (needle '("edit a.txt" "+BETA" "Allow once" "Always allow" "Reject" "Reject all"))
        (ok (on-screen tui needle) needle))
      (ok (equal (nl "alpha" "beta") (read-file project "a.txt")) "nothing written yet")
      (h:tui-type tui "1")
      (ok (wait-screen tui "Edited."))
      (ok (equal (nl "alpha" "BETA") (read-file project "a.txt")))
      (ok (not (on-screen tui "Allow once")) "the dialog is gone")
      (ok (on-screen tui "● edit a.txt"))
      (ok (not (probe-file (local-settings config project))) "once saves nothing"))))

(deftest program-approve-always
  (with-project (project config) '(("a.txt" "alpha
beta
"))
    (with-code-tui (tui program backend
                        :steps (list (list :tool "edit" (edit-args "a.txt" "alpha" "ALPHA"))
                                     (list :tool "edit" (edit-args "a.txt" "beta" "BETA"))
                                     "Both done."))
        (project config)
      (send-line tui "change both")
      (ok (wait-screen tui "Permission"))
      (h:tui-press tui :arrow-down)
      (h:tui-press tui :enter)
      (ok (wait-screen tui "Both done.") "the second edit of a.txt did not ask")
      (ok (equal (nl "ALPHA" "BETA") (read-file project "a.txt")))
      (let ((saved (json:decode (read-file project ".cl-stack-code/settings.local.json"))))
        (ok (equal '("edit(a.txt)") (coerce (jget saved "permissions" "allow") 'list))
            "the rule is saved to settings.local.json")))))

(deftest program-reject-with-feedback
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-code-tui (tui program backend
                        :steps (list (list :tool "edit" (edit-args "a.txt" "alpha" "omega"))
                                     "OK, I will not."))
        (project config)
      (send-line tui "change it")
      (ok (wait-screen tui "Permission"))
      (h:tui-type tui "3")
      (ok (wait-screen tui "What should it do instead?"))
      (send-line tui "use b.txt")
      (ok (wait-screen tui "OK, I will not."))
      (ok (equal (nl "alpha") (read-file project "a.txt")))
      (let ((results (request-tool-results (second (scripted-requests backend)))))
        (ok (= 1 (length results)))
        (ok (has "use b.txt" (result-content (first results))))
        (ok (result-error-p (first results)))))))

(deftest program-reject-all
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :steps (list (list :tools (list "write" (write-args "b.txt" "b"))
                                           (list "write" (write-args "c.txt" "c")))
                                     "Nothing written."))
        (project config)
      (send-line tui "write two")
      (ok (wait-screen tui "Permission (1 of 2)"))
      (h:tui-type tui "4")
      (ok (wait-screen tui "Nothing written."))
      (ok (not (probe-file (merge-pathnames "b.txt" project))))
      (ok (not (probe-file (merge-pathnames "c.txt" project))))
      (ok (= 2 (length (request-tool-results (second (scripted-requests backend)))))))))

(deftest program-approve-the-second-of-two
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :steps (list (list :tools (list "write" (write-args "b.txt" "b"))
                                           (list "write" (write-args "c.txt" "c")))
                                     "One of two."))
        (project config)
      (send-line tui "write two")
      (ok (wait-screen tui "Permission (1 of 2)"))
      (ok (on-screen tui "write b.txt"))
      (h:tui-type tui "3")
      (ok (wait-screen tui "What should it do instead?"))
      (h:tui-press tui :enter)
      (ok (wait-screen tui "Permission (2 of 2)") "the next dialog")
      (ok (on-screen tui "write c.txt"))
      (h:tui-type tui "1")
      (ok (wait-screen tui "One of two."))
      (ok (not (probe-file (merge-pathnames "b.txt" project))))
      (ok (equal "c" (read-file project "c.txt"))))))

(deftest program-escape-in-the-dialog
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :steps (list (list :tool "write" (write-args "b.txt" "b")) "Stopped."))
        (project config)
      (send-line tui "write")
      (ok (wait-screen tui "Permission"))
      (h:tui-press tui :escape)
      (ok (wait-screen tui "Stopped.") "Esc rejects and the run goes on")
      (ok (not (probe-file (merge-pathnames "b.txt" project)))))))

(deftest program-deny-rule-needs-no-dialog
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :argv '("--disallowed-tools" "bash(rm *)")
                        :steps (list (list :tool "bash" (json-args "command" "rm -rf build")) "Fine."))
        (project config)
      (send-line tui "clean")
      (ok (wait-screen tui "Fine."))
      (ok (on-screen tui "● bash rm -rf build"))
      (ok (not (on-screen tui "Allow once"))))))

(deftest program-bypass-permissions-asks-nothing
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :argv '("--permission-mode" "bypassPermissions")
                        :steps (list (list :tool "write" (write-args "b.txt" "b")) "Wrote."))
        (project config)
      (send-line tui "write")
      (ok (wait-screen tui "Wrote."))
      (ok (equal "b" (read-file project "b.txt"))))))

;;; Turn control.

(deftest program-escape-interrupts
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-code-tui (tui program backend :gates (list gate)
                          :steps (list (list :gate gate "late") "after"))
          (project config)
        (send-line tui "hi")
        (ok (wait-screen tui "Working… (Esc to interrupt)"))
        (ok (wait-for* tui (lambda () (gate-waiting-p gate))))
        (h:tui-press tui :escape)
        (open-gate gate)
        (ok (wait-screen tui "interrupted"))
        (ok (wait-idle tui program))
        (ok (not (on-screen tui "Working…")))
        (send-line tui "again")
        (ok (wait-screen tui "after") "the conversation goes on")
        (ok (has "again" (request-text (second (scripted-requests backend)))))))))

(deftest program-queues-follow-ups
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-code-tui (tui program backend :gates (list gate)
                          :steps (list (list :gate gate "first answer") "second answer"))
          (project config)
        (send-line tui "one")
        (ok (wait-for* tui (lambda () (gate-waiting-p gate))))
        (send-line tui "two")
        (ok (wait-screen tui "queued: two"))
        (let ((queued (row-index tui "queued: two"))
              (spinner (row-index tui "Working…")))
          (ok (and queued spinner (= (1+ queued) spinner)) "queued rows sit above the spinner")
          (ok (and spinner (rule-row-p (nth (1+ spinner) (screen tui))))
              "the spinner sits on the rule"))
        (ok (equal '("two") (state-queue (code-program-state program))))
        (open-gate gate)
        (ok (wait-screen tui "second answer"))
        (ok (not (on-screen tui "queued:")))
        (let ((rows (mapcar (lambda (n) (row-index tui n))
                            '("> one" "first answer" "> two" "second answer"))))
          (ok (and (every #'identity rows) (apply #'< rows)) "transcript order"))
        (let ((second (second (scripted-requests backend))))
          (ok (has "one" (request-text second)) "history kept")
          (ok (has "two" (request-text second))))))))

(deftest program-interrupt-restores-the-queue
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-code-tui (tui program backend :gates (list gate)
                          :steps (list (list :gate gate "late")))
          (project config)
        (send-line tui "one")
        (ok (wait-for* tui (lambda () (gate-waiting-p gate))))
        (send-line tui "two")
        (ok (wait-screen tui "queued: two"))
        (h:tui-press tui :escape)
        (open-gate gate)
        (ok (wait-screen tui "interrupted"))
        (ok (wait-idle tui program))
        (ok (wait-for* tui (lambda () (equal "two" (w:text-input-value (code-program-input program))))))
        (ok (= 1 (length (scripted-requests backend))) "the queued message was not sent")))))

;;; Input.

(deftest program-mention-completion
  (with-project (project config) '(("src/alpha.lisp" "(defun alpha () :alpha)") ("README.md" "r"))
    (with-code-tui (tui program backend :steps '("Seen.")) (project config)
      (ok (wait-screen tui "Message, @file"))
      (h:tui-type tui "look @alp")
      (ok (wait-screen tui "> @src/alpha.lisp") "the menu")
      (h:tui-press tui :tab)
      (ok (wait-for* tui (lambda () (equal "look @src/alpha.lisp"
                                           (w:text-input-value (code-program-input program))))))
      (h:tui-press tui :enter)
      (ok (wait-screen tui "Seen."))
      (ok (on-screen tui "> look @src/alpha.lisp"))
      (let ((text (request-text (first-request backend))))
        (ok (has "<file path=\"src/alpha.lisp\">" text))
        (ok (has "(defun alpha () :alpha)" text))))))

(deftest program-completion-sees-new-files
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :argv '("--permission-mode" "acceptEdits")
                        :steps (list (list :tool "write" (write-args "fresh.txt" "f")) "made"))
        (project config)
      (send-line tui "make a file")
      (ok (wait-screen tui "made"))
      (ok (wait-idle tui program))
      (h:tui-type tui "@fre")
      (ok (wait-screen tui "> @fresh.txt") "the file list is read again after a turn"))))

(deftest program-history
  (with-project (project config) '()
    (with-code-tui (tui program backend :steps '("answer-a")) (project config)
      (send-line tui "one")
      (ok (wait-screen tui "answer-a"))
      (ok (wait-idle tui program))
      (h:tui-press tui :arrow-up)
      (ok (wait-for* tui (lambda () (equal "one" (w:text-input-value (code-program-input program)))))))))

(deftest program-multi-line-input
  (with-project (project config) '()
    (with-code-tui (tui program backend :steps '("ok")) (project config)
      (h:tui-type tui "line one")
      (h:tui-press tui :enter :modifiers '(:alt))
      (h:tui-type tui "line two")
      (ok (wait-screen tui "line two"))
      (let ((two (row-index tui "line two")))
        (ok (and two (equal "> line one" (trimmed (nth (1- two) (screen tui))))))
        (ok (and two (rule-row-p (nth (- two 2) (screen tui)))) "the input grew upwards"))
      (h:tui-press tui :enter)
      (ok (wait-screen tui "ok"))
      (ok (has (format nil "line one~%line two") (request-text (first-request backend)))))))

;;; Commands.

(deftest program-help
  (with-project (project config) '()
    (with-code-tui (tui program backend :rows 30) (project config)
      (send-line tui "/help")
      (ok (wait-screen tui "/permissions [MODE]"))
      (ok (null (scripted-requests backend)) "nothing goes to the model"))))

(deftest program-clear
  (with-project (project config) '()
    (with-code-tui (tui program backend :steps '("first answer" "second answer")) (project config)
      (send-line tui "one")
      (ok (wait-screen tui "first answer"))
      (ok (wait-idle tui program))
      (send-line tui "/clear")
      (ok (wait-gone tui "first answer"))
      (ok (wait-screen tui "0 in · 0 out"))
      (send-line tui "two")
      (ok (wait-screen tui "second answer"))
      (let ((second (request-text (second (scripted-requests backend)))))
        (ok (has "two" second))
        (ok (not (has "first answer" second)) "a new conversation")))))

(deftest program-switches-the-model
  (with-project (project config) '()
    (let ((other (make-scripted-backend '("from the other model"))))
      (with-code-tui (tui program backend :steps '("from mock")
                          :providers (list (cons "other" (scripted-provider other))))
          (project config)
        (send-line tui "one")
        (ok (wait-screen tui "from mock"))
        (ok (wait-idle tui program))
        (send-line tui "/model nope:x")
        (ok (wait-screen tui "error:"))
        (ok (equal "mock" (state-model (code-program-state program))))
        (send-line tui "/model other:big")
        (ok (wait-screen tui "model: other:big"))
        (ok (wait-screen tui " other:big · default · ") "the status line")
        (ok (equal "big" (scripted-model other)))
        (send-line tui "two")
        (ok (wait-screen tui "from the other model"))
        (ok (= 1 (length (scripted-requests backend))))
        (let ((text (request-text (first-request other))))
          (ok (has "one" text) "the history is kept")
          (ok (has "from mock" text))
          (ok (has "two" text)))))))

(deftest program-switches-the-permission-mode
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :steps (list (list :tool "write" (write-args "b.txt" "b")) "Wrote."))
        (project config)
      (send-line tui "/permissions acceptEdits")
      (ok (wait-screen tui "permission mode: acceptEdits"))
      (ok (wait-screen tui " mock · acceptEdits · "))
      (send-line tui "write")
      (ok (wait-screen tui "Wrote.") "no dialog in acceptEdits")
      (ok (equal "b" (read-file project "b.txt"))))))

;;; Quitting.

(deftest program-exit-command
  (with-project (project config) '()
    (with-code-tui (tui program backend) (project config)
      (ok (wait-screen tui "Message, @file"))
      (send-line tui "/exit")
      (ok (wait-for* tui (lambda () (not (h:tui-running-p tui)))))
      (ok (state-quit-p (code-program-state program))))))

(deftest program-ctrl-d-and-ctrl-c
  (with-project (project config) '()
    (testing "Ctrl-D on an empty input quits"
      (with-code-tui (tui program backend) (project config)
        (ok (wait-screen tui "Message, @file"))
        (ctrl tui :d)
        (ok (wait-for* tui (lambda () (not (h:tui-running-p tui)))))))
    (testing "Ctrl-C clears the input, then quits"
      (with-code-tui (tui program backend) (project config)
        (ok (wait-screen tui "Message, @file"))
        (h:tui-type tui "draft")
        (ok (wait-screen tui "> draft"))
        (ctrl tui :c)
        (ok (wait-screen tui "Message, @file"))
        (ok (h:tui-running-p tui))
        (ctrl tui :c)
        (ok (wait-for* tui (lambda () (not (h:tui-running-p tui)))))))))

(deftest program-ctrl-c-interrupts-a-turn
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-code-tui (tui program backend :gates (list gate) :steps (list (list :gate gate "late")))
          (project config)
        (send-line tui "hi")
        (ok (wait-for* tui (lambda () (gate-waiting-p gate))))
        (ctrl tui :c)
        (open-gate gate)
        (ok (wait-screen tui "interrupted"))
        (ok (h:tui-running-p tui) "still running")))))

;;; Configuration errors signal from MAKE-CODE-PROGRAM.

(deftest program-configuration-errors
  (with-project (project config) '((".cl-stack-code/settings.json" "{\"maxTurns\": \"x\"}"))
    (ok (typep (failure (make-program project config)) 'settings-error)))
  (with-project (project config) '()
    (ok (typep (failure (make-program project config :model "nope:x")) 'model-not-found))
    (ok (typep (failure (make-code-program
                         (parse-arguments (list "--cwd" (native (merge-pathnames "missing/" project))))
                         :user-config-dir config :getenv (env-lookup)))
               'code-usage-error))))
