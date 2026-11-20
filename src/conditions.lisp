(in-package #:cl-stack-code)

;;; Conditions (CLHS 9). RUN-CLI handles every ERROR and returns
;;; CONDITION-EXIT-CODE: 2 for usage and configuration errors, 1 otherwise.

(define-condition code-error (error)
  ((message :initarg :message :reader code-error-message :initform nil))
  (:documentation "Root of cl-stack-code's errors.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c) "cl-stack-code error")))))

(define-condition code-usage-error (code-error) ()
  (:documentation "The command line is wrong: bad or unknown flags, no -p, no
prompt, a --cwd that is not a directory. Exit 2."))

(define-condition permission-rule-error (code-usage-error)
  ((text :initarg :text :reader permission-rule-error-text :initform nil
         :documentation "The rule as given (a string, or the JSON object)."))
  (:documentation "A permission rule string or object does not parse.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "bad permission rule ~s"
                                        (permission-rule-error-text c)))))))

(define-condition settings-error (code-error)
  ((file :initarg :file :reader settings-error-file :initform nil
         :documentation "The settings file (a pathname), or NIL for a string.")
   (key :initarg :key :reader settings-error-key :initform nil
        :documentation "Key path of the bad value (\"maxTurns\",
\"permissions.allow[1]\", \"env.FOO\"), or NIL when the file is not JSON or
not an object."))
  (:documentation "A settings file is not JSON, not an object, or holds a
value of the wrong type. Restarts: CONTINUE (skip the file), USE-VALUE (a
SETTINGS to use instead). Exit 2.")
  (:report (lambda (c s)
             (format s "~@[~a: ~]~@[~a: ~]~a"
                     (and (settings-error-file c)
                          (uiop:native-namestring (settings-error-file c)))
                     (settings-error-key c)
                     (or (code-error-message c) "invalid settings")))))

(define-condition model-not-found (code-error)
  ((designator :initarg :designator :reader model-not-found-designator
               :initform nil))
  (:documentation "No provider for the model designator. Restart USE-VALUE
(an LLM-BACKEND). Exit 2.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "unknown provider in model ~s"
                                        (model-not-found-designator c)))))))

(define-condition run-failed (code-error)
  ((cause :initarg :cause :reader run-failed-cause :initform nil))
  (:documentation "The agent run signalled; CAUSE is the condition. Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (and (run-failed-cause c)
                                     (princ-to-string (run-failed-cause c)))
                                "the run failed")))))

(defgeneric condition-exit-code (condition)
  (:documentation "Process exit code for CONDITION when it ends RUN-CLI.")
  (:method ((condition condition)) 1)
  (:method ((condition code-usage-error)) 2)
  (:method ((condition settings-error)) 2)
  (:method ((condition model-not-found)) 2))
