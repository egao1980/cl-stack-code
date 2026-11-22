(in-package #:cl-stack-code/tests)

;;; H3e-1 through the SDK (and so --rpc) and the TUI: the init event, rules
;;; once per session across turns, the instructions event, a rewind restoring
;;; the instruction set in the same process, startup notes.

(deftest h3e1-client-init
  (with-project (project config) (lisp-workspace-fixture)
    (with-test-client (client backend events project config)
      (let ((init (code-session-init (client-new-session client))))
        (ok (equal '("rove") (map 'list (lambda (s) (event-value s "name")) (event-value init "skills"))))
        (ok (= 2 (length (event-value init "imports"))))
        (ok (= 1 (length (event-value init "rules"))))
        (ok (equalp #() (event-value init "notes")))
        (ok (equal "skill" (car (last (coerce (event-value init "tools") 'list)))))))))

(deftest h3e1-client-rule-once-per-session
  (with-project (project config) (lisp-rule-project)
    (with-test-client (client backend events project config
                       :steps (list (lisp-read-step "src/a.lisp") "one"
                                    (lisp-read-step "src/b.lisp") "two"))
      (let ((s (client-new-session client)))
        (multiple-value-bind (result turn-events) (client-query s "first" :timeout 30)
          (declare (ignore result))
          (let ((ev (first (events-of turn-events "instructions"))))
            (ok ev "the SDK delivers the instructions event")
            (when ev
              (ok (equal '("rule") (map 'list (lambda (f) (event-value f "kind")) (event-value ev "files")))))))
        (multiple-value-bind (result turn-events) (client-query s "second" :timeout 30)
          (declare (ignore result))
          (ok (null (events-of turn-events "instructions")) "not again in the next turn"))
        (ok (= 1 (count-of +lisp-rule-body+ (request-text (car (last (scripted-requests backend)))))))
        (let ((rule (native (truename (merge-pathnames ".claude/rules/lisp.md" project)))))
          (ok (equal (list (list rule) (list rule))
                     (records-loaded-rules project config (code-session-id s)))))))))

(deftest h3e1-client-init-instruction-set
  (with-project (project config) (lisp-workspace-fixture)
    (with-test-client (client backend events project config)
      (let ((set-id (event-value (code-session-init (client-new-session client)) "instruction_set")))
        (ok (and (stringp set-id) (= 64 (length set-id))))))))

(deftest h3e1-client-rewind-reloads-rule
  (with-project (project config) (lisp-rule-project)
    (with-test-client (client backend events project config
                       :steps (list "one"
                                    (lisp-read-step "src/a.lisp") "two"
                                    (lisp-read-step "src/b.lisp") "three"))
      (let* ((s (client-new-session client))
             (id (code-session-id s)))
        (client-query s "first" :timeout 30)
        (multiple-value-bind (result turn-events) (client-query s "second" :timeout 30)
          (declare (ignore result))
          (ok (events-of turn-events "instructions") "turn 2 loads the rule"))
        (let ((turn-2-set (record-instructions (second (session-dir-records project config id)))))
          (client-rewind s 1 :mode :conversation)
          (multiple-value-bind (result turn-events) (client-query s "third" :timeout 30)
            (declare (ignore result))
            (let ((ev (first (events-of turn-events "instructions"))))
              (ok ev "after the rewind the rule loads again, in the same process")
              (when ev
                (ok (equal turn-2-set (event-value ev "instruction_set"))
                    "the same set as turn 2's, the same revision"))))
          (ok (= 1 (count-of +lisp-rule-body+ (request-text (car (last (scripted-requests backend)))))))
          (let ((records (session-dir-records project config id)))
            (ok (equal '("first" "third") (mapcar #'record-prompt records)))
            (ok (equal turn-2-set (record-instructions (second records))))
            (ok (not (equal turn-2-set (record-instructions (first records)))))))))))

(deftest h3e1-event-types
  (ok (member "instructions" +event-types+ :test #'string=))
  (ok (equal "unit" (car (last +event-types+))) "unit stays last"))

(deftest h3e1-tui-startup-notes
  (with-project (project config) '(("AGENTS.md" "@gone.md
"))
    (with-code-tui (tui program backend :cols 220 :rows 20) (project config)
      (ok (wait-screen tui "import not found: @gone.md") "the note is a transcript notice"))))
