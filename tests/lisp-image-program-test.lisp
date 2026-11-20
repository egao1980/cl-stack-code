(in-package #:cl-stack-code/tests)

;;; H4b interactive: a spawned image, the banner, the status line marker,
;;; the idle policies and a restart through the approval dialog.

(defparameter *image-timeout* 40
  "Seconds an image wait may take (spawning an image, then a turn).")

(deftest lisp-image-program-turn-policy
  (with-project (project config) '()
    (with-code-tui (tui program backend
                        :argv '("--lisp-image" "spawn" "--allowed-tools" "repl-eval")
                        :steps (list (list :tool "repl-eval" (json-args "code" +late-error+))
                                     "Started."
                                     (list :tool "debug-invoke-restart" (json-args "restart" 0))
                                     "Fixed."))
        (project config)
      (ok (wait-for* tui (lambda () (search "λ image" (last-row tui))) :timeout *image-timeout*)
          "the status line marker")
      (ok (not (search "(debugger)" (last-row tui))))
      (send-line tui "start the worker")
      (ok (wait-screen tui "Started." :timeout *image-timeout*))
      (ok (wait-screen tui "λ image is in the debugger: late boom" :timeout *image-timeout*)
          "the banner")
      (ok (wait-screen tui "λ image entered the debugger" :timeout *image-timeout*)
          "the transcript notice")
      (ok (wait-requests tui backend 3 :timeout *image-timeout*)
          "onDebugger turn: an idle event starts a turn")
      (let ((turns (request-image-turns (third (scripted-requests backend)))))
        (ok (= 1 (length turns)))
        (ok (has "late boom" (turn-text* (first turns)))))
      (ok (wait-screen tui "Permission" :timeout *image-timeout*) "the restart asks")
      (ok (on-screen tui "debug-invoke-restart"))
      (let ((banner (row-index tui "λ image is in the debugger"))
            (rule (position-if #'rule-row-p (screen tui))))
        (ok (and banner rule (= (1+ banner) rule)) "the banner sits right above the rule"))
      (ok (search "λ image (debugger)" (last-row tui)))
      (h:tui-type tui "1")
      (ok (wait-screen tui "Fixed." :timeout *image-timeout*))
      (ok (wait-gone tui "λ image is in the debugger" :timeout *image-timeout*)
          "the banner goes when the image leaves the debugger")
      (ok (wait-for* tui (lambda () (not (search "(debugger)" (last-row tui))))))
      (ok (= 4 (length (scripted-requests backend))))
      (ok (has "Invoked restart 0 [RETRY-LATER]"
               (result-content (car (last (request-tool-results (fourth (scripted-requests backend)))))))))))

(deftest lisp-image-program-notice-policy
  (with-project (project config) '()
    (write-file project ".cl-stack-code/settings.json"
                (lisp-settings "image" "spawn" "onDebugger" "notice"))
    (with-code-tui (tui program backend
                        :argv '("--allowed-tools" "repl-eval")
                        :steps (list (list :tool "repl-eval" (json-args "code" +late-error+))
                                     "Started."
                                     "It hit late boom; restart 0 retries it."))
        (project config)
      (send-line tui "start the worker")
      (ok (wait-screen tui "Started." :timeout *image-timeout*))
      (ok (wait-screen tui "λ image is in the debugger: late boom" :timeout *image-timeout*))
      (sleep 2)
      (ok (= 2 (length (scripted-requests backend))) "onDebugger notice: no turn starts")
      (ok (not (state-busy-p (code-program-state program))))
      (send-line tui "what happened?")
      (ok (wait-requests tui backend 3 :timeout *image-timeout*))
      (let* ((turns (request-turns (third (scripted-requests backend))))
             (asked (position-if (lambda (turn) (has "what happened?" (turn-text* turn))) turns))
             (event (position-if #'image-turn-p* turns)))
        (ok (and asked event (< asked event)) "the queued event follows the user's message"))
      (ok (wait-screen tui "restart 0 retries it" :timeout *image-timeout*)))))

(deftest lisp-image-program-observe-marker
  (with-swank-server (port server)
    (with-project (project config) '()
      (with-code-tui (tui program backend
                          :argv (list "--lisp-image" (format nil "attach:~d" port) "--lisp-observe")
                          :steps (list "Hello."))
          (project config)
        (ok (wait-for* tui (lambda () (search "λ image (observe)" (last-row tui)))
                       :timeout *image-timeout*))
        (ok (equal (format nil "image (attached 127.0.0.1:~d, swank, observe)" port)
                   (getf (state-image (code-program-state program)) :description))))
      (ok (has "=> 3" (server-eval server "(+ 1 2)")) "closing the program leaves the image running"))))

(deftest lisp-image-program-configuration-errors
  (with-project (project config) '()
    (ok (typep (failure (make-program project config :argv '("--lisp-image" "spawn" "--lisp-observe")))
               'code-usage-error)
        "the checks run before the terminal")
    (ok (typep (failure (make-program project config :argv '("--lisp-image" "attach:127.0.0.1:1")))
               'lisp-image-error)
        "an image that cannot be reached fails before the terminal")))
