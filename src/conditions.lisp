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

(define-condition session-lock-error (session-error)
  ((file :initarg :file :reader session-lock-error-file :initform nil
         :documentation "The lock file (a pathname).")
   (operation :initarg :operation :reader session-lock-error-operation
              :initform :read
              :documentation ":READ or :DELETE.")
   (cause :initarg :cause :reader session-lock-error-cause :initform nil
          :documentation "The file or stream error underneath."))
  (:documentation "The session's lock file exists but cannot be read or
removed (permission denied, not a lock file). A lock file that vanishes
between the probe and the read is not an error: another process released or
broke it. While waiting for the lock the restart BREAK-LOCK (remove the lock
file and take it) is offered for an unreadable lock: safe only when no other
process holds it. Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "session ~@[~a ~]lock file ~a cannot be ~:[read~;removed~]: ~a"
                                        (session-error-session c)
                                        (and (session-lock-error-file c)
                                             (uiop:native-namestring (session-lock-error-file c)))
                                        (eq :delete (session-lock-error-operation c))
                                        (session-lock-error-cause c)))))))

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

;;; H5a: plans (src/plans.lisp).

(define-condition plan-error (code-error)
  ((plan :initarg :plan :reader plan-error-plan :initform nil
         :documentation "The PLAN, or NIL."))
  (:documentation "Root of the plan errors: a plan that cannot be opened,
read or written, or an operation on a plan that is no longer open. Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c) "plan error")))))

(define-condition plan-not-found (plan-error)
  ((designator :initarg :designator :reader plan-not-found-designator :initform nil
               :documentation "The plan id asked for."))
  (:documentation "REOPEN-PLAN: no plan with that id under the plans
directory, the plan is no longer :OPEN, or its area directory is gone. Exit 2
(it comes from the command line).")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "no open plan ~a" (plan-not-found-designator c)))))))

(define-condition plan-drift (plan-error)
  ((paths :initarg :paths :reader plan-drift-paths :initform '()
          :documentation "Relative POSIX paths (sorted, string<) that changed
both in the area and in the working copy since the plan's base, to different
results."))
  (:documentation "APPROVE-PLAN: the working copy changed since the plan's
base at paths the plan changed too. Signalled once, with every such path,
before anything is written. Restarts REBASE-PLAN (merge the working copy
into the area and make it the new base; nothing is applied), OVERWRITE-PLAN
(apply, the plan's version wins at PATHS) and ABORT-APPROVAL (write nothing;
the plan stays open). Unhandled, nothing is written and the plan stays open.
Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "the working copy changed since plan ~a was opened: ~{~a~^, ~}"
                                        (let ((p (plan-error-plan c)))
                                          (if p (plan-id p) "?"))
                                        (plan-drift-paths c)))))))

(defmethod condition-exit-code ((condition plan-not-found)) 2)
