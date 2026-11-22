(in-package #:cl-stack-code/tests)

;;; R4d-4b: plan mode's sandbox in the interactive program (headless TUI
;;; driver, scripted mock LLM) and through the SDK. Portable: the recording
;;; backend. The hosts read *PLAN-COMPUTE-BACKEND* when they are made (this
;;; thread); the plan opens on the program's agent thread.

(deftest sandbox-program-confined-runs-without-asking
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-plan-backend (b)
      (with-plan-tui (tui program backend
                          :steps (list (bash-step "echo hi")
                                       (list :tool "write" (write-args "a.txt" (nl "beta")))
                                       "Done."))
          (project config)
        (ok (plan-turn tui "go"))
        (ok (not (on-screen tui "Allow once")) "bash ran without a dialog")
        (ok (not (on-screen tui "no sandbox")) "no notice while confined")
        (ok (some (lambda (l) (has "echo hi" (launch-command l))) (command-launches b))
            "through the backend")
        (ok (= 1 (length (canary-launches b))) "probed once")))))

(deftest sandbox-program-unavailable-notice-and-asks
  (with-project (project config) '(("a.txt" "alpha
"))
    (let ((*plan-compute-backend* nil))
      (with-plan-tui (tui program backend
                          :steps (list (bash-step (marker-command project "ran.txt")) "Done."))
          (project config)
        (send-line tui "go")
        (ok (wait-screen tui "no sandbox (") "the notice is a transcript entry")
        (ok (on-screen tui "job_input ask before"))
        (ok (wait-screen tui "Permission") "bash asks again (0.4.0)")
        (ok (on-screen tui "Allow once"))
        (ok (not (file-exists project "ran.txt")) "nothing ran before the answer")
        (h:tui-type tui "3")
        (ok (wait-screen tui "What should it do instead?"))
        (h:tui-press tui :enter)
        (ok (wait-idle tui program))
        (ok (not (file-exists project "ran.txt")) "rejected: never ran")))))

(deftest sandbox-program-refusal-then-asks
  (with-project (project config) '()
    (with-plan-backend (b (make-recording-backend :refuse-marked t))
      (with-plan-tui (tui program backend
                          :steps (list (bash-step (format nil "echo first; ~a" +refuse-marker+))
                                       "Done."
                                       (bash-step "echo second")
                                       "Done again."))
          (project config)
        (send-line tui "one")
        (ok (wait-screen tui "the sandbox refused a command (") "the notice")
        (ok (wait-idle tui program))
        (ok (not (on-screen tui "Allow once")) "the refused command did not ask")
        (let ((before (length (command-launches b))))
          (send-line tui "two")
          (ok (wait-screen tui "Permission") "from the next turn bash asks")
          (ok (on-screen tui "Allow once"))
          (h:tui-type tui "1")
          (ok (wait-screen tui "Done again."))
          (ok (= before (length (command-launches b)))
              "the next turn's shell is no longer confined: the backend saw nothing"))))))

(deftest-parametrize sandbox-client-plan-event
    ((label make status) :ids ("confined" "unavailable")
     ("confined" (lambda () (make-recording-backend)) "confined")
     ("unavailable" (lambda () nil) "unavailable"))
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (let ((*plan-compute-backend* (funcall make)))
      (with-test-client (client backend events project config :steps (list "Done."))
        (let ((s (client-new-session client :permission-mode :plan)))
          (multiple-value-bind (result turn-events) (client-query s "go" :timeout 60)
            (declare (ignore result))
            (let ((opened (client-plan-event turn-events "opened")))
              (ok opened label)
              (ok (equal status (and opened (event-value opened "sandbox" "status")))))))))))
