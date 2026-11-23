(in-package #:cl-stack-code)

;;; H3e-2a: MCP servers in the harness (brief: cl-stack
;;; docs/capabilities/cl-stack-code.md, "H3e-2 — locked"). Configuration and
;;; trust are src/mcp-config.lisp. Building blocks, none reimplemented here
;;; (the names below are theirs, as published):
;;;   mcp-protocol 0.4.1      MCP-CONNECT / BACKEND-MCP-CONNECT, MCP-INITIALIZE,
;;;                           LIST-ALL-TOOLS, CALL-TOOL :TIMEOUT, the client's
;;;                           handlers (:LOG-HANDLER gets an MCP-LOG-MESSAGE:
;;;                           MCP-LOG-MESSAGE-LEVEL / -DATA; :ON-TOOLS-CHANGED
;;;                           a function of the client, after
;;;                           MCP-CLIENT-TOOLS-GENERATION is bumped),
;;;                           MCP-CLIENT-INSTRUCTIONS, MCP-TIMEOUT, MCP-ERROR
;;;   mcp-backend-stdio 0.3.0 BACKEND-MCP-CONNECT keys :INPUT :OUTPUT (streams)
;;;                           or :COMMAND (argv) :ENV (alist) :ENV-MODE
;;;                           (:MERGE) :DIRECTORY :ERROR-OUTPUT, plus the
;;;                           handlers; CLOSE-STDIO-MCP-CLIENT (EOF to the
;;;                           server; a :COMMAND child reaped),
;;;                           STDIO-MCP-CLIENT-PROCESS
;;;   mcp-backend-streamable-http 0.4.0  BACKEND-MCP-CONNECT keys :URL :HEADERS
;;;                           (alist or hash table of strings), plus the
;;;                           handlers; MCP-TRANSPORT-UNSUPPORTED (a legacy
;;;                           HTTP+SSE server answered; readers -URL,
;;;                           -TRANSPORT, -STATUS)
;;;   ai-agent-protocol 0.15.0  MAKE-PREFIXED-TOOL-SOURCE inner prefix,
;;;                           AGENT-TOOL-OUTPUT (-TEXT -PARTS -STRUCTURED),
;;;                           AGENT-UNKNOWN-TOOL-ERROR
;;;   ai-agent-protocol/mcp 0.2.0  MAKE-MCP-TOOL-SOURCE peer &key CACHE-TOOLS
;;;                           TOOL-ERROR-BEHAVIOR PROCESS-TOOL-CALL TIMEOUT
;;;                           LIST-TIMEOUT (+TOOL-ERROR-BEHAVIORS+ :retry
;;;                           :failed :error), MCP-TOOL-SOURCE-TOOLS,
;;;                           MCP-TOOL-SOURCE-READ-ONLY-P
;;;   supervisor-protocol 0.5.0  START-UNIT … :STDIO :CHANNEL,
;;;                           UNIT-CHANNEL-STREAMS unit → (values input output)
;;;
;;; The manager (one per session: -p run, TUI program, SDK / --rpc session)
;;;   MAKE-MCP-MANAGER configs &key supervisor settings env cwd http-backend
;;;   on-status → an MCP-MANAGER holding one MCP-CONNECTION per config, in
;;;   order, each :PENDING (:DISABLED for a disabled config; :UNSUPPORTED for
;;;   :sse until a backend speaks the legacy HTTP+SSE transport — the error
;;;   text "transport sse is not supported yet"; never a crash).
;;;   START-MCP-SERVERS manager &key (approve (constantly nil)) → the
;;;   connections, once every startable one is :CONNECTED or :FAILED. Each
;;;   config's approval is MCP-SERVER-APPROVAL; :UNAPPROVED ones are offered to
;;;   APPROVE (a function of the connection → T to start it now); otherwise
;;;   they stay :UNAPPROVED (headless) and :REJECTED ones :REJECTED. Every
;;;   started server connects on a thread of its own, all in parallel, each
;;;   bounded by its startup timeout (MCP-TIMEOUTS); one that does not answer
;;;   in time is :FAILED "timed out after N s" and its child is stopped. A
;;;   failure (spawn error, the child exiting, an initialize error, the
;;;   timeout) never signals out: the connection is :FAILED with the text in
;;;   MCP-CONNECTION-ERROR, its tools are absent, the session goes on.
;;;   ON-STATUS (function of the connection) runs after every status change.
;;;   RECONNECT-MCP-SERVER manager &optional name → closes and starts the named
;;;   server again (every :FAILED and :CLOSED one when NAME is NIL; an
;;;   approved :UNAPPROVED one too); an unknown NAME → MCP-SERVER-NOT-FOUND.
;;;   CLOSE-MCP-MANAGER manager: every client closed, every stdio unit stopped
;;;   (the child reaped, as SHUTDOWN-SUPERVISOR does); statuses :CLOSED.
;;;   Idempotent. -p closes it at the end of the run, before the supervisor;
;;;   CLOSE-CODE-PROGRAM and CLIENT-CLOSE-SESSION do too.
;;;   ADD-MCP-SERVERS manager configs → adds and starts (trusted, scope :sdk
;;;   unless set) servers after the session started; a name already present is
;;;   replaced (closed first). ACP-2's session/new and session/load mcpServers
;;;   go here (or CLIENT-NEW-SESSION :MCP-SERVERS before the first turn).
;;;
;;; Transports
;;;   :stdio  a supervised channel unit of the session's supervisor:
;;;             (sup:start-unit supervisor :mcp-server :command argv
;;;                             :owner <scope "mcp" under the root>
;;;                             :labels (list :server NAME) :cwd <cwd>
;;;                             :env <the config's env over the process's>
;;;                             :restart :never :stdio :channel)
;;;           (argv: the command, then the args). :RESTART :NEVER (a channel
;;;           unit's default; a restarted child would have lost its MCP
;;;           session; /mcp reconnect starts a new unit instead). Then
;;;           (sup:unit-channel-streams unit) → (values input output), and
;;;             (mcp-protocol:mcp-connect :backend <a stdio-mcp-backend>
;;;                                       :input input :output output
;;;                                       :log-handler … :on-tools-changed …)
;;;           and MCP-INITIALIZE under the startup timeout. Stderr goes to
;;;           the unit log. It shows in /ps and units/*. The server's
;;;           notifications/message lines go to the same unit log as stderr
;;;           records "[mcp LEVEL] DATA" (the :LOG-HANDLER, from
;;;           MCP-LOG-MESSAGE-LEVEL and MCP-LOG-MESSAGE-DATA). Closing:
;;;           MCP-BACKEND-STDIO:CLOSE-STDIO-MCP-CLIENT (EOF), then the unit is
;;;           stopped and reaped by the supervisor (SUP:STOP-UNIT).
;;;           Without a supervisor (a test may pass NIL) the child runs
;;;           through the backend's :COMMAND argv :ENV alist :ENV-MODE :MERGE
;;;           :DIRECTORY cwd :ERROR-OUTPUT NIL (stderr dropped);
;;;           CLOSE-STDIO-MCP-CLIENT reaps it (STDIO-MCP-CLIENT-PROCESS is the
;;;           handle).
;;;   :http   (mcp-protocol:mcp-connect :backend <a streamable-http-mcp-backend>
;;;                                     :url URL :headers <the config's alist>
;;;                                     :log-handler … :on-tools-changed …),
;;;           with HTTP-BACKEND (the run's http-protocol backend) bound as
;;;           HTTP-PROTOCOL:*HTTP-BACKEND* in the connecting thread and in
;;;           tool calls. A server that answers as a legacy HTTP+SSE one
;;;           (MCP-BACKEND-STREAMABLE-HTTP:MCP-TRANSPORT-UNSUPPORTED from the
;;;           initialize) is :UNSUPPORTED, error "transport sse is not
;;;           supported yet", as an :sse config.
;;;   :sse    :UNSUPPORTED (above), never connected.
;;;
;;; Tools (MCP-MANAGER-TOOL-SOURCE manager → one tool source)
;;;   The source the agent gets, after the unit tools: (file shell [lisp]
;;;   units mcp) when any server is configured; MAKE-CODE-TOOLS's other
;;;   positions do not move. Its tools are the connected servers' tools in
;;;   config order, each server's through
;;;   (ai-agent-protocol:make-prefixed-tool-source
;;;     (ai-agent-protocol/mcp:make-mcp-tool-source
;;;       client :cache-tools (mcp-server-config-cache-tools c)
;;;              :tool-error-behavior (mcp-server-config-tool-error-behavior c)
;;;              :timeout <tool timeout> :list-timeout <startup timeout>)
;;;     "mcp__<server>__"),
;;;   so a reconnect or a list_changed changes the next step's tools. A call
;;;   whose name no connected server offers (a server closed between the
;;;   listing and the call, or dropped by a restore) → the source's error
;;;   callback gets an AI-AGENT-PROTOCOL:AGENT-UNKNOWN-TOOL-ERROR, as
;;;   ai-agent-protocol's combined source does: a tool error the model reads,
;;;   never a failed run.
;;;   MCP-TOOL-NAME server tool → "mcp__<server>__<tool>" (Claude Code's
;;;   convention); every character of SERVER or TOOL outside [A-Za-z0-9_-]
;;;   becomes "_". A name two servers produce: the later server's tool is
;;;   dropped (a notice once).
;;;   Permissions: actions are those names, resource "*": `mcp__lisp__*`,
;;;   `mcp__lisp__repl-eval`, `mcp__*` work as any rule (deny > ask > allow
;;;   across layers; a deny with resource * hides the tool). The default
;;;   effect (no rule matches) is ASK, except ALLOW when the tool's
;;;   readOnlyHint is true AND its server is trusted (MCP-SERVER-TRUSTED-P):
;;;   a hint is the server's own claim, so it only lowers the bar for servers
;;;   the user configured; a project server's "read-only" tool still asks
;;;   until a rule allows it. -p denies the ask (headless), as for bash.
;;;   Plan mode: MCP tools run in another process or on another machine, which
;;;   the plan area cannot confine and the projected diff cannot show, so in
;;;   plan mode an MCP tool is DENIED (feedback +MCP-PLAN-MODE-FEEDBACK+)
;;;   unless it is read-only-and-trusted (as above) or an allow rule names it
;;;   (the user's explicit choice).
;;;   Results: the text the model reads is AGENT-TOOL-OUTPUT-TEXT (text items
;;;   joined, placeholders for images); an image reaches the next model call
;;;   through ai-agent-protocol's parts turn; the tool_result event (-p
;;;   stream-json, SDK, --rpc) gains "images": [{"media_type", "data"}] when
;;;   there are any, and "structured" when the result had structuredContent.
;;;   isError → status "error", is_error true (the server's text as content).
;;;
;;; Visibility
;;;   MCP-CONNECTION-OBJECT connection → {"name", "scope" (lower case),
;;;   "transport", "status" ("pending" "connecting" "connected" "failed"
;;;   "disabled" "unapproved" "rejected" "unsupported" "closed"), "tools"
;;;   [prefixed names, server order], "error" (text or null), "unit" (the
;;;   unit id or null), "file" (native namestring or null)}.
;;;   The system init event (-p stream-json, the SDK's CODE-SESSION-INIT)
;;;   gains "mcp_servers": [objects] when at least one server is configured
;;;   (the statuses after START-MCP-SERVERS), and its "tools" end with the MCP
;;;   names. -p prints on stderr, before the run, one notice per server that
;;;   did not connect: MCP-STATUS-NOTICE connection →
;;;     unapproved  "cl-stack-code: MCP server NAME (<file>) is not approved; skipped (approve it in the interactive mode, or add \"NAME\" to enabledMcpjsonServers in <user settings file>)"
;;;     failed      "cl-stack-code: MCP server NAME failed: <error>"
;;;     unsupported "cl-stack-code: MCP server NAME: transport sse is not supported yet"
;;;     rejected    "cl-stack-code: MCP server NAME is disabled by disabledMcpjsonServers"
;;;   (disabled, connected: no notice). -p never fails because of a server.
;;;   TUI: /mcp → a notice of MCP-STATUS-LINES (STATE-MCP); /mcp reconnect
;;;   [NAME] → effect (:mcp-reconnect NAME-or-NIL) and the notice
;;;   "reconnecting NAME" ("reconnecting MCP servers"); anything else → error
;;;   "usage: /mcp [reconnect [NAME]]". Allowed while busy.
;;;   MCP-STATUS-LINES servers → "no MCP servers configured", or
;;;     "MCP servers:" then per server
;;;     "  NAME (SCOPE, TRANSPORT): WORD" (WORD: "connected · N tool[s]",
;;;     "failed: ERROR", "needs approval", "rejected", "disabled",
;;;     "unsupported: ERROR", "connecting", "pending", "closed"),
;;;     and for a connected one "    TOOL, TOOL, …" (the prefixed names).
;;;   Core events: (:mcp-status SERVERS) sets STATE-MCP (a list of
;;;   MCP-CONNECTION-OBJECT hash tables); (:mcp-approval NAME MESSAGE) queues
;;;   NAME in STATE-MCP-PROMPT (the program shows the dialog
;;;   +MCP-APPROVAL-CHOICES+ with MESSAGE for its first entry; MESSAGE is
;;;   MCP-APPROVAL-MESSAGE); (:mcp-reply CHOICE) pops it → effect
;;;   (:mcp-approve NAME CHOICE). The program saves Yes / No
;;;   (SAVE-MCP-APPROVAL) and starts the server on Yes.
;;;   MCP-APPROVAL-MESSAGE connection → "MCP server NAME from FILE wants to
;;;   run: COMMAND ARG …" (stdio) / "wants to connect to URL" (http).
;;;
;;; SDK and RPC
;;;   CLIENT-NEW-SESSION … &key MCP-SERVERS: configs or a decoded mcpServers
;;;   object, scope :sdk (trusted). CLIENT-MCP-SERVERS session → the objects.
;;;   CLIENT-RECONNECT-MCP session &optional name → the objects after the
;;;   reconnect. --rpc: "mcp/list" {session_id} → {"servers": [...]};
;;;   "mcp/reconnect" {session_id, server?} → {"servers": [...]};
;;;   session/new takes "mcp_servers" (an mcpServers object). Unknown server →
;;;   MCP-SERVER-NOT-FOUND, RPC error -32020 with data "server".
;;;
;;; The instruction set (H3e-1's protocol, src/instruction-sets.lisp)
;;;   The MCP servers are part of the session's instruction set, like the
;;;   instruction files, skills and rules: what the model is offered besides
;;;   the conversation. Each manager has one MCP-SERVERS-COMPONENT
;;;   (MCP-MANAGER-COMPONENT, made by MAKE-MCP-MANAGER), role :MCP-SERVERS.
;;;   Every session registers it, servers or not: -p, the program and the SDK
;;;   (so --rpc and ACP) make the supervisor and the manager before the
;;;   session's instruction set opens, and pass the component to
;;;   %OPEN-SESSION-INSTRUCTIONS :COMPONENTS, which registers it after the
;;;   built-in ones and before the :start / :resume commit. So every revision
;;;   this version writes has the role, last, and a rewind to before the
;;;   first turn ("0", the start revision) restores it too. The wiring then
;;;   sets (MCP-MANAGER-INSTRUCTION-SET manager) to the set.
;;;
;;;   Snapshot (COMPONENT-SNAPSHOT), data only, one entry per connection in
;;;   MCP-MANAGER-CONNECTIONS order (NIL with no server configured):
;;;     (:name "fake" :scope :user :transport :stdio :config "sha256:…"
;;;      :status :connected
;;;      :tools ((:name "echo" :description "sha256:…" :schema "sha256:…"
;;;               :read-only t) …)
;;;      :instructions nil)
;;;   :NAME, :SCOPE, :TRANSPORT and :STATUS as MCP-CONNECTION-OBJECT's (as
;;;   keywords). :CONFIG is the sha256 ("sha256:<64 hex>", P:OCTETS-HASH of
;;;   the UTF-8 of the data printed as H3c prints files, not interned) of
;;;     (:transport T :command C :args (A …) :env-names (K …) :url U
;;;      :header-names (K …) :disabled B :timeout MS :startup-timeout MS
;;;      :cache-tools B :tool-error-behavior KW)
;;;   of the config as connected (after ${VAR}). Env and header VALUES are
;;;   never in a snapshot or its hash input: revisions are written to the
;;;   session directory, and tokens must not be. :TOOLS (NIL unless
;;;   :CONNECTED): the tools the server's source offers (MCP-TOOL-SOURCE-TOOLS,
;;;   app-only ones left out), server order; :NAME the server's own name (the
;;;   offered name is MCP-TOOL-NAME of it); :DESCRIPTION the
;;;   INTERN-INSTRUCTION-TEXT hash of the text the model reads (the
;;;   description, else the title, else ""); :SCHEMA that of JSON-PROTOCOL:ENCODE
;;;   of the input schema as decoded ({"type": "object"} when absent; the
;;;   server's key order, so one server's schema hashes the same in every
;;;   process); :READ-ONLY the readOnlyHint (T or NIL). :INSTRUCTIONS stays NIL
;;;   in H3e-2a; H3e-2b puts the INTERN-INSTRUCTION-TEXT hash of the server's
;;;   instructions there when includeInstructions puts them in the prompt.
;;;   No unit id, error text, pid or time: two processes with the same
;;;   servers in the same state write the same revision.
;;;
;;;   Commits (COMMIT-MCP-SERVERS manager → (values id new-p), or NIL without
;;;   a set: COMMIT-INSTRUCTION-SET set :COMPONENT). After START-MCP-SERVERS
;;;   (once, when every startable server settled), ADD-MCP-SERVERS (a server
;;;   added, or replaced), RECONNECT-MCP-SERVER, and when a server's offered
;;;   list changed (a list_changed, or a fetch with cacheTools false, that
;;;   gives a different list). Commits run on the thread that owns the set
;;;   (H3e-1): the three functions commit when they return there; a change
;;;   that happens elsewhere (a list_changed, the TUI's background start) is
;;;   committed before the next model call. An unchanged snapshot commits
;;;   nothing new (content-addressed ids). The init event's "instruction_set"
;;;   (-p stream-json, the SDK's CODE-SESSION-INIT, so session/new) is
;;;   INSTRUCTION-SET-CURRENT after START-MCP-SERVERS, so it covers the
;;;   servers as "mcp_servers" shows them.
;;;
;;;   Restore (COMPONENT-RESTORE; decided). A rewind or a /fork in the same
;;;   process (H3e-1's %FOLLOW-HEAD: the SDK's rewind, /rewind, REWIND-TO's
;;;   conversation part) restores the component to the revision of the new
;;;   head:
;;;   1. The configured set becomes the revision's, in its order. A live
;;;      server the revision lacks is closed (CLOSE-STDIO-MCP-CLIENT, its unit
;;;      stopped) and removed from MCP-MANAGER-CONNECTIONS: its tools are gone
;;;      from the next model call, /mcp, mcp/list and CLIENT-MCP-SERVERS. A
;;;      live server with the revision's name and :CONFIG hash is kept as it
;;;      is (not restarted). A revision server the manager does not have (or
;;;      has with another hash) is added again :PENDING from the config the
;;;      manager held with that name and hash (it remembers every config it
;;;      held), and connected lazily: before the next model call, in
;;;      parallel, under its startup timeout, with the approval rules of
;;;      START-MCP-SERVERS (approvals are the user's settings, never
;;;      restored). One it never held → :FAILED, error "not configured in
;;;      this process".
;;;   2. The tools offered for a server the revision recorded :CONNECTED are
;;;      the revision's (:TOOLS: names, descriptions and schemas from its
;;;      texts, :READ-ONLY for the permission default) while that server is
;;;      connected, until its list is next refreshed (a list_changed, a
;;;      reconnect, every fetch with cacheTools false); then the server's
;;;      list again, and a commit. Calls always go to the live server: a
;;;      revision tool the server dropped answers with its own error, a tool
;;;      error the model reads. For any other server the live list is offered.
;;;   3. Nothing is committed by the restore (H3e-1); the next commit is the
;;;      next change, and a lazily reconnected server that comes back as it
;;;      was commits the same id.
;;;   Why: the set must follow the conversation, as rules do. A server added
;;;   after the rewind point is the conversation's future: its tools must not
;;;   be offered, and its process must not keep running. Keeping a live
;;;   connection that the revision also has costs nothing and loses no server
;;;   state; reconnecting lazily keeps /rewind instant. The revision's tool
;;;   list, not the live one, because a revision is what the model was told
;;;   (H3e-1 renders old revisions from their stored texts the same way): a
;;;   rewind or a fork replays the same request, byte for byte, so the model
;;;   sees what it saw and the provider's prompt cache still hits. This is not
;;;   new staleness: a cached list (cacheTools, the default) already lives
;;;   until list_changed; the restore only seeds that cache from the revision,
;;;   and the same signals refresh it.
;;;   A fork into a new session in this process (the SDK's CLIENT-FORK-SESSION,
;;;   /clone, a conflict fork): CLONE-SESSION copies the revisions with their
;;;   :MCP-SERVERS snapshots (H3e-1). The fork's session has its own
;;;   supervisor and manager, whose servers are the fork point's revision's
;;;   (configs from the parent's manager, so SDK servers carry over; servers
;;;   added after the fork point do not). They connect at its start; its
;;;   :resume / :component commits then give the fork point's id back when
;;;   the servers come back as they were, and the fork's init event names it.
;;;   A new process (--resume, --continue, --fork-session in a new process):
;;;   the servers are the configuration's (files, flags, SDK), as for any
;;;   resume: H3e-1's :resume reads the set from the process.
;;;
;;; Overlap with the built-in Lisp tools (H4b): a server named, say, "lisp"
;;; running lisp-mcp offers mcp__lisp__repl-eval next to the built-in
;;; repl-eval. Both stay, under their distinct names; nothing is merged or
;;; hidden. The built-in layer is the one to use for Lisp work (one image
;;; the product owns, debugger events in the inbox, restart rules); the
;;; brief says so.
;;;
;;; Later (H3e-2b): sampling (make-mcp-sampling-handler behind an ask,
;;; action mcp_sampling, samplingModel), elicitation through the approval
;;; UI, server instructions in the prompt (includeInstructions, a tagged
;;; <mcp-instructions server="x"> block), deferred tool loading, roots,
;;; resources and prompts, deferred approvals for -p.

;;; Given: constants, classes, condition.

(defparameter +mcp-tool-prefix+ "mcp__")

(defparameter +mcp-plan-mode-feedback+
  "MCP tools are not available in plan mode: they run outside the plan area, so their effects cannot be projected or confined. Read-only tools of trusted servers still run; an allow rule naming the tool lets it run."
  "The deny feedback of an MCP tool in plan mode.")

(defparameter +mcp-statuses+
  '(:pending :connecting :connected :failed :disabled :unapproved :rejected
    :unsupported :closed))

(defparameter +mcp-approval-choices+
  '((:yes "Yes, trust it in this project")
    (:no "No, never in this project")
    (:later "Not now"))
  "The TUI's project-server approval dialog.")

(defparameter +mcp-unit-kind+ :mcp-server)

(defclass mcp-connection ()
  ((config :initarg :config :reader mcp-connection-config)
   (status :initarg :status :initform :pending :accessor mcp-connection-status)
   (error :initform nil :accessor mcp-connection-error)
   (client :initform nil :accessor mcp-connection-client)
   (unit :initform nil :accessor mcp-connection-unit)
   (source :initform nil :accessor mcp-connection-source
           :documentation "The prefixed tool source while connected.")
   (lock :initform (bt:make-lock "mcp-connection") :reader %mcp-connection-lock)))

(defun mcp-connection-name (connection)
  (mcp-server-config-name (mcp-connection-config connection)))

(defclass mcp-manager ()
  ((connections :initarg :connections :initform '() :accessor mcp-manager-connections)
   (supervisor :initarg :supervisor :initform nil :reader mcp-manager-supervisor)
   (settings :initarg :settings :initform nil :reader mcp-manager-settings)
   (env :initarg :env :initform (constantly nil) :reader mcp-manager-env)
   (cwd :initarg :cwd :initform nil :reader mcp-manager-cwd)
   (http-backend :initarg :http-backend :initform nil :reader mcp-manager-http-backend)
   (on-status :initarg :on-status :initform nil :reader mcp-manager-on-status)
   (closed :initform nil :accessor mcp-manager-closed-p)
   ;; The instruction set (see the header)
   (component :initform nil :accessor mcp-manager-component
              :documentation "The manager's MCP-SERVERS-COMPONENT (MAKE-MCP-MANAGER makes it).")
   (instruction-set :initform nil :accessor mcp-manager-instruction-set
                    :documentation "The session's INSTRUCTION-SET, once it is open (NIL before).")
   (lock :initform (bt:make-lock "mcp-manager") :reader %mcp-manager-lock)))

(defclass mcp-servers-component ()
  ((manager :initarg :manager :reader mcp-servers-component-manager))
  (:documentation "The instruction set's :MCP-SERVERS component of one MCP-MANAGER
(see the header, \"The instruction set\")."))

(defmethod component-role ((c mcp-servers-component))
  :mcp-servers)

(define-condition mcp-server-not-found (code-error)
  ((server :initarg :server :reader mcp-server-not-found-server))
  (:report (lambda (c s) (format s "no MCP server named ~s" (mcp-server-not-found-server c)))))

;;; Stubbed.

(defun mcp-tool-name (server tool)
  (declare (ignore server tool))
  (%h3e2-pending "mcp-tool-name"))

(defun make-mcp-manager (configs &key supervisor settings env cwd http-backend on-status)
  (declare (ignore configs supervisor settings env cwd http-backend on-status))
  (%h3e2-pending "make-mcp-manager"))

(defun start-mcp-servers (manager &key (approve (constantly nil)))
  (declare (ignore manager approve))
  (%h3e2-pending "start-mcp-servers"))

(defun reconnect-mcp-server (manager &optional name)
  (declare (ignore manager name))
  (%h3e2-pending "reconnect-mcp-server"))

(defun add-mcp-servers (manager configs)
  (declare (ignore manager configs))
  (%h3e2-pending "add-mcp-servers"))

(defun close-mcp-manager (manager)
  (declare (ignore manager))
  (%h3e2-pending "close-mcp-manager"))

(defun mcp-manager-tool-source (manager)
  (declare (ignore manager))
  (%h3e2-pending "mcp-manager-tool-source"))

(defun mcp-connection-tools (connection)
  "The prefixed tool names of a connected server, server order (NIL otherwise)."
  (declare (ignore connection))
  (%h3e2-pending "mcp-connection-tools"))

(defun mcp-connection-object (connection)
  (declare (ignore connection))
  (%h3e2-pending "mcp-connection-object"))

(defun mcp-status-notice (connection &key user-config-dir)
  (declare (ignore connection user-config-dir))
  (%h3e2-pending "mcp-status-notice"))

(defun mcp-status-lines (servers)
  (declare (ignore servers))
  (%h3e2-pending "mcp-status-lines"))

(defun mcp-approval-message (connection)
  (declare (ignore connection))
  (%h3e2-pending "mcp-approval-message"))

(defun %mcp-command (state argument)
  "/mcp in the core (see the header)."
  (declare (ignore state argument))
  (%h3e2-pending "/mcp"))

(defun %mcp-event (state event)
  "(:mcp-status …) (:mcp-approval …) (:mcp-reply …) in the core."
  (declare (ignore state event))
  (%h3e2-pending "MCP core events"))

;;; The instruction set (see the header).

(defmethod component-snapshot ((c mcp-servers-component) store)
  (declare (ignore store))
  (%h3e2-pending "the :mcp-servers snapshot"))

(defmethod component-restore ((c mcp-servers-component) snapshot store)
  (declare (ignore snapshot store))
  (%h3e2-pending "the :mcp-servers restore"))

(defun commit-mcp-servers (manager)
  "COMMIT-INSTRUCTION-SET of MANAGER's set, reason :COMPONENT → (values id
new-p), or NIL when MANAGER has no set."
  (declare (ignore manager))
  (%h3e2-pending "commit-mcp-servers"))

;;; SDK (src/client.lisp wires sessions; these are the entry points).

(defun client-mcp-servers (session)
  (declare (ignore session))
  (%h3e2-pending "client-mcp-servers"))

(defun client-reconnect-mcp (session &optional name)
  (declare (ignore session name))
  (%h3e2-pending "client-reconnect-mcp"))

(defun client-add-mcp-servers (session servers)
  "ADD-MCP-SERVERS on SESSION's manager; SERVERS as CLIENT-NEW-SESSION's :MCP-SERVERS."
  (declare (ignore session servers))
  (%h3e2-pending "client-add-mcp-servers"))

;;; Exports (kept here so the merges with H3e-1 and ACP-2 stay small).

(export '(;; src/mcp-config.lisp
          +default-mcp-timeout-ms+ +default-mcp-tool-timeout-ms+ +mcp-json-file-name+
          +mcp-transports+ +mcp-scopes+ +mcp-settings-keys+
          mcp-server-config make-mcp-server-config mcp-server-config-name
          mcp-server-config-scope mcp-server-config-transport mcp-server-config-command
          mcp-server-config-args mcp-server-config-env mcp-server-config-url
          mcp-server-config-headers mcp-server-config-disabled-p mcp-server-config-timeout
          mcp-server-config-startup-timeout mcp-server-config-cache-tools
          mcp-server-config-tool-error-behavior mcp-server-config-file
          settings-mcp mcp-settings mcp-server-trusted-p parse-mcp-servers mcp-json-path
          read-mcp-json expand-mcp-variables effective-mcp-servers mcp-server-approval
          save-mcp-approval mcp-timeouts
          ;; src/mcp.lisp
          +mcp-tool-prefix+ +mcp-plan-mode-feedback+ +mcp-statuses+ +mcp-approval-choices+
          +mcp-unit-kind+
          mcp-connection mcp-connection-config mcp-connection-status mcp-connection-error
          mcp-connection-client mcp-connection-unit mcp-connection-source mcp-connection-name
          mcp-manager mcp-manager-connections mcp-manager-supervisor mcp-manager-closed-p
          mcp-manager-component mcp-manager-instruction-set
          mcp-servers-component mcp-servers-component-manager commit-mcp-servers
          mcp-server-not-found mcp-server-not-found-server
          mcp-tool-name make-mcp-manager start-mcp-servers reconnect-mcp-server add-mcp-servers
          close-mcp-manager mcp-manager-tool-source mcp-connection-tools mcp-connection-object
          mcp-status-notice mcp-status-lines mcp-approval-message
          state-mcp state-mcp-prompt
          client-mcp-servers client-reconnect-mcp client-add-mcp-servers
          invocation-mcp-config invocation-strict-mcp-config-p))

;;; Given: the flags, read from the flag layer.

(defun invocation-mcp-config (invocation)
  "The --mcp-config values, in order."
  (getf (settings-mcp (invocation-settings invocation)) :config-files))

(defun invocation-strict-mcp-config-p (invocation)
  (and (getf (settings-mcp (invocation-settings invocation)) :strict) t))
