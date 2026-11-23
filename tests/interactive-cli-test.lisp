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
                             :data-dir (data-dir-of (uiop:parse-native-namestring
                                                     config :ensure-directory t))
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

(defun %loaded-asd-table ()
  "(system name . native .asd namestring) for every system this image loaded
from an .asd: the exact file each one came from. Not the subsystems of a
package-inferred system (rove/main): ASDF makes those from their .lisp file."
  (let ((table '()))
    (dolist (name (asdf:already-loaded-systems) (nreverse table))
      (let* ((system (asdf:registered-system name))
             (file (and system (ignore-errors (asdf:system-source-file system)))))
        (when (and file
                   (or (string= name (asdf:primary-system-name name))
                       (not (typep system 'asdf:package-inferred-system))))
          (push (cons name (uiop:native-namestring file)) table))))))

(defun %pin-loaded-systems-form ()
  "A form for a child image: ASDF finds every system this image loaded at the
.asd it was loaded from, ahead of the source registry. A registry directory
can hold a stale sibling .asd of another system (compression-protocol#5: a
compression-protocol.asd 0.2.0 beside the 0.4.0 one); it never wins."
  (with-standard-io-syntax
    (format nil "(let ((table '~s)) ~a)"
            (%loaded-asd-table)
            (concatenate
             'string
             "(push (lambda (name)"
             " (let ((entry (assoc (asdf:coerce-name name) table"
             " :test (function string=))))"
             " (and entry (probe-file (uiop:parse-native-namestring (cdr entry))))))"
             " asdf:*system-definition-search-functions*)"))))

(defun %child-dynamic-space-size ()
  "This image's heap size as an SBCL --dynamic-space-size argument, so a child
that compiles the systems has the room its parent was given (#18)."
  #+sbcl (format nil "~dMB" (floor (sb-ext:dynamic-space-size) (* 1024 1024)))
  #-sbcl (error "the child images are started with SBCL only"))

(defun %child-asdf-forms ()
  "The --eval forms that give a child SBCL this image's ASDF and systems: load
ASDF, a source registry of the loaded systems' directories (for anything not
loaded here), and the exact .asd files of the loaded ones, which come first."
  (list (%asdf-load-form)
        (format nil "(uiop:symbol-call :asdf :initialize-source-registry '~s)"
                (%registry-form))
        (%pin-loaded-systems-form)))

(defun pty-child-argv (report project config)
  #-sbcl (declare (ignore report project config))
  #-sbcl (error "the pty smoke test starts its child with SBCL only")
  #+sbcl
  (append
   (list (uiop:native-namestring sb-ext:*runtime-pathname*)
         "--core" (uiop:native-namestring sb-ext:*core-pathname*) "--noinform"
         "--dynamic-space-size" (%child-dynamic-space-size)
         "--non-interactive" "--no-sysinit" "--no-userinit")
   (loop for form in (append (%child-asdf-forms)
                           (list "(uiop:symbol-call :asdf :load-system \"cl-stack-code/tests\")"
                                 (format nil "(uiop:symbol-call :cl-stack-code/tests :pty-child-main ~s ~s ~s)"
                                         report (native project) (native config))))
         append (list "--eval" form))))

(deftest child-finds-the-loaded-asd-files
  ;; The pin form a child evaluates: every loaded system resolves to the .asd
  ;; this image loaded it from, whatever the registry directories hold.
  (let ((asdf:*system-definition-search-functions*
          (copy-list asdf:*system-definition-search-functions*)))
    (let ((*package* (find-package :cl-user)))
      (eval (read-from-string (%pin-loaded-systems-form))))
    (let ((search (first asdf:*system-definition-search-functions*)))
      (dolist (name '("cl-stack-code" "cl-stack-code/tests"))
        (ok (uiop:pathname-equal (truename (asdf:system-source-file name)) (funcall search name))
            name))
      (ok (null (funcall search "no-such-system-anywhere"))))))

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
