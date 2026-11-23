(in-package #:cl-stack-code/tests)

;;; H3e-2b helpers (test code, complete).
;;;
;;; The fake2 server is H3e-2a's fake child (this SBCL, the parent's
;;; mcp-backend-stdio fasls through mcp-support's setup file), serving
;;; mcp-protocol's DISPATCH-MCP-METHOD on an rpc-backend-stdio transport in
;;; client mode (:ON-REQUEST, :DISPATCH :CONCURRENT). So a tool handler can
;;; send the client a JSON-RPC request and wait for its answer, as a
;;; 2025-11-25 server does (FastMCP's ctx.sample / ctx.elicit). The *_mrtr
;;; tools ask the 2026-07-28 way instead (mcp-protocol's REQUEST-SAMPLING /
;;; REQUEST-ELICITATION: the call answers input_required, the client retries
;;; with inputResponses); their second round needs mcp-protocol 0.5.0.
;;; Environment:
;;;   FAKE_MCP_INSTRUCTIONS  initialize's "instructions" (unset: none)
;;;   FAKE_MCP_EXTRA_TOOLS   N: also tool_01 … tool_NN, "Extra tool NN about
;;;                          TOPIC", TOPIC cycling weather, calendar, invoice,
;;;                          github, database (tool_03 and tool_08 are invoice)
;;; Tools (input schema {"type": "object"}):
;;;   echo {msg}            readOnlyHint; → msg
;;;   caps                  → "sampling=yes|no elicitation=yes|no form=yes|no":
;;;                           the client capabilities it last saw (initialize,
;;;                           or a 2026-07-28 request's _meta)
;;;   ask_model {prompt, max_tokens, hint}
;;;                         sampling/createMessage: messages [user PROMPT
;;;                         (default "Write a haiku")], systemPrompt "You are
;;;                         fake2.", maxTokens MAX_TOKENS (default 10000),
;;;                         modelPreferences hints [HINT (default "gpt-x")],
;;;                         includeContext "allServers"
;;;                         → "sampled: TEXT | model M | stop S", or
;;;                           "sampling error CODE MESSAGE"
;;;   ask_model_mrtr {prompt} the same request through REQUEST-SAMPLING
;;;   ask_user {question}   elicitation/create, mode "form", message QUESTION
;;;                         (default "Which colour?"), +FAKE2-SCHEMA+'s schema
;;;                         → "elicited: ACTION K=V K=V" (content keys sorted),
;;;                           or "elicitation error CODE MESSAGE"
;;;   ask_user_bad          elicitation with a nested object property
;;;   ask_user_mrtr         ask_user through REQUEST-ELICITATION

(defparameter +fake2-mcp-script+
  "(in-package :cl-user)
(format *error-output* \"fake2-mcp: started~%\") (finish-output *error-output*)
(defvar *transport* nil)
(defvar *caps* nil)
(defun env (name) (let ((v (uiop:getenv name))) (and v (plusp (length v)) v)))
(defun obj (&rest kv) (apply #'mcp-protocol:json-object kv))
(defun p (o k) (and (hash-table-p o) (mcp-protocol:param o k)))
(defvar *server* (make-instance 'mcp-protocol:mcp-server :name \"fake2\" :version \"1.0.0\"
                                :instructions (env \"FAKE_MCP_INSTRUCTIONS\")))
(defun note-caps (method params)
  (let ((c (if (equal method \"initialize\")
               (p params \"capabilities\")
               (p (p params \"_meta\") \"io.modelcontextprotocol/clientCapabilities\"))))
    (when (hash-table-p c) (setf *caps* c))))
(defun yes (x) (if x \"yes\" \"no\"))
(defun caps-text ()
  (format nil \"sampling=~a elicitation=~a form=~a\"
          (yes (p *caps* \"sampling\")) (yes (p *caps* \"elicitation\"))
          (yes (p (p *caps* \"elicitation\") \"form\"))))
(defun ask-client (method params)
  (handler-case (values (rpc-protocol:rpc-call method params :transport *transport* :timeout 300) nil)
    (rpc-protocol:rpc-error (e)
      (values nil (format nil \"~a ~a\" (rpc-protocol:rpc-error-code e) (rpc-protocol:rpc-error-message e))))))
(defun content-text (result)
  (let ((c (p result \"content\")))
    (cond ((hash-table-p c) (or (p c \"text\") \"\"))
          ((vectorp c) (format nil \"~{~a~}\" (map 'list (lambda (x) (or (p x \"text\") \"\")) c)))
          (t \"\"))))
(defun kv-text (content)
  (if (hash-table-p content)
      (format nil \"~{~a~^ ~}\"
              (sort (loop for k being the hash-keys of content using (hash-value v)
                          collect (format nil \"~a=~a\" k v))
                    #'string<))
      \"\"))
(defun sampling-params (prompt max-tokens hint)
  (obj \"messages\" (vector (obj \"role\" \"user\" \"content\" (obj \"type\" \"text\" \"text\" prompt)))
       \"systemPrompt\" \"You are fake2.\"
       \"maxTokens\" max-tokens
       \"modelPreferences\" (obj \"hints\" (vector (obj \"name\" hint)))
       \"includeContext\" \"allServers\"))
(defun sampled-text (result error)
  (if error
      (format nil \"sampling error ~a\" error)
      (format nil \"sampled: ~a | model ~a | stop ~a\" (content-text result) (p result \"model\")
              (p result \"stopReason\"))))
(defvar *schema*
  (obj \"type\" \"object\"
       \"properties\" (obj \"colour\" (obj \"type\" \"string\" \"title\" \"Colour\"
                                         \"enum\" (vector \"red\" \"green\" \"blue\"))
                         \"count\" (obj \"type\" \"integer\" \"title\" \"How many\" \"minimum\" 1 \"maximum\" 10)
                         \"note\" (obj \"type\" \"string\" \"description\" \"Anything else\"))
       \"required\" (vector \"colour\")))
(defun elicited-text (result error)
  (if error
      (format nil \"elicitation error ~a\" error)
      (format nil \"elicited: ~a ~a\" (p result \"action\") (kv-text (p result \"content\")))))
(defun tool (name description handler &key read-only)
  (mcp-protocol:register-tool
   *server*
   (apply #'mcp-protocol:make-mcp-tool name :description description
          :input-schema (obj \"type\" \"object\") :handler handler
          (and read-only (list :annotations (obj \"readOnlyHint\" t))))))
(tool \"echo\" \"Echo msg\" (lambda (a) (or (p a \"msg\") \"\")) :read-only t)
(tool \"caps\" \"The client capabilities\" (lambda (a) (declare (ignore a)) (caps-text)))
(tool \"ask_model\" \"Ask the client's model\"
      (lambda (a)
        (multiple-value-call #'sampled-text
          (ask-client \"sampling/createMessage\"
                      (sampling-params (or (p a \"prompt\") \"Write a haiku\")
                                       (or (p a \"max_tokens\") 10000) (or (p a \"hint\") \"gpt-x\"))))))
(tool \"ask_model_mrtr\" \"Ask the client's model (MRTR)\"
      (lambda (a)
        (sampled-text (mcp-protocol:request-sampling
                       (sampling-params (or (p a \"prompt\") \"Write a haiku\") 10000 \"gpt-x\") :id \"s1\")
                      nil)))
(tool \"ask_user\" \"Ask the user\"
      (lambda (a)
        (multiple-value-call #'elicited-text
          (ask-client \"elicitation/create\"
                      (obj \"mode\" \"form\" \"message\" (or (p a \"question\") \"Which colour?\")
                           \"requestedSchema\" *schema*)))))
(tool \"ask_user_bad\" \"Ask with a nested schema\"
      (lambda (a)
        (declare (ignore a))
        (multiple-value-call #'elicited-text
          (ask-client \"elicitation/create\"
                      (obj \"message\" \"Where?\"
                           \"requestedSchema\"
                           (obj \"type\" \"object\"
                                \"properties\" (obj \"address\" (obj \"type\" \"object\"
                                                                  \"properties\" (obj \"street\" (obj \"type\" \"string\"))))))))))
(tool \"ask_user_mrtr\" \"Ask the user (MRTR)\"
      (lambda (a)
        (declare (ignore a))
        (elicited-text (mcp-protocol:request-elicitation
                        (obj \"mode\" \"form\" \"message\" \"Which colour?\" \"requestedSchema\" *schema*)
                        :id \"e1\")
                       nil)))
(let ((n (let ((v (env \"FAKE_MCP_EXTRA_TOOLS\"))) (if v (parse-integer v) 0)))
      (topics '(\"weather\" \"calendar\" \"invoice\" \"github\" \"database\")))
  (loop for k from 1 to n
        do (let ((name (format nil \"tool_~2,'0d\" k)))
             (tool name (format nil \"Extra tool ~2,'0d about ~a\" k (nth (mod (1- k) 5) topics))
                   (lambda (a) (declare (ignore a)) (format nil \"~a ran\" name))))))
(defun handle (method params)
  (note-caps method params)
  (handler-case (mcp-protocol:dispatch-mcp-method *server* method params)
    (mcp-protocol:mcp-input-required (c)
      (mcp-protocol:input-required-result (mcp-protocol:mcp-input-required-requests c)
                                          (mcp-protocol:mcp-input-required-state c)))
    (mcp-protocol:mcp-error (c)
      (error 'rpc-protocol:rpc-error :message (or (mcp-protocol:mcp-error-message c) \"mcp error\")
                                     :code (or (mcp-protocol:mcp-error-code c) -32603)
                                     :data (mcp-protocol:mcp-error-data c)))))
(setf *transport* (rpc-backend-stdio:make-stdio-rpc-transport
                   :input *standard-input* :output *standard-output* :dispatch :concurrent
                   :on-request #'handle
                   :on-notification (lambda (m p) (ignore-errors (handle m p)))))
(rpc-backend-stdio:stdio-rpc-transport-wait-closed *transport*)
")

(defparameter +fake2-base-tools+
  '("echo" "caps" "ask_model" "ask_model_mrtr" "ask_user" "ask_user_bad" "ask_user_mrtr")
  "The fake2 server's own tools (before FAKE_MCP_EXTRA_TOOLS).")

(defparameter +fake2-instructions+
  "Use fake2's ask_model to write poems. Never call echo twice in a row."
  "The instructions the tests give fake2.")

(defun fake2-script (base)
  "Write the fake2 script under BASE (once) → its native namestring."
  (let ((path (merge-pathnames "fake2-mcp-server.lisp" (uiop:ensure-directory-pathname base))))
    (unless (probe-file path)
      (with-open-file (o path :direction :output :if-exists :supersede :external-format :utf-8)
        (write-string +fake2-mcp-script+ o)))
    (native path)))

(defun fake2-server (base &key instructions extra-tools env
                            (sampling nil sampling-p) (elicitation nil elicitation-p)
                            (include-instructions nil include-p) (always-load nil always-p))
  "A server object (hash table) running fake2. The H3e-2b keys are written
only when given: SAMPLING T, NIL (false) or a hash table; the others booleans."
  (let ((argv (apply #'child-argv
                     (append (%child-load-forms base)
                             (list (format nil "(load (uiop:parse-native-namestring ~s) :external-format :utf-8)"
                                           (fake2-script base))))))
        (env-object (make-hash-table :test 'equal)))
    (when instructions (setf (gethash "FAKE_MCP_INSTRUCTIONS" env-object) instructions))
    (when extra-tools (setf (gethash "FAKE_MCP_EXTRA_TOOLS" env-object) (princ-to-string extra-tools)))
    (loop for (k v) on env by #'cddr do (setf (gethash k env-object) v))
    (let ((object (args "command" (first argv) "args" (coerce (rest argv) 'vector) "env" env-object)))
      (when sampling-p (setf (gethash "sampling" object) sampling))
      (when elicitation-p (setf (gethash "elicitation" object) elicitation))
      (when include-p (setf (gethash "includeInstructions" object) include-instructions))
      (when always-p (setf (gethash "alwaysLoad" object) always-load))
      object)))

(defun extra-tool-names (n)
  (loop for k from 1 to n collect (format nil "tool_~2,'0d" k)))

(defun fake2-tools (&optional (extra 0))
  (append +fake2-base-tools+ (extra-tool-names extra)))

(defun user-fake2 (config base &rest keys)
  "User settings with fake2 as \"f2\" (KEYS as FAKE2-SERVER's)."
  (write-user-settings config "mcpServers" (args "f2" (apply #'fake2-server base keys))))

(defun pj2 (project config steps &rest argv)
  "-p stream-json run → (values exit out err backend)."
  (code project config (append (list "-p" "go" "--output-format" "stream-json") argv)
        :steps steps))

(defun f2-call (tool &rest kv)
  "A mock LLM step calling mcp__f2__TOOL with KV as its arguments."
  (list :tool (format nil "mcp__f2__~a" tool) (if kv (apply #'json-args kv) "{}")))

(defun f2-result (out tool)
  "The content of the tool_result of mcp__f2__TOOL in stream-json OUT."
  (jget (tool-result-of out (format nil "mcp__f2__~a" tool)) "content"))

(defun system-subtype-events (out subtype)
  "The stream-json \"system\" events of SUBTYPE in OUT."
  (remove-if-not (lambda (e) (equal subtype (jget e "subtype"))) (events out "system")))

(defun sdk-system-events (events subtype)
  "The collected SDK \"system\" events of SUBTYPE."
  (remove-if-not (lambda (e) (equal subtype (event-value e "subtype"))) (events-of events "system")))

(defun request-system-text (request)
  "The text of REQUEST's :system turn, or NIL."
  (let ((turn (find :system (request-turns request) :key #'llm:llm-turn-role)))
    (and turn (turn-text* turn))))

(defun pending-mcp (session kind &key (timeout 15))
  "Wait for a waiting approval of KIND (\"mcp_sampling\" / \"mcp_elicitation\") in
SESSION → its object, or NIL."
  (wait-until (lambda ()
                (find kind (client-pending-approvals session)
                      :key (lambda (r) (event-value r "kind")) :test #'equal))
              :timeout timeout))

(defun turn-tool-content (turn name)
  "The content of the first tool_result of NAME among TURN's events."
  (let ((r (find name (events-of (code-turn-events turn) "tool_result")
                 :key (lambda (e) (event-value e "name")) :test #'equal)))
    (and r (event-value r "content"))))

(defun color-content (&rest kv)
  "An elicitation content object from alternating keys and values."
  (apply #'args kv))

(defun sampling-request-of (backend)
  "The scripted request that carried fake2's sampling messages, or NIL."
  (find-if (lambda (r) (equal "You are fake2." (request-system-text r)))
           (scripted-requests backend)))

(defun mcp-setting-layers (&rest kv)
  "A settings object (hash table) from alternating keys and values, as JSON text."
  (json:encode (apply #'args kv)))
