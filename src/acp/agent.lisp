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
;;;     advertised); mcpCapabilities {http: true, sse: false} (#40: legacy
;;;     HTTP+SSE servers are reported as unsupported by the SDK); authMethods
;;;     []; agentInfo the agent's info. The client's capabilities decide fs / terminal (below).
;;;   authenticate, logout, session/delete, session/resume,
;;;     session/set_config_option: not implemented (acp-protocol's default
;;;     answers -32601).
;;;   session/new {cwd, mcpServers} → CLIENT-NEW-SESSION :CWD cwd (an
;;;     absolute path) :MCP-SERVERS (#40: stdio → command / args / env,
;;;     http and sse → url / headers, as MCP-SERVER-CONFIGs of scope :sdk,
;;;     trusted; an sse one is reported unsupported, a server that fails to
;;;     start is reported failed, neither fails the session). The decoded
;;;     servers are also kept on the session (CODE-ACP-AGENT-MCP-SERVERS),
;;;     never refused. → sessionId =
;;;     the SDK session's id (CODE-SESSION-ID, 32 hex digits: the id of its
;;;     record on disk); modes {currentModeId: PERMISSION-MODE-MODE-ID of
;;;     the session's mode, availableModes: one SESSION-MODE per
;;;     +ACP-MODE-IDS+, in order}. A configuration error (CODE-USAGE-ERROR,
;;;     SETTINGS-ERROR, MODEL-NOT-FOUND, …) → ACP-INVALID-PARAMS with its text.
;;;   session/load {sessionId, cwd, mcpServers} (mcpServers kept as for
;;;     session/new, replacing what the session had; passed to
;;;     CLIENT-RESUME-SESSION :MCP-SERVERS, or, for a session still open,
;;;     CLIENT-ADD-MCP-SERVERS) → CLIENT-RESUME-SESSION of
;;;     sessionId. #44: no such session on disk, and sessionId has the form
;;;     this agent hands out (32 lowercase hex digits) → CLIENT-NEW-SESSION
;;;     :SESSION-ID sessionId, an empty session under that id: the SDK's
;;;     session store writes nothing before a session's first turn (src/
;;;     sessions.lisp, "Laziness"), so a session/new that never had a turn
;;;     (an editor restoring its last thread after a restart) has no record.
;;;     Any other id → ACP-RESOURCE-NOT-FOUND, -32002, data {"sessionId"}.
;;;     Before the response, the session's record (the turns
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

;;; Implementation. The agent's STATE is an %ASTATE: the open ACP sessions by
;;; id (each an %ASESS: the SDK session, its COURIER (bridge.lisp), the
;;; client capabilities it was opened with and its mcpServers) and the closed
;;; flag, under the agent's LOCK.

(defstruct (%astate (:constructor %make-astate ()))
  (sessions (make-hash-table :test 'equal))
  (closed nil))

(defstruct (%asess (:constructor %make-asess (courier caps)))
  courier caps session (mcp-servers '())
  (context-sent nil))  ; #41: the session-context update went out

(defparameter +%mode-titles+
  '("Default" "Accept edits" "Bypass permissions" "Plan")
  "The SESSION-MODE names, in +ACP-MODE-IDS+ order.")

(defun make-code-acp-agent (&rest client-args)
  (loop for (key) on client-args by #'cddr
        when (member key '(:on-event :on-approval))
          do (error 'code:code-usage-error
                    :message (format nil "MAKE-CODE-ACP-AGENT: ~s is the agent's own" key)))
  (let ((client (apply #'code:make-client :on-event nil :on-approval nil client-args)))
    (let ((agent (make-instance 'code-acp-agent
                                :client client
                                :info (acp:make-acp 'acp:implementation
                                                    :name "cl-stack-code"
                                                    :title "cl-stack-code"
                                                    :version code:+version+))))
      (setf (%agent-state agent) (%make-astate))
      agent)))

(defun close-code-acp-agent (agent)
  (let ((first (bt:with-lock-held ((%agent-lock agent))
                 (let ((state (%agent-state agent)))
                   (unless (%astate-closed state)
                     (setf (%astate-closed state) t))))))
    (when first
      (code:close-client (code-acp-agent-client agent)))
    t))

(defun %agent-closed-p (agent)
  (bt:with-lock-held ((%agent-lock agent))
    (%astate-closed (%agent-state agent))))

(defun %find-asess (agent id &key (errorp t))
  "The open %ASESS of session ID; none → ACP-RESOURCE-NOT-FOUND (or NIL)."
  (or (and (stringp id)
           (bt:with-lock-held ((%agent-lock agent))
             (gethash id (%astate-sessions (%agent-state agent)))))
      (and errorp (%session-not-found id))))

(defun %session-not-found (id)
  (error 'acp:acp-resource-not-found
         :message (format nil "No session ~a" id)
         :data (let ((h (make-hash-table :test 'equal)))
                 (setf (gethash "sessionId" h) (if (stringp id) id :null))
                 h)))

(defun %put-asess (agent id as)
  (bt:with-lock-held ((%agent-lock agent))
    (setf (gethash id (%astate-sessions (%agent-state agent))) as)))

(defun %drop-asess (agent id)
  (bt:with-lock-held ((%agent-lock agent))
    (remhash id (%astate-sessions (%agent-state agent)))))

(defun %rekey (agent as new-id)
  "Decision 2: a conflict fork gave the session NEW-ID."
  (let ((old (courier-session-id (%asess-courier as))))
    (when (and (stringp new-id) (not (equal old new-id)))
      (bt:with-lock-held ((%agent-lock agent))
        (let ((table (%astate-sessions (%agent-state agent))))
          (remhash old table)
          (setf (gethash new-id table) as
                (courier-session-id (%asess-courier as)) new-id))))))

(defun code-acp-agent-mcp-servers (agent session-id)
  (let ((as (%find-asess agent session-id :errorp nil)))
    (and as (copy-list (%asess-mcp-servers as)))))

;;; SDK conditions → ACP conditions (translation only, at the GF boundary).

(defun %sdk-error (condition)
  (let ((text (princ-to-string condition)))
    (typecase condition
      (acp:acp-error condition)
      (code:session-not-found
       (%session-not-found-object (code:session-not-found-designator condition) text))
      (code:session-not-open
       (%session-not-found-object (code:session-not-open-id condition) text))
      (code:turn-busy (make-condition 'acp:acp-invalid-request :message text))
      ((or code:code-usage-error code:settings-error code:model-not-found
           code:lisp-image-error code:checkpoint-error)
       (make-condition 'acp:acp-invalid-params :message text))
      (t (make-condition 'acp:acp-internal-error :message text :cause condition)))))

(defun %session-not-found-object (id text)
  (make-condition 'acp:acp-resource-not-found
                  :message text
                  :data (let ((h (make-hash-table :test 'equal)))
                          (setf (gethash "sessionId" h) (if (stringp id) id :null))
                          h)))

(defmacro with-sdk-errors (() &body body)
  "BODY; an SDK error leaves as its ACP condition (ACP conditions as they are)."
  `(handler-case (progn ,@body)
     (acp:acp-error (e) (error e))
     (error (e) (error (%sdk-error e)))))

(defun %client-caps ()
  "The capabilities the connection's client advertised at initialize."
  (and acp:*acp-connection*
       (acp:acp-connection-client-capabilities acp:*acp-connection*)))

(defun %modes (session)
  (acp:make-acp 'acp:session-mode-state
                :current-mode-id (permission-mode-mode-id (code:code-session-permission-mode session))
                :available-modes (map 'vector (lambda (id title)
                                                (acp:make-acp 'acp:session-mode :id id :name title))
                                      +acp-mode-ids+ +%mode-titles+)))

(defun %slot (object name)
  "OBJECT's slot NAME, or NIL when unbound or JSON null."
  (and object (slot-boundp object name)
       (let ((v (slot-value object name))) (if (eq v :null) nil v))))

(defun %mcp-servers (request)
  (coerce (or (%slot request 'acp:mcp-servers) #()) 'list))

(defun %pairs (entries)
  "ACP name / value objects (env-variable, http-header) → an alist."
  (map 'list (lambda (e) (cons (acp:name e) (acp:value e))) (or entries #())))

(defun %mcp-server-config (server)
  "One ACP mcpServers entry → the SDK's MCP-SERVER-CONFIG (scope :sdk)."
  (etypecase server
    (acp:mcp-server-stdio
     (code:make-mcp-server-config (acp:name server) :scope :sdk :transport :stdio
                                  :command (acp:command server)
                                  :args (coerce (or (%slot server 'acp:args) #()) 'list)
                                  :env (%pairs (%slot server 'acp:env))))
    ((or acp:mcp-server-http acp:mcp-server-sse)
     (code:make-mcp-server-config (acp:name server) :scope :sdk
                                  :transport (if (typep server 'acp:mcp-server-sse) :sse :http)
                                  :url (acp:url server)
                                  :headers (%pairs (%slot server 'acp:headers))))))

(defun %mcp-server-configs (servers)
  (mapcar #'%mcp-server-config servers))

;;; initialize

(defmethod acp:acp-initialize ((agent code-acp-agent) request)
  (declare (ignore request))
  (make-instance 'acp:initialize-response
                 :protocol-version 1
                 :agent-capabilities
                 (make-instance 'acp:agent-capabilities
                                :load-session t
                                :prompt-capabilities (make-instance 'acp:prompt-capabilities
                                                                    :embedded-context t)
                                ;; #40: HTTP servers connect; legacy SSE is unsupported
                                :mcp-capabilities (make-instance 'acp:mcp-capabilities
                                                                 :http t :sse nil)
                                :session-capabilities
                                (make-instance 'acp:session-capabilities
                                               :session-list (make-hash-table :test 'equal)
                                               :session-close (make-hash-table :test 'equal)))
                 :auth-methods (vector)
                 :agent-info (acp:acp-peer-info agent)))

;;; session/new, session/load

(defun %open-asess (agent caps open-fn)
  "OPEN-FN (tool-sources-hook) → the SDK session; → the %ASESS, registered."
  (let* ((courier (make-courier))
         (as (%make-asess courier caps))
         (session (funcall open-fn (tool-sources-hook courier caps)))
         (id (code:code-session-id session)))
    (setf (courier-session-id courier) id
          (%asess-session as) session)
    (%put-asess agent id as)
    as))

(defmethod acp:acp-new-session ((agent code-acp-agent) request)
  (with-sdk-errors ()
    (let* ((client (code-acp-agent-client agent))
           (servers (%mcp-servers request))
           (as (%open-asess agent (%client-caps)
                            (lambda (hook)
                              (code:client-new-session client :cwd (acp:cwd request)
                                                              :tool-sources hook
                                                              :mcp-servers (%mcp-server-configs servers))))))
      (setf (%asess-mcp-servers as) servers)
      (acp:make-acp 'acp:new-session-response
                    :session-id (courier-session-id (%asess-courier as))
                    :modes (%modes (%asess-session as))))))

(defun %handed-out-id-p (id)
  "#44: ID has the form of the session ids this agent hands out (32 lowercase
hex digits: NORMALIZE-SESSION-ID leaves it as it is)."
  (and (stringp id) (equal id (code:normalize-session-id id))))

(defmethod acp:acp-load-session ((agent code-acp-agent) request)
  (with-sdk-errors ()
    (let* ((client (code-acp-agent-client agent))
           (id (acp:session-id request))
           (servers (%mcp-servers request))
           (open (%find-asess agent id :errorp nil))
           (as (or open
                   (%open-asess agent (%client-caps)
                                (lambda (hook)
                                  (handler-case
                                      (code:client-resume-session
                                       client id :cwd (acp:cwd request)
                                                 :tool-sources hook
                                                 :mcp-servers (%mcp-server-configs servers))
                                    (code:session-not-found ()
                                      ;; #44: a session without turns has no
                                      ;; record (the store writes nothing before
                                      ;; the first commit): open it again, empty,
                                      ;; under its id.
                                      (if (%handed-out-id-p id)
                                          (code:client-new-session
                                           client :cwd (acp:cwd request)
                                                  :session-id id
                                                  :tool-sources hook
                                                  :mcp-servers (%mcp-server-configs servers))
                                          (%session-not-found id)))))))))
      (when (and open servers)
        (code:client-add-mcp-servers (%asess-session as) (%mcp-server-configs servers)))
      (setf (%asess-mcp-servers as) servers)
      (%replay as)
      (acp:make-acp 'acp:load-session-response :modes (%modes (%asess-session as))))))

;;; The replay of a session's record (session/load), from the SDK's JSON
;;; export (CLIENT-EXPORT-SESSION; the schema is EXPORT-SESSION's).

(defun %jv (object &rest keys)
  (let ((v (apply #'code:event-value object keys)))
    (if (eq v :null) nil v)))

(defun %part-input (part)
  "A tool_call part's arguments as a JSON object, or the raw string."
  (let ((arguments (%jv part "arguments")))
    (or (%decoded-arguments arguments) arguments)))

(defun %replay (as)
  (let* ((session (%asess-session as))
         (sid (courier-session-id (%asess-courier as)))
         (cwd (code:code-session-cwd session))
         (export (json:decode (code:client-export-session session :format :json)))
         (remote acp:*acp-remote*))
    (flet ((send (update) (acp:acp-send-update remote sid update))
           (parts (message) (coerce (or (%jv message "parts") #()) 'list)))
      (loop for turn across (or (%jv export "turns") #())
            for messages = (coerce (or (%jv turn "messages") #()) 'list)
            do (let ((prompt (%jv turn "prompt")))
                 (when (stringp prompt)
                   (send (acp:make-acp 'acp:update-user-message-chunk
                                       :content (%text-content prompt)))))
               (let ((results (make-hash-table :test 'equal)))
                 (dolist (m messages)
                   (dolist (p (parts m))
                     (when (equal "tool_result" (%jv p "type"))
                       (setf (gethash (%jv p "id") results) p))))
                 (dolist (m messages)
                   (when (equal "assistant" (%jv m "role"))
                     (dolist (p (parts m))
                       (let ((type (%jv p "type"))
                             (text (%jv p "text")))
                         (cond
                           ((and (equal type "thinking") (stringp text) (plusp (length text)))
                            (send (acp:make-acp 'acp:update-agent-thought-chunk
                                                :content (%text-content text))))
                           ((and (equal type "text") (stringp text) (plusp (length text)))
                            (send (acp:make-acp 'acp:update-agent-message-chunk
                                                :content (%text-content text))))
                           ((equal type "tool_call")
                            (let* ((id (%jv p "id"))
                                   (name (%jv p "name"))
                                   (input (%part-input p))
                                   (result (gethash id results))
                                   (status (if (and result (not (%jv result "is_error")))
                                               "completed"
                                               "failed")))
                              (send (acp:make-acp 'acp:update-tool-call
                                                  :tool-call-id id
                                                  :title (code:tool-call-summary name input)
                                                  :kind (tool-kind name)
                                                  :status status
                                                  :raw-input input
                                                  :locations (tool-call-locations input cwd)))
                              (send (acp:make-acp 'acp:update-tool-call-update
                                                  :tool-call-id id
                                                  :status status
                                                  :content (%result-text-content
                                                            (let ((c (and result (%jv result "content"))))
                                                              (if (stringp c) c "")))))))))))))))))

;;; session/list, session/close, session/set_mode, session/cancel

(defmethod acp:acp-list-sessions ((agent code-acp-agent) request)
  (with-sdk-errors ()
    (let* ((client (code-acp-agent-client agent))
           (cwd (%slot request 'acp:cwd))
           (rows (code:client-list-sessions client :cwd cwd))
           (dir (uiop:native-namestring
                 (if cwd
                     (truename (uiop:ensure-directory-pathname (uiop:parse-native-namestring cwd)))
                     (code:client-cwd client)))))
      (acp:make-acp 'acp:list-sessions-response
                    :sessions (map 'vector
                                   (lambda (row)
                                     (let ((prompt (%jv row "prompt"))
                                           (at (%jv row "updated_at")))
                                       (acp:make-acp 'acp:session-info
                                                     :session-id (%jv row "session_id")
                                                     :cwd dir
                                                     :title (and (stringp prompt) prompt)
                                                     :updated-at (and (integerp at)
                                                                      (dt:print-rfc3339 (dt:make-instant at))))))
                                   rows)))))

(defmethod acp:acp-close-session ((agent code-acp-agent) request)
  (with-sdk-errors ()
    (let* ((id (acp:session-id request))
           (as (%find-asess agent id)))
      (%drop-asess agent id)
      (code:client-close-session (%asess-session as))
      (acp:make-acp 'acp:close-session-response))))

(defmethod acp:acp-set-session-mode ((agent code-acp-agent) request)
  (with-sdk-errors ()
    (let* ((id (acp:session-id request))
           (as (%find-asess agent id))
           (mode-id (acp:mode-id request))
           (mode (mode-id-permission-mode mode-id)))
      (unless mode
        (error 'acp:acp-invalid-params
               :message (format nil "Unknown mode ~s: use one of ~{~a~^, ~}" mode-id +acp-mode-ids+)))
      (code:client-set-permission-mode (%asess-session as) mode)
      (acp:acp-send-update acp:*acp-remote* (courier-session-id (%asess-courier as))
                           (acp:make-acp 'acp:update-current-mode-update
                                         :current-mode-id (permission-mode-mode-id mode)))
      (acp:make-acp 'acp:set-session-mode-response))))

(defmethod acp:acp-cancel ((agent code-acp-agent) notification)
  (let ((as (%find-asess agent (acp:session-id notification) :errorp nil)))
    (when as
      ;; An idle or closing session: nothing to stop.
      (handler-case (code:client-interrupt (%asess-session as))
        (error () nil))
      (kill-client-terminals (%asess-courier as)))
    nil))

;;; session/prompt

(defun %link-mention (root uri)
  "The root-relative path of a file: URI naming a regular file under ROOT, or NIL."
  (let* ((path (handler-case (fs:path-pathname (fs:ensure-path uri))
                 (error () nil)))
         (true (and path (probe-file path)))
         (root (uiop:ensure-directory-pathname root)))
    (and (stringp uri) (uiop:string-prefix-p "file:" uri)
         true (pathname-name true) (uiop:subpathp true root)
         (uiop:unix-namestring (uiop:enough-pathname true root)))))

(defun %prompt-input (session blocks)
  "→ (values text mentions) of the prompt BLOCKS (agent.lisp header). Image,
audio, blob or unknown blocks → ACP-INVALID-PARAMS."
  (let ((texts '()) (mentions '()) (root (code:code-session-cwd session)))
    (loop for block across (or blocks #())
          do (typecase block
               (acp:text-content (push (acp:text block) texts))
               (acp:resource-link
                (let ((rel (%link-mention root (acp:uri block))))
                  (if rel
                      (push rel mentions)
                      (push (format nil "[~a](~a)" (acp:name block) (acp:uri block)) texts))))
               (acp:embedded-resource
                (let ((r (acp:resource block)))
                  (unless (typep r 'acp:text-resource-contents)
                    (error 'acp:acp-invalid-params
                           :message "Binary embedded resources are not supported"))
                  (push (format nil "<resource uri=\"~a\">~%~a~%</resource>" (acp:uri r) (acp:text r))
                        texts)))
               (t (error 'acp:acp-invalid-params
                         :message (format nil "~a content is not supported (not advertised)"
                                          (if (typep block 'acp:content-block)
                                              (%slot block 'acp:wire-type)
                                              "This"))))))
    (let ((text (format nil "~{~a~^~%~%~}" (nreverse texts)))
          (mentions (nreverse mentions)))
      (values (if (and mentions (string= "" (string-trim '(#\Space #\Tab #\Newline) text)))
                  (format nil "See ~{~a~^, ~}." mentions)
                  text)
              mentions))))

(defparameter +%edit-tool-names+ '("write" "edit" "multi_edit"))

(defun %diff-content (cwd rel old new new-file-p)
  (acp:make-acp 'acp:diff
                :path (uiop:native-namestring (merge-pathnames (uiop:parse-unix-namestring rel) cwd))
                :old-text (and (not new-file-p) old)
                :new-text new))

(defun %local-diff (as event)
  "Loop thread: the DIFF of an edit tool_use from the disk, before the tool can
run; NIL for a client-fs session (the pump reads the buffer) or no diff."
  (when (and (equal "tool_use" (code:event-type event))
             (member (code:event-value event "name") +%edit-tool-names+ :test #'equal)
             (not (acp:client-supports-p (%asess-caps as) :read-text-file)))
    (let ((cwd (code:code-session-cwd (%asess-session as))))
      (multiple-value-bind (rel old new new-file-p)
          (code:tool-call-texts cwd (code:event-value event "name") (code:event-value event "input"))
        (and rel (%diff-content cwd rel old new new-file-p))))))

(defun %client-diff (as event)
  "Pumping thread: the DIFF of an edit tool_use against the client's buffer."
  (when (and (member (code:event-value event "name") +%edit-tool-names+ :test #'equal)
             (acp:client-supports-p (%asess-caps as) :read-text-file))
    (let ((cwd (code:code-session-cwd (%asess-session as)))
          (courier (%asess-courier as)))
      (multiple-value-bind (rel old new new-file-p)
          (code:tool-call-texts
           cwd (code:event-value event "name") (code:event-value event "input")
           :read-file (lambda (rel)
                        (let ((text (client-read-text
                                     courier
                                     (uiop:native-namestring
                                      (merge-pathnames (uiop:parse-unix-namestring rel) cwd)))))
                          (values text (and text t)))))
        (and rel (%diff-content cwd rel old new new-file-p))))))

(defun %send-event (as event diff diffs)
  "EVENT's updates to the client; a tool_use of an edit tool carries its DIFF."
  (let ((sid (courier-session-id (%asess-courier as)))
        (cwd (code:code-session-cwd (%asess-session as))))
    (dolist (update (event-updates event :cwd cwd))
      (when (typep update 'acp:update-tool-call)
        (let ((diff (or diff (%client-diff as event))))
          (when diff
            (setf (gethash (acp:tool-call-id update) diffs) diff
                  (acp:content update) (vector diff)))))
      (acp:acp-send-update acp:*acp-remote* sid update))))

(defun %ask (as event answered diffs)
  "An approval_request: one session/request_permission, its answer to the SDK.
Calls a previous answer resolved already (:always, :reject-all) ask nothing."
  (let ((id (code:event-value event "id")))
    (unless (gethash id answered)
      (let* ((session (%asess-session as))
             (name (code:event-value event "name"))
             (input (code:event-value event "input"))
             (diff (gethash id diffs))
             (locations (tool-call-locations input (code:code-session-cwd session)))
             (tool-call (acp:make-acp 'acp:tool-call-update
                                      :tool-call-id id
                                      :title (code:tool-call-summary name input)
                                      :kind (tool-kind name)
                                      :status "pending"
                                      :raw-input input
                                      :content (and diff (vector diff))
                                      :locations (and (plusp (length locations)) locations)))
             (decision (permission-kind-decision
                        (acp:acp-ask-permission acp:*acp-remote* (courier-session-id (%asess-courier as))
                                                tool-call +acp-permission-options+))))
        ;; A cancelled outcome answers nothing: the cancel interrupts the turn.
        (when decision
          (handler-case
              (dolist (resolved (code:client-respond-approval session id decision))
                (setf (gethash resolved answered) t))
            (code:approval-not-found () nil)))))))

(defun %pump (agent as)
  "Pump AS's courier on this (the prompt's) thread until the turn's result. → it."
  (let ((courier (%asess-courier as))
        (client (code-acp-agent-client agent))
        (answered (make-hash-table :test 'equal))
        (diffs (make-hash-table :test 'equal)))
    (loop
      (let ((item (courier-take courier 1)))
        (cond
          ((null item)
           (when (or (%agent-closed-p agent) (code:client-closed-p client))
             (error 'acp:acp-internal-error :message "The agent closed during the turn")))
          ((eq :call (first item)) (courier-run-call courier item))
          (t (destructuring-bind (event diff) (rest item)
               (let ((type (code:event-type event)))
                 (cond ((equal type "result") (return event))
                       ((equal type "approval_request") (%ask as event answered diffs))
                       (t (%send-event as event diff diffs)))))))))))

(defmethod acp:acp-prompt ((agent code-acp-agent) request)
  (with-sdk-errors ()
    (let* ((as (%find-asess agent (acp:session-id request)))
           (session (%asess-session as))
           (courier (%asess-courier as)))
      (multiple-value-bind (text mentions) (%prompt-input session (%slot request 'acp:prompt))
        (courier-claim courier)
        ;; #41: once per session, what it found (instructions, skills, rules)
        (unless (%asess-context-sent as)
          (setf (%asess-context-sent as) t)
          (handler-case
              (dolist (update (session-init-updates (code:code-session-init session)
                                                    :cwd (code:code-session-cwd session)))
                (acp:acp-send-update acp:*acp-remote* (courier-session-id courier) update))
            (error () nil)))
        (let ((result nil) (started nil))
          (unwind-protect
               (progn
                 (code:client-turn session text
                                   :mentions mentions
                                   :on-event (lambda (s event)
                                               (declare (ignore s))
                                               (courier-post courier
                                                             (list :event event
                                                                   ;; a diff is a nicety:
                                                                   ;; never lose the event
                                                                   (handler-case (%local-diff as event)
                                                                     (error () nil))))))
                 (setf started t
                       result (%pump agent as)))
            (courier-release courier)
            ;; Left without the result (an error, $/cancel_request): the turn
            ;; must not run on unseen.
            (when (and started (null result))
              (handler-case (code:client-interrupt session)
                (error () nil))))
          (%rekey agent as (code:event-value result "session_id"))
          (let ((reason (result-stop-reason result)))
            (if reason
                (acp:make-acp 'acp:prompt-response :stop-reason reason)
                (error 'acp:acp-internal-error
                       :message (let ((e (code:event-value result "error")))
                                  (if (stringp e) e "The turn failed"))))))))))
