(in-package #:cl-stack-code)

;;; H3d: cl-stack-code --rpc, JSON-RPC 2.0 over stdin / stdout
;;; (rpc-protocol-json's codec, rpc-backend-stdio's transport: one JSON value
;;; per line). A thin adapter over src/client.lisp: each method is one client
;;; function, and the client's events are the server's notifications.
;;;
;;; Entry
;;;   cl-stack-code --rpc [--cwd DIR] [--model M] [--permission-mode MODE]
;;;                 [--allowed-tools …] [--disallowed-tools …] [--max-turns N]
;;;                 [--append-system-prompt T] [--lisp-image …] [--plan-area K]
;;;   RUN-CLI → %RUN-RPC: CHECK-RPC-FLAGS (exit 2), %RESOLVE-CWD (exit 2), then
;;;   SERVE-RPC on a STDIO-RPC-TRANSPORT over RUN-CLI's INPUT and OUTPUT, with
;;;   the client made from the invocation (CWD, the flag layer
;;;   INVOCATION-SETTINGS, PLAN-AREA from --plan-area, and RUN-CLI's
;;;   PROVIDERS, USER-CONFIG-DIR, DATA-DIR, GETENV). Only JSON-RPC goes to
;;;   OUTPUT; nothing goes to ERROR-OUTPUT while serving. When INPUT ends,
;;;   the client is closed (running turns are interrupted and committed) and
;;;   the exit code is 0.
;;;   SERVE-RPC transport &rest client-args → 0: MAKE-CLIENT with CLIENT-ARGS,
;;;   :ON-EVENT sending each event as a notification on TRANSPORT,
;;;   :ON-APPROVAL NIL (approvals wait for approval/respond); RPC-SERVE with
;;;   MAKE-RPC-HANDLER until EOF; CLOSE-CLIENT (UNWIND-PROTECT).
;;;   Requests are handled one at a time on the reading thread; none blocks
;;;   on a turn (turn/start returns once the turn has started).
;;;
;;; Notifications
;;;   Method +RPC-EVENT-METHOD+ ("event"); params = the event object, as is
;;;   (its "session_id" says which session). Sent from the client's loop
;;;   thread through RPC-NOTIFY (rpc-backend-stdio writes each line whole).
;;;   They can arrive before the response of the request that caused them
;;;   (session/new's init, a turn's first events): order by the stream of
;;;   events, not by responses.
;;;
;;; Methods (+RPC-METHODS+). params is an object (absent = {}); unknown keys
;;; are ignored; a missing or mistyped key → -32602 (RPC-INVALID-PARAMS) with
;;; the message "METHOD: KEY must be …". Every key is snake_case. Session
;;; methods take "session_id", the exact id of a session open in this
;;; server (else -32002 SESSION-NOT-OPEN).
;;;   initialize       {}                         → {"name":"cl-stack-code","version","protocol"
;;;                                                  (+RPC-PROTOCOL-VERSION+),"methods","events"
;;;                                                  (+EVENT-TYPES+)}. Optional: any method works first.
;;;   session/new      {cwd?, model?, permission_mode? (a mode name: "default"
;;;                    "acceptEdits" "bypassPermissions" "plan"), session_id?}
;;;                                               → the init object (CLIENT-NEW-SESSION)
;;;   session/resume   {session_id (id, prefix or UUID) | last: true, cwd?,
;;;                    model?, permission_mode?, fork?, new_session_id?}
;;;                                               → the init object (CLIENT-RESUME-SESSION;
;;;                                                  new_session_id is :SESSION-ID with fork)
;;;   session/list     {cwd?}                     → {"sessions": [CLIENT-LIST-SESSIONS objects]}
;;;   session/fork     {session_id, at? (integer or string), new_session_id?}
;;;                                               → the new session's init object
;;;   session/close    {session_id}               → {"closed": true}
;;;   turn/start       {session_id, prompt, mentions? [strings]}
;;;                                               → {"session_id"} once the turn runs
;;;   turn/steer       {session_id, text}         → {"posted": true}
;;;   turn/interrupt   {session_id}               → {"interrupted": true|false}
;;;   approval/respond {session_id, id, decision ("once" "always" "reject"
;;;                    "reject_all"), feedback?}  → {"resolved": [ids]}
;;;   plan/approve     {session_id, on_drift? ("abort" "rebase" "overwrite")}
;;;                                               → the plan object
;;;   plan/reject      {session_id}               → the plan object
;;;   checkpoint/list  {session_id}               → {"checkpoints": [objects]}
;;;   rewind           {session_id, turn (integer or string), mode? ("both"
;;;                    "conversation" "files"), on_drift?}
;;;                                               → the rewind object
;;;   settings/get     {session_id? | cwd?}       → CLIENT-SETTINGS of the session, else of cwd
;;;                                                  (relative to the server's), else the server's
;;;   tools/list       {session_id}               → {"tools": [objects]}
;;;   Any other method → -32601.
;;;
;;; Errors (RPC-ERROR-FOR condition → (values code message data))
;;;   The first entry of +RPC-ERROR-CODES+ whose type the condition is of
;;;   gives the code; an RPC-PROTOCOL:RPC-ERROR keeps its own code and data.
;;;   message = the condition's text (PRINC). data = {"condition": the type
;;;   name, lower case} plus, per condition:
;;;     session-not-found        "designator"
;;;     session-not-open         "session_id"
;;;     turn-busy, turn-not-running "session_id"
;;;     approval-not-found       "id"
;;;     session-conflict         "expected", "actual" (revision ids or null)
;;;     session-turn-not-found   "designator"
;;;     plan-error and subtypes  "plan_id" (or null)
;;;     checkpoint-not-found     "designator"
;;;     settings-error           "file" (native namestring or null), "key" (or null)
;;;     model-not-found          "designator"
;;;   MAKE-RPC-HANDLER client → (lambda (method params)) for RPC-SERVE: the
;;;   method's result object, or an RPC-PROTOCOL:RPC-ERROR made from
;;;   RPC-ERROR-FOR (any ERROR inside a method).
;;;
;;; The subprocess client (optional SDK half): drive a cl-stack-code --rpc
;;; process, or any transport whose peer is SERVE-RPC.
;;;   CONNECT-RPC-CLIENT &key COMMAND TRANSPORT ON-EVENT (ERROR-OUTPUT
;;;   :INTERACTIVE) → an RPC-CLIENT. COMMAND: an argv (rpc-backend-stdio
;;;   :COMMAND, launched at once); TRANSPORT: a client STDIO-RPC-TRANSPORT
;;;   (e.g. MAKE-STDIO-RPC-PAIR's second value; its ON-NOTIFICATION is set
;;;   here). Exactly one of the two. Each "event" notification is recorded
;;;   and passed to ON-EVENT (lambda (event)) on the reader thread.
;;;   RPC-CLIENT-CALL client method params &key (TIMEOUT 60) → the
;;;   result; an error response → RPC-PROTOCOL:RPC-ERROR (code, message,
;;;   data); PARAMS a hash table or NIL.
;;;   RPC-CLIENT-EVENTS client &key TYPE SESSION-ID → the events received so
;;;   far, oldest first, optionally only those of TYPE / SESSION-ID.
;;;   RPC-CLIENT-WAIT-EVENT client predicate &key (TIMEOUT 30) → the first
;;;   recorded event (already there or still to come) for which PREDICATE is
;;;   true, or NIL after TIMEOUT seconds.
;;;   RPC-CLIENT-PROCESS client → the child's process handle, or NIL.
;;;   CLOSE-RPC-CLIENT client &key (TIMEOUT 10) → the child's exit code after
;;;   CLOSE-STDIO-RPC-TRANSPORT (its stdin closed first, so the server sees
;;;   EOF and exits 0), or NIL for a TRANSPORT client. Idempotent.

(defparameter +rpc-protocol-version+ 1
  "The --rpc protocol's version (initialize's \"protocol\").")

(defparameter +rpc-event-method+ "event"
  "The method of every server → client notification.")

(defparameter +rpc-methods+
  '("initialize"
    "session/new" "session/resume" "session/list" "session/fork" "session/close"
    "turn/start" "turn/steer" "turn/interrupt"
    "approval/respond"
    "plan/approve" "plan/reject"
    "checkpoint/list" "rewind"
    "settings/get" "tools/list")
  "Every --rpc method, in this order (initialize's \"methods\").")

(defparameter +rpc-error-codes+
  '((session-not-found . -32001)
    (session-not-open . -32002)
    (turn-busy . -32003)
    (turn-not-running . -32004)
    (approval-not-found . -32005)
    (session-conflict . -32006)
    (session-turn-not-found . -32007)
    (plan-error . -32008)
    (checkpoint-error . -32009)
    (settings-error . -32010)
    (model-not-found . -32011)
    (lisp-image-error . -32012)
    (session-locked . -32013)
    (client-closed . -32014)
    (code-usage-error . -32602)
    (code-error . -32000)
    (error . -32603))
  "Condition type → JSON-RPC error code; the first type that matches wins.
RPC-PROTOCOL:RPC-ERROR (checked before the table) keeps its own code.")

(defclass rpc-client ()
  ((transport :initarg :transport :reader %rpc-client-transport)
   (owns-process :initarg :owns-process :initform nil :reader %rpc-client-owns-process)
   (on-event :initarg :on-event :initform nil :reader %rpc-client-on-event)
   (lock :initform (bt:make-lock "rpc-client") :reader %rpc-client-lock)
   (events :initform '() :accessor %rpc-client-events :documentation "Newest first.")
   (closed :initform nil :accessor %rpc-client-closed))
  (:documentation "A JSON-RPC client of a cl-stack-code --rpc server."))

;;; The error table.

(defun %null (value)
  (if (null value) :null value))

(defun %condition-fields (condition)
  "The per-condition keys and values of the error data (see the header)."
  (typecase condition
    (session-not-found (list "designator" (%null (session-not-found-designator condition))))
    (session-not-open (list "session_id" (%null (session-not-open-id condition))))
    (turn-busy (list "session_id" (%null (turn-busy-session-id condition))))
    (turn-not-running (list "session_id" (%null (turn-not-running-session-id condition))))
    (approval-not-found (list "id" (%null (approval-not-found-id condition))))
    (session-conflict (list "expected" (%null (session-conflict-expected condition))
                            "actual" (%null (session-conflict-actual condition))))
    (session-turn-not-found
     (list "designator" (%null (session-turn-not-found-designator condition))))
    (plan-error (list "plan_id" (let ((plan (plan-error-plan condition)))
                                  (if plan (plan-id plan) :null))))
    (checkpoint-not-found
     (list "designator" (%null (checkpoint-not-found-designator condition))))
    (settings-error (list "file" (let ((file (settings-error-file condition)))
                                   (if file (uiop:native-namestring file) :null))
                          "key" (%null (settings-error-key condition))))
    (model-not-found (list "designator" (%null (model-not-found-designator condition))))
    (t '())))

(defun rpc-error-for (condition)
  (if (typep condition 'rpc-protocol:rpc-error)
      (values (rpc-protocol:rpc-error-code condition)
              (or (rpc-protocol:rpc-error-message condition) (princ-to-string condition))
              (rpc-protocol:rpc-error-data condition))
      (values (cdr (find-if (lambda (row) (typep condition (car row))) +rpc-error-codes+))
              (princ-to-string condition)
              (apply #'%json-object
                     "condition" (string-downcase (symbol-name (type-of condition)))
                     (%condition-fields condition)))))

;;; Params.

(defun %type-phrase (type)
  (if (consp type)
      (format nil "one of ~{~s~^, ~}" (rest type))
      (ecase type
        (:string "a string")
        (:integer "an integer")
        (:boolean "a boolean")
        (:object "an object")
        (:strings "an array of strings")
        (:turn "an integer or a string"))))

(defun %bad-param (method key type)
  (error 'rpc-protocol:rpc-invalid-params
         :message (format nil "~a: ~a must be ~a" method key (%type-phrase type))))

(defun %type-p (value type)
  (if (consp type)
      (and (stringp value) (member value (rest type) :test #'string=) t)
      (ecase type
        (:string (stringp value))
        (:integer (integerp value))
        (:boolean (member value '(t nil)))
        (:object (hash-table-p value))
        (:strings (and (vectorp value) (not (stringp value)) (every #'stringp value)))
        (:turn (or (integerp value) (stringp value))))))

(defun %param (method params key type &key required)
  "PARAMS's KEY checked against TYPE: absent or null → NIL (or, REQUIRED, an
RPC-INVALID-PARAMS); a mistyped value → RPC-INVALID-PARAMS."
  (multiple-value-bind (value found) (gethash key params)
    (cond ((or (not found) (eq value :null)
               ;; false only answers a boolean
               (and (null value) (not (eq type :boolean))))
           (when required (%bad-param method key type))
           nil)
          ((%type-p value type) value)
          (t (%bad-param method key type)))))

(defun %params-object (method params)
  (cond ((hash-table-p params) params)
        ((or (null params) (and (vectorp params) (zerop (length params))))
         (make-hash-table :test 'equal))
        (t (%bad-param method "params" :object))))

(defparameter +rpc-mode-names+ '("default" "acceptEdits" "bypassPermissions" "plan"))
(defparameter +rpc-drift-names+ '("abort" "rebase" "overwrite"))
(defparameter +rpc-rewind-mode-names+ '("both" "conversation" "files"))

(defun %keyword (string)
  (and string (intern (string-upcase string) :keyword)))

(defun %session-param (client method params)
  (let ((id (%param method params "session_id" :string :required t)))
    (or (client-find-session client id)
        (error 'session-not-open :id id))))

(defun %mode-param (method params)
  (let ((name (%param method params "permission_mode" (cons :member +rpc-mode-names+))))
    (and name (parse-permission-mode name))))

;;; Methods.

(defparameter *%rpc-methods*
  (list
   (cons "initialize"
         (lambda (client method params)
           (declare (ignore client method params))
           (%json-object "name" "cl-stack-code"
                         "version" +version+
                         "protocol" +rpc-protocol-version+
                         "methods" (coerce +rpc-methods+ 'vector)
                         "events" (coerce +event-types+ 'vector))))
   (cons "session/new"
         (lambda (client method params)
           (code-session-init
            (client-new-session client
                                :cwd (%param method params "cwd" :string)
                                :model (%param method params "model" :string)
                                :permission-mode (%mode-param method params)
                                :session-id (%param method params "session_id" :string)))))
   (cons "session/resume"
         (lambda (client method params)
           (let* ((last (%param method params "last" :boolean))
                  (id (%param method params "session_id" :string :required (not last))))
             (code-session-init
              (client-resume-session client (if last :last id)
                                     :cwd (%param method params "cwd" :string)
                                     :model (%param method params "model" :string)
                                     :permission-mode (%mode-param method params)
                                     :fork (%param method params "fork" :boolean)
                                     :session-id (%param method params "new_session_id" :string))))))
   (cons "session/list"
         (lambda (client method params)
           (%json-object "sessions"
                         (coerce (client-list-sessions client
                                                       :cwd (%param method params "cwd" :string))
                                 'vector))))
   (cons "session/fork"
         (lambda (client method params)
           (let ((at (%param method params "at" :turn))
                 (new-id (%param method params "new_session_id" :string)))
             (code-session-init
              (client-fork-session (%session-param client method params)
                                   :at at :session-id new-id)))))
   (cons "session/close"
         (lambda (client method params)
           (client-close-session (%session-param client method params))
           (%json-object "closed" t)))
   (cons "turn/start"
         (lambda (client method params)
           (let* ((prompt (%param method params "prompt" :string :required t))
                  (mentions (%param method params "mentions" :strings))
                  (session (%session-param client method params)))
             (client-turn session prompt :mentions (coerce mentions 'list))
             (%json-object "session_id" (code-session-id session)))))
   (cons "turn/steer"
         (lambda (client method params)
           (let ((text (%param method params "text" :string :required t)))
             (client-steer (%session-param client method params) text)
             (%json-object "posted" t))))
   (cons "turn/interrupt"
         (lambda (client method params)
           (%json-object "interrupted"
                         (and (client-interrupt (%session-param client method params)) t))))
   (cons "approval/respond"
         (lambda (client method params)
           (let* ((id (%param method params "id" :string :required t))
                  (decision (%param method params "decision"
                                    (cons :member (mapcar #'car +approval-decision-names+))
                                    :required t))
                  (feedback (%param method params "feedback" :string))
                  (session (%session-param client method params)))
             (%json-object "resolved"
                           (coerce (client-respond-approval
                                    session id
                                    (cdr (assoc decision +approval-decision-names+
                                                :test #'string=))
                                    :feedback feedback)
                                   'vector)))))
   (cons "plan/approve"
         (lambda (client method params)
           (let ((on-drift (%param method params "on_drift" (cons :member +rpc-drift-names+))))
             (client-approve-plan (%session-param client method params)
                                  :on-drift (or (%keyword on-drift) :abort)))))
   (cons "plan/reject"
         (lambda (client method params)
           (client-reject-plan (%session-param client method params))))
   (cons "checkpoint/list"
         (lambda (client method params)
           (%json-object "checkpoints"
                         (coerce (client-checkpoints (%session-param client method params))
                                 'vector))))
   (cons "rewind"
         (lambda (client method params)
           (let ((turn (%param method params "turn" :turn :required t))
                 (mode (%param method params "mode" (cons :member +rpc-rewind-mode-names+)))
                 (on-drift (%param method params "on_drift" (cons :member +rpc-drift-names+))))
             (client-rewind (%session-param client method params) turn
                            :mode (or (%keyword mode) :both)
                            :on-drift (or (%keyword on-drift) :abort)))))
   (cons "settings/get"
         (lambda (client method params)
           (let ((id (%param method params "session_id" :string))
                 (cwd (%param method params "cwd" :string)))
             (cond (id (client-settings (%session-param client method params)))
                   (cwd (%client-settings-at client cwd))
                   (t (client-settings client))))))
   (cons "tools/list"
         (lambda (client method params)
           (%json-object "tools"
                         (coerce (client-tools (%session-param client method params))
                                 'vector)))))
  "Method name → (lambda (client method params)) → the result object.")

(defun make-rpc-handler (client)
  (lambda (method params)
    (let ((fn (cdr (assoc method *%rpc-methods* :test #'equal))))
      (unless fn
        (error 'rpc-protocol:rpc-method-not-found
               :message (format nil "Method not found: ~a" method)))
      (handler-case (funcall fn client method (%params-object method params))
        (rpc-protocol:rpc-error (e) (error e))
        (error (e)
          (multiple-value-bind (code message data) (rpc-error-for e)
            (error 'rpc-protocol:rpc-error :code code :message message :data data)))))))

;;; The server.

(defun serve-rpc (transport &rest client-args)
  (let ((client (apply #'make-client
                       :on-event (lambda (session event)
                                   (declare (ignore session))
                                   (rpc-protocol:rpc-notify +rpc-event-method+ event
                                                            :transport transport))
                       :on-approval nil
                       client-args)))
    (unwind-protect
         (rpc-protocol:rpc-serve (make-rpc-handler client) :transport transport)
      (close-client client))
    0))

(defun %run-rpc (inv &key output input error-output providers user-config-dir getenv data-dir)
  (declare (ignore error-output))
  (check-rpc-flags inv)
  (let ((cwd (%resolve-cwd (invocation-cwd inv))))
    (serve-rpc (rpc-backend-stdio:make-stdio-rpc-transport :input input :output output)
               :cwd cwd
               :settings (invocation-settings inv)
               :plan-area (or (invocation-plan-area inv) :auto)
               :providers providers
               :user-config-dir user-config-dir
               :data-dir data-dir
               :getenv (or getenv #'uiop:getenv))))

;;; The subprocess client.

(defun connect-rpc-client (&key command transport on-event (error-output :interactive))
  (unless (if command (null transport) transport)
    (error 'code-usage-error
           :message "CONNECT-RPC-CLIENT needs exactly one of :COMMAND and :TRANSPORT"))
  (let* ((tx (or transport
                 (rpc-backend-stdio:make-stdio-rpc-transport :command command
                                                             :error-output error-output)))
         (client (make-instance 'rpc-client :transport tx
                                            :owns-process (and command t)
                                            :on-event on-event)))
    (setf (rpc-backend-stdio:stdio-rpc-transport-on-notification tx)
          (lambda (method params)
            (when (equal method +rpc-event-method+)
              (bt:with-lock-held ((%rpc-client-lock client))
                (push params (%rpc-client-events client)))
              (when on-event
                (handler-case (funcall on-event params)
                  (error () nil))))))
    client))

(defun rpc-client-call (client method params &key (timeout 60))
  (rpc-protocol:rpc-call method (or params (make-hash-table :test 'equal))
                         :timeout timeout :transport (%rpc-client-transport client)))

(defun rpc-client-events (client &key type session-id)
  (remove-if-not (lambda (e)
                   (and (or (null type) (equal type (event-type e)))
                        (or (null session-id) (equal session-id (event-value e "session_id")))))
                 (bt:with-lock-held ((%rpc-client-lock client))
                   (reverse (%rpc-client-events client)))))

(defun rpc-client-wait-event (client predicate &key (timeout 30))
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout internal-time-units-per-second)))))
    (loop
      (let ((hit (find-if predicate (rpc-client-events client))))
        (when hit (return hit)))
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (sleep 0.02))))

(defun rpc-client-process (client)
  (rpc-backend-stdio:stdio-rpc-transport-process (%rpc-client-transport client)))

(defun close-rpc-client (client &key (timeout 10))
  (let ((tx (%rpc-client-transport client)))
    (unless (%rpc-client-closed client)
      (rpc-backend-stdio:close-stdio-rpc-transport tx :timeout timeout)
      (setf (%rpc-client-closed client)
            (list (let ((process (rpc-backend-stdio:stdio-rpc-transport-process tx)))
                    (and (%rpc-client-owns-process client) process
                         (process-protocol:exit-code process))))))
    (first (%rpc-client-closed client))))
