(in-package #:cl-stack-code/tests)

;;; H5a: the interactive core's plan events, effects and commands
;;; (src/interactive.lisp header, "H5a"). Pure: no program, no files.

(defparameter +plan-id+ "abcdef0123456789abcdef0123456789")

(defun opened-state (&rest keys)
  "An idle plan-mode state with plan +PLAN-ID+ open."
  (feed (apply #'fresh-state :permission-mode :plan keys)
        (list :plan-opened :id +plan-id+ :kind :git :root "/tmp/area/")))

(defun projected-state (&optional (changes '((:modified "a.txt"))))
  (feed (opened-state)
        (list :plan-projected :id +plan-id+ :changes changes
                              :diff (if changes (format nil "diff --git a/a.txt b/a.txt~%") ""))))

(deftest plan-core-opened
  (let ((s (opened-state)))
    (ok (equal +plan-id+ (getf (state-plan s) :id)))
    (ok (eq :git (getf (state-plan s) :kind)))
    (ok (null (state-plan-prompt s)))
    (ok (equal "plan abcdef01 (git): edits go to a copy of the project in /tmp/area/; the project changes only when you approve"
               (entry-text (last-entry s))))
    (ok (eq :notice (entry-kind (last-entry s))))))

(deftest plan-core-projected
  (let ((s (projected-state)))
    (ok (eq :plan (state-plan-prompt s)) "idle with changes: the plan dialog")
    (ok (equal '((:modified "a.txt")) (getf (state-plan s) :changes)))
    (let ((e (last-entry s)))
      (ok (eq :plan (entry-kind e)))
      (ok (equal +plan-id+ (entry-id e)))
      (ok (equal '((:modified "a.txt")) (entry-input e)))
      (ok (has "diff --git" (entry-text e))))))

(deftest plan-core-projected-empty
  (let ((s (projected-state '())))
    (ok (null (state-plan-prompt s)))
    (ok (equal "plan abcdef01: no changes yet" (entry-text (last-entry s))))))

(deftest plan-core-projected-while-busy
  (let ((s (feed (opened-state) '(:submit "go"))))
    (feed s (list :plan-projected :id +plan-id+ :changes '((:added "b.txt")) :diff "x"))
    (ok (null (state-plan-prompt s)) "no dialog while a turn runs")
    (ok (eq :plan (entry-kind (last-entry s))))))

(deftest-parametrize plan-core-replies
    ((choice effects notice)
     :ids ("approve" "reject" "continue")
     (:approve '((:approve-plan)) nil)
     (:reject '((:reject-plan)) nil)
     (:continue nil "plan abcdef01 stays open: send a message to keep planning, /plan to review it"))
  (let ((s (projected-state)))
    (ok (equal effects (effects s (list :reply choice))))
    (ok (null (state-plan-prompt s)))
    (when notice
      (ok (equal notice (entry-text (last-entry s)))))))

(deftest plan-core-escape-keeps-planning
  (let ((s (projected-state)))
    (ok (null (effects s '(:interrupt))))
    (ok (null (state-plan-prompt s)))
    (ok (has "stays open" (entry-text (last-entry s))))
    (ok (state-plan s) "still open")))

(deftest plan-core-drift
  (let ((s (projected-state)))
    (feed s '(:reply :approve) '(:plan-drift :paths ("a.txt" "b.txt")))
    (ok (eq :drift (state-plan-prompt s)))
    (ok (eq :error (entry-kind (last-entry s))))
    (ok (equal "the working copy changed since plan abcdef01 was opened: a.txt, b.txt"
               (entry-text (last-entry s))))))

(deftest-parametrize plan-core-drift-replies
    ((choice effects)
     :ids ("rebase" "overwrite" "abort")
     (:rebase '((:approve-plan :on-drift :rebase)))
     (:overwrite '((:approve-plan :on-drift :overwrite)))
     (:abort nil))
  (let ((s (projected-state)))
    (feed s '(:reply :approve) '(:plan-drift :paths ("a.txt")))
    (ok (equal effects (effects s (list :reply choice))))
    (ok (null (state-plan-prompt s)))))

(deftest plan-core-drift-escape
  (let ((s (projected-state)))
    (feed s '(:reply :approve) '(:plan-drift :paths ("a.txt")))
    (ok (null (effects s '(:interrupt))) "Esc in the drift dialog is :abort")
    (ok (null (state-plan-prompt s)))))

(deftest-parametrize plan-core-closed
    ((event text open-p)
     :ids ("applied" "empty" "discarded" "rebased" "rebased-conflicts" "aborted")
     ('(:plan-closed :status :applied :changes ((:modified "a.txt") (:added "b.txt")))
      "plan abcdef01 applied: 2 files changed" nil)
     ('(:plan-closed :status :empty) "plan abcdef01 had no changes" nil)
     ('(:plan-closed :status :discarded) "plan abcdef01 discarded" nil)
     ('(:plan-closed :status :rebased) "plan abcdef01 rebased onto the working copy" t)
     ('(:plan-closed :status :rebased :conflicts ("a.txt" "c.txt"))
      "plan abcdef01 rebased onto the working copy; conflicts in a.txt, c.txt" t)
     ('(:plan-closed :status :aborted) "nothing applied; plan abcdef01 stays open" t))
  (let ((s (projected-state)))
    (feed s '(:reply :approve) event)
    (ok (equal text (entry-text (last-entry s))))
    (ok (eq :notice (entry-kind (last-entry s))))
    (ok (eq open-p (and (state-plan s) t)))
    (ok (null (state-plan-prompt s)))))

(deftest plan-core-applied-one-file
  (let ((s (projected-state)))
    (feed s '(:plan-closed :status :applied :changes ((:modified "a.txt"))))
    (ok (equal "plan abcdef01 applied: 1 file changed" (entry-text (last-entry s))))))

(deftest plan-core-commands
  (let ((s (opened-state)))
    (ok (equal '((:show-plan)) (effects s '(:submit "/plan"))))
    (ok (equal '((:approve-plan)) (effects s '(:submit "/approve"))))
    (ok (equal '((:reject-plan)) (effects s '(:submit "/reject"))))))

(deftest plan-core-commands-without-a-plan
  (let ((s (fresh-state :permission-mode :plan)))
    (ok (null (effects s '(:submit "/plan"))))
    (ok (equal "no open plan" (entry-text (last-entry s))))
    (ok (eq :notice (entry-kind (last-entry s))))
    (dolist (command '("/approve" "/reject"))
      (ok (null (effects s (list :submit command))))
      (ok (eq :error (entry-kind (last-entry s))))
      (ok (equal "no open plan" (entry-text (last-entry s)))))))

(deftest plan-core-commands-while-busy
  (let ((s (feed (opened-state) '(:submit "go"))))
    (dolist (command '("/plan" "/approve" "/reject"))
      (ok (null (effects s (list :submit command))) command)
      (ok (eq :error (entry-kind (last-entry s))))
      (ok (has "not available while a turn runs" (entry-text (last-entry s)))))))

(deftest plan-core-open-plan-blocks-leaving
  (let ((s (opened-state)))
    (dolist (command '("/clear" "/permissions default" "/permissions acceptEdits"))
      (ok (null (effects s (list :submit command))) command)
      (ok (equal "plan abcdef01 is open: /approve or /reject it first" (entry-text (last-entry s))))
      (ok (eq :plan (state-permission-mode s))))
    (ok (null (effects s '(:submit "/permissions plan"))) "staying in plan mode is fine")
    (ok (eq :plan (state-permission-mode s)))
    (ok (has "permission mode: plan" (entry-text (last-entry s))))
    (ok (null (effects s '(:submit "/permissions"))) "showing the rules is fine")
    (ok (has "permission mode: plan" (entry-text (last-entry s))))))

(deftest plan-core-approvals-come-first
  (let ((s (projected-state))
        (inv (proposed "c1" "bash")))
    (feed s '(:reply :continue) '(:submit "go")
          (list :turn-end :reason :approval :pending (list inv)))
    (ok (equal (list (list :approve inv :always nil) '(:resume))
               (effects s '(:reply :once)))
        "a tool approval is answered by :reply, not the plan")))

(deftest plan-core-help
  (dolist (needle '("/plan" "/approve" "/reject"))
    (ok (has needle +help-text+) needle))
  (ok (equal '(:approve :continue :reject) (mapcar #'first +plan-choices+)))
  (ok (equal '(:rebase :overwrite :abort) (mapcar #'first +drift-choices+))))
