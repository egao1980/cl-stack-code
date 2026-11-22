(in-package #:cl-stack-code/tests)

;;; R4d-4b: plan mode's sandbox in -p (src/sandbox.lisp header), portable:
;;; the recording backend (it runs commands unchanged, so these tests check
;;; what is passed and what asks, not what the kernel denies; the real
;;; backends are tests/sandbox-seatbelt-test.lisp and sandbox-landlock-test.lisp).

(defun sandbox-run (project config steps &rest argv)
  "A stream-json plan run with prompt \"go\". → (values exit out err backend)."
  (apply #'plan-run project config steps argv))

;;; Confined.

(deftest sandbox-cli-plan-passes-the-confinement
  (with-project (project config) '(("a.txt" "alpha"))
    (with-plan-backend (b)
      (multiple-value-bind (exit out)
          (sandbox-run project config (list (bash-step "echo hi") "ok"))
        (ok (eql 0 exit))
        (let* ((plan (only-plan project config))
               (runs (command-launches b))
               (launch (first runs))
               (c (and launch (recorded-launch-confinement launch))))
          (ok (= 1 (length (canary-launches b))) "probed once, when the plan opened")
          (ok (= 1 (length runs)) "bash ran through the backend")
          (when c
            (ok (has "echo hi" (launch-command launch)))
            (ok (equal (dir-keys (list (plan-root plan) (plan-scratch-directory plan)))
                       (dir-keys (sc:confinement-writable c)))
                "writable: the area and the scratch dir")
            (ok (eq :all (sc:confinement-read c)))
            (ok (equal (dir-keys (sc:default-deny-read)) (dir-keys (sc:confinement-deny-read c))))
            (ok (eq :none (sc:confinement-network c)) "network off")
            (ok (eq :scrub (sc:confinement-env-mode c)))
            (ok (equal (dir-key (plan-root plan)) (dir-key (recorded-launch-directory launch)))
                "it starts in the area"))
          (let ((result (first (tool-results out "bash"))))
            (ok (equal "done" (jget result "status")) "no approval needed")
            (ok (has "hi" (jget result "content"))))
          (let ((sandbox (plan-sandbox-event out)))
            (ok sandbox "the plan event says how the shell runs")
            (when sandbox
              (ok (equal "confined" (jget sandbox "status")))
              (ok (equal "recording-backend" (jget sandbox "backend")))
              (ok (equal "none" (jget sandbox "network")))
              (ok (equal (dir-keys (list (plan-root plan) (plan-scratch-directory plan)))
                         (dir-keys (coerce (jget sandbox "writable") 'list))))
              (ok (eq :null (gethash "reason" sandbox))))))))))

(deftest sandbox-cli-jobs-are-confined
  (with-project (project config) '()
    (with-plan-backend (b)
      (multiple-value-bind (exit out)
          (sandbox-run project config
                       (list (list :tool "bash" (json-args "command" "echo bg"
                                                           "run_in_background" t))
                             "ok"))
        (declare (ignore out))
        (ok (eql 0 exit))
        (ok (some (lambda (l) (has "echo bg" (launch-command l))) (command-launches b))
            "a background job is launched through the backend too")))))

(deftest-parametrize sandbox-cli-allow-network
    ((how) :ids ("flag" "user-settings")
     (:flag)
     (:settings))
  (with-project (project config) '()
    (with-plan-backend (b)
      (when (eq how :settings)
        (user-settings config "{\"sandbox\": {\"network\": \"allow\"}}"))
      (multiple-value-bind (exit out)
          (apply #'sandbox-run project config (list (bash-step "echo hi") "ok")
                 (and (eq how :flag) '("--allow-network")))
        (ok (eql 0 exit))
        (let ((launch (first (command-launches b))))
          (ok launch)
          (when launch
            (ok (eq :allow (sc:confinement-network (recorded-launch-confinement launch))))))
        (let ((sandbox (plan-sandbox-event out)))
          (ok (and sandbox (equal "allow" (jget sandbox "network")))))))))

(deftest sandbox-cli-project-settings-cannot-allow-network
  (with-project (project config) '()
    (project-settings project "{\"sandbox\": {\"network\": \"allow\"}}")
    (with-plan-backend (b)
      (sandbox-run project config (list (bash-step "echo hi") "ok"))
      (let ((launch (first (command-launches b))))
        (ok (and launch (eq :none (sc:confinement-network (recorded-launch-confinement launch)))))))))

(deftest sandbox-cli-allow-network-needs-plan-mode
  (with-project (project config) '()
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--allow-network" "go") :steps '("ok"))
      (declare (ignore out))
      (ok (eql 2 exit))
      (ok (has "--allow-network needs --permission-mode plan" err)))))

(deftest sandbox-cli-environment
  (with-project (project config) '()
    (user-settings config "{\"env\": {\"CSC_SETTINGS_VAR\": \"from-settings\"}}")
    (setf (uiop:getenv "CSC_IMAGE_SECRET") "leaked")
    (unwind-protect
         (with-plan-backend (b)
           (multiple-value-bind (exit out)
               (sandbox-run project config (list (bash-step (env-command)) "ok"))
             (ok (eql 0 exit))
             (let ((content (jget (first (tool-results out "bash")) "content")))
               (ok (has "CSC_SETTINGS_VAR=from-settings" content) "the settings env is added back")
               (ok (not (has "CSC_IMAGE_SECRET" content)) "the rest of the environment is scrubbed")
               (ok (has "XDG_CACHE_HOME=" content) "caches go to the scratch dir")
               (ok (has (string-right-trim "/\\" (native (merge-pathnames "cache/" (plan-scratch-directory
                                                                                     (only-plan project config)))))
                        content)))))
      (setf (uiop:getenv "CSC_IMAGE_SECRET") ""))))

(deftest sandbox-cli-system-prompt
  (with-project (project config) '()
    (with-plan-backend (b)
      (multiple-value-bind (exit out err backend)
          (sandbox-run project config '("ok"))
        (declare (ignore err out))
        (ok (eql 0 exit))
        (let ((system (request-system (first-request backend))))
          (ok (has (format nil "~%# Sandbox~%Sandbox: every command runs confined.") system)
              "the policy is in the system prompt")
          (ok (has "network access is off" system))
          (ok (has (physical-native (plan-root (only-plan project config))) system)
              "it names the area")
          (let ((feedback (search +plan-mode-feedback+ system))
                (section (search "# Sandbox" system)))
            (ok (and feedback section (< feedback section)) "after the plan-mode section")))))))

;;; No sandbox: plan mode asks, -p refuses the ask.

(deftest-parametrize sandbox-cli-unavailable-asks
    ((label make) :ids ("no-backend" "unavailable" "canary-fails")
     ("no backend" (lambda () nil))
     ("unavailable" (lambda () (make-recording-backend :available "test: no sandbox here")))
     ("canary fails" (lambda () (make-recording-backend :canary-exit 3))))
  (with-project (project config) '(("a.txt" "alpha"))
    (let* ((b (funcall make))
           (*plan-compute-backend* b))
      (multiple-value-bind (exit out err)
          (sandbox-run project config
                       (list (bash-step (marker-command project "ran.txt"))
                             (write-tool "a.txt" "beta")
                             "ok"))
        (ok (eql 0 exit) label)
        (let* ((plan (only-plan project config))
               (id8 (subseq (plan-id plan) 0 8))
               (bash (first (tool-results out "bash"))))
          (ok (equal "denied" (jget bash "status")) "bash asks, which -p refuses")
          (ok (has +headless-denial-feedback+ (jget bash "content")))
          (ok (not (file-exists project "ran.txt")) "nothing ran")
          (ok (has (format nil "cl-stack-code: plan ~a: no sandbox (" id8) err) "the notice on stderr")
          (ok (has "bash and job_input ask before each command" err))
          (ok (= 1 (count-substring (format nil "plan ~a: no sandbox" id8) err)) "once")
          (ok (equal "beta" (area-file plan "a.txt")) "the file tools still work in the area")
          (let ((sandbox (plan-sandbox-event out)))
            (ok (and sandbox (equal "unavailable" (jget sandbox "status"))))
            (ok (and sandbox (stringp (jget sandbox "reason")))))
          (when (typep b 'recording-backend)
            (ok (null (command-launches b)) "the backend ran no command")))))))

(defun count-substring (needle haystack)
  (loop with start = 0
        for pos = (search needle haystack :start2 start)
        while pos
        count t
        do (setf start (1+ pos))))

(deftest sandbox-cli-unavailable-text-mode-notice
  (with-project (project config) '()
    (let ((*plan-compute-backend* nil))
      (multiple-value-bind (exit out err)
          (code project config '("-p" "--permission-mode" "plan" "go") :steps '("ok"))
        (ok (eql 0 exit))
        (ok (not (has "no sandbox" out)) "stdout is the answer")
        (ok (has "no sandbox (" err))))))

(deftest sandbox-cli-unavailable-system-prompt
  (with-project (project config) '()
    (let ((*plan-compute-backend* nil))
      (multiple-value-bind (exit out err backend)
          (sandbox-run project config '("ok"))
        (declare (ignore out err))
        (ok (eql 0 exit))
        (ok (has (format nil "# Sandbox~%There is no sandbox: ~a." +no-sandbox-backend-reason+)
                 (request-system (first-request backend))))))))

(deftest sandbox-cli-unavailable-allow-rule-still-allows
  (if (not (unix-p))
      (skip "/bin/sh")
      (with-project (project config) '()
        (let ((*plan-compute-backend* nil))
          (multiple-value-bind (exit out err)
              (sandbox-run project config (list (bash-step "echo hi") "ok") "--allowed-tools" "bash")
            (ok (eql 0 exit))
            (ok (equal "done" (jget (first (tool-results out "bash")) "status"))
                "the user's explicit allow rule runs it")
            (ok (has "no sandbox (" err) "after the notice: never silently"))))))

(deftest sandbox-cli-fail-if-unavailable
  (with-project (project config) '()
    (user-settings config "{\"sandbox\": {\"failIfUnavailable\": true}}")
    (let ((*plan-compute-backend* (make-recording-backend :available "test: no sandbox here")))
      (multiple-value-bind (exit out err backend)
          (sandbox-run project config (list (bash-step "echo hi") "ok"))
        (declare (ignore out))
        (ok (eql 1 exit))
        (ok (has "sandbox.failIfUnavailable" err))
        (ok (has "test: no sandbox here" err))
        (ok (null (scripted-requests backend)) "the model was never called")))))

;;; A refusal mid-session.

(deftest sandbox-cli-refused-mid-session
  (with-project (project config) '()
    (with-plan-backend (b (make-recording-backend :refuse-marked t))
      (multiple-value-bind (exit out err)
          (sandbox-run project config
                       (list (bash-step (format nil "~a; ~a" (marker-command project "ran.txt")
                                                +refuse-marker+))
                             (bash-step (format nil "~a; ~a" (marker-command project "ran2.txt")
                                                +refuse-marker+))
                             "ok"))
        (ok (eql 0 exit))
        (let* ((plan (only-plan project config))
               (id8 (subseq (plan-id plan) 0 8))
               (results (tool-results out "bash")))
          (ok (= 2 (length results)))
          (ok (every (lambda (r) (has "the sandbox refused it (" (jget r "content"))) results)
              "the model gets PLAN-SANDBOX-REFUSAL-RESULT")
          (ok (every (lambda (r) (has "test: refused on purpose" (jget r "content"))) results))
          (ok (not (file-exists project "ran.txt")) "nothing ran")
          (ok (not (file-exists project "ran2.txt")) "the rest of the turn stays confined: refused again")
          (ok (= 1 (count-substring (format nil "plan ~a: the sandbox refused a command" id8) err))
              "the notice once, on stderr"))))))

;;; Other modes are unchanged.

(deftest-parametrize sandbox-cli-other-modes-unchanged
    ((mode) :ids ("default" "accept-edits" "bypass")
     ("default")
     ("acceptEdits")
     ("bypassPermissions"))
  (with-project (project config) '()
    (with-plan-backend (b)
      (multiple-value-bind (exit out err backend)
          (code project config (list "-p" "--output-format" "stream-json" "--permission-mode" mode
                                     "--allowed-tools" "bash" "go")
                :steps (list (bash-step "echo hi") "ok"))
        (ok (eql 0 exit))
        (ok (null (launches b)) "no confinement, no probe")
        (ok (not (has "sandbox" err)))
        (ok (null (plan-events out)))
        (ok (not (has "# Sandbox" (request-system (first-request backend)))))
        (when (unix-p)
          (ok (equal "done" (jget (first (tool-results out "bash")) "status"))))))))

;;; The image stays refused in plan mode (H5d).

(deftest sandbox-cli-lisp-image-still-refused
  (with-project (project config) '()
    (with-plan-backend (b)
      (multiple-value-bind (exit out err)
          (code project config '("-p" "--permission-mode" "plan" "--lisp-image" "spawn" "go")
                :steps '("ok"))
        (declare (ignore out))
        (ok (eql 2 exit))
        (ok (has "--lisp-image is not available in plan mode yet" err))
        (ok (null (launches b)))))))

;;; Windows: no backend yet, plan mode asks.

(deftest sandbox-cli-windows-asks
  #-(or windows win32) (skip "Windows only")
  #+(or windows win32)
  (with-project (project config) '()
    (let ((*plan-compute-backend* :default))
      (multiple-value-bind (exit out err)
          (sandbox-run project config (list (bash-step "echo hi") "ok"))
        (ok (eql 0 exit))
        (ok (has "compute-backend-mxc" err) "the notice names what is missing")
        (ok (has "bash and job_input ask before each command" err))
        (ok (equal "denied" (jget (first (tool-results out "bash")) "status")))
        (let ((sandbox (plan-sandbox-event out)))
          (ok (and sandbox (equal "unavailable" (jget sandbox "status")))))))))
