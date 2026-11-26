(in-package #:cl-stack-code/tests)

;;; R4d-4b helpers (src/sandbox.lisp header). The portable tests confine plan
;;; mode through a RECORDING-BACKEND: compute-protocol's model backend (NOT a
;;; sandbox: it runs the argv unchanged, with the scrubbed environment) that
;;; records every launch and can be told to be unavailable, to fail the
;;; canary, or to refuse the commands that name a marker.

;;; The suite's default backend. Before R4d-4b plan mode ran bash unconfined
;;; and without asking; the older suites keep that meaning on every OS (also
;;; on Windows, which has no backend, and on a Linux CI container where
;;; Landlock is unavailable) by running plan mode over the model backend. The
;;; R4d-4b tests bind *PLAN-COMPUTE-BACKEND* themselves; the hosts read it
;;; once, in the thread that makes them (see the header).

(defvar *suite-plan-backend* (sc:make-model-confinement-backend)
  "The confining backend every plan run of the suite uses unless a test binds
*PLAN-COMPUTE-BACKEND* (the model backend: runs commands unchanged).")

(setup (setf *plan-compute-backend* *suite-plan-backend*))
(teardown (setf *plan-compute-backend* :default))

(defparameter +refuse-marker+ "REFUSE-ME"
  "A command line naming this is refused by a RECORDING-BACKEND made with
:REFUSE-MARKED T.")

(defclass recording-backend (sc:model-confinement-backend)
  ((lock :initform (bt:make-lock "recording-backend") :reader rb-lock)
   (launches :initform '() :accessor rb-launches
             :documentation "One RECORDED-LAUNCH per BACKEND-CONFINE-ARGV call, oldest first.")
   (available :initarg :available :initform t :reader rb-available
              :documentation "T, or a reason string: CONFINEMENT-AVAILABLE-P is false with it.")
   (canary-exit :initarg :canary-exit :initform nil :reader rb-canary-exit
                :documentation "An integer: the canary (\"exit 0\") exits with it instead.")
   (refuse-marked :initarg :refuse-marked :initform nil :reader rb-refuse-marked
                  :documentation "True: a command line naming +REFUSE-MARKER+ is refused
(CONFINEMENT-UNAVAILABLE from BACKEND-CONFINE-ARGV) before anything runs."))
  (:documentation "A model backend recording its launches (R4d-4b tests)."))

(defstruct recorded-launch
  confinement   ; the resolved confinement CONFINE-COMMAND gave the backend
  argv          ; the argv it gave the backend
  directory     ; the start directory
  tmp)          ; the private temp directory, or NIL

(defun make-recording-backend (&rest keys &key (features sc:+confinement-features+)
                                            &allow-other-keys)
  (let ((keys (copy-list keys)))
    (remf keys :features)
    (apply #'make-instance 'recording-backend :features (copy-list features) keys)))

(defmethod sc:confinement-available-p ((b recording-backend))
  (if (eq t (rb-available b))
      (values t nil)
      (values nil (rb-available b))))

(defun canary-argv-p (argv)
  (equal "exit 0" (car (last argv))))

(defmethod sc:backend-confine-argv ((b recording-backend) confinement argv directory tmp)
  (bt:with-lock-held ((rb-lock b))
    (setf (rb-launches b)
          (append (rb-launches b)
                  (list (make-recorded-launch :confinement confinement :argv (copy-list argv)
                                              :directory directory :tmp tmp)))))
  (when (and (rb-refuse-marked b) (search +refuse-marker+ (car (last argv))))
    (error 'sc:confinement-unavailable :backend b :reason "test: refused on purpose"))
  (multiple-value-bind (out env cleanups) (call-next-method)
    (when (and (rb-canary-exit b) (canary-argv-p out))
      (setf out (append (butlast out) (list (format nil "exit ~d" (rb-canary-exit b))))))
    (values out (append env (list (cons "CL_STACK_CODE_TEST_BACKEND" "recording"))) cleanups)))

(defun launches (b)
  (bt:with-lock-held ((rb-lock b)) (copy-list (rb-launches b))))

(defun command-launches (b)
  "B's launches other than the canary."
  (remove-if (lambda (l) (canary-argv-p (recorded-launch-argv l))) (launches b)))

(defun canary-launches (b)
  (remove-if-not (lambda (l) (canary-argv-p (recorded-launch-argv l))) (launches b)))

(defun launch-command (launch)
  "The command line of LAUNCH (the last element of its argv)."
  (car (last (recorded-launch-argv launch))))

(defmacro with-plan-backend ((backend &optional (form '(make-recording-backend))) &body body)
  "BODY with BACKEND bound to FORM and *PLAN-COMPUTE-BACKEND* bound to it."
  `(let* ((,backend ,form)
          (*plan-compute-backend* ,backend))
     (declare (ignorable ,backend))
     ,@body))

;;; Paths.

(defun dir-key (x)
  "X (a directory pathname or native namestring) as the namestring of its
truename, or of X itself when it does not exist."
  (let* ((p (uiop:ensure-directory-pathname
             (if (stringp x) (uiop:parse-native-namestring x :ensure-directory t) x)))
         (true (uiop:probe-file* p :truename t)))
    (namestring (or true p))))

(defun dir-keys (xs)
  (mapcar #'dir-key xs))

(defun physical-native (dir)
  "The native namestring STACK-COMPUTE:PHYSICAL-PATH gives for DIR."
  (uiop:native-namestring (sc:physical-path dir)))

(defun temp-directory-named (prefix)
  "A fresh directory under the system temp directory, outside every test root."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "~a-~36R" prefix (random (expt 36 8) (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (truename dir)))

;;; Settings.

(defun user-settings (config json)
  "Write JSON as the user settings file of CONFIG (the user config dir)."
  (write-file config "settings.json" json))

(defun project-settings (project json)
  (write-file project ".cl-stack-code/settings.json" json))

(defun plan-settings (&rest keys)
  "Merged settings in preview mode with the flag layer's sandbox plist KEYS."
  (merge-settings (make-settings :permission-mode :preview :sandbox keys)))

;;; Runs.

(defun tool-results (out name)
  "The stream-json tool_result events of OUT for tool NAME."
  (remove-if-not (lambda (e) (equal name (jget e "name"))) (events out "tool_result")))

(defun plan-sandbox-event (out)
  "The \"sandbox\" object of OUT's plan opened / reopened event, or NIL."
  (let ((opened (or (plan-event out "opened") (plan-event out "reopened"))))
    (and opened (let ((s (gethash "sandbox" opened))) (and (hash-table-p s) s)))))

(defun marker-command (dir name)
  "A command creating file NAME in DIR (proof that it ran)."
  (let ((path (uiop:native-namestring (merge-pathnames name dir))))
    (pick (format nil "echo ran > '~a'" path)
          (format nil "echo ran> \"~a\"" path))))

(defun env-command ()
  (pick "env" "set"))
