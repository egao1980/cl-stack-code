(in-package #:cl-stack-code/tests)

;;; INTERACTIVE-UPDATE: the pure core (src/interactive.lisp header).

(deftest core-fresh-state
  (let ((s (fresh-state :permission-mode :plan :cwd #p"/tmp/x/")))
    (ok (null (state-transcript s)))
    (ok (not (state-busy-p s)))
    (ok (null (state-queue s)))
    (ok (null (state-approvals s)))
    (ok (equal "mock" (state-model s)))
    (ok (eq :plan (state-permission-mode s)))
    (ok (equal '(0 0 0 0) (state-usage s)))
    (ok (not (state-quit-p s)))))

(deftest core-submit-starts-a-turn
  (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "fix @src/a.lisp"))
    (ok (equal '((:run "fix @src/a.lisp")) fx) "the raw text goes to :run")
    (ok (state-busy-p s))
    (ok (equal '(:user) (kinds s)))
    (ok (equal '("fix @src/a.lisp") (texts s)) "mentions are not expanded in the transcript")))

(deftest core-blank-submit-does-nothing
  (multiple-value-bind (s fx) (feed (fresh-state) (list :submit (format nil "  ~%	")))
    (ok (null fx))
    (ok (null (state-transcript s)))
    (ok (not (state-busy-p s)))))

(deftest core-submit-while-busy-queues
  (let ((s (busy-state)))
    (ok (null (effects s '(:submit "second"))))
    (ok (null (effects s '(:submit "third"))))
    (ok (equal '("second" "third") (state-queue s)))
    (ok (equal '(:user) (kinds s)) "queued messages get no entry yet")
    (ok (state-busy-p s))))

(deftest core-turn-end-sends-the-next-queued-message
  (let ((s (busy-state)))
    (feed s '(:submit "second") '(:submit "third"))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :stop))
      (ok (equal '((:run "second")) fx))
      (ok (state-busy-p s))
      (ok (equal '("third") (state-queue s)))
      (ok (equal '(:user :user) (kinds s)))
      (ok (equal "second" (entry-text (last-entry s)))))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :stop))
      (ok (equal '((:run "third")) fx))
      (ok (null (state-queue s))))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :stop))
      (ok (null fx))
      (ok (not (state-busy-p s))))))

(deftest core-parts-stream-into-one-assistant-entry
  (let ((s (busy-state)))
    (feed s '(:part "Hel") '(:part "lo **wor") '(:part "ld**"))
    (ok (equal '(:user :assistant) (kinds s)))
    (ok (equal "Hello **world**" (entry-text (last-entry s))))
    (feed s (list :invocation (proposed "c1" "read" "{\"file_path\":\"a.txt\"}")))
    (feed s '(:part "After."))
    (ok (equal '(:user :assistant :tool :assistant) (kinds s))
        "text after a tool call is a new assistant entry")
    (ok (equal "After." (entry-text (last-entry s))))))

(deftest core-usage-adds-up
  (let ((s (busy-state)))
    (feed s '(:usage (10 5 2 1)) '(:usage (7 3 0 4)))
    (ok (equal '(17 8 2 5) (state-usage s)))))

(deftest core-invocation-entries
  (let* ((s (busy-state))
         (inv (proposed "c1" "edit" "{\"file_path\":\"a.txt\"}")))
    (feed s (list :invocation inv))
    (let ((e (last-entry s)))
      (ok (eq :tool (entry-kind e)))
      (ok (equal "c1" (entry-id e)))
      (ok (equal "edit" (entry-name e)))
      (ok (equal "{\"file_path\":\"a.txt\"}" (entry-input e)))
      (ok (eq :proposed (entry-status e))))
    (setf (a:agent-invocation-status inv) :done
          (a:agent-invocation-result inv) "Edited a.txt")
    (feed s (list :invocation inv))
    (ok (equal '(:user :tool) (kinds s)) "the same id updates its entry")
    (let ((e (last-entry s)))
      (ok (eq :done (entry-status e)))
      (ok (equal "Edited a.txt" (entry-result e)))
      (ok (not (entry-error-p e))))
    (let ((bad (proposed "c2" "bash" "{\"command\":\"false\"}")))
      (setf (a:agent-invocation-status bad) :error
            (a:agent-invocation-result bad) "[exit code 1]"
            (a:agent-invocation-error-p bad) t)
      (feed s (list :invocation bad))
      (ok (equal '(:user :tool :tool) (kinds s)))
      (ok (entry-error-p (last-entry s))))))

(deftest core-interrupt
  (testing "busy: cancel"
    (ok (equal '((:cancel)) (effects (busy-state) '(:interrupt)))))
  (testing "idle: nothing"
    (let ((s (fresh-state)))
      (ok (null (effects s '(:interrupt))))
      (ok (null (state-transcript s))))))

(deftest core-canceled-turn-returns-the-queue-to-the-input
  (let ((s (busy-state)))
    (feed s '(:submit "second") '(:submit "third"))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :canceled))
      (ok (equal (list (list :restore-input (format nil "second~%third"))) fx))
      (ok (null (state-queue s)))
      (ok (not (state-busy-p s)))
      (ok (eq :notice (entry-kind (last-entry s))))
      (ok (equal "interrupted" (entry-text (last-entry s))))))
  (testing "nothing queued: no restore"
    (multiple-value-bind (s fx) (feed (busy-state) '(:turn-end :reason :canceled))
      (ok (null fx))
      (ok (equal "interrupted" (entry-text (last-entry s)))))))

(deftest core-failed-turn
  (let ((s (busy-state)))
    (feed s '(:submit "second"))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :failed :message "backend exploded"))
      (ok (equal '((:restore-input "second")) fx))
      (ok (not (state-busy-p s)))
      (ok (eq :error (entry-kind (last-entry s))))
      (ok (equal "backend exploded" (entry-text (last-entry s)))))))

(deftest core-max-steps-turn
  (let ((s (busy-state)))
    (feed s '(:submit "second"))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :max-steps
                                          :message "reached max turns (3)"))
      (ok (equal '((:run "second")) fx) "the queue goes on")
      (ok (equal '(:user :notice :user) (kinds s)))
      (ok (equal "reached max turns (3)" (entry-text (second (state-transcript s))))))))

(deftest core-approvals-wait
  (let* ((s (busy-state))
         (i1 (proposed "c1" "edit"))
         (i2 (proposed "c2" "write")))
    (multiple-value-bind (s fx) (feed s (list :turn-end :reason :approval :pending (list i1 i2)))
      (ok (null fx))
      (ok (state-busy-p s) "still busy while approvals wait")
      (ok (equal (list i1 i2) (state-approvals s))))
    (testing "an invocation answered elsewhere leaves the list"
      (setf (a:agent-invocation-status i2) :approved)
      (ok (equal (list i1) (state-approvals s))))))

(defun approval-state ()
  (let* ((s (busy-state))
         (i1 (proposed "c1" "edit"))
         (i2 (proposed "c2" "write"))
         (i3 (proposed "c3" "bash")))
    (feed s (list :turn-end :reason :approval :pending (list i1 i2 i3)))
    (values s i1 i2 i3)))

(deftest core-reply-once
  (multiple-value-bind (s i1 i2 i3) (approval-state)
    (ok (equal (list (list :approve i1 :always nil) '(:resume))
               (effects s '(:reply :once))))
    (ok (equal (list i2 i3) (state-approvals s)) "the next one is first")
    (ok (equal (list (list :approve i2 :always nil) '(:resume))
               (effects s '(:reply :once))))
    (ok (equal (list i3) (state-approvals s)))
    (ok (state-busy-p s))))

(deftest core-reply-always
  (multiple-value-bind (s i1 i2) (approval-state)
    (ok (equal (list (list :approve i1 :always t) '(:resume))
               (effects s '(:reply :always))))
    (testing "the program approved a matching one too"
      (setf (a:agent-invocation-status i2) :approved)
      (ok (equal 1 (length (state-approvals s))))
      (ok (equal "c3" (a:agent-invocation-id (first (state-approvals s))))))))

(deftest core-reply-reject-with-feedback
  (multiple-value-bind (s i1 i2 i3) (approval-state)
    (ok (equal (list (list :deny i1 :feedback "use b.txt" :all nil) '(:resume))
               (effects s '(:reply :reject "use b.txt"))))
    (ok (equal (list i2 i3) (state-approvals s)))
    (ok (equal (list (list :deny i2 :feedback nil :all nil) '(:resume))
               (effects s '(:reply :reject))))))

(deftest core-reply-reject-all
  (multiple-value-bind (s i1) (approval-state)
    (ok (equal (list (list :deny i1 :feedback nil :all t) '(:resume))
               (effects s '(:reply :reject-all))))
    (ok (null (state-approvals s)) "every pending invocation is answered")
    (ok (state-busy-p s) "busy until the resumed run ends")))

(deftest core-reply-without-approvals-does-nothing
  (ok (null (effects (busy-state) '(:reply :once))))
  (ok (null (effects (fresh-state) '(:reply :reject-all)))))

(deftest core-interrupt-with-approvals-rejects-all
  (multiple-value-bind (s i1) (approval-state)
    (ok (equal (list (list :deny i1 :feedback nil :all t) '(:resume))
               (effects s '(:interrupt))))
    (ok (null (state-approvals s)))))

(deftest core-quit
  (testing "idle"
    (multiple-value-bind (s fx) (feed (fresh-state) '(:quit))
      (ok (equal '((:quit)) fx))
      (ok (state-quit-p s))))
  (testing "busy: the turn is canceled first"
    (ok (equal '((:cancel) (:quit)) (effects (busy-state) '(:quit)))))
  (testing "/exit is the same"
    (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "/exit"))
      (ok (equal '((:quit)) fx))
      (ok (state-quit-p s))
      (ok (null (state-transcript s)) "a command gets no :user entry"))
    (ok (equal '((:cancel) (:quit)) (effects (busy-state) '(:submit "/exit"))))))

(deftest core-help
  (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "/help"))
    (ok (null fx))
    (ok (equal '(:notice) (kinds s)))
    (ok (equal +help-text+ (entry-text (last-entry s)))))
  (dolist (needle '("/help" "/clear" "/model" "/permissions" "/exit" "Esc" "@"))
    (ok (has needle +help-text+) needle))
  (testing "works while busy"
    (let ((s (busy-state)))
      (ok (null (effects s '(:submit "/help"))))
      (ok (equal '(:user :notice) (kinds s)))
      (ok (null (state-queue s)) "commands are not queued"))))

(deftest core-clear
  (let ((s (fresh-state)))
    (feed s '(:submit "hi") '(:part "hello") '(:usage (10 5 2 1)) '(:turn-end :reason :stop))
    (multiple-value-bind (s fx) (feed s '(:submit "/clear"))
      (ok (equal '((:new-conversation)) fx))
      (ok (null (state-transcript s)))
      (ok (equal '(0 0 0 0) (state-usage s)))))
  (testing "refused while busy"
    (let ((s (busy-state)))
      (ok (null (effects s '(:submit "/clear"))))
      (ok (equal '(:user :error) (kinds s)))
      (ok (has "/clear" (entry-text (last-entry s))))
      (ok (has "Esc" (entry-text (last-entry s)))))))

(deftest core-model
  (testing "show"
    (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "/model"))
      (ok (null fx))
      (ok (equal '("model: mock") (texts s)))))
  (testing "switch: the program confirms"
    (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "/model   openai:gpt-x  "))
      (ok (equal '((:set-model "openai:gpt-x")) fx))
      (ok (equal "mock" (state-model s)) "unchanged until :model-set")
      (feed s '(:model-set "openai:gpt-x"))
      (ok (equal "openai:gpt-x" (state-model s)))
      (ok (equal "model: openai:gpt-x" (entry-text (last-entry s))))))
  (testing "refused while busy"
    (let ((s (busy-state)))
      (ok (null (effects s '(:submit "/model other"))))
      (ok (eq :error (entry-kind (last-entry s))))
      (ok (has "/model" (entry-text (last-entry s)))))))

(deftest core-permissions
  (testing "show the mode and the rules"
    (let ((s (fresh-state :rules (list (parse-permission-rule "read" :allow)
                                       (parse-permission-rule "bash(git *)" :allow)
                                       (parse-permission-rule "bash(rm *)" :deny)))))
      (ok (null (effects s '(:submit "/permissions"))))
      (ok (equal (format nil "permission mode: default~%allow read~%allow bash(git *)~%deny bash(rm *)")
                 (entry-text (last-entry s))))))
  (testing "switch"
    (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "/permissions acceptEdits"))
      (ok (equal '((:set-permission-mode :accept-edits)) fx))
      (ok (eq :accept-edits (state-permission-mode s)))
      (ok (equal "permission mode: acceptEdits" (entry-text (last-entry s))))))
  (testing "unknown mode"
    (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "/permissions yolo"))
      (ok (null fx))
      (ok (eq :default (state-permission-mode s)))
      (ok (eq :error (entry-kind (last-entry s))))
      (ok (equal "unknown permission mode \"yolo\": use default, acceptEdits, bypassPermissions, plan"
                 (entry-text (last-entry s))))))
  (testing "refused while busy"
    (let ((s (busy-state)))
      (ok (null (effects s '(:submit "/permissions plan"))))
      (ok (eq :default (state-permission-mode s)))
      (ok (eq :error (entry-kind (last-entry s)))))))

(deftest core-unknown-command
  (multiple-value-bind (s fx) (feed (fresh-state) '(:submit "/frob now"))
    (ok (null fx))
    (ok (equal '(:error) (kinds s)))
    (ok (equal "unknown command /frob: try /help" (entry-text (last-entry s))))))

(deftest core-program-messages
  (let ((s (fresh-state)))
    (feed s '(:notice "saved") '(:error "no such provider"))
    (ok (equal '(:notice :error) (kinds s)))
    (ok (equal '("saved" "no such provider") (texts s)))))

(deftest core-status-line-text
  (let ((s (fresh-state :cwd #p"/srv/project/" :permission-mode :accept-edits)))
    (feed s '(:usage (10 5 2 1)) '(:usage (10 5 2 1)))
    (multiple-value-bind (left right) (status-line-text s)
      (ok (equal (format nil " mock · acceptEdits · ~a" (native #p"/srv/project/")) left))
      (ok (equal "20 in · 10 out " right))))
  (testing "the home directory is ~/"
    (let* ((home (native (user-homedir-pathname)))
           (dir (merge-pathnames "work/app/" (user-homedir-pathname)))
           (s (fresh-state :cwd dir)))
      ;; "~", then the native namestring from the home's final separator on
      (ok (equal (format nil " mock · default · ~~~a" (subseq (native dir) (1- (length home))))
                 (status-line-text s))))))
