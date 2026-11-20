(in-package #:cl-stack-code/tests)

;;; RUN-CLI without -p (src/program.lisp header, last paragraph), and one
;;; smoke test of the real thing: a child Lisp running RUN-CLI on a pty from
;;; pty-protocol, the screen read back through the pure-Lisp emulator. The pty
;;; test is Unix only (Windows: SKIP), as tui-backend-tty's crash test is.

(deftest interactive-needs-a-terminal
  (with-project (project config) '()
    (dolist (argv '(() ("fix" "it")))
      (multiple-value-bind (exit out err backend) (code project config argv :steps '("x"))
        (ok (eql 2 exit) argv)
        (ok (equal "" out))
        (ok (has "terminal" err) err)
        (ok (has "-p" err) err)
        (ok (null (scripted-requests backend)))))))

(deftest interactive-output-format-needs-print
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("--output-format" "json" "hi"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "--output-format" err) err))))

(deftest interactive-configuration-errors-come-first
  (with-project (project config) '((".cl-stack-code/settings.json" "[1]"))
    (multiple-value-bind (exit out err) (code project config '())
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "settings.json" err) "the settings error, not the terminal one"))))

;;; The pty smoke test.

(defun windows-p () (uiop:os-windows-p))

(defun %stty-g ()
  (string-trim '(#\Space #\Newline #\Return)
               (uiop:run-program '("stty" "-g") :input :interactive :output :string
                                                :error-output nil :ignore-error-status t)))

(defun %report (path &rest form)
  (with-open-file (s path :direction :output :if-exists :append :if-does-not-exist :create
                          :external-format :utf-8)
    (with-standard-io-syntax
      (let ((*package* (find-package :keyword)))
        (prin1 form s)
        (terpri s)))))

(defun pty-child-main (report project config)
  "Run in the child on the pty: the interactive RUN-CLI on the real terminal."
  (let ((backend (make-scripted-backend '("Hello from the pty"))))
    (%report report :before (%stty-g))
    (let ((code (handler-case
                    (run-cli (list "--cwd" project "--model" "mock")
                             :providers (list (cons "mock" (scripted-provider backend)))
                             :user-config-dir (uiop:parse-native-namestring config
                                                                            :ensure-directory t)
                             :getenv (env-lookup))
                  (error (c) (%report report :error (princ-to-string c)) -1))))
      (%report report :exit code (length (scripted-requests backend)) (%stty-g)))))

(defun %asdf-load-form ()
  #+sbcl
  (let* ((home-fn (find-symbol "SBCL-HOMEDIR-PATHNAME" "SB-INT"))
         (home (and home-fn (ignore-errors (funcall home-fn))))
         (fasl (and home (probe-file (merge-pathnames "contrib/asdf.fasl" home)))))
    (if fasl (format nil "(load ~s)" (uiop:native-namestring fasl)) "(require :asdf)"))
  #-sbcl "(require :asdf)")

(defun %registry-form ()
  (let ((dirs '()))
    (dolist (name (asdf:already-loaded-systems))
      (let ((dir (ignore-errors (asdf:system-source-directory name))))
        (when dir (pushnew (uiop:native-namestring dir) dirs :test #'string=))))
    `(:source-registry ,@(mapcar (lambda (d) (list :directory d)) dirs)
                       :ignore-inherited-configuration)))

(defun pty-child-argv (report project config)
  #-sbcl (declare (ignore report project config))
  #-sbcl (error "the pty smoke test starts its child with SBCL only")
  #+sbcl
  (append
   (list (uiop:native-namestring sb-ext:*runtime-pathname*)
         "--core" (uiop:native-namestring sb-ext:*core-pathname*) "--noinform"
         "--non-interactive" "--no-sysinit" "--no-userinit")
   (loop for form in (list (%asdf-load-form)
                           (format nil "(uiop:symbol-call :asdf :initialize-source-registry '~s)"
                                   (%registry-form))
                           "(uiop:symbol-call :asdf :load-system \"cl-stack-code/tests\")"
                           (format nil "(uiop:symbol-call :cl-stack-code/tests :pty-child-main ~s ~s ~s)"
                                   report (native project) (native config)))
         append (list "--eval" form))))

(defun read-forms (path)
  (when (probe-file path)
    (with-open-file (s path :external-format :utf-8)
      (let ((*read-eval* nil) (*package* (find-package :keyword)))
        (loop for form = (handler-case (read s nil s) (error () s))
              until (eq form s) collect form)))))

(defun pty-screen-text (term)
  (format nil "~{~a~^~%~}" (getf (tp:terminal-snapshot term :cells nil) :lines)))

(defun pty-wait (pty term needle timeout)
  "Feed the pty's output to TERM until NEEDLE is on its screen. → T or NIL."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (when (search needle (pty-screen-text term)) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (let ((chunk (pp:pty-read pty :timeout 0.1)))
        (cond ((null chunk) (return (and (search needle (pty-screen-text term)) t)))
              ((plusp (length chunk)) (tp:terminal-feed term chunk)))))))

(defun pty-drain-until-exit (pty term timeout)
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((chunk (pp:pty-read pty :timeout 0.1)))
        (when (and chunk (plusp (length chunk))) (tp:terminal-feed term chunk))
        (multiple-value-bind (code signal) (pp:pty-wait pty :timeout 0.05)
          (when (or code signal) (return code)))
        (when (or (null chunk) (> (get-internal-real-time) deadline)) (return nil))))))

(defun octets (string)
  (map '(vector (unsigned-byte 8)) #'char-code string))

(defun pty-type (pty string)
  "Write STRING to the child's terminal. A child that already exited drops
the write, so the test reports its assertions."
  (handler-bind ((pp:pty-io-error #'continue))
    (pp:pty-write pty (octets string))))

(deftest pty-interactive-smoke
  (when (windows-p) (skip "the pty smoke test runs on Unix"))
  (unless (windows-p)
    (with-project (project config) '()
      (let* ((report (uiop:native-namestring
                      (merge-pathnames (format nil "cl-stack-code-pty-~36r.sexp"
                                               (random (expt 36 8) (make-random-state t)))
                                       (uiop:temporary-directory))))
             (pty (pp:spawn-pty (pty-child-argv report project config) :cols 100 :rows 30))
             (term (tp:make-terminal :cols 100 :rows 30 :backend (emulator))))
        (unwind-protect
             (progn
               (ok (pty-wait pty term "Message, @file" 300)
                   (format nil "the first frame (the child may compile):~%~a" (pty-screen-text term)))
               (ok (search " mock · default · " (pty-screen-text term)) "the status line")
               (pty-type pty (format nil "hi~c" #\Return))
               (ok (pty-wait pty term "Hello from the pty" 60) "a turn on the mock model")
               (pty-type pty (string (code-char 3)))   ; Ctrl-C, empty input: quit
               (pty-drain-until-exit pty term 60)
               (let* ((forms (read-forms report))
                      (before (second (assoc :before forms)))
                      (exit (assoc :exit forms)))
                 (ok (null (assoc :error forms)) (format nil "~s" forms))
                 (ok (eql 0 (second exit)) (format nil "run-cli returned 0: ~s" exit))
                 (ok (eql 1 (third exit)) "one request")
                 (ok (and before (plusp (length before)) (equal before (fourth exit)))
                     (format nil "the terminal is restored: ~s vs ~s" before (fourth exit)))))
          (ignore-errors (pp:pty-close pty))
          (ignore-errors (tp:terminal-close term))
          (uiop:delete-file-if-exists report))))))
