(in-package #:cl-stack-code/tests)

;;; H5b: /checkpoints and /rewind in the interactive core (src/interactive.lisp
;;; header, "H5b"), driven with hand-built events.

(defun rewind-state (&rest keys)
  "An idle state with two turns done."
  (feed (apply #'fresh-state keys)
        '(:submit "one") '(:turn-end :reason :stop)
        '(:submit "two") '(:turn-end :reason :stop)))

(deftest core-checkpoints-command
  (let ((s (rewind-state)))
    (ok (equal '((:checkpoints)) (effects s '(:submit "/checkpoints")))))
  (ok (equal '((:checkpoints)) (effects (busy-state) '(:submit "/checkpoints")))
      "also while a turn runs"))

(deftest-parametrize core-rewind-parts
    ((line effects)
     :ids ("files" "n-conversation" "n-both" "bare" "n")
     ("/rewind files" '((:rewind 1 :parts (:files))))
     ("/rewind 2 conversation" '((:rewind 2 :parts (:conversation))))
     ("/rewind 3 both" '((:rewind 3 :parts (:conversation :files))))
     ("/rewind" '((:rewind 1)))
     ("/rewind 4" '((:rewind 4))))
  (let ((s (rewind-state)))
    (ok (equal effects (effects s (list :submit line))))))

(deftest core-rewind-parts-state
  (let ((s (rewind-state)))
    (effects s '(:submit "/rewind 2 files"))
    (ok (eql 2 (getf (state-rewind s) :n)))
    (ok (equal '(:files) (getf (state-rewind s) :parts)))))

(deftest-parametrize core-rewind-usage-errors
    ((line text)
     :ids ("bad-part" "too-many" "bad-n-with-part" "zero")
     ("/rewind 2 all" "usage: /rewind [N] [conversation|files|both]")
     ("/rewind 2 files more" "usage: /rewind [N] [conversation|files|both]")
     ("/rewind x files" "usage: /rewind [N], N a positive number of turns")
     ("/rewind 0 files" "usage: /rewind [N], N a positive number of turns"))
  (let ((s (rewind-state)))
    (ok (null (effects s (list :submit line))))
    (ok (equal (list :error text) (list (entry-kind (last-entry s)) (entry-text (last-entry s)))))))

(deftest core-rewind-refusals
  (let ((s (busy-state)))
    (ok (null (effects s '(:submit "/rewind files"))))
    (ok (equal "/rewind is not available while a turn runs (Esc interrupts it)"
               (entry-text (last-entry s)))))
  (let ((s (rewind-state :permission-mode :plan)))
    (feed s '(:plan-opened :id "0123456789abcdef0123456789abcdef" :kind :copy :root "/tmp/area/"))
    (ok (null (effects s '(:submit "/rewind files"))))
    (ok (equal "plan 01234567 is open: /approve or /reject it first" (entry-text (last-entry s))))
    (ok (equal '((:rewind 1 :parts (:conversation))) (effects s '(:submit "/rewind conversation")))
        "the conversation alone is fine with a plan open")))

(deftest core-rewind-prompt
  (let ((s (rewind-state)))
    (feed s '(:rewind-prompt :n 1 :turn 1 :paths ("a.txt" "b.txt")))
    (ok (eq :rewind (state-rewind-prompt s)))
    (ok (equal '(1 1 ("a.txt" "b.txt"))
               (list (getf (state-rewind s) :n) (getf (state-rewind s) :turn) (getf (state-rewind s) :paths))))))

(deftest-parametrize core-rewind-dialog-replies
    ((choice effects)
     :ids ("both" "conversation" "files" "cancel")
     (:both '((:rewind 1 :parts (:conversation :files))))
     (:conversation '((:rewind 1 :parts (:conversation))))
     (:files '((:rewind 1 :parts (:files))))
     (:cancel '()))
  (let ((s (rewind-state)))
    (feed s '(:rewind-prompt :n 1 :turn 1 :paths ("a.txt")))
    (ok (equal effects (effects s (list :reply choice))))
    (ok (null (state-rewind-prompt s)) "every answer closes the dialog")
    (when (eq choice :cancel)
      (ok (equal "rewind canceled" (entry-text (last-entry s))))
      (ok (null (state-rewind s))))))

(deftest core-rewind-dialog-esc
  (let ((s (rewind-state)))
    (feed s '(:rewind-prompt :n 2 :turn 0 :paths ("a.txt")))
    (ok (null (effects s '(:interrupt))))
    (ok (null (state-rewind-prompt s)))
    (ok (equal "rewind canceled" (entry-text (last-entry s))))))

(deftest-parametrize core-rewind-drift-replies
    ((choice effects)
     :ids ("rebase" "overwrite" "abort")
     (:rebase '((:rewind 2 :parts (:files) :on-drift :rebase)))
     (:overwrite '((:rewind 2 :parts (:files) :on-drift :overwrite)))
     (:abort '()))
  (let ((s (rewind-state)))
    (effects s '(:submit "/rewind 2 files"))
    (feed s '(:rewind-drift :paths ("a.txt" "b.txt")))
    (ok (eq :drift (state-rewind-prompt s)))
    (ok (equal '(:error "the working copy changed since the last checkpoint: a.txt, b.txt")
               (list (entry-kind (last-entry s)) (entry-text (last-entry s)))))
    (ok (equal effects (effects s (list :reply choice))))
    (ok (null (state-rewind-prompt s)))
    (when (eq choice :abort)
      (ok (equal "nothing restored" (entry-text (last-entry s)))))))

(deftest core-rewind-drift-esc
  (let ((s (rewind-state)))
    (effects s '(:submit "/rewind files"))
    (feed s '(:rewind-drift :paths ("a.txt")))
    (ok (null (effects s '(:interrupt))))
    (ok (equal "nothing restored" (entry-text (last-entry s))))))

(deftest core-rewind-reply-prefers-approvals
  (let ((s (busy-state)))
    (feed s (list :turn-end :reason :approval :pending (list (proposed "i1" "bash"))))
    (setf (state-rewind-prompt s) :rewind
          (state-rewind s) (list :n 1 :turn 1 :paths '("a.txt")))
    (ok (equal :approve (first (first (effects s '(:reply :once)))))
        "a waiting tool approval answers first")))

(deftest-parametrize core-rewound-notices
    ((event text)
     :ids ("both" "conversation" "files" "empty" "merged" "aborted")
     ('(:rewound :turn 1 :parts (:conversation :files) :conversation :moved :files :applied
                :changes ((:modified "a.txt")) :conflicts ())
      "rewound to turn 1: conversation and files (1 file changed)")
     ('(:rewound :turn 2 :parts (:conversation) :conversation :moved :files :skipped)
      "rewound to turn 2: conversation")
     ('(:rewound :turn 0 :parts (:files) :conversation :skipped :files :applied
                :changes ((:modified "a.txt") (:added "b.txt")))
      "rewound to turn 0: files (2 files changed)")
     ('(:rewound :turn 1 :parts (:files) :conversation :skipped :files :empty)
      "rewound to turn 1: files (no changes)")
     ('(:rewound :turn 1 :parts (:files) :conversation :skipped :files :merged
                :changes ((:modified "a.txt")) :conflicts ("a.txt"))
      "rewound to turn 1: files (1 file changed, merged with the working copy; conflicts in a.txt)")
     ('(:rewound :turn 1 :parts (:conversation :files) :conversation :unchanged :files :aborted)
      "nothing restored"))
  (let ((s (rewind-state)))
    (effects s '(:submit "/rewind files"))
    (ok (null (effects s event)))
    (ok (equal (list :notice text) (list (entry-kind (last-entry s)) (entry-text (last-entry s)))))
    (ok (null (state-rewind s)))
    (ok (null (state-rewind-prompt s)))))

(deftest-parametrize rewind-description-rows
    ((result text)
     :ids ("both" "both-empty" "both-merged-clean" "conversation-unchanged")
     ('(:turn 1 :parts (:conversation :files) :conversation :moved :files :applied
       :changes ((:modified "a.txt") (:removed "b.txt")))
      "conversation and files (2 files changed)")
     ('(:turn 1 :parts (:conversation :files) :conversation :moved :files :empty)
      "conversation and files (no changes)")
     ('(:turn 1 :parts (:conversation :files) :conversation :moved :files :merged
       :changes ((:modified "a.txt")))
      "conversation and files (1 file changed, merged with the working copy)")
     ('(:turn 1 :parts (:conversation) :conversation :unchanged :files :skipped)
      "conversation"))
  (ok (equal text (rewind-description result))))

(deftest core-help-mentions-checkpoints
  (dolist (needle '("/checkpoints" "/rewind [N] [PART]" "conversation, files or both"))
    (ok (has needle +help-text+) needle))
  (ok (equal '((:both "Conversation and files") (:conversation "Conversation only")
               (:files "Files only") (:cancel "Cancel"))
             +rewind-choices+)))
