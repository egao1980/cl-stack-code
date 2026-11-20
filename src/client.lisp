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
;;;   CLIENT-RESUME-SESSION client designator &key CWD MODEL PERMISSION-MODE
;;;                         FORK SESSION-ID
;;;     DESIGNATOR: an id, a unique prefix of at least 4 hex characters or a
;;;     UUID (OPEN-SESSION), or :LAST, the project's last session
;;;     (--continue). None → SESSION-NOT-FOUND. A session open in this client
;;;     already → that CODE-SESSION as it is, and no event (unless FORK). FORK:
;;;     CLONE-SESSION at the head, with SESSION-ID (else a random id), opened as
;;;     a new session (--fork-session). The model: MODEL, else the head
;;;     record's, else the settings, else +DEFAULT-MODEL+ (H3c). The init
;;;     event gains "turns" (the length of the head's line); with FORK also
;;;     "forked_from" (the source id).
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
;;;     opened its plan); then, as they happen, text_delta, assistant,
;;;     tool_use, approval_request, approval_resolved, tool_result, steering
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
;;;     turn's result follows as usual.
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
  '("system" "text_delta" "assistant" "tool_use" "tool_result"
    "approval_request" "approval_resolved" "steering" "image_event"
    "plan" "rewind" "session" "result")
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

;;; Stubs.

(defun make-client (&key cwd settings providers user-config-dir data-dir
                         (getenv #'uiop:getenv) on-event on-approval (plan-area :auto))
  (declare (ignore cwd settings providers user-config-dir data-dir getenv on-event
                   on-approval plan-area))
  (%not-implemented 'make-client))

(defun close-client (client)
  (declare (ignore client))
  (%not-implemented 'close-client))

(defun client-sessions (client)
  (declare (ignore client))
  (%not-implemented 'client-sessions))

(defun client-new-session (client &key cwd model permission-mode session-id)
  (declare (ignore client cwd model permission-mode session-id))
  (%not-implemented 'client-new-session))

(defun client-resume-session (client designator &key cwd model permission-mode fork session-id)
  (declare (ignore client designator cwd model permission-mode fork session-id))
  (%not-implemented 'client-resume-session))

(defun client-fork-session (session &key at session-id)
  (declare (ignore session at session-id))
  (%not-implemented 'client-fork-session))

(defun client-close-session (session)
  (declare (ignore session))
  (%not-implemented 'client-close-session))

(defun client-find-session (client id)
  (declare (ignore client id))
  (%not-implemented 'client-find-session))

(defun client-list-sessions (client &key cwd)
  (declare (ignore client cwd))
  (%not-implemented 'client-list-sessions))

(defun client-busy-p (session)
  (declare (ignore session))
  (%not-implemented 'client-busy-p))

(defun client-turn (session prompt &key mentions on-event)
  (declare (ignore session prompt mentions on-event))
  (%not-implemented 'client-turn))

(defun client-wait (turn &key timeout)
  (declare (ignore turn timeout))
  (%not-implemented 'client-wait))

(defun client-query (session prompt &key mentions on-event timeout)
  (declare (ignore session prompt mentions on-event timeout))
  (%not-implemented 'client-query))

(defun client-steer (session text)
  (declare (ignore session text))
  (%not-implemented 'client-steer))

(defun client-interrupt (session)
  (declare (ignore session))
  (%not-implemented 'client-interrupt))

(defun client-pending-approvals (session)
  (declare (ignore session))
  (%not-implemented 'client-pending-approvals))

(defun client-respond-approval (session id decision &key feedback)
  (declare (ignore session id decision feedback))
  (%not-implemented 'client-respond-approval))

(defun client-approve-plan (session &key (on-drift :abort))
  (declare (ignore session on-drift))
  (%not-implemented 'client-approve-plan))

(defun client-reject-plan (session)
  (declare (ignore session))
  (%not-implemented 'client-reject-plan))

(defun client-checkpoints (session)
  (declare (ignore session))
  (%not-implemented 'client-checkpoints))

(defun client-rewind (session turn &key (mode :both) (on-drift :abort))
  (declare (ignore session turn mode on-drift))
  (%not-implemented 'client-rewind))

(defun client-settings (session-or-client)
  (declare (ignore session-or-client))
  (%not-implemented 'client-settings))

(defun client-tools (session)
  (declare (ignore session))
  (%not-implemented 'client-tools))
