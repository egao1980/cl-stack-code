(in-package #:cl-stack-code)

;;; H3e-2a: MCP servers in the harness (brief: cl-stack
;;; docs/capabilities/cl-stack-code.md, "H3e-2 — locked"). Configuration and
;;; trust are src/mcp-config.lisp. Building blocks, none reimplemented here:
;;; mcp-protocol 0.4.0 (client, every tool field, list_changed, timeouts),
;;; mcp-backend-stdio 0.3.0 (the client over a child's pipes),
;;; mcp-backend-streamable-http 0.4.0 (headers), ai-agent-protocol 0.15.0
;;; (MAKE-PREFIXED-TOOL-SOURCE, AGENT-TOOL-OUTPUT) and ai-agent-protocol/mcp
;;; 0.2.0 (MAKE-MCP-TOOL-SOURCE), supervisor-protocol 0.5.0 (channel units,
;;; egao1980/supervisor-protocol#13).
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
;;;   :stdio  a supervised unit of the session's supervisor: kind :MCP-SERVER,
;;;           owner scope "mcp" under the root, labels (:server NAME), the
;;;           command and args as argv, the config's env over the process's,
;;;           cwd the session's working directory, :RESTART :NEVER (a
;;;           restarted child would have lost its MCP session; /mcp reconnect
;;;           starts a new unit instead), a channel unit (stdin/stdout are the
;;;           JSON-RPC pipes for mcp-backend-stdio, stderr goes to the unit
;;;           log). It shows in /ps and units/*. The server's
;;;           notifications/message (log) lines go to the same unit log as
;;;           stderr records "[mcp LEVEL] DATA" (the client's log handler).
;;;           Without a supervisor (none in the SDK? there is always one; a
;;;           test may pass NIL) the child runs through mcp-backend-stdio's
;;;           :COMMAND and its stderr is dropped.
;;;   :http   mcp-backend-streamable-http, the config's headers on every
;;;           request, with HTTP-BACKEND (the run's http-protocol backend,
;;;           bound in the connecting thread).
;;;   :sse    :UNSUPPORTED (above).
;;;
;;; Tools (MCP-MANAGER-TOOL-SOURCE manager → one tool source)
;;;   The source the agent gets, after the unit tools: (file shell [lisp]
;;;   units mcp) when any server is configured; MAKE-CODE-TOOLS's other
;;;   positions do not move. Its tools are the connected servers' tools in
;;;   config order, each server's through
;;;   (ai-agent-protocol:make-prefixed-tool-source
;;;     (ai-agent-protocol/mcp:make-mcp-tool-source client :cache-tools …
;;;      :tool-error-behavior … :timeout <tool timeout>) "mcp__<server>__"),
;;;   so a reconnect or a list_changed changes the next step's tools.
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
   (lock :initform (bt:make-lock "mcp-manager") :reader %mcp-manager-lock)))

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
