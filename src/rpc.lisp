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

;;; Stubs.

(defun rpc-error-for (condition)
  (declare (ignore condition))
  (%not-implemented 'rpc-error-for))

(defun make-rpc-handler (client)
  (declare (ignore client))
  (%not-implemented 'make-rpc-handler))

(defun serve-rpc (transport &rest client-args)
  (declare (ignore transport client-args))
  (%not-implemented 'serve-rpc))

(defun %run-rpc (inv &key output input error-output providers user-config-dir getenv data-dir)
  (declare (ignore inv output input error-output providers user-config-dir getenv data-dir))
  (%not-implemented '%run-rpc))

(defun connect-rpc-client (&key command transport on-event (error-output :interactive))
  (declare (ignore command transport on-event error-output))
  (%not-implemented 'connect-rpc-client))

(defun rpc-client-call (client method params &key (timeout 60))
  (declare (ignore client method params timeout))
  (%not-implemented 'rpc-client-call))

(defun rpc-client-events (client &key type session-id)
  (declare (ignore client type session-id))
  (%not-implemented 'rpc-client-events))

(defun rpc-client-wait-event (client predicate &key (timeout 30))
  (declare (ignore client predicate timeout))
  (%not-implemented 'rpc-client-wait-event))

(defun rpc-client-process (client)
  (declare (ignore client))
  (%not-implemented 'rpc-client-process))

(defun close-rpc-client (client &key (timeout 10))
  (declare (ignore client timeout))
  (%not-implemented 'close-rpc-client))
