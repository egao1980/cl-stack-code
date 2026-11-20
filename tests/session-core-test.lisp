(in-package #:cl-stack-code/tests)

;;; The interactive core's H3c events and commands (src/interactive.lisp
;;; header, "H3c: sessions and steering").

(defun session-state (&rest keys)
  (apply #'fresh-state :session-id "0123456789abcdef0123456789abcdef" keys))

(deftest core-session-command
  (let ((s (session-state)))
    (ok (null (effects s '(:submit "/session"))))
    (ok (equal '(:notice "session 0123456789abcdef0123456789abcdef")
               (entry-summary (last-entry s))))
    (feed s '(:session "feedfacefeedfacefeedfacefeedface"))
    (ok (equal "feedfacefeedfacefeedfacefeedface" (state-session-id s)))
    (ok (null (effects s '(:submit "/session"))))
    (ok (has "feedface" (entry-text (last-entry s))))))

(deftest core-session-commands-emit-effects
  (let ((s (session-state)))
    (ok (equal '((:tree)) (effects s '(:submit "/tree"))))
    (ok (equal '((:fork nil)) (effects s '(:submit "/fork"))))
    (ok (equal '((:fork "abcd1234")) (effects s '(:submit "/fork  abcd1234 "))))
    (ok (equal '((:fork "3")) (effects s '(:submit "/fork 3"))))
    (ok (equal '((:rewind 1)) (effects s '(:submit "/rewind"))))
    (ok (equal '((:rewind 4)) (effects s '(:submit "/rewind 4"))))
    (ok (equal '((:clone)) (effects s '(:submit "/clone"))))
    (ok (equal '((:export "out/s.md")) (effects s '(:submit "/export out/s.md"))))
    (ok (null (state-busy-p s)) "none of them starts a turn")
    (ok (null (state-transcript s)) "no entries of their own")))

(deftest-parametrize core-session-command-usage-errors
    ((line text)
     :ids ("rewind-zero" "rewind-word" "rewind-negative" "export-bare" "steer-bare")
     ("/rewind 0" "usage: /rewind [N], N a positive number of turns")
     ("/rewind two" "usage: /rewind [N], N a positive number of turns")
     ("/rewind -1" "usage: /rewind [N], N a positive number of turns")
     ("/export" "usage: /export FILE (.md or .json)")
     ("/steer" "usage: /steer MESSAGE"))
  (let ((s (session-state)))
    (ok (null (effects s (list :submit line))))
    (ok (equal (list :error text) (entry-summary (last-entry s))))))

(deftest core-session-commands-while-busy
  (let ((s (busy-state :session-id "0123456789abcdef0123456789abcdef")))
    (ok (equal '((:tree)) (effects s '(:submit "/tree"))) "/tree works while busy")
    (ok (null (effects s '(:submit "/session"))))
    (ok (eq :notice (entry-kind (last-entry s))))
    (dolist (line '("/fork" "/rewind" "/clone" "/export x.md"))
      (ok (null (effects s (list :submit line))) line)
      (ok (eq :error (entry-kind (last-entry s))))
      (ok (has (first (uiop:split-string line)) (entry-text (last-entry s))))
      (ok (has "Esc" (entry-text (last-entry s)))))
    (ok (null (state-queue s)) "commands are never queued")))

(deftest core-steer-while-busy
  (let ((s (busy-state)))
    (let ((before (length (state-transcript s))))
      (ok (equal '((:steer "look at b too")) (effects s '(:steer "look at b too"))))
      (ok (equal '("look at b too") (state-steering s)))
      (ok (= before (length (state-transcript s))) "no entry until the run takes it")
      (ok (equal '((:steer "and c")) (effects s '(:submit "/steer and c"))) "/steer is the same")
      (ok (equal '("look at b too" "and c") (state-steering s)))
      (ok (null (state-queue s)) "steering is not the follow-up queue")
      (ok (null (effects s '(:steer "   "))) "blank: nothing")
      (ok (equal '("look at b too" "and c") (state-steering s))))))

(deftest core-steer-when-idle-is-submit
  (let ((s (fresh-state)))
    (ok (equal '((:run "hello")) (effects s '(:steer "hello"))))
    (ok (state-busy-p s))
    (ok (null (state-steering s)))
    (ok (equal '(:user "hello") (entry-summary (last-entry s)))))
  (let ((s (busy-state)))
    (ok (equal '((:tree)) (effects s '(:steer "/tree"))) "a command is a command")))

(deftest core-steered-adds-entries
  (let ((s (busy-state)))
    (feed s '(:steer "one") '(:steer "two") '(:part "working"))
    (feed s '(:steered ("one")))
    (ok (equal '("two") (state-steering s)))
    (ok (equal '(:user "one") (entry-summary (last-entry s))))
    (feed s '(:part " more") '(:steered ("two")))
    (ok (null (state-steering s)))
    (ok (equal '((:user "first") (:assistant "working") (:user "one") (:assistant " more")
                 (:user "two"))
               (mapcar #'entry-summary (state-transcript s)))
        "steering shows where the run took it")))

(deftest core-untaken-steering-becomes-the-next-turn
  (let ((s (busy-state)))
    (feed s '(:submit "queued follow-up") '(:steer "late steer"))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :stop))
      (ok (equal '((:run "late steer")) fx) "steering first")
      (ok (state-busy-p s))
      (ok (null (state-steering s)))
      (ok (equal '("queued follow-up") (state-queue s)))
      (ok (equal '(:user "late steer") (entry-summary (last-entry s)))))))

(deftest core-cancel-restores-steering-and-queue
  (let ((s (busy-state)))
    (feed s '(:submit "follow") '(:steer "steer one") '(:steer "steer two"))
    (multiple-value-bind (s fx) (feed s '(:turn-end :reason :canceled))
      (ok (equal (list (list :restore-input (format nil "steer one~%steer two~%follow"))) fx))
      (ok (null (state-steering s)))
      (ok (null (state-queue s)))
      (ok (not (state-busy-p s)))))
  (let ((s (busy-state)))
    (feed s '(:steer "only steering"))
    (ok (equal '((:restore-input "only steering"))
               (effects s '(:turn-end :reason :failed :message "boom"))))))

(deftest core-session-reset
  (let ((s (session-state)))
    (feed s '(:submit "one") '(:part "1") '(:turn-end :reason :stop)
          '(:usage (10 5 2 1)))
    (let ((entries (list (make-entry :kind :user :text "zero")
                         (make-entry :kind :assistant :text "0"))))
      (multiple-value-bind (s fx)
          (feed s (list :session-reset :entries entries :input "one" :notice "forked"))
        (ok (equal '((:restore-input "one")) fx))
        (ok (equal '((:user "zero") (:assistant "0") (:notice "forked"))
                   (mapcar #'entry-summary (state-transcript s))))
        (ok (not (eq entries (state-transcript s))) "a copy of the list")
        (ok (equal '(10 5 2 1) (state-usage s)) "usage is kept"))
      (multiple-value-bind (s fx) (feed s (list :session-reset :entries '()))
        (ok (null fx))
        (ok (null (state-transcript s)))))))

(deftest core-help-mentions-sessions-and-steering
  (dolist (needle '("/session" "/tree" "/fork" "/rewind" "/clone" "/export" "/steer" "Ctrl-T"))
    (ok (has needle +help-text+) needle)))
