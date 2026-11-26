(in-package #:cl-stack-code)

;;; H3d: the in-process SDK. ONE core for the Lisp API and for --rpc:
;;; src/rpc.lisp is a thin adapter that maps JSON-RPC methods onto the
;;; functions below and sends their events as notifications.
;;;
;;; Values
;;;   Every event, result and reply object is a json-protocol object: an EQUAL
;;;   hash table with string keys, vectors for arrays, :NULL for null, T / NIL
;;;   for true / false. It is exactly what stream-json writes as one line and
;;;   what --rpc sends, so the SDK, -p and --rpc share one schema. Keys are
;;;   snake_case. EVENT-TYPE and EVENT-VALUE read them (given).
;;;
;;; The client
;;;   MAKE-CLIENT &key CWD SETTINGS PROVIDERS USER-CONFIG-DIR DATA-DIR GETENV
;;;                    ON-EVENT ON-APPROVAL (PLAN-AREA :AUTO)
;;;     CWD          default working directory of new sessions (a directory
;;;                  designator, relative to the process directory; default
;;;                  the process directory). Not a directory → CODE-USAGE-ERROR
;;;                  "--cwd X is not a directory", as -p.
;;;     SETTINGS     the flag layer (a SETTINGS, as INVOCATION-SETTINGS;
;;;                  default (MAKE-SETTINGS)). Each session merges the user,
;;;                  project and local files of its own working directory
;;;                  under it (LOAD-SETTINGS :CLI), then its own overrides.
;;;     PROVIDERS, USER-CONFIG-DIR, DATA-DIR, GETENV: as RUN-CLI.
;;;     ON-EVENT     (lambda (session event)) for every event of every session.
;;;     ON-APPROVAL  (lambda (session request)) → a decision or NIL (Approvals).
;;;     PLAN-AREA    :AUTO, :GIT or :COPY: the area kind of plan sessions.
;;;   It starts one thread, the client's LOOP THREAD, running one libuv event
;;;   loop for all of the client's sessions, with the bindings %RUN-HEADLESS
;;;   makes (HTTP-PROTOCOL:*HTTP-BACKEND*, HTTP-BACKEND-ASYNC:*EVENT-BACKEND-
;;;   MAKER*, AGENT:*OFF-LOOP-SPECIALS*). It writes to no stream: the loop
;;;   thread binds *STANDARD-OUTPUT*, *ERROR-OUTPUT* and *TRACE-OUTPUT* to a
;;;   null stream. → a CODE-CLIENT.
;;;   CLOSE-CLIENT CLIENT: interrupts every running turn (each ends as an
;;;   interrupted turn: committed, its result event delivered), closes every
;;;   session (CLIENT-CLOSE-SESSION), stops and joins the loop thread.
;;;   Idempotent. Afterwards every client function but CLOSE-CLIENT,
;;;   CLIENT-CLOSED-P and the readers signals CLIENT-CLOSED.
;;;   WITH-CLIENT (VAR &rest ARGS) &body BODY: MAKE-CLIENT, BODY,
;;;   CLOSE-CLIENT in an UNWIND-PROTECT (given).
;;;
;;; Threads
;;;   Callbacks (the client's ON-EVENT and ON-APPROVAL, a turn's ON-EVENT) run
;;;   on the loop thread, in event order. An error in a callback is dropped:
;;;   it never fails a turn. Every client function may be called from any
;;;   thread: from another thread it runs on the loop thread and waits for
;;;   it (CLIENT-CLOSED if the client closes meanwhile); from the loop thread
;;;   (inside a callback) it runs at once. So a callback may answer an
;;;   approval, steer or interrupt. CLIENT-WAIT and CLIENT-QUERY block, so
;;;   they refuse the loop thread (CODE-USAGE-ERROR "CLIENT-WAIT cannot run
;;;   on the client's loop thread").
;;;
;;; Sessions
;;;   A CODE-SESSION is one open conversation: an H3c session store plus its
;;;   own agent, tools, rules, checkpointer (H5b), plan (H5a, plan mode) and
;;;   image (H4b, lispImage on). It is set up as MAKE-CODE-PROGRAM sets up the
;;;   interactive mode (the same functions and errors, nothing touched
;;;   before they pass): %RESOLVE-CWD, LOAD-SETTINGS, the session overrides,
;;;   RESOLVE-MODEL, CHECK-LISP-IMAGE-SETTINGS, MAKE-CODE-TOOLS,
;;;   START-LISP-IMAGE, ASSEMBLE-SYSTEM-PROMPT, %AGENT-PERMISSIONS,
;;;   %AGENT-SETTINGS, and a SETTINGS-RULE-STORE on the local settings file
;;;   (an "always" answer is saved there, as in the TUI). One client may hold
;;;   many sessions; each runs at most one turn at a time.
;;;   CLIENT-NEW-SESSION client &key CWD MODEL PERMISSION-MODE SESSION-ID
;;;                      TOOL-SOURCES
;;;     CWD is relative to the client's CWD. MODEL (a designator) and
;;;     PERMISSION-MODE (a keyword, as SETTINGS-PERMISSION-MODE) override the
;;;     merged settings for this session. SESSION-ID as --session-id: a bad one
;;;     → CODE-USAGE-ERROR "bad session id \"X\": use 32 hex digits or a UUID";
;;;     an existing one → CODE-USAGE-ERROR "session ID already exists: use
;;;     --resume ID". The configuration errors of -p signal here
;;;     (CODE-USAGE-ERROR, SETTINGS-ERROR, MODEL-NOT-FOUND, LISP-IMAGE-ERROR,
;;;     CHECKPOINT-ERROR) and nothing stays open. The store is created lazily
;;;     (CREATE-SESSION: nothing on disk before the first turn). Then the
;;;     session's INIT event is delivered: -p's stream-json "system" init
;;;     object (subtype "init", version, cwd, project_root, model,
;;;     permission_mode, tools, instructions, and lisp_image with the image
;;;     on) with the session's id. → the CODE-SESSION; CODE-SESSION-INIT is
;;;     that same object.
;;;     TOOL-SOURCES (ACP-2, tool backends): NIL, or (lambda (sources) →
;;;     sources), called once on the loop thread right after MAKE-CODE-TOOLS
;;;     with the working directory's sources (file-tools shell-tools [lisp]
;;;     [units]). What it returns is the session's working-directory source
;;;     list (offered, run, and given back after a plan closes): the same
;;;     shape, a FILE-TOOLS first (it may be a new one, e.g. over another
;;;     CL-STACK-PATHLIB filesystem), and the given shell, lisp and unit
;;;     objects in place (the session closes them; a hook may CHANGE-CLASS
;;;     the shell tools to a subclass of AGENT-TOOLS:SHELL-TOOLS). Another
;;;     value → CODE-USAGE-ERROR; its errors fail the open as a configuration
;;;     error does. Plan-area sources never pass through it.
;;;   CLIENT-RESUME-SESSION client designator &key CWD MODEL PERMISSION-MODE
;;;                         FORK SESSION-ID TOOL-SOURCES
;;;     DESIGNATOR: an id, a unique prefix of at least 4 hex characters or a
;;;     UUID (OPEN-SESSION), or :LAST, the project's last session
;;;     (--continue). None → SESSION-NOT-FOUND. A session open in this client
;;;     already → that CODE-SESSION as it is, and no event (unless FORK). FORK:
;;;     CLONE-SESSION at the head, with SESSION-ID (else a random id), opened as
;;;     a new session (--fork-session). The model: MODEL, else the head
;;;     record's, else the settings, else +DEFAULT-MODEL+ (H3c). The init
;;;     event gains "turns" (the length of the head's line); with FORK also
;;;     "forked_from" (the source id). TOOL-SOURCES as for CLIENT-NEW-SESSION
;;;     (ignored for a session already open).
;;;   CLIENT-FORK-SESSION session &key AT SESSION-ID → a new CODE-SESSION:
;;;     CLONE-SESSION of SESSION's store :AT (a turn number or id prefix, as
;;;     RESOLVE-TURN; default the head; SESSION-TURN-NOT-FOUND), with
;;;     SESSION's cwd, model and mode. Its init event has "turns" and
;;;     "forked_from". SESSION is not changed; a running turn there is fine
;;;     (the clone copies the committed head).
;;;   CLIENT-CLOSE-SESSION session → T: interrupts its running turn (which is
;;;     committed and delivers its result), closes its tools, image and
;;;     checkpointer. An open plan stays open on disk (session/resume reopens
;;;     it). Afterwards the session's functions signal SESSION-NOT-OPEN.
;;;     Idempotent.
;;;   CLIENT-FIND-SESSION client id → the open session with exactly that id,
;;;     or NIL. CLIENT-SESSIONS client → the open sessions, oldest first.
;;;   CLIENT-LIST-SESSIONS client &key CWD → one object per session of the
;;;     project of CWD (default the client's), in LIST-SESSIONS order (newest
;;;     first): {"session_id", "turns" (length of the head's line), "prompt"
;;;     (first line of the line's first prompt, or null), "head" (revision id
;;;     or null), "updated_at" (unix seconds of the newest revision, or null),
;;;     "open" (open in this client)}.
;;;   CLIENT-BUSY-P session → true while a turn runs or waits for approvals.
;;;
;;; Turns
;;;   CLIENT-TURN session prompt &key MENTIONS ON-EVENT → a CODE-TURN, once the
;;;   turn has started (it runs on).
;;;     PROMPT: a string that is not blank (else CODE-USAGE-ERROR "no prompt").
;;;     @path tokens expand as in the TUI (EXPAND-MENTIONS on the tool root:
;;;     the working directory, or the plan area in plan mode). MENTIONS:
;;;     root-relative paths, each attached as a <file path="REL">…</file>
;;;     block after the text's own (in order, skipping a path already
;;;     attached, capped at +MAX-MENTION-CHARS+); a path that is not a
;;;     regular file under the root → CODE-USAGE-ERROR "mention P is not a
;;;     file under the working directory", before anything starts. A turn
;;;     running or waiting → TURN-BUSY (no queue: wait for "result", steer, or
;;;     interrupt). ON-EVENT (lambda (session event)) gets this turn's events,
;;;     after the client's ON-EVENT.
;;;     The run: as the interactive program runs a message. The session's
;;;     first turn (and the first after a rewind moved the head) starts
;;;     RUN-AI-AGENT-ASYNC on SESSION-TURNS of the store plus the prompt;
;;;     later turns CONTINUE-AI-AGENT-ASYNC (history kept). Plan mode opens or
;;;     reopens the session's plan first (H5a, kind PLAN-AREA); then
;;;     BEGIN-CHECKPOINT-TURN (H5b). The turn record's prompt is PROMPT as
;;;     given.
;;;     Events, in this order: plan "opened" / "reopened" (a plan turn that
;;;     opened its plan); then, as they happen, text_delta, thinking_delta
;;;     (ACP-2: {"type","session_id","step","text"}, one per non-empty
;;;     streamed thinking part), assistant, tool_use, approval_request, approval_resolved, tool_result, steering
;;;     "taken" and image_event; at the turn's end steering "dropped" (when
;;;     posts were not taken), plan "projected" (a plan turn that stopped or
;;;     hit max turns), and last "result". The run's events have stream-json's
;;;     exact shapes: one emitter, the %REPORT that -p uses, with a sink per
;;;     destination (stream-json lines, or the session's callbacks); step
;;;     counts from 1 in each turn.
;;;     The end of a turn commits it (the H3c turn record: prompt, the turns
;;;     since the last commit, finish, model, mode, usage, steering, plan) and
;;;     runs END-CHECKPOINT-TURN, BEFORE the result event is delivered, so the
;;;     session's files are current when a caller sees "result". A
;;;     SESSION-CONFLICT forks the session as -p does: a {"type":"session",
;;;     "subtype":"forked","from":OLD,"session_id":NEW} event, then the result
;;;     with NEW, and CODE-SESSION-ID becomes NEW.
;;;     The result object is -p's, for this turn only: "subtype" ("success",
;;;     "error_max_turns", "error_during_execution"), "is_error", "result",
;;;     "error", "num_turns", "duration_ms", "usage", "permission_denials",
;;;     "session_id", and "plan" in plan turns. A failed generate →
;;;     "error_during_execution" with its message; an interrupt → the same
;;;     subtype with error "interrupted". permission_denials reasons:
;;;     "denied" (a rule or policy) and "rejected" (reject, reject_all, or an
;;;     interrupt while the call waited).
;;;   CLIENT-WAIT turn &key TIMEOUT → the result object, or NIL when TIMEOUT
;;;     seconds pass first. A finished turn → its result at once.
;;;   CLIENT-QUERY session prompt &key MENTIONS ON-EVENT TIMEOUT → (values
;;;     result events): CLIENT-TURN, then CLIENT-WAIT. When TIMEOUT passes,
;;;     the turn is interrupted and its interrupted result is returned.
;;;     EVENTS is CODE-TURN-EVENTS.
;;;   CLIENT-STEER session text → T. AGENT-RUN-POST of TEXT (mentions
;;;     expanded) into the running turn (H3c steering): the run takes it
;;;     before its next generate, and a post during the final answer makes it
;;;     take one more step. No turn running (idle, or waiting for approvals)
;;;     → TURN-NOT-RUNNING. Taken: {"type":"steering","subtype":"taken",
;;;     "texts":[as given]}. Not taken when the turn ends: drained
;;;     (DRAIN-AGENT-RUN-INBOX), {"subtype":"dropped","texts"} before the
;;;     result, and never sent later. Taken texts go to the record's steering.
;;;   CLIENT-INTERRUPT session → T when a turn was running or waiting, NIL when
;;;     idle. CANCEL-AGENT-RUN; approvals still waiting are denied first (one
;;;     approval_resolved "interrupt" each) and the run does not resume. The
;;;     turn's result follows as usual. ACP-2: the session's running
;;;     foreground bash commands (H8d :shell-job units of its shell tools that
;;;     are not background jobs) are stopped too, so the turn ends now, not
;;;     when the command would; background jobs keep running.
;;;   CLIENT-SET-PERMISSION-MODE session mode → MODE (ACP-2). The session's
;;;     permission mode (a keyword, as SETTINGS-PERMISSION-MODE; NIL is
;;;     :DEFAULT) from its next turn on: its settings gain the mode, its rules
;;;     and agent settings are rebuilt and the kept run is dropped (the next
;;;     turn starts a new run on SESSION-TURNS: history kept, as after a
;;;     rewind); CODE-SESSION-PERMISSION-MODE is MODE. :PLAN: the next turn
;;;     opens or reopens the plan, as in a plan-mode session; leaving :PLAN
;;;     gives the working directory's tools back and leaves the open plan on
;;;     disk. Another keyword → CODE-USAGE-ERROR (PERMISSION-MODE-NAME); a
;;;     lispImage that does not go with MODE → CHECK-LISP-IMAGE-SETTINGS's
;;;     error; a turn running or waiting → TURN-BUSY.
;;;
;;; Approvals
;;;   No handler answers AGENT-APPROVAL-REQUIRED (bypassPermissions approves
;;;   every ask, as in -p), so an ask pauses the run (:approval). For each
;;;   :proposed invocation, in order, one event
;;;     {"type":"approval_request","session_id","step","id","name","input",
;;;      "summary" (TOOL-CALL-SUMMARY),"preview" (TOOL-CALL-PREVIEW on the
;;;      tool root, or null)}
;;;   is delivered, then ON-APPROVAL is called with it. Its value answers at
;;;   once: :ONCE, :ALWAYS, :REJECT, (:REJECT FEEDBACK), :REJECT-ALL. NIL
;;;   leaves the call waiting; CLIENT-PENDING-APPROVALS lists the requests
;;;   still waiting (oldest first).
;;;   CLIENT-RESPOND-APPROVAL session id decision &key FEEDBACK → the ids it
;;;   resolved (strings, in request order):
;;;     :ONCE        APPROVE-INVOCATION
;;;     :ALWAYS      APPROVE-INVOCATION :ALWAYS T: the rule goes to
;;;                  settings.local.json, and other waiting calls it covers
;;;                  are approved with it
;;;     :REJECT      DENY-INVOCATION :FEEDBACK (a blank FEEDBACK is none)
;;;     :REJECT-ALL  DENY-INVOCATION :ALL T: every waiting call
;;;   ID not waiting → APPROVAL-NOT-FOUND; another DECISION →
;;;   CODE-USAGE-ERROR. One {"type":"approval_resolved","session_id","id",
;;;   "decision"} per resolved id ("once" "always" "reject" "reject_all"
;;;   "interrupt"). When nothing waits any more, the run resumes
;;;   (RESUME-AI-AGENT-ASYNC). A rule save that fails (SETTINGS-ERROR) still
;;;   approves the call once, as in the TUI.
;;;
;;; Plans (H5a), checkpoints and rewinds (H5b): -p's objects
;;;   CLIENT-APPROVE-PLAN session &key (ON-DRIFT :ABORT) → the plan object
;;;     --apply writes: {"type":"plan","subtype":"applied","plan_id",
;;;     "changes"}, "rebased" (conflicts) or "drift" (paths; nothing written).
;;;     It is delivered as an event too. APPROVE-PLAN :CHECKPOINTER with
;;;     PLAN-DRIFT answered per ON-DRIFT (:ABORT, :REBASE, :OVERWRITE), then
;;;     RECORD-PLAN-CHECKPOINTS with the session's head (as the TUI). Once
;;;     applied the plan is closed; the next plan-mode turn opens a new one.
;;;     Busy → TURN-BUSY. No open plan → PLAN-NOT-FOUND "session S has no open
;;;     plan".
;;;   CLIENT-REJECT-PLAN session → {"type":"plan","subtype":"discarded",
;;;     "plan_id"} (also an event). Errors as approving.
;;;   CLIENT-CHECKPOINTS session → a list, newest first, of {"id","ordinal",
;;;     "reason" ("before" "turn" "plan_before" "plan_after" "rewind"),"turn",
;;;     "files_kind" ("copy" "git" "jj"),"message","recorded_at" (unix
;;;     seconds),"expired"}.
;;;   CLIENT-REWIND session turn &key (MODE :BOTH) (ON-DRIFT :ABORT) → -p's
;;;     rewind object {"type":"rewind","session_id","turn","parts",
;;;     "conversation","files","changes","conflicts","drift","checkpoint"}
;;;     (also an event). TURN: an integer, or a string as --rewind takes it.
;;;     MODE :BOTH, :CONVERSATION or :FILES. A drift abort is a value (files
;;;     "aborted"), not an error. CHECKPOINT-NOT-FOUND and
;;;     SESSION-TURN-NOT-FOUND propagate. Busy → TURN-BUSY. When the
;;;     conversation moved, the next turn starts a new run on the new head.
;;;
;;; Introspection
;;;   CLIENT-SETTINGS session-or-client → {"settings": S, "files": [the
;;;     settings files read, native namestrings, in order]}. S is the merged
;;;     settings in the settings-file shape: "model", "maxTurns",
;;;     "permissionMode" (null when unset), "permissions": {"allow", "ask",
;;;     "deny"} (FORMAT-PERMISSION-RULE strings), "env" (the NAMES of the keys
;;;     set, sorted; values are never returned: they hold API keys),
;;;     "appendSystemPrompt" (or null), "checkpoints": {"enabled", "keep",
;;;     "kind"}, "lispImage": {"image", "backend", "observe", "onDebugger"}
;;;     (CHECKPOINT-SETTINGS / LISP-IMAGE-SETTINGS values, image as "off",
;;;     "spawn" or "attach:H:P"). A session: its settings, overrides included;
;;;     a client: those of its CWD.
;;;   CLIENT-TOOLS session → a list of {"name","description","input_schema"}
;;;     in offered order.
;;;   CLIENT-EXPORT-SESSION session &key (FORMAT :JSON) → EXPORT-SESSION's
;;;     text of the session's head line (ACP-2: session/load replays it), read
;;;     on the loop thread.
;;;
;;; The image (H4b)
;;;   With lispImage on, every session has its own image, started by
;;;   CLIENT-NEW-SESSION / -RESUME-SESSION. Its events are image_event
;;;   objects as in -p. During a turn they are posted into the run. While
;;;   idle they are delivered at once and kept: the next turn posts them
;;;   right after its prompt. onDebugger "turn" does not start turns here:
;;;   the caller decides.

;;; Given: events.

(defparameter +event-types+
  '("system" "text_delta"
    ;; ACP-2: streamed thinking, right after text_delta
    "thinking_delta"
    "assistant" "tool_use" "tool_result"
    "approval_request" "approval_resolved" "steering" "image_event"
    "plan" "rewind" "session" "result"
    ;; H3e-1: lazily loaded instruction files and rules
    "instructions"
    ;; H8d: units/subscribe notifications
    "unit")
  "Every event \"type\" the SDK, -p's stream-json and --rpc can deliver.")

(defparameter +approval-decision-names+
  '(("once" . :once) ("always" . :always) ("reject" . :reject) ("reject_all" . :reject-all))
  "Wire names of the approval decisions (approval/respond, approval_resolved).")

(defun event-type (event)
  "EVENT's \"type\" string."
  (and (hash-table-p event) (gethash "type" event)))

(defun event-value (event &rest keys)
  "Walk EVENT by string KEYS (objects) and integer KEYS (arrays). → the value,
or NIL when a key is missing."
  (let ((object event))
    (dolist (k keys object)
      (setf object
            (etypecase k
              (string (and (hash-table-p object) (gethash k object)))
              (integer (and (vectorp object) (< -1 k (length object)) (aref object k))))))))

;;; Given: the objects. Their slots are the implementation's to fill; the
;;; readers are the API.

(defclass code-client ()
  ((cwd :initarg :cwd :reader client-cwd
        :documentation "Truename of the default working directory.")
   (settings :initarg :settings :initform (make-settings) :reader %client-settings
             :documentation "The flag layer.")
   (providers :initarg :providers :initform nil :reader %client-providers)
   (user-config-dir :initarg :user-config-dir :initform nil :reader %client-user-config-dir)
   (data-dir :initarg :data-dir :initform nil :reader %client-data-dir)
   (getenv :initarg :getenv :initform #'uiop:getenv :reader %client-getenv)
   (on-event :initarg :on-event :initform nil :accessor %client-on-event)
   (on-approval :initarg :on-approval :initform nil :accessor %client-on-approval)
   (plan-area :initarg :plan-area :initform :auto :reader %client-plan-area)
   ;; R4d-4b
   (plan-backend :initarg :plan-backend :initform nil :reader %client-plan-backend
                 :documentation "PLAN-COMPUTE-BACKEND, resolved by MAKE-CLIENT (its thread).")
   (lock :initform (bt:make-lock "cl-stack-code client") :reader %client-lock)
   (sessions :initform '() :accessor %client-sessions
             :documentation "Open CODE-SESSIONs, newest first.")
   (thread :initform nil :accessor %client-thread)
   (event-backend :initform nil :accessor %client-event-backend)
   (event-loop :initform nil :accessor %client-event-loop)
   (closed :initform nil :accessor client-closed-p))
  (:documentation "An in-process cl-stack-code host: sessions on one loop thread."))

(defclass code-session ()
  ((client :initarg :client :reader code-session-client)
   (id :initarg :id :accessor code-session-id
       :documentation "The session store's id (a new one after a conflict fork).")
   (cwd :initarg :cwd :reader code-session-cwd)
   (model :initarg :model :accessor code-session-model :documentation "The model designator.")
   (permission-mode :initarg :permission-mode :accessor code-session-permission-mode)
   (init :initarg :init :initform nil :accessor code-session-init
         :documentation "The session's init event object.")
   (store :initarg :store :accessor code-session-store :documentation "The SESSION-STORE.")
   ;; The implementation's (loop thread only).
   (state :initform nil :accessor %session-state
          :documentation "A plist or struct of the implementation's choice: agent, run,
handle, sources, settings, checkpointer, plan, image link, pending approvals,
posted steering, committed turns, the current CODE-TURN, closed flag."))
  (:documentation "One open conversation of a CODE-CLIENT."))

(defclass code-turn ()
  ((session :initarg :session :reader code-turn-session)
   (prompt :initarg :prompt :reader code-turn-prompt)
   (events :initform '() :accessor %turn-events :documentation "Newest first.")
   (result :initform nil :accessor %turn-result)
   (lock :initform (bt:make-lock "code-turn") :reader %turn-lock)
   (done :initform (bt:make-condition-variable) :reader %turn-done))
  (:documentation "One turn of a CODE-SESSION."))

(defun code-turn-events (turn)
  "TURN's events so far, oldest first (a fresh list)."
  (bt:with-lock-held ((%turn-lock turn))
    (reverse (%turn-events turn))))

(defun code-turn-result (turn)
  "TURN's result object, or NIL while it runs."
  (bt:with-lock-held ((%turn-lock turn))
    (%turn-result turn)))

(defun code-turn-done-p (turn)
  (and (code-turn-result turn) t))

(defmacro with-client ((var &rest args) &body body)
  "MAKE-CLIENT with ARGS, BODY, then CLOSE-CLIENT (always)."
  `(let ((,var (make-client ,@args)))
     (unwind-protect (progn ,@body)
       (close-client ,var))))

;;; Implementation.
;;;
;;; The client's thread slot holds a %LOOP (the loop thread and its stop
;;; flag); every session's state is a %SESS. Everything below that touches a
;;; %SESS runs on the loop thread (%CALL takes every public function there).
;;; A turn's events come from a per-turn %REPORT (src/headless.lisp) whose
;;; sink delivers them to the callbacks; idle events (init, plan, rewind,
;;; image events between turns) use a turn-less report.

(defstruct (%loop (:constructor %make-loop ()))
  (thread nil)
  (stopping nil))

(defstruct (%sess (:conc-name %s-))
  cwd config settings mode designator data-dir getenv
  sessions-dir project-dir max-turns
  agent sources link checkpointer cwd-instructions
  ;; H5a
  plan plan-sources plan-turn-p
  ;; R4d-4b
  plan-sandbox
  ;; the run (kept across turns: CONTINUE-AI-AGENT-ASYNC)
  run handle
  (committed (make-hash-table :test 'eq))
  (usage (list 0 0 0 0))                ; since the last commit
  (steering '())                        ; texts taken since the last commit
  (posted '())                          ; (llm-turn . text) not taken yet
  ;; the current turn
  (state :idle)                         ; :idle :running :waiting :ending
  turn report pre start interrupted
  (pending '())                         ; (invocation . approval_request), oldest first
  ;; closing
  closed close-pending
  ;; H8d (set once by %OPEN-CODE-SESSION)
  supervisor unit-tools
  ;; H3e-1 (set once by %OPEN-CODE-SESSION): the instruction context, the
  ;; session's discovery and instruction set, and the closure that renders
  ;; the working directory's system prompt from the set's current revision.
  context discovery instruction-set render
  ;; H3e-2a (set once by %OPEN-CODE-SESSION): the session's MCP-MANAGER.
  mcp
  (unit-subs '())                       ; ("sub-N" SUP:SUBSCRIPTION), loop thread
  (unit-sub-counter 0)                  ; loop thread
  (units-lock (bt:make-lock "cl-stack-code session units"))
  prev-sample prev-sample-time          ; CLIENT-UNITS :RESOURCES, under UNITS-LOCK
  ;; H3f (set once by %OPEN-CODE-SESSION): the effective context window and
  ;; the secrets messages hide; RETRY-OF of the turn being started.
  window secrets retry-of)

;;; The loop thread and dispatch.

(defun %loop-thread-p (client)
  (let ((loop (%client-thread client)))
    (and loop (eq (bt:current-thread) (%loop-thread loop)))))

(defun %client-thread-main (client http maker)
  (let* ((null-stream (make-broadcast-stream))
         (*standard-output* null-stream)
         (*error-output* null-stream)
         (*trace-output* null-stream)
         (eb (%client-event-backend client))
         (el (%client-event-loop client))
         (event:*event-backend* eb)
         (event:*event-loop* el)
         (http-protocol:*http-backend* (or http (http-backend-async:make-async-backend)))
         (http-backend-async:*event-backend-maker*
           (or maker #'event-backend-libuv:make-libuv-backend))
         (agent:*off-loop-specials*
           (union '(http-protocol:*http-backend* http-backend-async:*event-backend-maker*)
                  agent:*off-loop-specials*)))
    (handler-bind ((agent:agent-tool-error
                     ;; R4d-4b: a confined bash the backend refused. The SDK's
                     ;; notice is the plan event's "sandbox" object.
                     (%plan-sandbox-refusal-handler
                      (lambda (c)
                        (let ((session (%session-of-run client (agent:agent-error-run c))))
                          (and session (%s-plan-sandbox (%session-state session)))))
                      nil))
                   (agent:agent-approval-required
                     (lambda (c)
                       ;; Only a bypassPermissions session answers; otherwise
                       ;; the run pauses and the caller answers.
                       (let ((session (%session-of-run client (agent:agent-error-run c))))
                         (when (and session
                                    (eq :bypass-permissions
                                        (%s-mode (%session-state session))))
                           (agent:invoke-approve c)))))
                   (warning
                     (lambda (w)
                       (let ((restart (find-restart 'muffle-warning w)))
                         (when restart (invoke-restart restart))))))
      (loop until (%loop-stopping (%client-thread client))
            do (handler-case (event:run eb el :stop-when-idle nil)
                 (error () nil))))))

(defun %session-of-run (client run)
  (and run
       (find run (%client-sessions client)
             :key (lambda (s) (%s-run (%session-state s))) :test #'eq)))

(defun %call (client fn &key internal)
  "Run FN on CLIENT's loop thread and return its values; at once when called
there. Its error is signalled again in the caller (the same object)."
  (let ((loop (%client-thread client)))
    (when (and (not internal)
               (or (client-closed-p client) (null loop) (%loop-stopping loop)))
      (error 'client-closed))
    (if (eq (bt:current-thread) (%loop-thread loop))
        (funcall fn)
        (let ((lock (bt:make-lock "client call"))
              (cv (bt:make-condition-variable))
              (box nil))
          (event:wake-call (%client-event-backend client) (%client-event-loop client)
                           (lambda ()
                             (let ((r (handler-case (cons :ok (multiple-value-list (funcall fn)))
                                        (error (e) (cons :error e)))))
                               (bt:with-lock-held (lock)
                                 (setf box r)
                                 (bt:condition-notify cv)))))
          (bt:with-lock-held (lock)
            (loop until (or box (not (bt:thread-alive-p (%loop-thread loop))))
                  do (bt:condition-wait cv lock :timeout 0.2)))
          (case (car box)
            (:ok (values-list (cdr box)))
            (:error (error (cdr box)))
            (t (error 'client-closed)))))))

(defmacro %on-client-loop ((client) &body body)
  `(%call ,client (lambda () ,@body)))

;;; The client.

(defun %given-directory (given)
  (if (pathnamep given) (uiop:native-namestring given) given))

(defun make-client (&key cwd settings providers user-config-dir data-dir
                         (getenv #'uiop:getenv) on-event on-approval (plan-area :auto))
  (let* ((dir (truename (%resolve-cwd (%given-directory cwd))))
         (client (make-instance 'code-client
                                :cwd dir
                                :settings (or settings (make-settings))
                                :providers providers
                                :user-config-dir user-config-dir
                                :data-dir data-dir
                                :getenv (or getenv #'uiop:getenv)
                                :on-event on-event
                                :on-approval on-approval
                                :plan-area (or plan-area :auto)
                                ;; R4d-4b: here, not on the loop thread.
                                :plan-backend (plan-compute-backend)))
         (eb (event-backend-libuv:make-libuv-backend))
         (el (event:make-event-loop eb))
         (loop (%make-loop))
         (http http-protocol:*http-backend*)
         (maker http-backend-async:*event-backend-maker*))
    (setf (%client-event-backend client) eb
          (%client-event-loop client) el
          (%client-thread client) loop)
    (handler-bind ((error (lambda (e)
                            (declare (ignore e))
                            (event:close-event-loop eb el))))
      (setf (%loop-thread loop)
            (bt:make-thread (lambda () (%client-thread-main client http maker))
                            :name "cl-stack-code client")))
    client))

(defun close-client (client)
  (let ((loop (%client-thread client)))
    (when (or (client-closed-p client) (null loop) (%loop-stopping loop))
      (return-from close-client nil))
    (let ((turns (handler-case
                     (%call client
                            (lambda ()
                              (loop for session in (reverse (%client-sessions client))
                                    for turn = (%close-session session)
                                    when turn collect turn))
                            :internal t)
                   (error () nil))))
      (if (%loop-thread-p client)
          ;; Inside a callback: the turns end on this thread later.
          (progn
            (setf (%loop-stopping loop) t
                  (client-closed-p client) t)
            (event:wake-call (%client-event-backend client) (%client-event-loop client)
                             (lambda () (event:stop (%client-event-backend client)
                                                    (%client-event-loop client)))))
          (progn
            (dolist (turn turns)
              (client-wait turn :timeout 60))
            (setf (%loop-stopping loop) t)
            (let ((eb (%client-event-backend client))
                  (el (%client-event-loop client)))
              (event:wake-call eb el (lambda () (event:stop eb el)))
              (let ((ended (%join-thread (%loop-thread loop) 10)))
                (setf (client-closed-p client) t)
                (when ended
                  (event:close-event-loop eb el)))))))
    nil))

(defun client-sessions (client)
  (%on-client-loop (client) (reverse (%client-sessions client))))

(defun client-find-session (client id)
  (%on-client-loop (client)
    (find id (%client-sessions client) :key #'code-session-id :test #'equal)))

;;; Reports, sinks and delivery.

(defun %sdk-denial-reason (decision)
  "The SDK's permission_denials reason: a person (or an interrupt) refused
the call → \"rejected\"; a rule or policy → \"denied\"."
  (if (member decision '(:rejected :unattended)) "rejected" "denied"))

(defun %deliver (session object on-event)
  "The client's ON-EVENT, then ON-EVENT (a turn's), on the loop thread. A
callback error is dropped."
  (let ((f (%client-on-event (code-session-client session))))
    (when f
      (handler-case (funcall f session object)
        (error () nil))))
  (when on-event
    (handler-case (funcall on-event session object)
      (error () nil)))
  object)

(defun %session-report (session &optional turn on-event)
  "A %REPORT whose sink delivers to SESSION's callbacks (and records TURN's
events when TURN is given)."
  (make-%report :format :sdk
                :output (make-broadcast-stream)
                :session (code-session-id session)
                :sink (if turn
                          (lambda (object)
                            (bt:with-lock-held ((%turn-lock turn))
                              (push object (%turn-events turn)))
                            (%deliver session object on-event))
                          (lambda (object) (%deliver session object nil)))
                :denial-reason #'%sdk-denial-reason
                :image-tools (%sources-lisp-tools (%s-sources (%session-state session)))
                :instruction-set (%s-instruction-set (%session-state session))
                :mcp (%s-mcp (%session-state session))))

(defun %with-session-mcp (session fn)
  "H3e-2a: FN of SESSION's MCP-MANAGER, on the client's loop thread (the set's)."
  (%on-client-loop ((code-session-client session))
    (funcall fn (%s-mcp (%live session)))))

;;; Sessions.

(defun %live (session)
  "SESSION's state; SESSION-NOT-OPEN once it was closed."
  (let ((st (%session-state session)))
    (when (or (null st) (%s-closed st))
      (error 'session-not-open :id (code-session-id session)))
    st))

(defun %session-dir (client cwd)
  "CWD (relative to the client's) as a directory truename; the client's when
NIL. Not a directory → CODE-USAGE-ERROR."
  (if (null cwd)
      (client-cwd client)
      (let* ((given (%given-directory cwd))
             (path (and (stringp given) (plusp (length given))
                        (uiop:parse-native-namestring given :ensure-directory t)))
             (dir (and path (uiop:directory-exists-p
                             (uiop:merge-pathnames* path (client-cwd client))))))
        (if dir
            (truename dir)
            (error 'code-usage-error
                   :message (format nil "--cwd ~a is not a directory" given))))))

(defun %client-data-root (client)
  "The data directory: MAKE-CLIENT's DATA-DIR, else USER-DATA-DIRECTORY."
  (or (%client-data-dir client)
      (user-data-directory :getenv (%client-getenv client))))

(defun %client-config (client)
  (or (%client-user-config-dir client)
      (user-config-directory :getenv (%client-getenv client))))

(defun %merged-settings (client dir &key model permission-mode)
  "The settings files of DIR under the client's flag layer, then the session
overrides."
  (let ((loaded (load-settings dir :user-config-dir (%client-config client)
                                   :cli (%client-settings client))))
    (if (or model permission-mode)
        (merge-settings loaded (make-settings :model model :permission-mode permission-mode))
        loaded)))

(defun %sessions-dir-of-client (client dir)
  (%sessions-dir dir (%client-data-dir client) (%client-getenv client)))

(defun %check-new-id (sessions-dir id)
  "SESSION-ID as --session-id: a bad one or an existing one → CODE-USAGE-ERROR."
  (when id
    (let ((normal (normalize-session-id id)))
      (unless normal
        (%usage-fail "bad session id ~s: use 32 hex digits or a UUID" id))
      (when (%session-exists-p sessions-dir normal)
        (%usage-fail "session ~a already exists: use --resume ~a" normal normal)))))

(defun %open-code-session (client dir settings designator store-fn
                           &key turns forked-from tool-sources mcp-servers
                             (mcp-configs nil mcp-configs-p))
  "Set SESSION up as MAKE-CODE-PROGRAM sets up the interactive mode; STORE-FN
makes its store once the configuration passed. → the CODE-SESSION, its init
event delivered. H3e-2a: MCP-SERVERS are the SDK's (CLIENT-NEW-SESSION);
MCP-CONFIGS, when given, are the servers exactly (a fork's)."
  (let* ((getenv (%client-getenv client))
         (config (%client-config client))
         (data-dir (%client-data-dir client))
         (env (%env-lookup settings getenv))
         (mcp-configs (if mcp-configs-p
                          mcp-configs
                          (effective-mcp-servers dir settings :user-config-dir config
                                                              :sdk-servers mcp-servers :env env)))
         (resolved (multiple-value-list
                    (resolve-model designator :providers (%client-providers client) :env env)))
         (backend (%apply-settings-request-timeout (first resolved) settings))
         (mode (or (settings-permission-mode settings) :default))
         (link (when (settings-lisp-image settings)
                 (check-lisp-image-settings settings mode)
                 (and (lisp-image-enabled-p settings) (%make-image-link))))
         (project-dir (or (find-project-root dir) dir))
         (store nil)
         (checkpointer nil)
         (supervisor nil)
         (mcp nil)
         (sources nil)
         (context nil)
         (discovery nil)
         (instruction-set nil)
         (done nil))
    (unwind-protect
         (progn
           (setf store (funcall store-fn project-dir)
                 checkpointer (%make-run-checkpointer settings dir data-dir getenv))
           ;; H8d: the session's supervisor, before the tools; H3e-2a: then the
           ;; MCP manager, before the instruction set opens.
           (setf supervisor (make-code-supervisor dir :data-dir (%client-data-root client)
                                                      :getenv getenv)
                 mcp (make-mcp-manager mcp-configs :supervisor supervisor :settings settings
                                                   :env env :cwd dir
                                                   :http-backend http-protocol:*http-backend*))
           ;; The set is this (the loop) thread's; a change elsewhere is posted here.
           (let ((eb (%client-event-backend client))
                 (el (%client-event-loop client)))
             (%set-mcp-owner mcp (bt:current-thread)
                             (lambda (fn)
                               (event:wake-call eb el (lambda ()
                                                        (handler-case (funcall fn)
                                                          (error () nil)))))))
           ;; H3e-1: the session's instruction set (:start or :resume).
           (multiple-value-setq (context discovery instruction-set)
             (%open-session-instructions dir settings store
                                         :user-config-dir config
                                         :components (list (mcp-manager-component mcp))))
           (setf (mcp-manager-instruction-set mcp) instruction-set)
           (setf sources (make-code-tools dir :settings settings
                                              :on-image-event (and link (%link-callback link))
                                              :supervisor supervisor
                                              :skills (context-skills context)))
           (%link-skill-tools instruction-set (code-skill-tools sources))
           ;; ACP-2: the caller's tool backends (TOOL-SOURCES, header).
           (when tool-sources
             (setf sources (%hooked-sources tool-sources sources)))
           ;; H3e-2a: the MCP source, last.
           (setf sources (append sources (list (mcp-manager-tool-source mcp))))
           (when link
             (setf (%link-tools link) (third sources))
             (start-lisp-image (third sources) settings))
           ;; H3e-2a: the servers, before the init event (headless: never asks).
           (start-mcp-servers mcp)
           (let ((offered (loop for source in sources
                                append (mapcar #'llm:llm-tool-name
                                               (agent:list-agent-tools source)))))
             (multiple-value-bind (instructions files)
                 (assemble-system-prompt dir :tools offered :backend backend
                                             :settings settings :user-config-dir config
                                             :lisp-image (%sources-lisp-tools sources)
                                             :context context :instruction-set instruction-set)
               (let* ((render (lambda ()
                                (values (assemble-system-prompt
                                         dir :tools offered :backend backend
                                             :settings settings :user-config-dir config
                                             :lisp-image (%sources-lisp-tools sources)
                                             :context context :instruction-set instruction-set))))
                      (rules (make-settings-rule-store
                              (third (settings-file-paths dir :user-config-dir config))))
                      (agent (agent:make-ai-agent
                              :name "cl-stack-code"
                              :backend backend
                              :model (third resolved)
                              :instructions instructions
                              :tools (%capped-sources sources settings (%tool-output-dir store))
                              :permissions (%agent-permissions settings)
                              :settings (%agent-settings dir settings :discovery discovery
                                                                      :backend backend
                                                                      :designator designator)
                              :permission-store rules))
                      (session (make-instance 'code-session
                                              :client client
                                              :id (session-id store)
                                              :cwd dir
                                              :model designator
                                              :permission-mode mode
                                              :store store)))
                 (setf (%session-state session)
                       (make-%sess :cwd dir :config config :settings settings :mode mode
                                   :designator designator
                                   :data-dir (%client-data-root client) :getenv getenv
                                   :sessions-dir (%sessions-dir-of-client client dir)
                                   :project-dir project-dir
                                   :max-turns (or (settings-max-turns settings) +default-max-turns+)
                                   :agent agent :sources sources :link link
                                   :checkpointer checkpointer
                                   :supervisor supervisor
                                   :unit-tools (code-unit-tools sources)
                                   :context context :discovery discovery
                                   :instruction-set instruction-set :render render
                                   :mcp mcp
                                   :window (multiple-value-list
                                            (effective-context-window settings backend designator))
                                   :secrets (%run-secrets settings getenv)))
                 (push session (%client-sessions client))
                 (setf done t)
                 (when link
                   (let ((eb (%client-event-backend client))
                         (el (%client-event-loop client)))
                     (%link-attach link (lambda (event)
                                          (event:wake-call eb el
                                                           (lambda ()
                                                             (%sdk-image-event session event)))))))
                 (setf (code-session-init session)
                       (apply #'%emit-event (%session-report session) "system"
                              (append (%system-init-keys dir (find-project-root dir) designator
                                                         mode offered files
                                                         (and link settings)
                                                         :context context :discovery discovery
                                                         :instruction-set instruction-set
                                                         :mcp-servers (mcp-manager-connections mcp)
                                                         :resilience (apply #'%resilience-init-keys
                                                                            settings
                                                                            (%s-window (%session-state session))))
                                      (and turns (list "turns" turns))
                                      (and forked-from (list "forked_from" forked-from)))))
                 session))))
      (unless done
        (%link-close link)
        ;; H3e-2a: the MCP clients and units, before the supervisor.
        (close-mcp-manager mcp)
        ;; H8d: unit tools, shell tools, then the supervisor.
        (%close-code-units supervisor :unit-tools (list (code-unit-tools sources))
                                      :shell-tools (list (second sources)))
        (when checkpointer
          (close-checkpointer checkpointer))))))

(defun %hooked-sources (hook sources)
  "ACP-2: SOURCES through the TOOL-SOURCES hook. The hook must give back a
list of the same shape whose shell, lisp and unit tools are the given objects
(the session closes those); anything else → CODE-USAGE-ERROR."
  (let ((new (funcall hook (copy-list sources))))
    (unless (and (listp new)
                 (= (length new) (length sources))
                 (tools:file-tools-p (first new))
                 (every #'eq (rest new) (rest sources)))
      (%usage-fail "a tool-sources hook must return (file-tools shell-tools …) with the session's own shell, lisp and unit tools"))
    new))

(defun %head-model (store)
  (let ((head (and store (session-head store))))
    (and head (record-model (revision-record head)))))

(defun client-new-session (client &key cwd model permission-mode session-id tool-sources
                                       mcp-servers)
  (%on-client-loop (client)
    (let* ((dir (%session-dir client cwd))
           (settings (%merged-settings client dir :model model :permission-mode permission-mode))
           (sessions-dir (%sessions-dir-of-client client dir))
           (inv (make-instance 'invocation :session-id session-id :settings (make-settings))))
      ;; --session-id's checks (a bad id, an existing one).
      (%session-source inv sessions-dir)
      (%open-code-session client dir settings
                          (or model (settings-model settings) +default-model+)
                          (lambda (project-dir)
                            (%session-for-run inv nil sessions-dir project-dir))
                          :tool-sources tool-sources
                          :mcp-servers mcp-servers))))

(defun client-resume-session (client designator &key cwd model permission-mode fork session-id
                                                      tool-sources mcp-servers)
  (%on-client-loop (client)
    (let* ((dir (%session-dir client cwd))
           (sessions-dir (%sessions-dir-of-client client dir))
           (inv (make-instance 'invocation
                               :continue-p (eq designator :last)
                               :resume (and (not (eq designator :last)) designator)
                               :fork-session-p (and fork t)
                               :session-id (and fork session-id)
                               :settings (make-settings)))
           (source (if (or (eq designator :last) (stringp designator))
                       (%session-source inv sessions-dir)
                       (error 'session-not-found :designator designator)))
           (open (and (not fork)
                      (find (session-id source) (%client-sessions client)
                            :key #'code-session-id :test #'equal))))
      (or open
          (let ((settings (%merged-settings client dir :model model
                                                       :permission-mode permission-mode)))
            (%open-code-session client dir settings
                                (or model (%head-model source) (settings-model settings)
                                    +default-model+)
                                (lambda (project-dir)
                                  (%session-for-run inv source sessions-dir project-dir))
                                :turns (length (session-line source))
                                :forked-from (and fork (session-id source))
                                :tool-sources tool-sources
                                :mcp-servers mcp-servers))))))

(defun client-fork-session (session &key at session-id)
  (let ((client (code-session-client session)))
    (%on-client-loop (client)
      (let* ((st (%live session))
             (store (code-session-store session))
             (revision (if at
                           (resolve-turn store (if (integerp at) (princ-to-string at) at))
                           (session-head store)))
             (settings (%s-settings st)))
        (%check-new-id (%s-sessions-dir st) session-id)
        (%open-code-session client (%s-cwd st) settings (%s-designator st)
                            (lambda (project-dir)
                              (declare (ignore project-dir))
                              (clone-session store :id session-id
                                                   :at (and revision (rev:revision-id revision))))
                            :turns (if revision
                                       (length (session-line store (rev:revision-id revision)))
                                       0)
                            :forked-from (session-id store)
                            ;; H3e-2a: the fork point's servers, from this manager.
                            :mcp-configs (%fork-mcp-configs (%s-mcp st) store revision))))))

(defun %fork-mcp-configs (manager store revision)
  "H3e-2a: the configs MANAGER held for the servers of STORE's instruction-set
revision at REVISION (the head when NIL), in its order (a server it never held
is left out)."
  (let* ((iset (session-instruction-store store))
         (id (session-instruction-set store (if revision (rev:revision-id revision) +head-ref+)))
         (entries (and id (%find-set-revision iset id)
                       (cdr (assoc :mcp-servers (read-instruction-set iset id))))))
    (loop for entry in entries
          for config = (and manager (%mcp-held-config manager (getf entry :name)
                                                      (getf entry :config)))
          when config collect config)))

(defun %close-session-resources (st)
  ;; H8d: the subscriptions end first (no event is delivered after this).
  (dolist (entry (shiftf (%s-unit-subs st) '()))
    (sup:unsubscribe (second entry)))
  (%link-close (%s-link st))
  ;; H3e-2a: the MCP clients and units, before the supervisor.
  (close-mcp-manager (%s-mcp st))
  ;; H8d: unit tools (the working directory's and the plan area's), shell
  ;; tools, then the supervisor (every unit stopped, logs kept).
  (%close-code-units (%s-supervisor st)
                     :unit-tools (list (%s-unit-tools st) (code-unit-tools (%s-plan-sources st)))
                     :shell-tools (list (second (%s-sources st)) (second (%s-plan-sources st))))
  (when (%s-checkpointer st)
    (close-checkpointer (%s-checkpointer st))))

(defun %close-session (session)
  "Loop thread: close SESSION. → the CODE-TURN still ending (its resources
close after its result), or NIL."
  (let ((st (%session-state session))
        (client (code-session-client session)))
    (when (and st (not (%s-closed st)))
      (setf (%s-closed st) t
            (%client-sessions client) (remove session (%client-sessions client)))
      (%interrupt st session)
      (if (eq :idle (%s-state st))
          (progn (%close-session-resources st) nil)
          (progn (setf (%s-close-pending st) t)
                 (%s-turn st))))))

(defun client-close-session (session)
  (let* ((client (code-session-client session))
         (turn (%on-client-loop (client) (%close-session session))))
    (when (and turn (not (%loop-thread-p client)))
      (client-wait turn :timeout 60))
    t))

(defun client-list-sessions (client &key cwd)
  (%on-client-loop (client)
    (let ((dir (%session-dir client cwd)))
      (mapcar (lambda (store)
                (let* ((line (session-line store))
                       (head (session-head store))
                       (first-prompt (and line (record-prompt (revision-record (first line)))))
                       (time (%latest-time store)))
                  (%json-object "session_id" (session-id store)
                                "turns" (length line)
                                "prompt" (if first-prompt (%first-line first-prompt) :null)
                                "head" (if head (rev:revision-id head) :null)
                                "updated_at" (if time (dt:instant-seconds time) :null)
                                "open" (and (find (session-id store) (%client-sessions client)
                                                  :key #'code-session-id :test #'equal)
                                            t))))
              (list-sessions (%sessions-dir-of-client client dir))))))

(defun client-busy-p (session)
  (%on-client-loop ((code-session-client session))
    (let ((st (%session-state session)))
      (and st (not (eq :idle (%s-state st)))))))

;;; Turns.

(defun %tool-root (st)
  (if (and (%s-plan st) (%s-plan-sources st))
      (plan-tool-root (%s-plan st) (%s-cwd st))
      (%s-cwd st)))

(defun %prompt-text (prompt mentions root)
  "PROMPT with its @mentions expanded, then MENTIONS attached (skipping a path
attached already)."
  (multiple-value-bind (text attached) (expand-mentions prompt root)
    (let ((parts (list text)))
      (dolist (rel mentions)
        (unless (member rel attached :test #'string=)
          (let* ((path (%project-file root rel))
                 (content (and path (%file-text path))))
            (when content
              (push rel attached)
              (push (%attachment rel content) parts)))))
      (apply #'concatenate 'string (nreverse parts)))))

(defun %sdk-agent-event (session)
  "The run's :ON-EVENT: the current turn's report, plus steering taken."
  (lambda (kind payload)
    (let ((st (%session-state session)))
      (when (eq kind :started)
        (setf (%s-run st) payload))
      (let ((report (%s-report st)))
        (when report
          (%on-agent-event report kind payload)))
      (when (eq kind :inbox)
        (handler-case (%sdk-on-inbox st payload)
          (error () nil))))))

(defun %sdk-on-inbox (st turns)
  "The run took TURNS from its inbox: the steering among them, as given."
  (let ((texts '()))
    (dolist (turn turns)
      (let ((entry (assoc turn (%s-posted st) :test #'eq)))
        (when entry
          (push (cdr entry) texts)
          (setf (%s-posted st) (remove entry (%s-posted st) :test #'eq)))))
    (when texts
      (setf texts (nreverse texts)
            (%s-steering st) (append (%s-steering st) texts))
      (when (%s-report st)
        (%emit-event (%s-report st) "steering" "subtype" "taken"
                     "texts" (coerce texts 'vector))))))

(defun %sdk-callback (session)
  (lambda (run)
    (let ((st (%session-state session)))
      (setf (%s-run st) run)
      (if (and (member (agent:agent-run-finish-reason run) '(:approval :deferred))
               (not (%s-interrupted st)))
          (%offer-approvals session st run)
          (%finish-turn session st run nil)))))

(defun %sdk-error-callback (session)
  (lambda (condition)
    (let ((st (%session-state session)))
      (%finish-turn session st (%s-run st) condition))))

(defun %sdk-plan-settings (st)
  (merge-settings (%s-settings st)
                  (make-settings :permission-mode :plan
                                 :lisp-image '(:image (:off)))))

(defun %sdk-plan-agent (st plan settings sandbox)
  "The area's tool sources for PLAN (confined while SANDBOX is) and the
instructions. → (values sources instructions). H8d: on the session's
supervisor, under an :agent scope \"plan-<id8>\"."
  (let* ((agent (%s-agent st))
         (sup (%s-supervisor st))
         (sources (append (apply #'make-code-tools (plan-tool-root plan (%s-cwd st))
                                 :settings settings
                                 :supervisor sup
                                 :scope (%plan-unit-scope sup plan)
                                 :skills (and (%s-context st) (context-skills (%s-context st)))
                                 (plan-sandbox-tool-keys sandbox))
                          ;; H3e-2a: the session's MCP source, last.
                          (and (%s-mcp st) (list (mcp-manager-tool-source (%s-mcp st)))))))
    (%link-skill-tools (%s-instruction-set st) (code-skill-tools sources))
    (handler-bind ((error (lambda (e)
                            (declare (ignore e))
                            (%close-code-units nil :unit-tools (list (code-unit-tools sources))
                                                   :shell-tools (list (second sources))))))
      (let ((offered (loop for source in sources
                           append (mapcar #'llm:llm-tool-name
                                          (agent:list-agent-tools source)))))
        (values sources
                (assemble-system-prompt
                 (%s-cwd st) :tools offered :backend (agent:ai-agent-backend agent)
                             :settings settings :user-config-dir (%s-config st)
                             :plan plan :sandbox sandbox
                             :context (%s-context st)
                             :instruction-set (%s-instruction-set st)))))))

(defun %sdk-ensure-plan (session st report)
  "H5a: open (or reopen) the session's plan and give the agent the area's
tools and instructions (as %ENSURE-PLAN); the run is dropped. The plan
\"opened\" / \"reopened\" event, with its \"sandbox\" object (R4d-4b: probed
when the plan opens; failIfUnavailable: the plan does not open). While a plan
is open, a sandbox that refused a command gets unconfined shell tools that
ask (%SDK-REFRESH-PLAN-SHELL)."
  (if (%s-plan st)
      (%sdk-refresh-plan-shell st)
      (let* ((client (code-session-client session))
             (cwd (%s-cwd st))
             (data-dir (%s-data-dir st))
             (store (code-session-store session))
             (entry (%head-plan-entry store))
             (reopened nil)
             (plan (or (and entry (eq :open (getf entry :status))
                            (handler-case (prog1 (reopen-plan (plans-directory cwd :data-dir data-dir)
                                                              (getf entry :id))
                                            (setf reopened t))
                              (plan-not-found () nil)))
                       (open-plan (%s-project-dir st) :kind (%client-plan-area client)
                                                      :data-dir data-dir
                                                      :session-id (session-id store))))
             (agent (%s-agent st))
             (settings (%sdk-plan-settings st))
             (sandbox (handler-bind ((plan-sandbox-unavailable
                                       (lambda (e)
                                         (declare (ignore e))
                                         ;; A fresh plan does not stay open behind it.
                                         (unless reopened (reject-plan plan)))))
                        (open-plan-sandbox plan settings
                                           :backend (%client-plan-backend client)))))
        (multiple-value-bind (sources instructions) (%sdk-plan-agent st plan settings sandbox)
          (setf (%s-cwd-instructions st) (agent:ai-agent-instructions agent)
                (agent:ai-agent-tools agent) sources
                (agent:ai-agent-instructions agent) instructions
                (agent:ai-agent-permissions agent) (%plan-permissions settings sandbox)
                (%s-plan st) plan
                (%s-plan-sources st) sources
                (%s-plan-sandbox st) sandbox
                (%s-run st) nil
                (%s-handle st) nil))
        (apply #'%emit-event report "plan" (%plan-open-keys plan reopened sandbox)))))

(defun %sdk-refresh-plan-shell (st)
  "R4d-4b, at a turn's start: after a refusal, the plan's shell tools again
without the confinement and the rules without the shell allows (bash and
job_input ask; denied with failIfUnavailable); the old sources are closed and
the run is dropped."
  (let ((sandbox (%s-plan-sandbox st))
        (old (%s-plan-sources st)))
    (when (%plan-shell-stale-p sandbox old)
      (let ((settings (%sdk-plan-settings st))
            (agent (%s-agent st)))
        (multiple-value-bind (sources instructions)
            (%sdk-plan-agent st (%s-plan st) settings sandbox)
          (setf (agent:ai-agent-tools agent) sources
                (agent:ai-agent-instructions agent) instructions
                (agent:ai-agent-permissions agent) (%plan-permissions settings sandbox)
                (%s-plan-sources st) sources
                (%s-run st) nil
                (%s-handle st) nil))
        (%close-code-units nil :unit-tools (list (code-unit-tools old))
                               :shell-tools (list (second old)))))))

(defun %restore-cwd-tools (st)
  "H5a: the plan closed: the working directory's tools and instructions
again, the run dropped."
  (let ((agent (%s-agent st))
        (sources (%s-plan-sources st)))
    (setf (agent:ai-agent-tools agent) (%s-sources st))
    (when (%s-cwd-instructions st)
      (setf (agent:ai-agent-instructions agent) (%s-cwd-instructions st)))
    (setf (%s-plan st) nil
          (%s-plan-sources st) nil
          (%s-plan-sandbox st) nil
          (%s-plan-turn-p st) nil
          (%s-run st) nil
          (%s-handle st) nil)
    ;; R4d-4b: the mode's rules, without the plan's sandbox.
    (setf (agent:ai-agent-permissions agent) (%agent-permissions (%s-settings st)))
    ;; H8d: the area's unit tools, then its shell tools (the plan scope's
    ;; units stop with the supervisor).
    (%close-code-units nil :unit-tools (list (code-unit-tools sources))
                           :shell-tools (list (second sources)))))

(defun %start-turn (session prompt mentions on-event &key retry-of)
  "Start a turn. H3f: RETRY-OF (a failed revision id) starts a new run from the
recorded conversation, adding no user turn."
  (let ((st (%live session)))
    (unless (eq :idle (%s-state st))
      (error 'turn-busy :session-id (code-session-id session)))
    (when (or (not (stringp prompt)) (%blank-text-p prompt))
      (error 'code-usage-error :message "no prompt"))
    (dolist (rel mentions)
      (unless (and (stringp rel) (%project-file (%tool-root st) rel))
        (%usage-fail "mention ~a is not a file under the working directory" rel)))
    (let* ((turn (make-instance 'code-turn :session session :prompt prompt))
           (report (%session-report session turn on-event))
           (store (code-session-store session))
           (ok (%sdk-callback session))
           (err (%sdk-error-callback session)))
      ;; H3f
      (setf (%report-window report) (first (%s-window st))
            (%report-secrets report) (%s-secrets st)
            (%report-timeout-ms report) (getf (resilience-settings (%s-settings st))
                                              :turn-timeout-ms)
            (%report-retry-of report) retry-of)
      (when retry-of
        (setf (%s-run st) nil (%s-handle st) nil))
      (setf (%s-turn st) turn
            (%s-report st) report
            (%s-state st) :running
            (%s-interrupted st) nil
            (%s-pending st) '()
            (%s-start st) (get-internal-real-time)
            (%s-plan-turn-p st) nil)
      (handler-case
          (progn
            (when (eq :plan (%s-mode st))
              (%sdk-ensure-plan session st report))
            (setf (%s-plan-turn-p st) (and (%s-plan st) t)
                  (%s-pre st) (handler-case (begin-checkpoint-turn (%s-checkpointer st) store)
                                (error () nil)))
            (let ((text (%prompt-text prompt mentions (%tool-root st)))
                  (run (%s-run st)))
              (if run
                  (progn
                    (setf (%report-run report) run)
                    (%ledger-start report (agent:agent-run-turns run) 0)
                    (%arm-turn-timer report)
                    (setf (%s-handle st) (agent:continue-ai-agent-async run text :callback ok
                                                                                 :error-callback err)))
                  (let ((history (session-turns store))
                        (committed (make-hash-table :test 'eq)))
                    (dolist (old history) (setf (gethash old committed) t))
                    (%ledger-start report history 0)
                    (%arm-turn-timer report)
                    (setf (%s-committed st) committed
                          (%s-usage st) (list 0 0 0 0)
                          (%s-steering st) '()
                          (%s-handle st)
                          (agent:run-ai-agent-async (%s-agent st)
                                                    (if retry-of
                                                        history
                                                        (append history (list (llm:user-turn text))))
                                                    :on-event (%sdk-agent-event session)
                                                    :callback ok :error-callback err))))
              ;; H4b: image events queued while idle follow the prompt.
              (%post-if-going (%sources-lisp-tools (%s-sources st)) (%s-run st))))
        (error (e) (%finish-turn session st (%s-run st) e)))
      turn)))

(defun client-turn (session prompt &key mentions on-event)
  (%on-client-loop ((code-session-client session))
    (%start-turn session prompt mentions on-event)))

;;; H3f: re-sending a failed turn, and compacting an idle session.

(defun client-retry-turn (session)
  "Re-send SESSION's failed last turn from the recorded conversation (no new
user turn). → a CODE-TURN; NOTHING-TO-RETRY when the head did not fail."
  (%on-client-loop ((code-session-client session))
    (let* ((st (%live session))
           (store (code-session-store session)))
      (unless (eq :idle (%s-state st))
        (error 'turn-busy :session-id (code-session-id session)))
      (unless (failed-turn-p store)
        (error 'nothing-to-retry))
      (let ((head (session-head store)))
        (%start-turn session (record-prompt (revision-record head)) nil nil
                     :retry-of (rev:revision-id head))))))

(defun client-compact (session &key instructions)
  "Compact SESSION's conversation now (idle only; busy → TURN-BUSY). The
compaction is recorded as an idle /compact record. → the compact event
object, or NIL when nothing was compacted."
  (check-type instructions (or null string))
  (let ((client (code-session-client session)))
    (when (%loop-thread-p client)
      (error 'code-usage-error :message "CLIENT-COMPACT cannot run on the client's loop thread"))
    (let ((lock (bt:make-lock "client compact"))
          (cv (bt:make-condition-variable))
          (box nil))
      (flet ((done (value)
               (bt:with-lock-held (lock)
                 (setf box (or value (list :none)))
                 (bt:condition-notify cv))))
        (%on-client-loop (client)
          (let ((st (%live session)))
            (unless (eq :idle (%s-state st))
              (error 'turn-busy :session-id (code-session-id session)))
            (let ((run (%s-run st)))
              (if (null run)
                  (done nil)
                  (let ((report (%session-report session)))
                    (%ledger-start report (agent:agent-run-turns run) 0)
                    (setf (%report-run report) run
                          (%report-window report) (first (%s-window st))
                          (%s-report st) report
                          (%s-state st) :compacting)
                    (flet ((finish (value)
                             (setf (%s-state st) :idle
                                   (%s-report st) nil)
                             (done value)))
                      (handler-case
                          (agent:compact-agent-run
                           run :instructions instructions
                               :callback
                               (lambda (did)
                                 (finish
                                  (handler-case
                                      (let ((marker (first (%report-markers report))))
                                        (when (and did marker)
                                          (%commit-session-compaction session st marker)
                                          (list :event (compact-event-object
                                                        (list :reason :manual
                                                              :before (%compact-payload-before report)
                                                              :after (length (agent:agent-run-turns run))
                                                              :tokens-before (getf marker :tokens-before)
                                                              :context-window (first (%s-window st)))))))
                                    (error (e) (list :error e)))))
                               :error-callback (lambda (e) (finish (list :error e))))
                        (error (e) (finish (list :error e))))))))))
        (bt:with-lock-held (lock)
          (loop until box do (bt:condition-wait cv lock :timeout 0.2)))
        (case (first box)
          (:event (second box))
          (:error (let ((e (second box)))
                    ;; "no compaction memory" or "run is busy": nothing compacted.
                    (if (typep e 'agent:agent-condition) nil (error e))))
          (t nil))))))

(defun %compact-payload-before (report)
  (getf (%report-last-compaction report) :before))

(defun %commit-session-compaction (session st marker)
  "Loop thread: commit the idle /compact record of MARKER."
  (let ((old (code-session-store session)))
    (multiple-value-bind (revision store)
        (commit-compaction-record old marker
                                  :model (%s-designator st)
                                  :permission-mode (%s-mode st)
                                  :instructions (let ((set (%s-instruction-set st)))
                                                  (and set (instruction-set-current set))))
      (unless (eq store old)
        (%rehome-instruction-set (%s-instruction-set st) store)
        (setf (code-session-store session) store
              (code-session-id session) (session-id store)))
      revision)))

(defun client-wait (turn &key timeout)
  (let ((client (code-session-client (code-turn-session turn))))
    (when (%loop-thread-p client)
      (error 'code-usage-error :message "CLIENT-WAIT cannot run on the client's loop thread"))
    (let ((deadline (and timeout
                         (+ (get-internal-real-time)
                            (round (* timeout internal-time-units-per-second))))))
      (bt:with-lock-held ((%turn-lock turn))
        (loop
          (let ((result (%turn-result turn)))
            (when result (return result)))
          (let ((left (and deadline
                           (/ (- deadline (get-internal-real-time))
                              internal-time-units-per-second))))
            (when (and left (<= left 0))
              (return nil))
            (bt:condition-wait (%turn-done turn) (%turn-lock turn)
                               :timeout (if left (min left 0.1) 0.1))))))))

(defun client-query (session prompt &key mentions on-event timeout)
  (when (%loop-thread-p (code-session-client session))
    (error 'code-usage-error :message "CLIENT-QUERY cannot run on the client's loop thread"))
  (let* ((turn (client-turn session prompt :mentions mentions :on-event on-event))
         (result (client-wait turn :timeout timeout)))
    (unless result
      (client-interrupt session)
      (setf result (client-wait turn)))
    (values result (code-turn-events turn))))

(defun client-steer (session text)
  (%on-client-loop ((code-session-client session))
    (let ((st (%live session)))
      (unless (and (eq :running (%s-state st)) (%s-run st))
        (error 'turn-not-running :session-id (code-session-id session)))
      (let ((turn (llm:user-turn (expand-mentions text (%tool-root st)))))
        (setf (%s-posted st) (append (%s-posted st) (list (cons turn text))))
        (agent:agent-run-post (%s-run st) turn)
        t))))

(defun %foreground-shell-units (st)
  "ACP-2: the live units of SESSION's running foreground bash commands: the
:shell-job units of its shell tools' scopes (working directory and plan area)
that are not registered background jobs."
  (loop for shell in (list (second (%s-sources st)) (second (%s-plan-sources st)))
        for scope = (and (tools:shell-tools-p shell) (tools:shell-tools-scope shell))
        when scope
          append (let ((jobs (remove nil (mapcar #'tools:shell-job-unit
                                                 (tools:shell-tools-jobs shell)))))
                   (remove-if (lambda (u)
                                (or (sup:unit-finished-p u)
                                    (not (eq :shell-job (sup:unit-kind u)))
                                    (member u jobs :test #'eq)))
                              (sup:scope-units scope)))))

(defparameter +interrupt-shell-watch-seconds+ 60
  "How long an interrupt keeps stopping the turn's foreground bash commands.")

(defun %stop-foreground-shell (st)
  "ACP-2: an interrupt stops the running foreground bash commands, so the
cancelled run gets its tool result now instead of when the command ends. A
call the run had already launched may start its command just after the
interrupt, so a watcher thread stops each foreground command it sees until the
interrupted turn has ended (bounded). SUP:STOP-UNIT waits, so this never runs
on the loop thread. The watcher only reads the session's state."
  (let ((turn (%s-turn st)))
    (when turn
      (bt:make-thread
       (lambda ()
         (loop with deadline = (+ (get-internal-real-time)
                                  (* +interrupt-shell-watch-seconds+ internal-time-units-per-second))
               while (and (eq turn (%s-turn st)) (not (code-turn-done-p turn))
                          (< (get-internal-real-time) deadline))
               do (dolist (u (handler-case (%foreground-shell-units st)
                               (error () nil)))
                    (handler-case (sup:stop-unit u :grace 1)
                      (error () nil)))
                  (sleep 0.1)))
       :name "cl-stack-code interrupt"))))

(defun %interrupt (st session)
  "Loop thread. → T when a turn was running or waiting."
  (case (%s-state st)
    (:running
     (setf (%s-interrupted st) t)
     (let ((target (or (%s-run st) (%s-handle st))))
       (when target (agent:cancel-agent-run target)))
     (%stop-foreground-shell st)
     t)
    (:waiting
     (setf (%s-interrupted st) t)
     (%finish-turn session st (%s-run st) nil)
     t)
    (t nil)))

(defun client-interrupt (session)
  (%on-client-loop ((code-session-client session))
    (%interrupt (%live session) session)))

;;; ACP-2: the permission mode of an open session, and its record.

(defun client-set-permission-mode (session mode)
  (%on-client-loop ((code-session-client session))
    (let ((st (%live session)))
      (permission-mode-name mode)        ; another keyword → CODE-USAGE-ERROR
      (%check-idle session st)
      (let* ((mode (or mode :default))
             (settings (merge-settings (%s-settings st) (make-settings :permission-mode mode)))
             (agent (%s-agent st)))
        (when (settings-lisp-image settings)
          (check-lisp-image-settings settings mode))
        ;; Leaving plan mode: the working directory's tools again; the plan
        ;; stays open on disk (the next plan-mode turn reopens it).
        (when (and (%s-plan st) (not (eq mode :plan)))
          (%restore-cwd-tools st))
        (setf (%s-settings st) settings
              (%s-mode st) mode
              (code-session-permission-mode session) mode
              (agent:ai-agent-settings agent) (%agent-settings (%s-cwd st) settings
                                                               :discovery (%s-discovery st)
                                                               :backend (agent:ai-agent-backend agent)
                                                               :designator (%s-designator st))
              ;; The next turn starts a new run on SESSION-TURNS.
              (%s-run st) nil
              (%s-handle st) nil)
        (unless (%s-plan st)
          (setf (agent:ai-agent-permissions agent) (%agent-permissions settings)))
        mode))))

(defun client-export-session (session &key (format :json))
  (%on-client-loop ((code-session-client session))
    (%live session)
    (with-output-to-string (s)
      (export-session (code-session-store session) s :format format))))

;;; Approvals.

(defun %offer-approvals (session st run)
  "The run paused: one approval_request per :proposed call, then ON-APPROVAL."
  (setf (%s-state st) :waiting)
  (let ((client (code-session-client session)))
    (dolist (inv (copy-list (%proposed run)))
      (when (and (%proposed-p inv) (eq :waiting (%s-state st)) (eq run (%s-run st)))
        (let* ((report (%s-report st))
               (id (agent:agent-invocation-id inv))
               (name (agent:agent-invocation-name inv))
               (input (%tool-input (agent:agent-invocation-arguments inv)))
               (request (%emit-event report "approval_request"
                                     "step" (gethash id (%report-call-steps report)
                                                     (%report-step report))
                                     "id" id
                                     "name" name
                                     "input" input
                                     "summary" (tool-call-summary name input)
                                     "preview" (or (tool-call-preview (%tool-root st) name input)
                                                   :null))))
          (setf (%s-pending st) (append (%s-pending st) (list (cons inv request))))
          (let ((f (%client-on-approval client)))
            (when f
              (let ((decision (handler-case (funcall f session request)
                                (error () nil))))
                (when decision
                  (handler-case (%respond session st id decision nil)
                    (error () nil)))))))))))

(defun %decision (decision feedback)
  "→ (values kind feedback) of a decision; another → CODE-USAGE-ERROR."
  (cond ((member decision '(:once :always :reject :reject-all)) (values decision feedback))
        ((and (consp decision) (eq :reject (first decision))
              (or (null (rest decision)) (stringp (second decision))))
         (values :reject (or (second decision) feedback)))
        (t (%usage-fail "bad approval decision ~s: use :once, :always, :reject, (:reject FEEDBACK) or :reject-all"
                        decision))))

(defun %resolve (st entry decision)
  "One approval_resolved event; ENTRY leaves the pending list."
  (%emit-event (%s-report st) "approval_resolved"
               "id" (agent:agent-invocation-id (car entry))
               "decision" decision)
  (setf (%s-pending st) (remove entry (%s-pending st) :test #'eq)))

(defun %respond (session st id decision feedback)
  (multiple-value-bind (kind feedback) (%decision decision feedback)
    (let ((entry (find id (%s-pending st) :key (lambda (e) (agent:agent-invocation-id (car e)))
                                          :test #'equal))
          (run (%s-run st))
          (feedback (and (stringp feedback) (not (%blank-text-p feedback)) feedback))
          (resolved '()))
      (unless (and entry run (eq :waiting (%s-state st)))
        (error 'approval-not-found :id id))
      (ecase kind
        (:once
         (%resolve st entry "once")
         (push id resolved)
         (%approve-once run (car entry)))
        (:always
         (%resolve st entry "always")
         (push id resolved)
         (handler-case (agent:approve-invocation run (car entry) :always t)
           (settings-error ()
             ;; The rule could not be saved; the call is still approved once.
             (%approve-once run (car entry))))
         ;; The other waiting calls the rule covers were approved with it.
         (dolist (other (copy-list (%s-pending st)))
           (unless (%proposed-p (car other))
             (%resolve st other "always")
             (push (agent:agent-invocation-id (car other)) resolved))))
        (:reject
         (%resolve st entry "reject")
         (push id resolved)
         (agent:deny-invocation run (car entry) :feedback feedback)
         (%push-denial (%s-report st) (car entry) "rejected"))
        (:reject-all
         (let ((all (copy-list (%s-pending st))))
           (dolist (other all)
             (%resolve st other "reject_all")
             (push (agent:agent-invocation-id (car other)) resolved))
           (dolist (other all)
             (when (%proposed-p (car other))
               (agent:deny-invocation run (car other) :feedback feedback))
             (%push-denial (%s-report st) (car other) "rejected"))
           (dolist (inv (%proposed run))
             (agent:deny-invocation run inv :feedback feedback)))))
      (%maybe-resume-run session st)
      (nreverse resolved))))

(defun %approve-once (run inv)
  (when (%proposed-p inv)
    (agent:approve-invocation run inv)))

(defun %maybe-resume-run (session st)
  "Resume the paused run when none of its calls waits any more."
  (let ((run (%s-run st)))
    (when (and run (eq :waiting (%s-state st))
               (notany #'%proposed-p (agent:agent-run-invocations run)))
      (setf (%s-state st) :running
            (%s-pending st) '())
      (handler-case
          (setf (%s-handle st)
                (agent:resume-ai-agent-async run :callback (%sdk-callback session)
                                                 :error-callback (%sdk-error-callback session)))
        (error (e) (%finish-turn session st run e))))))

(defun client-pending-approvals (session)
  (%on-client-loop ((code-session-client session))
    (mapcar #'cdr (%s-pending (%live session)))))

(defun client-respond-approval (session id decision &key feedback)
  (%on-client-loop ((code-session-client session))
    (%respond session (%live session) id decision feedback)))

;;; The end of a turn.

(defun %sdk-commit (session st run report finish)
  "Commit RUN's turns since the last commit (as %COMMIT-RUN); a conflict
forks the session (the \"session\" \"forked\" event). → (values revision
store) or NIL."
  (let* ((committed (%s-committed st))
         (in-flight (agent:agent-run-in-flight-turn run))
         (new (remove-if (lambda (turn)
                           (or (eq :system (llm:llm-turn-role turn)) (gethash turn committed)
                               ;; H3f: the partial turn of a failed step
                               (eq turn in-flight)))
                         (agent:agent-run-turns run))))
    (setf (%s-usage st) (mapcar #'+ (%s-usage st) (%report-usage report)))
    (when (or new (%report-markers report))
      (handler-case
          (let* ((old (code-session-store session))
                 (plan (%s-plan st))
                 (record (make-turn-record :prompt (code-turn-prompt (%s-turn st))
                                           :turns new
                                           :finish finish
                                           :model (%s-designator st)
                                           :permission-mode (or (%s-mode st) :default)
                                           :usage (copy-list (%s-usage st))
                                           :steering (copy-list (%s-steering st))
                                           :plan (and plan (%s-plan-turn-p st)
                                                      (plan-record plan))
                                           ;; H3e-1
                                           :instructions (let ((set (%s-instruction-set st)))
                                                           (and set (instruction-set-current set)))
                                           ;; H3f
                                           :compactions (reverse (%report-markers report))
                                           :retry-of (%report-retry-of report))))
            (multiple-value-bind (revision store) (%commit-forking old record)
              (dolist (turn new) (setf (gethash turn committed) t))
              (setf (%s-usage st) (list 0 0 0 0)
                    (%s-steering st) '())
              (unless (eq store old)
                ;; H3e-1: the set's revisions go to the clone from now on.
                (%rehome-instruction-set (%s-instruction-set st) store)
                (setf (code-session-store session) store
                      (code-session-id session) (session-id store)
                      (%report-session report) (session-id store))
                (%emit-event report "session" "subtype" "forked" "from" (session-id old)))
              (values revision store)))
        ;; Any other commit error: the turns go into the next commit (TUI).
        (error () nil)))))

(defun %finish-turn (session st run failure)
  "Loop thread, once per turn: deny calls left waiting, drain the steering
(\"dropped\"), the plan projection, commit, END-CHECKPOINT-TURN, then the
result; then the session is idle and CLIENT-WAIT answers."
  (when (member (%s-state st) '(:idle :ending))
    (return-from %finish-turn nil))
  (setf (%s-state st) :ending)
  (%disarm-turn-timer (%s-report st))
  (let* ((report (%s-report st))
         (turn (%s-turn st))
         (failure (or (%report-failure report) failure))
         (interrupted (%s-interrupted st))
         (reason (and run (agent:agent-run-finish-reason run)))
         (paused (member reason '(:approval :deferred)))
         (result nil))
    ;; A paused run that ends here: its waiting calls are refused, and the
    ;; run is not continued (the next turn starts a new one).
    (when paused
      (dolist (entry (copy-list (%s-pending st)))
        (%resolve st entry "interrupt")
        (when (%proposed-p (car entry))
          (agent:deny-invocation run (car entry) :reason "interrupted"))
        (%push-denial report (car entry) "rejected"))
      (dolist (inv (%proposed run))
        (agent:deny-invocation run inv :reason "interrupted")))
    (when run
      (agent:drain-agent-run-inbox run))
    (let ((dropped (mapcar #'cdr (shiftf (%s-posted st) '()))))
      (when dropped
        (%emit-event report "steering" "subtype" "dropped" "texts" (coerce dropped 'vector))))
    ;; H5a
    (when (and (%s-plan-turn-p st) (%s-plan st))
      (let ((plan (%s-plan st)))
        (if (and run (not failure) (not interrupted)
                 (not (member reason '(:canceled :approval :deferred))))
            (%headless-plan-finish report plan (make-instance 'invocation :settings (make-settings))
                                   run nil nil (make-broadcast-stream))
            (setf (%report-plan report)
                  (%plan-object plan :open (plan-changes plan) (plan-diff-text plan) '())))))
    (multiple-value-bind (revision store)
        (and run (%sdk-commit session st run report
                              (%run-finish run (or failure (%report-timeout report)) interrupted)))
      (let ((pre (shiftf (%s-pre st) nil)))
        (when (and revision pre)
          (handler-case (end-checkpoint-turn (%s-checkpointer st) store pre revision)
            (error () nil)))))
    (when paused
      (setf (%s-run st) nil (%s-handle st) nil))
    (multiple-value-bind (subtype condition)
        (%turn-outcome report run failure interrupted (%s-max-turns st))
      ;; H3f: after a model failure or a timeout the next turn starts from the
      ;; recorded conversation, never from a run holding a half step.
      (when (typep condition '(or model-error turn-timeout))
        (setf (%s-run st) nil (%s-handle st) nil))
      (setf result (%result-object report subtype
                                   (if (and run (not failure) (not (%report-timeout report)))
                                       (%trim-answer (agent:agent-run-text run))
                                       "")
                                   (and condition (princ-to-string condition))
                                   (round (* 1000 (- (get-internal-real-time) (%s-start st)))
                                          internal-time-units-per-second)
                                   condition))
      (funcall (%report-sink report) result))
    (setf (%s-state st) :idle
          (%s-turn st) nil
          (%s-report st) nil
          (%s-interrupted st) nil
          (%s-pending st) '())
    (when (%s-close-pending st)
      (setf (%s-close-pending st) nil)
      (%close-session-resources st))
    (bt:with-lock-held ((%turn-lock turn))
      (setf (%turn-result turn) result)
      ;; Every waiter wakes within its 0.1 s poll; one at once.
      (bt:condition-notify (%turn-done turn)))
    result))

;;; H4b: image events.

(defun %sdk-image-event (session event)
  "Loop thread: an image event of SESSION's image. During a turn it goes into
the turn (posted into the run); while idle it is delivered at once and stays
queued for the next turn."
  (let ((st (%session-state session)))
    (unless (or (null st) (%s-closed st))
      (%headless-image-event (or (%s-report st) (%session-report session)) event))))

;;; Plans, checkpoints, rewinds.

(defun %check-idle (session st)
  (unless (eq :idle (%s-state st))
    (error 'turn-busy :session-id (code-session-id session))))

(defun %open-plan-of (session st)
  (or (%s-plan st)
      (error 'plan-not-found
             :message (format nil "session ~a has no open plan" (code-session-id session)))))

(defun client-approve-plan (session &key (on-drift :abort))
  (%on-client-loop ((code-session-client session))
    (let ((st (%live session)))
      (%check-idle session st)
      (let* ((plan (%open-plan-of session st))
             (report (%session-report session))
             (store (code-session-store session)))
        (multiple-value-bind (status result event)
            (%headless-approve report plan
                               (make-instance 'invocation :on-drift on-drift
                                                          :settings (make-settings))
                               (%s-checkpointer st))
          (declare (ignore result))
          (let ((pre (%report-plan-pre report)))
            (when pre
              (handler-case (record-plan-checkpoints (%s-checkpointer st) store pre
                                                     (session-head store))
                (error () nil))))
          (when (member status '(:applied :empty))
            (%restore-cwd-tools st))
          event)))))

(defun client-reject-plan (session)
  (%on-client-loop ((code-session-client session))
    (let ((st (%live session)))
      (%check-idle session st)
      (let ((plan (%open-plan-of session st)))
        (reject-plan plan)
        (prog1 (%emit-event (%session-report session) "plan" "subtype" "discarded"
                            "plan_id" (plan-id plan))
          (%restore-cwd-tools st))))))

(defun %checkpoint-object (k)
  (%json-object "id" (checkpoint-id k)
                "ordinal" (checkpoint-ordinal k)
                "reason" (%change-kind-name (checkpoint-reason k))
                "turn" (checkpoint-turn k)
                "files_kind" (%keyword-name (checkpoint-files-kind k))
                "message" (checkpoint-message k)
                "recorded_at" (let ((at (checkpoint-recorded-at k)))
                                (if at (dt:instant-seconds at) :null))
                "expired" (and (checkpoint-expired-p k) t)))

(defun client-checkpoints (session)
  (%on-client-loop ((code-session-client session))
    (%live session)
    (mapcar #'%checkpoint-object
            (reverse (session-checkpoints (code-session-store session))))))

(defun %sdk-follow-head (session st)
  "H3e-1: restore the instruction set to the session's head and render the
working directory's system prompt from it."
  (when (%follow-head (%s-instruction-set st) (code-session-store session))
    (let ((prompt (and (%s-render st) (funcall (%s-render st)))))
      (when prompt
        (if (%s-plan st)
            (setf (%s-cwd-instructions st) prompt)
            (setf (agent:ai-agent-instructions (%s-agent st)) prompt))))))

(defun client-rewind (session turn &key (mode :both) (on-drift :abort))
  (%on-client-loop ((code-session-client session))
    (let ((st (%live session)))
      (%check-idle session st)
      (let* ((at (if (integerp turn) (princ-to-string turn) turn))
             (result (handler-bind ((plan-drift
                                      (lambda (c)
                                        (invoke-restart
                                         (find-restart (ecase on-drift
                                                         (:abort 'abort-approval)
                                                         (:rebase 'rebase-plan)
                                                         (:overwrite 'overwrite-plan))
                                                       c)))))
                       (rewind-to (%s-checkpointer st) (code-session-store session) at
                                  :parts (%rewind-parts mode)))))
        ;; The next turn starts a new run on the new head.
        (when (eq :moved (getf result :conversation))
          (setf (%s-run st) nil (%s-handle st) nil)
          ;; H3e-1: the instruction set follows the head.
          (%sdk-follow-head session st))
        (apply #'%emit-event (%session-report session) "rewind" (%rewind-keys result))))))

;;; Introspection.

(defun %image-designator-name (image)
  (ecase (first image)
    (:off "off")
    (:spawn "spawn")
    (:attach (format nil "attach:~a:~d" (second image) (third image)))))

(defun %settings-object (settings)
  "{\"settings\": S, \"files\": [...]} (see the header)."
  (let ((mode (settings-permission-mode settings))
        (append-prompt (settings-append-system-prompt settings)))
    (flet ((rules (list) (map 'vector #'format-permission-rule list)))
      (%json-object
       "settings"
       (%json-object
        "model" (or (settings-model settings) :null)
        "maxTurns" (or (settings-max-turns settings) :null)
        "permissionMode" (if mode (permission-mode-name mode) :null)
        "permissions" (%json-object "allow" (rules (settings-allow settings))
                                    "ask" (rules (settings-ask settings))
                                    "deny" (rules (settings-deny settings)))
        "env" (coerce (sort (remove-duplicates
                             (loop for (name . value) in (settings-env settings)
                                   when value collect name)
                             :test #'string=)
                            #'string<)
                      'vector)
        "appendSystemPrompt" (or append-prompt :null)
        "checkpoints" (multiple-value-bind (enabled keep kind) (checkpoint-settings settings)
                        (%json-object "enabled" (and enabled t) "keep" keep
                                      "kind" (%keyword-name kind)))
        "lispImage" (multiple-value-bind (image backend observe on-debugger)
                        (lisp-image-settings settings)
                      (%json-object "image" (%image-designator-name image)
                                    "backend" backend
                                    "observe" (and observe t)
                                    "onDebugger" (%keyword-name on-debugger))))
       "files" (map 'vector #'uiop:native-namestring (settings-files settings))))))

(defun %client-settings-at (client cwd)
  "CLIENT-SETTINGS of the directory CWD (relative to the client's)."
  (%on-client-loop (client)
    (%settings-object (%merged-settings client (%session-dir client cwd)))))

(defun client-settings (session-or-client)
  (etypecase session-or-client
    (code-session
     (%on-client-loop ((code-session-client session-or-client))
       (%settings-object (%s-settings (%live session-or-client)))))
    (code-client (%client-settings-at session-or-client nil))))

(defun client-tools (session)
  (%on-client-loop ((code-session-client session))
    (let ((st (%live session)))
      (loop for source in (agent:ai-agent-tools (%s-agent st))
            append (mapcar (lambda (tool)
                             (let ((schema (llm:llm-tool-parameters tool)))
                               (%json-object "name" (llm:llm-tool-name tool)
                                             "description" (or (llm:llm-tool-description tool) "")
                                             "input_schema"
                                             (cond ((hash-table-p schema) schema)
                                                   ((stringp schema)
                                                    (let ((v (handler-case (json:decode schema)
                                                               (error () nil))))
                                                      (if (hash-table-p v) v (%json-object))))
                                                   (t (%json-object))))))
                           (agent:list-agent-tools source))))))

;;; H8d: units (src/units.lisp). The file header's "H8d" part has the
;;; rules.
;;;
;;;   Sessions         %OPEN-CODE-SESSION makes the session's supervisor
;;;                    (MAKE-CODE-SUPERVISOR on the session's working directory
;;;                    and the client's data directory) before the tools and
;;;                    passes it to MAKE-CODE-TOOLS (plan tools too, as the
;;;                    program does); a configuration error shuts it down.
;;;                    CLIENT-CLOSE-SESSION ends its subscriptions, closes the
;;;                    unit tools and the shell tools and shuts it down.
;;;   CODE-SESSION-SUPERVISOR session → its SUP:SUPERVISOR.
;;;   CODE-SESSION-UNIT-TOOLS session → its UNIT-TOOLS (CODE-UNIT-TOOLS).
;;;   CLIENT-UNITS session &key KIND STATE OWNER RESOURCES → UNIT-OBJECTS of
;;;     the supervisor (KIND, STATE, OWNER as UNIT-OBJECTS takes them, strings
;;;     from --rpc; a bad one → CODE-USAGE-ERROR). RESOURCES: take a
;;;     SAMPLE-UNIT-RESOURCES now; cpu_percent from the session's previous
;;;     sample (NIL the first time).
;;;   CLIENT-SUBSCRIBE-UNITS session &key SINCE → (values ID SEQ COMPLETE):
;;;     SUP:SUBSCRIBE (SINCE as given, else from SUP:SUPERVISOR-LAST-SEQ); ID
;;;     "sub-<n>" (n per session, from 1); every event becomes a
;;;     UNIT-EVENT-OBJECT with that subscription and the session id, delivered
;;;     to the client's ON-EVENT on the loop thread in seq order, each once.
;;;     COMPLETE: SUP:EVENTS-SINCE's complete-p for SINCE (T without SINCE).
;;;   CLIENT-UNSUBSCRIBE-UNITS session id → T; an unknown or ended id →
;;;     SUBSCRIPTION-NOT-FOUND.
;;;   CLIENT-READ-UNIT session &key UNIT REF START-LINE LIMIT TAIL STREAMS →
;;;     {"unit","status","records","gaps","next_line","last_line","ended",
;;;     "memory"}: exactly one of UNIT / REF (else CODE-USAGE-ERROR). REF
;;;     "<unit>:<segment>:<line>" → start = line − 10, limit 40; UNIT → start
;;;     1, limit 200; START-LINE / LIMIT (1..2000) override; TAIL N → the last
;;;     N output lines (SUP:LOG-TAIL; START-LINE ignored). Records are output
;;;     records of STREAMS (default both; :stdout :stderr or "stdout"
;;;     "stderr"). next_line = SUP:LOG-READ's next line, last_line =
;;;     SUP:LOG-LAST-LINE, ended = SUP:LOG-CLOSED-P and nothing after,
;;;     memory = null. Without a log file: records [], gaps [], next_line and
;;;     last_line null, memory = SUP:UNIT-OUTPUT. Unknown unit →
;;;     UNIT-NOT-FOUND.
;;;   CLIENT-SEARCH-UNITS session query &key UNITS KINDS STREAMS SINCE UNTIL
;;;     K CONTEXT → {"hits": [...], "total": N}: SS:SEARCH-LOGS on the unit
;;;     tools' index (UNITS ids or globs; KINDS names of +UNIT-SEARCH-KINDS+;
;;;     SINCE / UNTIL as TOOLS:PARSE-TIME-ARGUMENT reads them; K 1..50, default
;;;     10; CONTEXT 0..10, default 2). Hit object: {"ref", "unit" (the hit
;;;     key), "segment", "line", "stream", "time" (RFC 3339 ms), "kinds"
;;;     [names], "score" (number or null), "text", "extent" [first, last] or
;;;     null, "excerpt" [UNIT-RECORD-OBJECTs of SS:HIT-EXCERPT with CONTEXT],
;;;     "gaps" [UNIT-GAP-OBJECTs]}. A bad argument (K or CONTEXT out of range, an
;;;     unknown kind or stream, a bad time, a blank QUERY without KINDS) →
;;;     CODE-USAGE-ERROR.
;;;   CLIENT-CONTROL-UNIT session unit action &key INPUT CONFIRMED →
;;;     {"result": text, "unit": UNIT-OBJECT}: UNIT-ACTION-PERMISSION with the
;;;     session's agent, unit tools and mode; :deny → UNIT-CONTROL-DENIED
;;;     (rule as FORMAT-PERMISSION-RULE); :ask and not CONFIRMED →
;;;     UNIT-CONTROL-NEEDS-CONFIRMATION (resource), nothing done; otherwise
;;;     TOOLS:CALL-UNIT-TOOL "unit_control" (UNIT-CONTROL-ARGUMENTS) off the
;;;     loop thread; a TOOLS:UNIT-NOT-FOUND → UNIT-NOT-FOUND; another
;;;     TOOL-FAILURE → UNIT-CONTROL-FAILED with its message. An action not in
;;;     +UNIT-RPC-ACTIONS+ → CODE-USAGE-ERROR.

(defun code-session-supervisor (session)
  "H8d: SESSION's supervisor."
  (let ((st (%session-state session)))
    (and st (%s-supervisor st))))

(defun code-session-unit-tools (session)
  "H8d: SESSION's unit tools."
  (let ((st (%session-state session)))
    (and st (%s-unit-tools st))))

(defun %session-units (session)
  "→ (values supervisor unit-tools state agent mode) of open SESSION, read on
the loop thread (SESSION-NOT-OPEN once closed)."
  (%on-client-loop ((code-session-client session))
    (let ((st (%live session)))
      (values (%s-supervisor st) (%s-unit-tools st) st (%s-agent st) (%s-mode st)))))

(defun client-units (session &key kind state owner resources)
  (multiple-value-bind (sup ut st) (%session-units session)
    (declare (ignore ut))
    ;; The checks first (UNIT-OBJECTS signals them again, the same way).
    (%state-filter state)
    (if resources
        ;; The OS call runs on the caller's thread, never the loop thread.
        (let* ((sample (sample-unit-resources (sup:supervisor-units sup)))
               (time (get-internal-real-time))
               (cpu (bt:with-lock-held ((%s-units-lock st))
                      (let ((previous (%s-prev-sample st))
                            (then (%s-prev-sample-time st)))
                        (setf (%s-prev-sample st) sample
                              (%s-prev-sample-time st) time)
                        (and previous
                             (%cpu-table previous sample
                                         (/ (- time then) internal-time-units-per-second)))))))
          (unit-objects sup :kind kind :state state :owner owner :stats sample :cpu cpu))
        (unit-objects sup :kind kind :state state :owner owner))))

(defun client-subscribe-units (session &key since)
  (unless (or (null since) (typep since '(integer 0)))
    (%usage-fail "since must be an integer >= 0: not ~s" since))
  (let ((client (code-session-client session)))
    (%on-client-loop (client)
      (let* ((st (%live session))
             (sup (%s-supervisor st))
             (eb (%client-event-backend client))
             (el (%client-event-loop client))
             (id (format nil "sub-~d" (incf (%s-unit-sub-counter st))))
             (entry (list id nil))
             (seq (sup:supervisor-last-seq sup))
             (complete (if since (nth-value 1 (sup:events-since sup since)) t)))
        ;; The callback runs on the supervisor's dispatcher thread (in seq
        ;; order, replay first): it only hands the event to the loop thread,
        ;; whose wake queue is FIFO. Without SINCE the replay starts after
        ;; SEQ, so nothing between reading SEQ and subscribing is lost.
        (setf (second entry)
              (sup:subscribe sup
                             (lambda (event)
                               (handler-case
                                   (event:wake-call
                                    eb el
                                    (lambda ()
                                      (when (member entry (%s-unit-subs st) :test #'eq)
                                        (%deliver session
                                                  (unit-event-object event
                                                                     :subscription id
                                                                     :session-id (code-session-id session))
                                                  nil))))
                                 ;; The loop is closing: nobody to deliver to.
                                 (error () nil)))
                             :since (or since seq)))
        (setf (%s-unit-subs st) (append (%s-unit-subs st) (list entry)))
        (values id seq complete)))))

(defun client-unsubscribe-units (session id)
  (%on-client-loop ((code-session-client session))
    (let* ((st (%live session))
           (entry (find id (%s-unit-subs st) :key #'first :test #'equal)))
      (unless entry
        (error 'subscription-not-found :id id))
      (setf (%s-unit-subs st) (remove entry (%s-unit-subs st) :test #'eq))
      (sup:unsubscribe (second entry))
      t)))

(defun %stream-keywords (streams)
  "STREAMS (NIL, or :stdout / :stderr / \"stdout\" / \"stderr\") → keywords;
another → CODE-USAGE-ERROR."
  (if (null streams)
      '(:stdout :stderr)
      (mapcar (lambda (s)
                (cond ((member s '(:stdout :stderr)) s)
                      ((equal s "stdout") :stdout)
                      ((equal s "stderr") :stderr)
                      (t (%usage-fail "streams must be stdout or stderr: not ~s" s))))
              (coerce streams 'list))))

(defun %check-range (name value low high)
  (unless (or (null value) (and (integerp value) (<= low value high)))
    (%usage-fail "~a must be an integer from ~d to ~d: not ~s" name low high value))
  value)

(defun client-read-unit (session &key unit ref start-line limit tail streams)
  (when (or (and unit ref) (and (null unit) (null ref)))
    (%usage-fail "give exactly one of unit and ref"))
  (when (and unit (not (stringp unit)))
    (%usage-fail "unit must be a string: not ~s" unit))
  (when (and ref (not (stringp ref)))
    (%usage-fail "ref must be a string: not ~s" ref))
  (%check-range "limit" limit 1 2000)
  (%check-range "tail" tail 1 2000)
  (unless (or (null start-line) (typep start-line '(integer 1)))
    (%usage-fail "start_line must be a positive integer: not ~s" start-line))
  (let ((streams (%stream-keywords streams))
        (sup (%session-units session)))
    (multiple-value-bind (id start count)
        (if ref
            (multiple-value-bind (key segment line) (ss:parse-log-ref ref)
              (declare (ignore segment))
              (unless key
                (%usage-fail "ref must be <unit>:<segment>:<line>: not ~s" ref))
              (values key (max 1 (- line 10)) 40))
            (values unit 1 200))
      (let ((u (sup:find-unit sup id)))
        (unless u
          (error 'unit-not-found :unit id))
        (let ((log (%unit-log-or-nil u)))
          (if (null log)
              (%json-object "unit" id "status" (unit-status-word u)
                            "records" #() "gaps" #()
                            "next_line" :null "last_line" :null
                            "ended" (and (sup:unit-finished-p u) t)
                            "memory" (sup:unit-output u))
              (multiple-value-bind (records gaps next)
                  (if tail
                      (multiple-value-bind (records gaps) (sup:log-tail log tail :streams streams)
                        (values records gaps (1+ (sup:log-last-line log))))
                      (sup:log-read log :start (or start-line start) :limit (or limit count)
                                        :streams streams))
                (let ((last (sup:log-last-line log)))
                  (%json-object "unit" id "status" (unit-status-word u)
                                "records" (map 'vector #'unit-record-object records)
                                "gaps" (map 'vector #'unit-gap-object gaps)
                                "next_line" next
                                "last_line" last
                                "ended" (and (sup:log-closed-p log) (> next last) t)
                                "memory" :null)))))))))

(defun %hit-object (index hit context)
  (multiple-value-bind (records gaps) (ss:hit-excerpt index hit :context context)
    (let ((time (ss:hit-time hit))
          (extent (ss:hit-extent hit))
          (score (ss:hit-score hit))
          (stream (ss:hit-stream hit)))
      (%json-object "ref" (ss:hit-ref hit)
                    "unit" (ss:hit-key hit)
                    "segment" (ss:hit-segment hit)
                    "line" (ss:hit-line hit)
                    "stream" (if stream (%lower stream) :null)
                    "time" (if time (%rfc3339-ms time) :null)
                    "kinds" (map 'vector #'%lower (ss:hit-kinds hit))
                    "score" (if score (float score 1d0) :null)
                    "text" (ss:hit-text hit)
                    "extent" (if extent (vector (car extent) (cdr extent)) :null)
                    "excerpt" (map 'vector #'unit-record-object records)
                    "gaps" (map 'vector #'unit-gap-object gaps)))))

(defun %time-argument (name value)
  (cond ((null value) nil)
        ((stringp value)
         (handler-case (tools:parse-time-argument value)
           (agent:tool-input-error (c)
             (%usage-fail "~a: ~a" name (%message-text c)))))
        (t (%usage-fail "~a must be a string (RFC 3339 or a duration ago): not ~s" name value))))

(defun client-search-units (session query &key units kinds streams since until k context)
  (unless (stringp query)
    (%usage-fail "query must be a string: not ~s" query))
  (%check-range "k" k 1 50)
  (%check-range "context" context 0 10)
  (let* ((k (or k 10))
         (context (or context 2))
         (streams (%stream-keywords streams))
         (kinds (mapcar (lambda (name)
                          (if (and (stringp name) (member name tools:+unit-search-kinds+ :test #'string=))
                              (intern (string-upcase name) :keyword)
                              (%usage-fail "kinds must be among ~{~a~^, ~}: not ~s"
                                           tools:+unit-search-kinds+ name)))
                        (coerce (or kinds '()) 'list)))
         (units (mapcar (lambda (u)
                          (if (and (stringp u) (plusp (length u)))
                              u
                              (%usage-fail "units must be unit ids or globs: not ~s" u)))
                        (coerce (or units '()) 'list)))
         (since (%time-argument "since" since))
         (until (%time-argument "until" until)))
    (multiple-value-bind (terms phrases) (ss:query-terms query)
      (unless (or terms phrases kinds)
        (%usage-fail "query has nothing to search for: give words or kinds")))
    (multiple-value-bind (sup ut) (%session-units session)
      (declare (ignore sup))
      (let ((index (tools:unit-tools-index ut)))
        (multiple-value-bind (hits total)
            (handler-case (ss:search-logs index query :units units :kinds kinds :streams streams
                                                      :since since :until until :k k)
              (ss:search-error (c)
                (%usage-fail "~a" (%message-text c))))
          (%json-object "hits" (map 'vector (lambda (hit) (%hit-object index hit context)) hits)
                        "total" total))))))

(defun %call-unit-control (unit-tools unit action arguments)
  "TOOLS:CALL-UNIT-TOOL \"unit_control\" → its text; the tool's conditions as
the product's (UNIT-NOT-FOUND, UNIT-CONTROL-FAILED)."
  (handler-case (tools:call-unit-tool unit-tools "unit_control" arguments)
    ;; First: TOOLS:UNIT-NOT-FOUND is a TOOL-INPUT-ERROR, so a TOOL-FAILURE.
    (tools:unit-not-found ()
      (error 'unit-not-found :unit unit))
    (agent:tool-failure (c)
      (error 'unit-control-failed :unit unit :action action :message (%message-text c)))
    ;; unit_control hidden by the settings: not an ERROR subtype.
    (agent:agent-unknown-tool (c)
      (error 'unit-control-failed :unit unit :action action :message (%message-text c)))))

(defun client-control-unit (session unit action &key input confirmed)
  (unless (stringp unit)
    (%usage-fail "unit must be a string: not ~s" unit))
  (let ((arguments (unit-control-arguments action unit :input input)))
    (multiple-value-bind (sup ut st agent mode) (%session-units session)
      (declare (ignore st))
      (multiple-value-bind (effect rule resources)
          (unit-action-permission agent ut action unit :input input :mode mode)
        (ecase effect
          (:deny (error 'unit-control-denied :unit unit :action action :rule (%unit-rule-text rule)))
          (:ask (unless confirmed
                  (error 'unit-control-needs-confirmation :unit unit :action action
                                                          :resource (first resources))))
          (:allow nil)))
      ;; The action runs on the caller's thread (stop and restart block);
      ;; called inside a loop-thread callback it runs there.
      (let* ((text (%call-unit-control ut unit action arguments))
             (u (sup:find-unit sup unit)))
        (%json-object "result" text
                      "unit" (if u (unit-object u :depth (%unit-depth u)) :null))))))
