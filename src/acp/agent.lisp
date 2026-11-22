(in-package #:cl-stack-code/acp)

;;; ACP-2: the agent. GIVEN: the class and its readers. STUBBED: the
;;; constructor, CLOSE-CODE-ACP-AGENT and every method below.
;;;
;;; CODE-ACP-AGENT, an ACP-PROTOCOL:ACP-AGENT over one CODE-CLIENT (the SDK,
;;; src/client.lisp). The core never depends on ACP: this system adapts the
;;; SDK as src/rpc.lisp does for --rpc, one ACP method onto one SDK call.
;;;   MAKE-CODE-ACP-AGENT &rest client-args → an agent whose CLIENT is
;;;     (MAKE-CLIENT client-args… :ON-EVENT … :ON-APPROVAL NIL): CLIENT-ARGS
;;;     are MAKE-CLIENT's but ON-EVENT and ON-APPROVAL, which are the agent's
;;;     (an ON-EVENT or ON-APPROVAL in CLIENT-ARGS → CODE-USAGE-ERROR). Its
;;;     ACP-PEER-INFO is an IMPLEMENTATION: name "cl-stack-code", title
;;;     "cl-stack-code", version CL-STACK-CODE:+VERSION+.
;;;   CODE-ACP-AGENT-CLIENT agent → the CODE-CLIENT (given).
;;;   CODE-ACP-AGENT-MCP-SERVERS agent session-id → the mcpServers of the
;;;     last session/new or session/load of SESSION-ID, as decoded (MCP-SERVER-
;;;     STDIO, MCP-SERVER-HTTP, MCP-SERVER-SSE objects, in order; a list), or NIL
;;;     for a session this agent does not have open.
;;;   CLOSE-CODE-ACP-AGENT agent → T: CLOSE-CLIENT (running turns are
;;;     interrupted and committed). Idempotent.
;;; One agent serves one connection. Its requests may run concurrently
;;; (acp-backend-stdio :CONCURRENT dispatch: a session/cancel or set_mode
;;; while a prompt runs), so its own state is under its LOCK.
;;;
;;; Threads (locked). Every message the agent sends (session/update,
;;; session/request_permission, fs/*, terminal/*) is sent from the thread
;;; running the ACP GF that caused it (ACP-PROMPT, ACP-LOAD-SESSION,
;;; ACP-SET-SESSION-MODE), never from the SDK's loop thread: the turn's
;;; events reach the prompt thread through a queue fed by CLIENT-TURN's
;;; ON-EVENT, and the prompt thread sends them in event order. A permission
;;; round trip blocks only the prompt thread, the loopback (not thread-safe,
;;; synchronous) sees one sender at a time, and every update of a turn is
;;; on the wire before its prompt response. Tool calls that go to the client
;;; (fs/*, terminal/*) run on the loop thread's tool workers and hand the
;;; request to the prompt thread the same way (or block on a request sent
;;; from there): they never call the client from the loop thread itself.
;;;
;;; The methods (the remote peer is ACP-PROTOCOL:*ACP-REMOTE*; the client's
;;; capabilities are ACP-CONNECTION-CLIENT-CAPABILITIES of
;;; ACP-PROTOCOL:*ACP-CONNECTION*, queried with CLIENT-SUPPORTS-P):
;;;
;;;   initialize → protocolVersion 1; agentCapabilities: loadSession true,
;;;     promptCapabilities {embeddedContext: true} (image and audio not
;;;     advertised), sessionCapabilities {list: {}, close: {}} (delete,
;;;     resume, additionalDirectories, systemPrompt and auth.logout not
;;;     advertised); mcpCapabilities {http: false, sse: false} (both sent
;;;     as false until H3e-2 connects MCP servers, see task.md); authMethods
;;;     []; agentInfo the agent's info. The client's capabilities decide fs / terminal (below).
;;;   authenticate, logout, session/delete, session/resume,
;;;     session/set_config_option: not implemented (acp-protocol's default
;;;     answers -32601).
;;;   session/new {cwd, mcpServers} → CLIENT-NEW-SESSION :CWD cwd (an
;;;     absolute path). mcpServers (stdio, http and sse servers alike) is
;;;     decoded and kept on the session (CODE-ACP-AGENT-MCP-SERVERS), never
;;;     refused, never connected yet: connecting them is H3e-2's SDK entry
;;;     (a documented TODO, task.md). → sessionId =
;;;     the SDK session's id (CODE-SESSION-ID, 32 hex digits: the id of its
;;;     record on disk); modes {currentModeId: PERMISSION-MODE-MODE-ID of
;;;     the session's mode, availableModes: one SESSION-MODE per
;;;     +ACP-MODE-IDS+, in order}. A configuration error (CODE-USAGE-ERROR,
;;;     SETTINGS-ERROR, MODEL-NOT-FOUND, …) → ACP-INVALID-PARAMS with its text.
;;;   session/load {sessionId, cwd, mcpServers} (mcpServers kept as for
;;;     session/new, replacing what the session had) → CLIENT-RESUME-SESSION of
;;;     sessionId (no such session → ACP-RESOURCE-NOT-FOUND, -32002, data
;;;     {"sessionId"}). Before the response, the session's record (the turns
;;;     of its head line, oldest first) is replayed as session/update
;;;     notifications: per turn a user_message_chunk with the prompt as the
;;;     record has it, then per assistant step its agent_thought_chunk
;;;     (thinking, when any), its agent_message_chunk (text, when any) and
;;;     per tool call a tool_call (status "completed" or "failed", rawInput)
;;;     followed by its tool_call_update with the result text. → modes, as
;;;     session/new. Later prompts continue the conversation (history kept).
;;;   session/list {cwd?} → CLIENT-LIST-SESSIONS :CWD cwd (default the
;;;     client's): one SESSION-INFO each, in that order: sessionId, cwd (the
;;;     project directory's absolute native namestring), title (the
;;;     "prompt" field; absent when null), updatedAt (RFC 3339 UTC of
;;;     "updated_at"; absent when null). No pagination: nextCursor absent.
;;;   session/close {sessionId} → CLIENT-CLOSE-SESSION; {} . Unknown or
;;;     already closed → ACP-RESOURCE-NOT-FOUND.
;;;   session/set_mode {sessionId, modeId} → the session's permission mode
;;;     becomes MODE-ID-PERMISSION-MODE of modeId from its next turn on (an
;;;     SDK function the core gains for it, see task.md), then a
;;;     current_mode_update with modeId is sent; {}. An unknown modeId →
;;;     ACP-INVALID-PARAMS; an unknown session → ACP-RESOURCE-NOT-FOUND.
;;;   session/prompt {sessionId, prompt} → {stopReason}. The prompt blocks:
;;;     text blocks are the prompt text, in order; a resource_link whose
;;;     file: URI names a regular file under the session's root is a
;;;     MENTION (its root-relative path); an embedded text resource is
;;;     appended to the prompt text with its URI and text (embeddedContext);
;;;     image / audio blocks → ACP-INVALID-PARAMS. Then CLIENT-TURN; every
;;;     event of the turn goes through EVENT-UPDATES (with the session's
;;;     cwd) and each update is sent, in event order, before the response.
;;;     Diffs: the tool_call of a write / edit / multi_edit carries one DIFF
;;;     content: path absolute, oldText the file's whole text before the
;;;     call (through fs/read_text_file when the client advertises it, else
;;;     from disk; absent when the file does not exist), newText the whole
;;;     text the call would leave (the edit applied to oldText; a write's
;;;     content); no diff when the edit does not apply.
;;;     Approvals: each approval_request → ACP-ASK-PERMISSION with the
;;;     session id, a TOOL-CALL-UPDATE (toolCallId the call id, title, kind,
;;;     status "pending", rawInput, the diff content as above) and
;;;     +ACP-PERMISSION-OPTIONS+; the kind → PERMISSION-KIND-DECISION →
;;;     CLIENT-RESPOND-APPROVAL (:always saves the rule as the TUI does;
;;;     :reject-all rejects every waiting call: one question for all of
;;;     them). A cancelled outcome answers nothing (the cancel interrupts).
;;;     The result event → RESULT-STOP-REASON; NIL → ACP-INTERNAL-ERROR
;;;     with the result's "error" as message. A session that is not open →
;;;     ACP-RESOURCE-NOT-FOUND; a turn already running → ACP-INVALID-REQUEST.
;;;   session/cancel {sessionId} → CLIENT-INTERRUPT of that session (an
;;;     unknown or idle one: ignored). Its prompt answers stopReason
;;;     "cancelled" (RESULT-STOP-REASON of the interrupted result), and a
;;;     permission request still pending is answered cancelled by the
;;;     client (acp-protocol).
;;;
;;; Client capabilities. When the client advertises fs.readTextFile /
;;; fs.writeTextFile, the session's file tools read / write files through
;;; fs/read_text_file / fs/write_text_file (absolute paths): the editor's
;;; buffers, unsaved changes included, and nothing touches the disk here.
;;; When it advertises terminal, the bash tool runs its command line through
;;; terminal/create (the shell and its arguments as the local bash tool
;;; would run them, cwd the tool root), terminal/wait_for_exit,
;;; terminal/output and terminal/release; the tool result is the output (and
;;; the exit status as the local tool reports it), and a tool_call_update of
;;; the call carries a TERMINAL content with the client's terminalId. A
;;; client that advertises neither gets the local tools, unchanged.

(defclass code-acp-agent (acp:acp-agent)
  ((client :initarg :client :reader code-acp-agent-client
           :documentation "The CODE-CLIENT this agent adapts.")
   (lock :initform (bt:make-lock "code-acp-agent") :reader %agent-lock)
   ;; The implementation's: open sessions by id, running prompts, queues …
   (state :initform nil :accessor %agent-state
          :documentation "Of the implementation's choice, under LOCK."))
  (:documentation "cl-stack-code as an ACP agent (ACP-2)."))

(defun make-code-acp-agent (&rest client-args)
  (declare (ignore client-args))
  (%acp2-pending 'make-code-acp-agent))

(defun close-code-acp-agent (agent)
  (declare (ignore agent))
  (%acp2-pending 'close-code-acp-agent))

(defmethod acp:acp-initialize ((agent code-acp-agent) request)
  (declare (ignore request))
  (%acp2-pending 'acp:acp-initialize))

(defmethod acp:acp-new-session ((agent code-acp-agent) request)
  (declare (ignore request))
  (%acp2-pending 'acp:acp-new-session))

(defmethod acp:acp-load-session ((agent code-acp-agent) request)
  (declare (ignore request))
  (%acp2-pending 'acp:acp-load-session))

(defmethod acp:acp-list-sessions ((agent code-acp-agent) request)
  (declare (ignore request))
  (%acp2-pending 'acp:acp-list-sessions))

(defmethod acp:acp-close-session ((agent code-acp-agent) request)
  (declare (ignore request))
  (%acp2-pending 'acp:acp-close-session))

(defmethod acp:acp-set-session-mode ((agent code-acp-agent) request)
  (declare (ignore request))
  (%acp2-pending 'acp:acp-set-session-mode))

(defmethod acp:acp-prompt ((agent code-acp-agent) request)
  (declare (ignore request))
  (%acp2-pending 'acp:acp-prompt))

(defmethod acp:acp-cancel ((agent code-acp-agent) notification)
  (declare (ignore notification))
  (%acp2-pending 'acp:acp-cancel))

(defun code-acp-agent-mcp-servers (agent session-id)
  (declare (ignore agent session-id))
  (%acp2-pending 'code-acp-agent-mcp-servers))
