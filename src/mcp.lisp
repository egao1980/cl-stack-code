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
;;; H3e-2b (0.16.0): sampling and elicitation (src/mcp-requests.lisp), server
;;; instructions in the prompt and deferred tool loading (src/mcp-context.lisp,
;;; which also amends this file's snapshot, objects and /mcp lines). Later:
;;; roots, resources and prompts, deferred approvals for -p.

;;; Given: constants, classes, condition.

(defparameter +mcp-tool-prefix+ "mcp__")

(defparameter +mcp-plan-mode-feedback+
  "MCP tools are not available in plan mode: they run outside the plan area, so their effects cannot be projected or confined. Read-only tools of trusted servers still run; an allow rule naming the tool lets it run."
  "The deny feedback of an MCP tool in plan mode.")

(defparameter +mcp-plan-mode-rules+
  (list (agent:make-permission-rule "mcp__*" "*" :deny :feedback +mcp-plan-mode-feedback+))
  "Plan mode's MCP rule, applied to an ask only (%MCP-PLAN-MODE-POLICY).")

(defun %mcp-plan-mode-policy (action resources effect)
  "Plan mode's permission policy: an MCP tool that would ask is denied with
+MCP-PLAN-MODE-FEEDBACK+. A policy only tightens, so an allow rule and the
read-only-and-trusted default (both :ALLOW already) still run it; the match is
the rule engine's."
  (when (eq effect :ask)
    (agent:permission-rules-effect +mcp-plan-mode-rules+ action resources)))

(defun code-permission-policy (settings)
  "The run's :permission-policy: SETTINGS-PERMISSION-POLICY, and in plan and
preview mode the MCP plan policy (MCP tools act outside the area in both).
H5c-0: in plan mode both apply; each only tightens, so the first one with an
opinion answers."
  (let ((mode-policy (settings-permission-policy settings))
        (mcp-policy (and (member (settings-permission-mode settings) '(:plan :preview))
                         #'%mcp-plan-mode-policy)))
    (if (and mode-policy mcp-policy)
        (lambda (action resources effect)
          (multiple-value-bind (decided rule) (funcall mode-policy action resources effect)
            (if decided
                (values decided rule)
                (funcall mcp-policy action resources effect))))
        (or mode-policy mcp-policy))))

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
   ;; H3e-2b (src/mcp-requests.lisp): who answers the servers' requests
   (broker :initarg :broker :initform nil :accessor mcp-manager-broker
           :documentation "The session's MCP-REQUEST-BROKER, or NIL (requests answered as headless).")
   (closed :initform nil :accessor mcp-manager-closed-p)
   ;; The instruction set (see the header)
   (component :initform nil :accessor mcp-manager-component
              :documentation "The manager's MCP-SERVERS-COMPONENT (MAKE-MCP-MANAGER makes it).")
   (instruction-set :initform nil :accessor mcp-manager-instruction-set
                    :documentation "The session's INSTRUCTION-SET, once it is open (NIL before).")
   (connecting :initform 0 :accessor %mcp-connecting
               :documentation "Connecting threads still running (CLOSE-MCP-MANAGER waits for them).")
   (connecting-cv :initform (bt:make-condition-variable) :reader %mcp-connecting-cv)
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

;;; The implementation.

(defparameter +mcp-sse-unsupported+ "transport sse is not supported yet")

(defparameter +mcp-not-configured+ "not configured in this process")

;;; Names.

(defun %mcp-sanitize (text)
  "TEXT with every character outside [A-Za-z0-9_-] as \"_\"."
  (map 'string (lambda (c)
                 (if (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9)
                         (char= c #\_) (char= c #\-))
                     c
                     #\_))
       text))

(defun %mcp-prefix (server)
  (concatenate 'string +mcp-tool-prefix+ (%mcp-sanitize server) "__"))

(defun mcp-tool-name (server tool)
  (concatenate 'string (%mcp-prefix server) (%mcp-sanitize tool)))

;;; The live objects (private subclasses of the given classes).

(defclass %live-mcp-connection (mcp-connection)
  ((attempt :initform 0 :accessor %mcp-attempt
            :documentation "Bumped by every start and close: a thread of an older attempt only cleans up.")
   (raw :initform nil :accessor %mcp-raw
        :documentation "The server's MCP-TOOL-SOURCE (unprefixed) while connected.")
   (seed :initform nil :accessor %mcp-seed
         :documentation "Restore step 2: the revision's tool list, or NIL.")
   (lazy :initarg :lazy :initform nil :accessor %mcp-lazy-p
         :documentation "Re-added by a restore: started before the next model call.")
   (pinned :initarg :pinned :initform nil :reader %mcp-pinned-hash
           :documentation "A placeholder's :CONFIG hash (the revision's).")
   (placeholder :initarg :placeholder :initform nil :reader %mcp-placeholder-p
                :documentation "True for a revision server this process never held.")
   ;; H3e-2b: the manager it belongs to (deferral and requests).
   (manager :initarg :manager :initform nil :accessor %mcp-connection-manager)))

(defclass %code-mcp-manager (mcp-manager)
  ((held :initform '() :accessor %mcp-held
         :documentation "(name hash config) of every config this manager held, newest first.")
   (dirty :initform nil :accessor %mcp-dirty
          :documentation "True when a change waits for a commit.")
   (owner :initform nil :accessor %mcp-owner
          :documentation "The thread that owns the instruction set (NIL: the caller's).")
   (post :initform nil :accessor %mcp-post
         :documentation "A function running a thunk on the owner thread, or NIL.")
   (decisions :initform '() :accessor %mcp-decisions
              :documentation "(name . :approved / :rejected) answered in this process (the TUI).")
   (noticed :initform '() :accessor %mcp-noticed
            :documentation "Tool names already reported as offered twice.")
   (notices :initform '() :accessor %mcp-notices
            :documentation "Notice texts not yet taken (%TAKE-MCP-NOTICES), newest first.")
   ;; H3e-2b (src/mcp-requests.lisp, src/mcp-context.lisp)
   (tool-source :initform nil :accessor %mcp-tool-source-cache
                :documentation "MCP-MANAGER-TOOL-SOURCE's source, made once.")
   (deferred :initform nil :accessor %mcp-deferred-source
     :documentation "The one AGENT:DEFERRED-TOOL-SOURCE around the 0.13 source.")
   (waits :initform '() :accessor %mcp-waits
          :documentation "The servers' requests being decided (%MCP-WAITs), oldest first.")
   (counters :initform '() :accessor %mcp-counters
             :documentation "Plist kind → the last request number given.")
   (running :initform '() :accessor %mcp-running
            :documentation "(connection . tool-use-id) of the MCP tool calls running.")
   (added-rules :initform '() :accessor %mcp-added-rules
                :documentation "Allow rules \"always\" added in this session (mcp_sampling(S)).")
   (rule-store :initform nil :accessor %mcp-rule-store
               :documentation "The session's PERMISSION-RULE-STORE (settings.local.json), or NIL.")
   (sampler :initform nil :accessor %mcp-sampler
            :documentation "Plist (:backend :model :designator :resolve :secrets :http :maker)
the sampling handler generates with (the surface sets it).")))

(defstruct (%mcp-seed (:constructor %make-mcp-seed (tools read-only plists generation)))
  tools          ; LLM-TOOLs (the server's own names) rebuilt from the revision's texts
  read-only      ; the names whose :READ-ONLY was T
  plists         ; the revision's :TOOLS entries, verbatim
  generation     ; MCP-CLIENT-TOOLS-GENERATION it was seeded at (NIL: at the next connect)
  served)        ; true once a model call was offered it (cacheTools false: one call)

(defun %mcp-connections (manager)
  (bt:with-lock-held ((%mcp-manager-lock manager))
    (copy-list (mcp-manager-connections manager))))

(defun %mcp-config-hash (config)
  "The snapshot's :CONFIG: sha256 of the config's data without env or header values."
  (p:octets-hash
   (p:utf8-encode
    (%print-data (append
                  (list :transport (mcp-server-config-transport config)
                        :command (mcp-server-config-command config)
                        :args (copy-list (mcp-server-config-args config))
                        :env-names (mapcar #'car (mcp-server-config-env config))
                        :url (mcp-server-config-url config)
                        :header-names (mapcar #'car (mcp-server-config-headers config))
                        :disabled (and (mcp-server-config-disabled-p config) t)
                        :timeout (mcp-server-config-timeout config)
                        :startup-timeout (mcp-server-config-startup-timeout config)
                        :cache-tools (and (mcp-server-config-cache-tools config) t)
                        :tool-error-behavior (mcp-server-config-tool-error-behavior config))
                  ;; H3e-2b: only when not the default, so 0.13 configs hash as before
                  (and (mcp-server-config-sampling config)
                       (list :sampling (copy-list (mcp-server-config-sampling config))))
                  (and (not (mcp-server-config-elicitation config))
                       (list :elicitation nil))
                  (and (not (eq :default (mcp-server-config-include-instructions config)))
                       (list :include-instructions
                             (and (mcp-server-config-include-instructions config) t)))
                  (and (mcp-server-config-always-load config)
                       (list :always-load t)))))))

(defun %mcp-connection-hash (connection)
  (or (and (typep connection '%live-mcp-connection) (%mcp-pinned-hash connection))
      (%mcp-config-hash (mcp-connection-config connection))))

(defun %make-mcp-connection (config &key lazy manager)
  (let ((c (make-instance '%live-mcp-connection
                          :config config :lazy lazy :manager manager
                          :status (cond ((mcp-server-config-disabled-p config) :disabled)
                                        ((eq :sse (mcp-server-config-transport config)) :unsupported)
                                        (t :pending)))))
    (when (eq :unsupported (mcp-connection-status c))
      (setf (mcp-connection-error c) +mcp-sse-unsupported+))
    c))

(defun %mcp-placeholder (entry)
  "A revision server this process never held: :FAILED \"not configured in this process\"."
  (let ((c (make-instance '%live-mcp-connection
                          :config (make-mcp-server-config (getf entry :name)
                                                          :scope (getf entry :scope)
                                                          :transport (getf entry :transport))
                          :status :failed
                          :pinned (getf entry :config)
                          :placeholder t)))
    (setf (mcp-connection-error c) +mcp-not-configured+)
    c))

(defun %mcp-hold (manager config)
  (let ((hash (%mcp-config-hash config))
        (name (mcp-server-config-name config)))
    (bt:with-lock-held ((%mcp-manager-lock manager))
      (unless (find-if (lambda (h) (and (equal name (first h)) (equal hash (second h))))
                       (%mcp-held manager))
        (push (list name hash config) (%mcp-held manager))))))

(defun %mcp-held-config (manager name hash)
  (third (find-if (lambda (h) (and (equal name (first h)) (equal hash (second h))))
                  (bt:with-lock-held ((%mcp-manager-lock manager))
                    (copy-list (%mcp-held manager))))))

(defun make-mcp-manager (configs &key supervisor settings env cwd http-backend on-status broker)
  (let ((manager (make-instance '%code-mcp-manager
                                :supervisor supervisor
                                :broker broker
                                :settings (or settings (make-settings))
                                :env (or env (constantly nil))
                                :cwd cwd
                                :http-backend http-backend
                                :on-status on-status)))
    (setf (mcp-manager-connections manager)
          (mapcar (lambda (config) (%make-mcp-connection config :manager manager)) configs)
          (mcp-manager-component manager)
          (make-instance 'mcp-servers-component :manager manager))
    (dolist (config configs)
      (%mcp-hold manager config))
    manager))

;;; Statuses and notices.

(defun %mcp-notify (manager connection)
  "ON-STATUS of CONNECTION. A host callback's error is dropped: a status change
must not break the thread that made it (a connecting thread, a reader)."
  (let ((fn (mcp-manager-on-status manager)))
    (when fn
      (handler-case (funcall fn connection)
        (error () nil)))))

(defun %mcp-set-status (manager connection status &key error (dirty t) attempt)
  "Set CONNECTION's STATUS and ERROR (only while ATTEMPT, when given, is
current) → true when set. DIRTY: a commit is owed."
  (let ((set (bt:with-lock-held ((%mcp-connection-lock connection))
               (when (or (null attempt) (eql attempt (%mcp-attempt connection)))
                 (setf (mcp-connection-status connection) status
                       (mcp-connection-error connection) error)
                 t))))
    (when set
      (when dirty (setf (%mcp-dirty manager) t))
      (%mcp-notify manager connection))
    set))

(defun %mcp-note (manager text)
  (bt:with-lock-held ((%mcp-manager-lock manager))
    (push text (%mcp-notices manager))))

(defun %take-mcp-notices (manager)
  "→ the notices not yet taken, oldest first."
  (and manager
       (bt:with-lock-held ((%mcp-manager-lock manager))
         (reverse (shiftf (%mcp-notices manager) '())))))

;;; Resources.

(defun %mcp-take (connection &key attempt)
  "Bump CONNECTION's attempt and take its client → (values client unit). The
unit stays readable (MCP-CONNECTION-UNIT) for the views. With ATTEMPT, only
while ATTEMPT is current (else NIL NIL)."
  (bt:with-lock-held ((%mcp-connection-lock connection))
    (when (or (null attempt) (eql attempt (%mcp-attempt connection)))
      (incf (%mcp-attempt connection))
      (let ((client (mcp-connection-client connection))
            (unit (mcp-connection-unit connection)))
        (setf (mcp-connection-client connection) nil
              (mcp-connection-source connection) nil
              (%mcp-raw connection) nil)
        (values client unit)))))

(defun %mcp-stop-unit (unit)
  (when (and unit (not (sup:unit-finished-p unit)))
    (handler-bind ((sup:stop-failed #'%abandon-on-stop-failed))
      (sup:stop-unit unit))))

(defun %mcp-dispose (client unit)
  "Close CLIENT (stdio: EOF to the server, a :command child reaped; a no-op for
other transports), then stop UNIT."
  (when client
    (mcp-backend-stdio:close-stdio-mcp-client client :force (null unit)))
  (%mcp-stop-unit unit))

(defun %mcp-claim (connection attempt &key client unit)
  "Record CLIENT / UNIT on CONNECTION while ATTEMPT is current → true; else NIL
(the caller disposes of them)."
  (bt:with-lock-held ((%mcp-connection-lock connection))
    (when (eql attempt (%mcp-attempt connection))
      (when client (setf (mcp-connection-client connection) client))
      (when unit (setf (mcp-connection-unit connection) unit))
      t)))

(defun %mcp-close-connection (manager connection &key (status :closed) (dirty t))
  ;; H3e-2b: its server's requests still waiting are answered first ("closed").
  (%mcp-answer-all manager "closed" :connection connection)
  (multiple-value-bind (client unit) (%mcp-take connection)
    (%mcp-dispose client unit))
  (unless (%mcp-placeholder-p connection)
    (%mcp-set-status manager connection status :dirty dirty)))

;;; Connecting.

(defun %mcp-scope (supervisor)
  "The root's :tool-source scope \"mcp\" of SUPERVISOR (an open one is reused)."
  (let ((root (sup:supervisor-root-scope supervisor)))
    (or (find-if (lambda (scope)
                   (and (equal "mcp" (sup:scope-name scope)) (not (sup:scope-closed-p scope))))
                 (sup:scope-children root))
        (sup:make-scope supervisor :tool-source "mcp" :parent root))))

(defun %mcp-data-text (data)
  (if (stringp data) data (json:encode data)))

(defun %mcp-unit-log-handler (unit)
  "The client's :LOG-HANDLER: \"[mcp LEVEL] DATA\" on UNIT's stderr log."
  (lambda (message)
    (sup:sink-write (sup:unit-output-sink unit) :stderr
                    (format nil "[mcp ~a] ~a~%"
                            (mcp-protocol:mcp-log-message-level message)
                            (%mcp-data-text (mcp-protocol:mcp-log-message-data message))))))

(defun %mcp-tools-changed (manager)
  "The client's :ON-TOOLS-CHANGED (a reader thread): a commit is owed before
the next model call."
  (lambda (client)
    (declare (ignore client))
    (setf (%mcp-dirty manager) t)))

(defun %mcp-open-client (manager connection attempt scope)
  "Spawn or connect CONNECTION's server → its MCP-CLIENT, or NIL when ATTEMPT
went stale meanwhile. H3e-2b: the client gets the request handlers
(MAKE-MCP-REQUEST-HANDLERS) on every transport, so its capabilities follow."
  (let* ((config (mcp-connection-config connection))
         (supervisor (mcp-manager-supervisor manager))
         (changed (%mcp-tools-changed manager)))
    (multiple-value-bind (sampling elicitation) (make-mcp-request-handlers manager connection)
      (ecase (mcp-server-config-transport config)
        (:stdio
         (let ((argv (cons (mcp-server-config-command config) (mcp-server-config-args config))))
           (if supervisor
               (let ((unit (sup:start-unit supervisor +mcp-unit-kind+
                                           :command argv
                                           :owner scope
                                           :labels (list :server (mcp-server-config-name config))
                                           :cwd (mcp-manager-cwd manager)
                                           :env (mcp-server-config-env config)
                                           :restart :never
                                           :stdio :channel)))
                 (unless unit
                   (error 'code-error :message "the supervisor refused the unit"))
                 (if (not (%mcp-claim connection attempt :unit unit))
                     (progn (%mcp-stop-unit unit) nil)
                     (multiple-value-bind (input output) (sup:unit-channel-streams unit)
                       (let ((client (mcp-protocol:mcp-connect
                                      :backend (mcp-backend-stdio:make-stdio-mcp-backend)
                                      :input input :output output
                                      :log-handler (%mcp-unit-log-handler unit)
                                      :on-tools-changed changed
                                      :sampling-handler sampling
                                      :elicitation-handler elicitation)))
                         (if (%mcp-claim connection attempt :client client)
                             client
                             (progn (%mcp-dispose client unit) nil))))))
               (let ((client (mcp-protocol:mcp-connect
                              :backend (mcp-backend-stdio:make-stdio-mcp-backend)
                              :command argv
                              :env (mcp-server-config-env config) :env-mode :merge
                              :directory (mcp-manager-cwd manager)
                              :error-output nil
                              :on-tools-changed changed
                              :sampling-handler sampling
                              :elicitation-handler elicitation)))
                 (if (%mcp-claim connection attempt :client client)
                     client
                     (progn (%mcp-dispose client nil) nil))))))
        (:http
         (let ((client (mcp-protocol:mcp-connect
                        :backend (mcp-backend-streamable-http:make-streamable-http-mcp-backend)
                        :url (mcp-server-config-url config)
                        :headers (mcp-server-config-headers config)
                        :on-tools-changed changed
                        :sampling-handler sampling
                        :elicitation-handler elicitation
                        :probe t)))
           (and (%mcp-claim connection attempt :client client) client)))))))

(defun %mcp-connect (manager connection attempt scope)
  "The connecting thread of one attempt. It never signals: a failure is the
connection's :FAILED (or :UNSUPPORTED) status and text."
  (let ((config (mcp-connection-config connection)))
    (handler-case
        (multiple-value-bind (startup tool)
            (mcp-timeouts config (mcp-manager-settings manager) (mcp-manager-env manager))
          (let ((client (%mcp-open-client manager connection attempt scope)))
            (when client
              (unless (eq :http (mcp-server-config-transport config))
                (mcp-protocol:mcp-initialize client))
              (let ((raw (ai-agent-protocol/mcp:make-mcp-tool-source
                          client
                          :cache-tools (mcp-server-config-cache-tools config)
                          :tool-error-behavior (mcp-server-config-tool-error-behavior config)
                          :timeout tool
                          :list-timeout startup)))
                ;; The first list is part of startup.
                (ai-agent-protocol/mcp:mcp-tool-source-tools raw)
                (%mcp-settle manager connection attempt raw)))))
      (mcp-backend-streamable-http:mcp-transport-unsupported ()
        (%mcp-fail manager connection attempt :unsupported +mcp-sse-unsupported+))
      (error (e)
        (%mcp-fail manager connection attempt :failed (%mcp-error-text e))))))

(defun %mcp-error-text (condition)
  (handler-case (princ-to-string condition)
    (error () (format nil "~a" (type-of condition)))))

(defun %mcp-settle (manager connection attempt raw)
  "ATTEMPT connected: CONNECTION's source, then :CONNECTED (a stale attempt
only closes what it opened)."
  (let ((ok (bt:with-lock-held ((%mcp-connection-lock connection))
              (when (eql attempt (%mcp-attempt connection))
                (setf (%mcp-raw connection) raw
                      (mcp-connection-source connection)
                      (make-instance '%mcp-server-source :inner nil :connection connection))
                (let ((seed (%mcp-seed connection)))
                  (when (and seed (null (%mcp-seed-generation seed)))
                    (setf (%mcp-seed-generation seed)
                          (mcp-protocol:mcp-client-tools-generation
                           (mcp-connection-client connection)))))
                t))))
    (when ok
      (%mcp-set-status manager connection :connected :attempt attempt))))

(defun %mcp-fail (manager connection attempt status text)
  "ATTEMPT failed: CONNECTION is STATUS with TEXT, then its client and unit go.
The status comes first: %MCP-TAKE bumps the attempt, and a waiter
(%MCP-CONNECT-ALL) that saw the bump before the status would return while the
connection still read :CONNECTING."
  (when (%mcp-set-status manager connection status :error text :attempt attempt)
    (multiple-value-bind (client unit) (%mcp-take connection :attempt attempt)
      (%mcp-dispose client unit))))

(defun %mcp-seconds-text (seconds)
  (if (integerp seconds) (princ-to-string seconds) (format nil "~a" (float seconds 1.0))))

(defun %mcp-connect-all (manager connections)
  "Connect CONNECTIONS, one thread each, in parallel; return once each one
connected, failed or passed its startup timeout (then :FAILED \"timed out
after N s\", its child stopped). Every wait is bounded."
  (when connections
    (let* ((lock (bt:make-lock "cl-stack-code mcp start"))
           (cv (bt:make-condition-variable))
           (http (or (mcp-manager-http-backend manager) http-protocol:*http-backend*))
           (supervisor (mcp-manager-supervisor manager))
           (scope (and supervisor (%mcp-scope supervisor)))
           (start (get-internal-real-time))
           (waits '()))
      (dolist (c connections)
        (let ((seconds (mcp-timeouts (mcp-connection-config c) (mcp-manager-settings manager)
                                     (mcp-manager-env manager)))
              (attempt (bt:with-lock-held ((%mcp-connection-lock c))
                         (incf (%mcp-attempt c)))))
          (%mcp-set-status manager c :connecting :attempt attempt)
          (push (list c attempt
                      (+ start (round (* seconds internal-time-units-per-second)))
                      seconds)
                waits)
          (bt:with-lock-held ((%mcp-manager-lock manager))
            (incf (%mcp-connecting manager)))
          (bt:make-thread (lambda ()
                            (let ((http-protocol:*http-backend* http))
                              (unwind-protect (%mcp-connect manager c attempt scope)
                                (bt:with-lock-held ((%mcp-manager-lock manager))
                                  (decf (%mcp-connecting manager))
                                  (bt:condition-notify (%mcp-connecting-cv manager)))
                                (bt:with-lock-held (lock)
                                  (bt:condition-notify cv)))))
                          :name (format nil "cl-stack-code mcp ~a" (mcp-connection-name c)))))
      (flet ((open-p (w)
               (destructuring-bind (c attempt &rest more) w
                 (declare (ignore more))
                 (bt:with-lock-held ((%mcp-connection-lock c))
                   (and (eql attempt (%mcp-attempt c))
                        (eq :connecting (mcp-connection-status c)))))))
        (loop
          (let ((expired '()))
            (bt:with-lock-held (lock)
              (let* ((open (remove-if-not #'open-p waits))
                     (now (get-internal-real-time)))
                (when (null open)
                  (return))
                (setf expired (remove-if (lambda (w) (> (third w) now)) open))
                (unless expired
                  (let ((next (reduce #'min open :key #'third)))
                    (bt:condition-wait cv lock
                                       :timeout (max 0.01 (/ (- next now)
                                                             internal-time-units-per-second)))))))
            (dolist (w expired)
              (destructuring-bind (c attempt deadline seconds) w
                (declare (ignore deadline))
                (%mcp-fail manager c attempt :failed
                           (format nil "timed out after ~a s" (%mcp-seconds-text seconds)))))))))))

(defun %mcp-project-dir (manager)
  (let ((cwd (or (mcp-manager-cwd manager) (uiop:getcwd))))
    (or (find-project-root cwd) cwd)))

(defun %mcp-approval (manager connection)
  (let ((config (mcp-connection-config connection)))
    (or (cdr (assoc (mcp-server-config-name config)
                    (bt:with-lock-held ((%mcp-manager-lock manager))
                      (copy-alist (%mcp-decisions manager)))
                    :test #'string=))
        (mcp-server-approval config (mcp-manager-settings manager)
                             :project-dir (%mcp-project-dir manager)))))

(defun %mcp-start (manager connections approve)
  "Start the startable CONNECTIONS after their approvals (see the header)."
  (let ((go '()))
    (dolist (c connections)
      (when (and (not (mcp-manager-closed-p manager))
                 (not (%mcp-placeholder-p c))
                 (member (mcp-connection-status c) '(:pending :failed :closed :unapproved :rejected)))
        (setf (%mcp-lazy-p c) nil)
        (ecase (%mcp-approval manager c)
          (:approved (push c go))
          (:rejected (%mcp-set-status manager c :rejected))
          (:unapproved
           (if (funcall approve c)
               (push c go)
               (%mcp-set-status manager c :unapproved))))))
    (%mcp-connect-all manager (nreverse go))))

;;; Commits (see the header, "Commits").

(defun commit-mcp-servers (manager)
  "COMMIT-INSTRUCTION-SET of MANAGER's set, reason :COMPONENT → (values id
new-p), or NIL when MANAGER has no set."
  (let ((set (mcp-manager-instruction-set manager)))
    (when set
      (setf (%mcp-dirty manager) nil)
      (commit-instruction-set set :component))))

(defun %mcp-drain (manager)
  "On the set's thread: the owed commit, if any."
  (when (and (%mcp-dirty manager) (not (mcp-manager-closed-p manager)))
    (commit-mcp-servers manager)))

(defun %commit-or-defer (manager)
  "Commit on the set's thread; elsewhere mark the commit owed (and post it)."
  (when (mcp-manager-instruction-set manager)
    (let ((owner (%mcp-owner manager)))
      (if (or (null owner) (eq owner (bt:current-thread)))
          (commit-mcp-servers manager)
          (progn
            (setf (%mcp-dirty manager) t)
            (let ((post (%mcp-post manager)))
              (when post
                (funcall post (lambda () (%mcp-drain manager))))))))))

(defun %set-mcp-owner (manager thread &optional post)
  "MANAGER's set is committed on THREAD from now on; POST runs a thunk there."
  (when manager
    (setf (%mcp-owner manager) thread
          (%mcp-post manager) post)))

(defun %mcp-refresh-seed (manager connection)
  "Restore step 2's end: a seed whose server's list changed (or, with
cacheTools false, that served one model call) gives way to the live list."
  (let ((seed (%mcp-seed connection))
        (client (mcp-connection-client connection)))
    (when (and seed client (eq :connected (mcp-connection-status connection))
               (%mcp-seed-generation seed))
      (cond ((not (eql (%mcp-seed-generation seed) (mcp-protocol:mcp-client-tools-generation client)))
             (setf (%mcp-seed connection) nil (%mcp-dirty manager) t))
            ((not (mcp-server-config-cache-tools (mcp-connection-config connection)))
             (if (%mcp-seed-served seed)
                 (setf (%mcp-seed connection) nil (%mcp-dirty manager) t)
                 (setf (%mcp-seed-served seed) t)))))
    ;; Every fetch refreshes a list that is not cached: the commit is content-addressed.
    (when (and (null (%mcp-seed connection))
               (eq :connected (mcp-connection-status connection))
               (not (mcp-server-config-cache-tools (mcp-connection-config connection))))
      (setf (%mcp-dirty manager) t))))

(defun %mcp-before-model-call (manager)
  "The run's :STEP (the set's thread, before each model call): the lazy
starts of a restore, the seeds, the owed commit."
  (when (and manager (not (mcp-manager-closed-p manager)))
    (let ((lazy (remove-if-not #'%mcp-lazy-p (%mcp-connections manager))))
      (when lazy
        (%mcp-start manager lazy (constantly nil))))
    (dolist (c (%mcp-connections manager))
      (%mcp-refresh-seed manager c))
    (%mcp-drain manager)))

;;; The runtime entry points.

(defun start-mcp-servers (manager &key (approve (constantly nil)))
  (%mcp-start manager (%mcp-connections manager) approve)
  (%commit-or-defer manager)
  (%mcp-connections manager))

(defun %mcp-decide (manager name decision)
  "A TUI answer for server NAME in this process (the settings object predates
the save): DECISION :APPROVED or :REJECTED; :REJECTED shows at once."
  (when manager
    (bt:with-lock-held ((%mcp-manager-lock manager))
      (push (cons name decision) (%mcp-decisions manager)))
    (when (eq decision :rejected)
      (let ((c (find name (%mcp-connections manager) :key #'mcp-connection-name :test #'equal)))
        (when c
          (%mcp-set-status manager c :rejected))))))

(defun %mcp-find (manager name)
  (or (find name (%mcp-connections manager) :key #'mcp-connection-name :test #'equal)
      (error 'mcp-server-not-found :server name
                                   :message (format nil "no MCP server named ~s" name))))

(defun reconnect-mcp-server (manager &optional name)
  (let ((targets (if name
                     (list (%mcp-find manager name))
                     (remove-if-not (lambda (c)
                                      (member (mcp-connection-status c) '(:failed :closed :unapproved)))
                                    (%mcp-connections manager)))))
    (dolist (c targets)
      (unless (%mcp-placeholder-p c)
        (%mcp-close-connection manager c :status :pending)))
    (%mcp-start manager targets (constantly nil))
    (%commit-or-defer manager)
    (%mcp-connections manager)))

(defun add-mcp-servers (manager configs)
  (let ((added '()))
    (dolist (config configs)
      (let* ((config (if (mcp-server-config-scope config)
                         config
                         (%copy-mcp-config config :scope :sdk)))
             (name (mcp-server-config-name config))
             (old (find name (%mcp-connections manager) :key #'mcp-connection-name :test #'equal))
             (new (%make-mcp-connection config :manager manager)))
        (when old
          (%mcp-close-connection manager old))
        (%mcp-hold manager config)
        (bt:with-lock-held ((%mcp-manager-lock manager))
          (setf (mcp-manager-connections manager)
                (if old
                    (substitute new old (mcp-manager-connections manager))
                    (append (mcp-manager-connections manager) (list new)))))
        (setf (%mcp-dirty manager) t)
        (%mcp-notify manager new)
        (push new added)))
    (%mcp-start manager (nreverse added) (constantly nil))
    (%commit-or-defer manager)
    (%mcp-connections manager)))

(defparameter +mcp-close-wait-seconds+ 10
  "How long CLOSE-MCP-MANAGER waits for connecting threads to finish.")

(defun %mcp-wait-connecting (manager seconds)
  "Wait (at most SECONDS) until no connecting thread of MANAGER runs. A thread
that loses its attempt to the close stops the child it started, so after the
wait no server child outlives the manager (Windows: its open handles and cwd
keep the project directory busy)."
  (let ((end (+ (get-internal-real-time) (round (* seconds internal-time-units-per-second))))
        (lock (%mcp-manager-lock manager)))
    (bt:with-lock-held (lock)
      (loop while (plusp (%mcp-connecting manager))
            do (let ((left (/ (- end (get-internal-real-time)) internal-time-units-per-second)))
                 (when (<= left 0) (return))
                 (bt:condition-wait (%mcp-connecting-cv manager) lock
                                    :timeout (min left 1)))))))

(defun close-mcp-manager (manager)
  (when (and manager
             (not (bt:with-lock-held ((%mcp-manager-lock manager))
                    (shiftf (mcp-manager-closed-p manager) t))))
    ;; H3e-2b: every request still waiting is answered ("closed") first.
    (%mcp-answer-all manager "closed")
    (dolist (c (%mcp-connections manager))
      (%mcp-close-connection manager c))
    (%mcp-wait-connecting manager +mcp-close-wait-seconds+))
  manager)

;;; The tool source (see the header, "Tools").

(defclass %mcp-seeded-source (agent:wrapper-tool-source)
  ((connection :initarg :connection :reader %seeded-connection))
  (:documentation "The server's MCP-TOOL-SOURCE, offering the restore's seed while it holds."))

(defun %mcp-live-seed (connection)
  "CONNECTION's seed while it holds (no side effects: listings run on any thread)."
  (let ((seed (%mcp-seed connection))
        (client (mcp-connection-client connection)))
    (and seed client
         (eql (%mcp-seed-generation seed) (mcp-protocol:mcp-client-tools-generation client))
         seed)))

(defmethod agent:list-agent-tools ((source %mcp-seeded-source) &key context)
  (declare (ignore context))
  (let ((seed (%mcp-live-seed (%seeded-connection source))))
    (if seed (copy-list (%mcp-seed-tools seed)) (call-next-method))))

(defmethod agent:tool-executable-p ((source %mcp-seeded-source) name &key context)
  (declare (ignore context))
  (let ((seed (%mcp-live-seed (%seeded-connection source))))
    (if seed
        (and (find name (%mcp-seed-tools seed) :key #'llm:llm-tool-name :test #'equal) t)
        (call-next-method))))

(defun %mcp-read-only-p (connection name)
  "NAME's readOnlyHint (the seed's while it holds)."
  (let ((seed (%mcp-live-seed connection))
        (raw (%mcp-raw connection)))
    (cond (seed (and (member name (%mcp-seed-read-only seed) :test #'equal) t))
          (raw (ai-agent-protocol/mcp:mcp-tool-source-read-only-p raw name))
          (t nil))))

(defclass %mcp-server-source (agent:wrapper-tool-source)
  ((connection :initarg :connection :reader %server-source-connection))
  (:documentation "One connected server's tools: its seed or live list under the
permission default, sanitized and prefixed \"mcp__<server>__\"."))

(defmethod agent:tool-source-inner ((source %mcp-server-source))
  (let* ((c (%server-source-connection source))
         (raw (%mcp-raw c)))
    (if (null raw)
        (agent:make-combined-tool-source)
        (let* ((config (mcp-connection-config c))
               (trusted (mcp-server-trusted-p config))
               (seeded (make-instance '%mcp-seeded-source :inner raw :connection c))
               (defaulted (agent:make-approval-required-tool-source
                           seeded
                           ;; The default effect: ask, unless read-only AND trusted.
                           (lambda (context tool arguments)
                             (declare (ignore context arguments))
                             (not (and trusted (%mcp-read-only-p c (llm:llm-tool-name tool)))))))
               (renames (loop for tool in (agent:list-agent-tools seeded)
                              for name = (llm:llm-tool-name tool)
                              for clean = (%mcp-sanitize name)
                              unless (string= name clean)
                                collect (cons clean name))))
          (agent:make-prefixed-tool-source
           (if renames (agent:make-renamed-tool-source defaulted renames) defaulted)
           (%mcp-prefix (mcp-connection-name c)))))))

(defclass %mcp-manager-source (agent:wrapper-tool-source)
  ((manager :initarg :manager :reader %source-manager))
  (:documentation "MCP-MANAGER-TOOL-SOURCE: the connected servers' sources in
config order, combined, without the names a deny \"*\" rule hides."))

(defmethod agent:tool-source-inner ((source %mcp-manager-source))
  (let ((m (%source-manager source)))
    (agent:make-filtered-tool-source
     (apply #'agent:make-combined-tool-source
            (loop for c in (%mcp-connections m)
                  for s = (mcp-connection-source c)
                  when (and s (eq :connected (mcp-connection-status c)))
                    collect s))
     (lambda (context tool)
       (declare (ignore context))
       (null (hidden-tool-names (mcp-manager-settings m) (list (llm:llm-tool-name tool))))))))

(defmethod agent:list-agent-tools :around ((source %mcp-manager-source) &key context)
  (declare (ignore context))
  (handler-bind ((agent:tool-name-conflict
                   (lambda (c)
                     ;; The later server's tool is dropped (the protocol's CONTINUE), noticed once.
                     (let* ((m (%source-manager source))
                            (name (agent:tool-name-conflict-name c))
                            (new (bt:with-lock-held ((%mcp-manager-lock m))
                                   (unless (member name (%mcp-noticed m) :test #'equal)
                                     (push name (%mcp-noticed m))
                                     t))))
                       (when new
                         (%mcp-note m (format nil "cl-stack-code: MCP tool ~a is offered by two servers; the later one is dropped"
                                              name))))
                     (continue c))))
    (call-next-method)))

(defmethod agent:invoke-tool-async :around ((source %mcp-manager-source) name arguments
                                            &rest keys &key context callback error-callback
                                            &allow-other-keys)
  (let* ((m (%source-manager source))
         (http-protocol:*http-backend* (or (mcp-manager-http-backend m)
                                           http-protocol:*http-backend*))
         ;; H3e-2b: the running call of its server (a request's tool_use_id).
         (inv (getf context :invocation))
         (connection (and inv (stringp name)
                          (find-if (lambda (c)
                                     (uiop:string-prefix-p (%mcp-prefix (mcp-connection-name c)) name))
                                   (%mcp-connections m))))
         (entry (and connection (cons connection (agent:agent-invocation-id inv)))))
    (if (null entry)
        (call-next-method)
        (flet ((done ()
                 (bt:with-lock-held ((%mcp-manager-lock m))
                   (setf (%mcp-running m) (remove entry (%mcp-running m) :test #'eq)))))
          (bt:with-lock-held ((%mcp-manager-lock m))
            (push entry (%mcp-running m)))
          (handler-bind ((error (lambda (c) (declare (ignore c)) (done))))
            (apply #'call-next-method source name arguments
                   :callback (lambda (&rest values)
                               (done)
                               (when callback (apply callback values)))
                   :error-callback (lambda (&rest values)
                                     (done)
                                     (when error-callback (apply error-callback values)))
                   keys))))))

(defun %mcp-connection-of-tool (manager name)
  "The connection whose prefix NAME (an offered MCP tool name) carries, or NIL."
  (find-if (lambda (c) (uiop:string-prefix-p (%mcp-prefix (mcp-connection-name c)) name))
           (%mcp-connections manager)))

(defclass %mcp-visible-source (agent:wrapper-tool-source)
  ((manager :initarg :manager :reader %visible-manager))
  (:documentation "H3e-2b: the deferred source's listing without the names a deny
\"*\" rule hides (tool_search). Only the listing: a deferred tool called by
name still reaches the deferred source (auto-load), so this is not an
offered-only filtered source."))

(defmethod agent:list-agent-tools ((source %mcp-visible-source) &key context)
  (let ((settings (mcp-manager-settings (%visible-manager source))))
    (remove-if (lambda (tool) (hidden-tool-names settings (list (llm:llm-tool-name tool))))
               (call-next-method source :context context))))

(defun mcp-manager-tool-source (manager)
  "H3e-2b: the 0.13 source wrapped once in AGENT:MAKE-DEFERRED-TOOL-SOURCE
(src/mcp-context.lisp), its listing without the names a deny \"*\" rule
hides (tool_search included). The same object on every call, so the loaded
set is the session's."
  (bt:with-lock-held ((%mcp-manager-lock manager))
    (or (%mcp-tool-source-cache manager)
        (multiple-value-bind (mode threshold)
            (mcp-tool-search-settings (mcp-manager-settings manager))
          (let* ((inner (make-instance '%mcp-manager-source :manager manager :inner nil))
                 (deferred (agent:make-deferred-tool-source
                            inner
                            :mode mode :threshold threshold
                            :keep (lambda (context tool)
                                    (declare (ignore context))
                                    (let ((c (%mcp-connection-of-tool manager (llm:llm-tool-name tool))))
                                      (and c (mcp-server-config-always-load (mcp-connection-config c)))))
                            :search-tool-name +tool-search-tool-name+
                            :on-load (lambda (names &key via)
                                       (declare (ignore names via))
                                       ;; A load owes a commit (before the next model call).
                                       (setf (%mcp-dirty manager) t)))))
            (setf (%mcp-deferred-source manager) deferred
                  (%mcp-tool-source-cache manager)
                  (make-instance '%mcp-visible-source :inner deferred :manager manager)))))))

(defun %mcp-loaded-names (manager)
  "The deferred source's loaded set (prefixed names), or NIL."
  (let ((d (%mcp-deferred-source manager)))
    (and d (agent:deferred-tool-source-loaded d))))

(defun %mcp-connection-deferred-p (manager connection)
  "True when CONNECTION's tools are behind tool_search now."
  (let ((d (and manager (%mcp-deferred-source manager))))
    (and d
         (eq :connected (mcp-connection-status connection))
         (not (mcp-server-config-always-load (mcp-connection-config connection)))
         (agent:deferred-tool-source-active-p d)
         t)))

;;; Views.

(defun mcp-connection-tools (connection)
  "The prefixed tool names of a connected server, server order (NIL otherwise)."
  (let ((source (mcp-connection-source connection)))
    (and source (eq :connected (mcp-connection-status connection))
         (handler-case (mapcar #'llm:llm-tool-name (agent:list-agent-tools source))
           (error () nil)))))

(defun %lower-name (keyword)
  (if keyword (string-downcase (string keyword)) :null))

(defun mcp-connection-object (connection)
  (let* ((config (mcp-connection-config connection))
         (unit (mcp-connection-unit connection))
         (file (mcp-server-config-file config))
         (tools (mcp-connection-tools connection))
         (manager (and (typep connection '%live-mcp-connection)
                       (%mcp-connection-manager connection)))
         (loaded (and manager (%mcp-loaded-names manager))))
    (%json-object "name" (mcp-server-config-name config)
                  "scope" (%lower-name (mcp-server-config-scope config))
                  "transport" (%lower-name (mcp-server-config-transport config))
                  "status" (%lower-name (mcp-connection-status connection))
                  "tools" (coerce tools 'vector)
                  "error" (or (mcp-connection-error connection) :null)
                  "unit" (if unit (sup:unit-id unit) :null)
                  "file" (if file (uiop:native-namestring file) :null)
                  ;; H3e-2b (src/mcp-context.lisp, "VISIBILITY")
                  "sampling" (and (mcp-sampling-settings config) t)
                  "elicitation" (and (mcp-server-config-elicitation config) t)
                  "instructions" (and (mcp-connection-instructions connection) t)
                  "deferred" (%mcp-connection-deferred-p manager connection)
                  "loaded" (coerce (remove-if-not (lambda (n) (member n loaded :test #'equal)) tools)
                                   'vector))))

(defun %mcp-file-text (config)
  (let ((file (mcp-server-config-file config)))
    (if file
        (uiop:native-namestring file)
        (format nil "~(~a~) configuration" (or (mcp-server-config-scope config) "the")))))

(defun mcp-status-notice (connection &key user-config-dir)
  (let ((name (mcp-connection-name connection))
        (config (mcp-connection-config connection)))
    (case (mcp-connection-status connection)
      (:unapproved
       (format nil "cl-stack-code: MCP server ~a (~a) is not approved; skipped (approve it in the interactive mode, or add \"~a\" to enabledMcpjsonServers in ~a)"
               name (%mcp-file-text config) name
               (uiop:native-namestring
                (merge-pathnames "settings.json"
                                 (uiop:ensure-directory-pathname
                                  (or user-config-dir (user-config-directory)))))))
      (:failed
       (format nil "cl-stack-code: MCP server ~a failed: ~a" name
               (or (mcp-connection-error connection) "unknown error")))
      (:unsupported
       (format nil "cl-stack-code: MCP server ~a: ~a" name
               (or (mcp-connection-error connection) +mcp-sse-unsupported+)))
      (:rejected
       (format nil "cl-stack-code: MCP server ~a is disabled by disabledMcpjsonServers" name))
      (t nil))))

(defun %mcp-status-word (object)
  (let ((status (gethash "status" object))
        (error (let ((e (gethash "error" object))) (if (stringp e) e "")))
        (n (length (gethash "tools" object))))
    (cond ((equal status "connected")
           ;; H3e-2b: the suffixes, only for keys present and true
           (format nil "connected · ~d tool~:p~:[~; · sampling~]~:[~; · instructions~]~@[ · deferred (~d loaded)~]"
                   n
                   (eq t (gethash "sampling" object))
                   (eq t (gethash "instructions" object))
                   (and (eq t (gethash "deferred" object))
                        (length (gethash "loaded" object #())))))
          ((equal status "failed") (format nil "failed: ~a" error))
          ((equal status "unapproved") "needs approval")
          ((equal status "unsupported") (format nil "unsupported: ~a" error))
          (t status))))

(defun mcp-status-lines (servers)
  (if (null servers)
      (list "no MCP servers configured")
      (cons "MCP servers:"
            (loop for object in (coerce servers 'list)
                  collect (format nil "  ~a (~a, ~a): ~a"
                                  (gethash "name" object) (gethash "scope" object)
                                  (gethash "transport" object) (%mcp-status-word object))
                  when (and (equal "connected" (gethash "status" object))
                            (plusp (length (gethash "tools" object))))
                    collect (format nil "    ~{~a~^, ~}" (coerce (gethash "tools" object) 'list))))))

(defun mcp-approval-message (connection)
  (let ((config (mcp-connection-config connection)))
    (if (eq :stdio (mcp-server-config-transport config))
        (format nil "MCP server ~a from ~a wants to run: ~{~a~^ ~}"
                (mcp-server-config-name config) (%mcp-file-text config)
                (cons (mcp-server-config-command config) (mcp-server-config-args config)))
        (format nil "MCP server ~a from ~a wants to connect to ~a"
                (mcp-server-config-name config) (%mcp-file-text config)
                (mcp-server-config-url config)))))

;;; The core (pure).

(defun %mcp-command (state argument)
  "/mcp in the core (see the header)."
  (multiple-value-bind (word rest) (%split-command (or argument ""))
    (cond ((zerop (length word))
           (%add-entry state :kind :notice
                             :text (format nil "~{~a~^~%~}" (mcp-status-lines (state-mcp state))))
           '())
          ((string= word "reconnect")
           (let ((name (and (plusp (length rest)) rest)))
             (%add-entry state :kind :notice
                               :text (if name
                                         (format nil "reconnecting ~a" name)
                                         "reconnecting MCP servers"))
             (list (list :mcp-reconnect name))))
          (t
           (%add-entry state :kind :error :text "usage: /mcp [reconnect [NAME]]")
           '()))))

(defun %mcp-event (state event)
  "(:mcp-status …) (:mcp-approval …) (:mcp-reply …) in the core."
  (destructuring-bind (kind &rest args) event
    (ecase kind
      (:mcp-status (setf (state-mcp state) (coerce (first args) 'list)) '())
      (:mcp-approval
       (destructuring-bind (name message) args
         (unless (assoc name (state-mcp-prompt state) :test #'equal)
           (setf (state-mcp-prompt state)
                 (append (state-mcp-prompt state) (list (cons name message))))))
       '())
      (:mcp-reply
       (let ((entry (pop (state-mcp-prompt state))))
         (and entry (list (list :mcp-approve (car entry) (first args)))))))))

;;; The instruction set (see the header).

(defun %mcp-tool-plist (raw tool store)
  (let ((name (llm:llm-tool-name tool)))
    (list :name name
          :description (intern-instruction-text store (or (llm:llm-tool-description tool) ""))
          :schema (intern-instruction-text store (json:encode (llm:llm-tool-parameters tool)))
          :read-only (and (ai-agent-protocol/mcp:mcp-tool-source-read-only-p raw name) t))))

(defun %mcp-snapshot-tools (connection store)
  (let ((seed (%mcp-live-seed connection))
        (raw (%mcp-raw connection)))
    (cond (seed (copy-tree (%mcp-seed-plists seed)))
          (raw (mapcar (lambda (tool) (%mcp-tool-plist raw tool store))
                       (agent:list-agent-tools raw)))
          (t '()))))

(defmethod component-snapshot ((c mcp-servers-component) store)
  (let ((m (mcp-servers-component-manager c)))
    (loop for conn in (%mcp-connections m)
          for config = (mcp-connection-config conn)
          for status = (mcp-connection-status conn)
          for tools = (and (eq status :connected) (%mcp-snapshot-tools conn store))
          for deferred = (%mcp-connection-deferred-p m conn)
          collect (list :name (mcp-server-config-name config)
                        :scope (mcp-server-config-scope config)
                        :transport (mcp-server-config-transport config)
                        :config (%mcp-connection-hash conn)
                        :status status
                        :tools tools
                        ;; H3e-2b (src/mcp-context.lisp)
                        :instructions (let ((text (mcp-connection-instructions conn)))
                                        (and text (intern-instruction-text store text)))
                        :deferred deferred
                        :loaded (and deferred
                                     (let ((loaded (%mcp-loaded-names m))
                                           (server (mcp-server-config-name config)))
                                       (loop for p in tools
                                             for own = (getf p :name)
                                             when (member (mcp-tool-name server own) loaded
                                                          :test #'equal)
                                               collect own)))))))

(defun %mcp-seed-from (entry store generation)
  "Restore step 2: ENTRY's :TOOLS as a seed."
  (let ((plists (getf entry :tools)))
    (%make-mcp-seed
     (mapcar (lambda (p)
               (llm:make-llm-tool :name (getf p :name)
                                  :description (instruction-text store (getf p :description))
                                  :parameters (json:decode (instruction-text store (getf p :schema)))))
             plists)
     (loop for p in plists when (getf p :read-only) collect (getf p :name))
     (copy-tree plists)
     generation)))

(defmethod component-restore ((c mcp-servers-component) snapshot store)
  (let* ((m (mcp-servers-component-manager c))
         (old (%mcp-connections m))
         (new (loop for entry in snapshot
                    collect (let* ((name (getf entry :name))
                                   (hash (getf entry :config))
                                   (live (find-if (lambda (x)
                                                    (and (equal name (mcp-connection-name x))
                                                         (equal hash (%mcp-connection-hash x))))
                                                  old)))
                              (or live
                                  (let ((held (%mcp-held-config m name hash)))
                                    (if held
                                        (%make-mcp-connection held :lazy t :manager m)
                                        (%mcp-placeholder entry)))))))
         (dropped (remove-if (lambda (x) (member x new)) old)))
    ;; 1. The revision's servers, in its order.
    (bt:with-lock-held ((%mcp-manager-lock m))
      (setf (mcp-manager-connections m) new))
    ;; 2. The revision's tool lists for its connected servers.
    (loop for entry in snapshot
          for conn in new
          do (setf (%mcp-seed conn)
                   (and (eq :connected (getf entry :status))
                        (getf entry :tools)
                        (handler-case
                            (%mcp-seed-from entry store
                                            (let ((client (mcp-connection-client conn)))
                                              (and client (eq :connected (mcp-connection-status conn))
                                                   (mcp-protocol:mcp-client-tools-generation client))))
                          (instruction-set-error () nil)))))
    ;; H3e-2b: the loaded set becomes the revision's (src/mcp-context.lisp).
    (let ((deferred (%mcp-deferred-source m)))
      (when deferred
        (setf (agent:deferred-tool-source-loaded deferred)
              (loop for entry in snapshot
                    append (mapcar (lambda (own) (mcp-tool-name (getf entry :name) own))
                                   (getf entry :loaded))))))
    ;; 3. Nothing is committed: the servers the revision lacks close quietly.
    (dolist (x dropped)
      (%mcp-close-connection m x :dirty nil))
    (dolist (x new)
      (%mcp-notify m x))
    (values)))

;;; SDK (src/client.lisp wires sessions; these are the entry points).

(defun client-mcp-servers (session)
  (%with-session-mcp session
                     (lambda (manager)
                       (mapcar #'mcp-connection-object (%mcp-connections manager)))))

(defun client-reconnect-mcp (session &optional name)
  (%with-session-mcp session
                     (lambda (manager)
                       (mapcar #'mcp-connection-object (reconnect-mcp-server manager name)))))

(defun client-add-mcp-servers (session servers)
  "ADD-MCP-SERVERS on SESSION's manager; SERVERS as CLIENT-NEW-SESSION's :MCP-SERVERS."
  (%with-session-mcp session
                     (lambda (manager)
                       (mapcar #'mcp-connection-object
                               (add-mcp-servers manager
                                                (%sdk-mcp-configs servers (mcp-manager-env manager)))))))

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
