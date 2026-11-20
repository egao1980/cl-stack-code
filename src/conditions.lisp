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

;;; H3c: sessions.

(define-condition session-error (code-error)
  ((session :initarg :session :reader session-error-session :initform nil
            :documentation "The session id, or NIL."))
  (:documentation "Root of the session errors: a session directory or file
that cannot be read or written, an id that already exists. Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "session ~@[~a ~]error"
                                        (session-error-session c)))))))

(define-condition session-not-found (session-error)
  ((designator :initarg :designator :reader session-not-found-designator
               :initform nil
               :documentation "The id or prefix asked for, or NIL for
--continue."))
  (:documentation "No session (or no unique one) for an id, a prefix or
--continue in this project. Exit 2: it comes from the command line.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (if (session-not-found-designator c)
                                    (format nil "no session ~s in this project"
                                            (session-not-found-designator c))
                                    "no session to continue in this project"))))))

(define-condition session-conflict (session-error)
  ((expected :initarg :expected :reader session-conflict-expected :initform nil
             :documentation "The head revision id this process built on, or NIL
for an empty session.")
   (actual :initarg :actual :reader session-conflict-actual :initform nil
           :documentation "The head revision id on disk."))
  (:documentation "Another process moved the session's head since this one
read it (the head ref's compare-and-swap failed). Nothing was written.
COMMIT-TURN offers the restart FORK-SESSION (save the turn as a new session
cloned at EXPECTED); ABORT gives up. Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "session ~a changed in another process (head ~a, expected ~a)"
                                        (session-error-session c)
                                        (or (session-conflict-actual c) "none")
                                        (or (session-conflict-expected c) "none")))))))

(define-condition session-locked (session-error)
  ((file :initarg :file :reader session-locked-file :initform nil
         :documentation "The lock file (a pathname)."))
  (:documentation "The session's lock file stayed taken for
*SESSION-LOCK-TIMEOUT* seconds. Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "session ~a is locked by another process~@[ (~a)~]"
                                        (session-error-session c)
                                        (and (session-locked-file c)
                                             (uiop:native-namestring (session-locked-file c)))))))))

(define-condition session-turn-not-found (session-error)
  ((designator :initarg :designator :reader session-turn-not-found-designator
               :initform nil
               :documentation "The turn number, id prefix or count asked for."))
  (:documentation "/fork AT or /rewind N names no turn of the session.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "no turn ~a in this session"
                                        (session-turn-not-found-designator c)))))))

(defmethod condition-exit-code ((condition session-not-found)) 2)
