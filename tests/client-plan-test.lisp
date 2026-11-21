(in-package #:cl-stack-code/tests)

;;; H3d: plans (H5a), checkpoints and rewinds (H5b) through the SDK. The
;;; objects are -p's (src/client.lisp, "Plans …").

(defun subtype-of (e) (event-value e "subtype"))

(defun client-plan-event (events subtype)
  (find subtype (events-of events "plan") :key #'subtype-of :test #'equal))

(deftest-parametrize client-plan-turn-and-approve
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) (list (list "a.txt" (nl "alpha")))
    (with-test-client (client backend events project config
                       :steps (list (write-tool "a.txt" (nl "beta")) "Done."))
      (let ((s (client-new-session client :permission-mode :plan)))
        (multiple-value-bind (result turn-events) (client-query s "make it beta" :timeout 60)
          (ok (equal "success" (event-value result "subtype")))
          (let ((opened (first turn-events)))
            (ok (equal "plan" (event-type opened)) "the plan opens first")
            (ok (equal "opened" (subtype-of opened)))
            (ok (equal (string-downcase (symbol-name kind)) (event-value opened "kind"))))
          (let ((projected (client-plan-event turn-events "projected")))
            (ok projected)
            (ok (has "+beta" (event-value projected "diff")))
            (ok (equal "a.txt" (event-value projected "changes" 0 "path"))))
          (ok (equal '("plan" "result") (last (event-types turn-events) 2)) "projected, then the result")
          (ok (equal "open" (event-value result "plan" "status")))
          (ok (equal (nl "alpha") (read-file project "a.txt")) "the project is untouched"))
        (let ((applied (client-approve-plan s)))
          (ok (equal "plan" (event-type applied)))
          (ok (equal "applied" (subtype-of applied)))
          (ok (equal "a.txt" (event-value applied "changes" 0 "path")))
          (ok (equal "modified" (event-value applied "changes" 0 "kind")))
          (ok (member applied (events-of events "plan")) "delivered as an event too"))
        (ok (equal (nl "beta") (read-file project "a.txt")))
        (ok (equal '("plan_after" "plan_before")
                   (mapcar (lambda (k) (event-value k "reason")) (client-checkpoints s)))
            "the approval's checkpoints")
        (let ((c (failure (client-approve-plan s))))
          (ok (typep c 'plan-not-found) "applied: no open plan")
          (ok (has "has no open plan" (princ-to-string c))))))))

(deftest client-plan-reject
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-test-client (client backend events project config
                       :steps (list (write-tool "a.txt" (nl "beta")) "Done."))
      (let ((s (client-new-session client :permission-mode :plan)))
        (client-query s "make it beta" :timeout 60)
        (let ((discarded (client-reject-plan s)))
          (ok (equal "discarded" (subtype-of discarded)))
          (ok (stringp (event-value discarded "plan_id"))))
        (ok (equal (nl "alpha") (read-file project "a.txt")))
        (ok (signals (client-reject-plan s) 'plan-not-found))))))

(deftest client-plan-drift
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-test-client (client backend events project config
                       :steps (list (write-tool "a.txt" (nl "beta")) "Done."))
      (let ((s (client-new-session client :permission-mode :plan)))
        (client-query s "make it beta" :timeout 60)
        (write-file project "a.txt" (nl "user"))
        (let ((drift (client-approve-plan s)))
          (ok (equal "drift" (subtype-of drift)))
          (ok (equalp #("a.txt") (event-value drift "paths")))
          (ok (equal (nl "user") (read-file project "a.txt")) "nothing written"))
        (let ((applied (client-approve-plan s :on-drift :overwrite)))
          (ok (equal "applied" (subtype-of applied)))
          (ok (equal (nl "beta") (read-file project "a.txt"))))))))

(deftest client-plan-next-turn-opens-a-new-plan
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-test-client (client backend events project config
                       :steps (list (write-tool "a.txt" (nl "beta")) "One."
                                    (write-tool "a.txt" (nl "gamma")) "Two."))
      (let ((s (client-new-session client :permission-mode :plan)))
        (let* ((first-events (nth-value 1 (client-query s "beta" :timeout 60)))
               (first-id (event-value (client-plan-event first-events "opened") "plan_id")))
          (client-approve-plan s)
          (let* ((second-events (nth-value 1 (client-query s "gamma" :timeout 60)))
                 (opened (client-plan-event second-events "opened")))
            (ok opened "a new plan")
            (ok (not (equal first-id (event-value opened "plan_id"))))
            (ok (has "+gamma" (event-value (client-plan-event second-events "projected") "diff")))))))))

(deftest client-plan-and-rewind-refuse-a-busy-session
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-test-client (client backend events project config
                         :steps (list (list :gate gate "Done.")))
        (let* ((s (client-new-session client :permission-mode :plan))
               (turn (client-turn s "think")))
          (ok (wait-until (lambda () (gate-waiting-p gate))))
          (ok (signals (client-approve-plan s) 'turn-busy))
          (ok (signals (client-reject-plan s) 'turn-busy))
          (ok (signals (client-rewind s 0) 'turn-busy))
          (open-gate gate)
          (client-wait turn :timeout 30))))))

(deftest client-checkpoints-list
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-test-client (client backend events project config
                       :steps (list (write-tool "a.txt" (nl "beta")) "Done."))
      (let ((s (client-new-session client :permission-mode :accept-edits)))
        (ok (null (client-checkpoints s)) "none yet")
        (client-query s "beta" :timeout 30)
        (let ((list (client-checkpoints s)))
          (ok (equal '("turn" "before") (mapcar (lambda (k) (event-value k "reason")) list))
              "newest first")
          (ok (equal '(1 0) (mapcar (lambda (k) (event-value k "turn")) list)))
          (ok (every (lambda (k) (equal '("expired" "files_kind" "id" "message" "ordinal" "reason"
                                          "recorded_at" "turn")
                                        (jkeys k)))
                     list))
          (ok (every (lambda (k) (equal "copy" (event-value k "files_kind"))) list))
          (ok (every (lambda (k) (null (event-value k "expired"))) list))
          (ok (every (lambda (k) (integerp (event-value k "recorded_at"))) list))
          (ok (equal '(2 1) (mapcar (lambda (k) (event-value k "ordinal")) list))))))))

(deftest client-rewind-both
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-test-client (client backend events project config
                       :steps (list (write-tool "a.txt" (nl "beta")) "One."
                                    (write-tool "a.txt" (nl "gamma")) "Two."
                                    "Three."))
      (let ((s (client-new-session client :permission-mode :accept-edits)))
        (client-query s "first" :timeout 30)
        (client-query s "second" :timeout 30)
        (let ((r (client-rewind s 1)))
          (ok (equal "rewind" (event-type r)))
          (ok (equal (code-session-id s) (event-value r "session_id")))
          (ok (eql 1 (event-value r "turn")))
          (ok (equal "moved" (event-value r "conversation")))
          (ok (equal "applied" (event-value r "files")))
          (ok (equal "a.txt" (event-value r "changes" 0 "path")))
          (ok (stringp (event-value r "checkpoint")))
          (ok (member r (events-of events "rewind")) "delivered as an event too"))
        (ok (equal (nl "beta") (read-file project "a.txt")))
        (client-query s "third" :timeout 30)
        (ok (equal '("first" "third") (request-user-texts (fifth (scripted-requests backend))))
            "the next turn starts on the new head")))))

(deftest client-rewind-modes-and-drift
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-test-client (client backend events project config
                       :steps (list (write-tool "a.txt" (nl "beta")) "One."))
      (let ((s (client-new-session client :permission-mode :accept-edits)))
        (client-query s "first" :timeout 30)
        (write-file project "a.txt" (nl "user"))
        (let ((r (client-rewind s 0 :mode :files)))
          (ok (equal "aborted" (event-value r "files")) "drift is a value, not an error")
          (ok (equalp #("a.txt") (event-value r "drift")))
          (ok (equalp #("files") (event-value r "parts")))
          (ok (equal (nl "user") (read-file project "a.txt"))))
        (let ((r (client-rewind s "0" :mode :files :on-drift :overwrite)))
          (ok (equal "applied" (event-value r "files")))
          (ok (equal (nl "alpha") (read-file project "a.txt"))))
        (let ((r (client-rewind s 0 :mode :conversation)))
          (ok (equal "moved" (event-value r "conversation")))
          (ok (equal "skipped" (event-value r "files"))))
        (ok (signals (client-rewind s 7) 'code-error) "no such turn")))))
