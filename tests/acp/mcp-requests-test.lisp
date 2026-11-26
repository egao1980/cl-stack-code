(in-package #:cl-stack-code/acp/tests)

;;; H3e-2b in ACP (src/acp/requests.lisp): an MCP server's sampling request
;;; becomes a tool call and a session/request_permission, its elicitation
;;; becomes elicitation/create when the editor advertises elicitation.form,
;;; else it is declined. fake2 (cl-stack-code/tests' mcp2-support) is
;;; configured in the user settings, so every ACP session has it.

(defvar *elicitation-answer* nil
  "What the RECORDING-CLIENT answers to elicitation/create: (action content-hash-table-or-nil),
or NIL for the default (-32601, as acp-protocol's).")

(defmethod acp:acp-create-elicitation ((client recording-client) request)
  (%record client 'calls (cons "elicitation/create" request))
  (if *elicitation-answer*
      (destructuring-bind (action &optional content) *elicitation-answer*
        (if content
            (acp:make-acp 'acp:create-elicitation-response :action action :content content)
            (acp:make-acp 'acp:create-elicitation-response :action action)))
      (call-next-method)))

(defun %sampling-object (&key (id "mcp-sampling-1") (tool-use-id "call-1-1"))
  (args "type" "approval_request" "kind" "mcp_sampling" "session_id" "s" "step" 1 "id" id
        "name" "mcp_sampling" "server" "f2" "tool_use_id" (or tool-use-id :null)
        "input" (args "server" "f2"
                      "messages" (vector (args "role" "user" "text" "Write a haiku"))
                      "system_prompt" "You are fake2." "max_tokens" 4096 "model" "mock")
        "summary" "MCP server f2 asks the model (mock, ≤ 4096 tokens): Write a haiku"
        "preview" :null))

(defun %elicitation-object (&key (tool-use-id "call-1-1"))
  (args "type" "approval_request" "kind" "mcp_elicitation" "session_id" "s" "step" 1
        "id" "mcp-elicitation-1" "name" "mcp_elicitation" "server" "f2"
        "tool_use_id" (or tool-use-id :null)
        "input" (args "server" "f2" "message" "Which colour?"
                      "requested_schema" (json:decode cl-stack-code/tests::+fake2-schema-json+))
        "summary" "MCP server f2 asks: Which colour?" "preview" :null))

(defun %sampling-event (outcome &key (id "mcp-sampling-1"))
  (args "type" "system" "subtype" "mcp_sampling" "session_id" "s" "server" "f2" "request_id" id
        "tool_use_id" "call-1-1" "outcome" outcome "reason" :null "model" "mock" "max_tokens" 4096
        "usage" :null "error" :null))

(defun %f2-settings (config base &rest keys)
  (apply #'cl-stack-code/tests::user-fake2 config base keys))

(defun %f2-call (tool)
  (cl-stack-code/tests::f2-call tool))

(defun %allow (&rest tools)
  (make-settings :allow (mapcar (lambda (tool) (parse-permission-rule tool :allow)) tools)))

(defun %tool-text (client id)
  "The text contents of tool call ID's updates, joined."
  (format nil "~{~a~^~%~}" (loop for u in (tool-call-updates client id) append (text-contents u))))

;;; Mapping (pure)

(deftest acp-h3e2b-tool-search-kind
  (ok (equal "search" (tool-kind "tool_search")))
  (ok (equal "other" (tool-kind "mcp__f2__ask_model")) "MCP tools stay other"))

(deftest acp-h3e2b-sampling-tool-call
  (let ((tc (mcp-sampling-tool-call (%sampling-object))))
    (ok (typep tc 'acp:update-tool-call))
    (ok (equal "mcp-sampling-1" (acp:tool-call-id tc)))
    (ok (equal "other" (slot tc 'acp:kind)))
    (ok (equal "pending" (slot tc 'acp:status)))
    (ok (has "MCP server f2 asks the model" (slot tc 'acp:title)))
    (ok (equal "f2" (jget (slot tc 'acp:raw-input) "server")))
    (ok (equal (list (format nil "system: You are fake2.~%user: Write a haiku")) (text-contents tc))
        "the messages, one line each"))
  (let ((p (mcp-sampling-permission-tool-call (%sampling-object))))
    (ok (typep p 'acp:tool-call-update))
    (ok (equal "mcp-sampling-1" (acp:tool-call-id p)))
    (ok (equal "pending" (slot p 'acp:status)))))

(deftest acp-h3e2b-request-updates
  (let ((u (mcp-request-updates (%sampling-event "approved") :announced '("mcp-sampling-1"))))
    (ok (= 1 (length u)))
    (ok (typep (first u) 'acp:update-tool-call-update) "an announced request is updated")
    (ok (equal "completed" (slot (first u) 'acp:status))))
  (let ((u (mcp-request-updates (%sampling-event "rejected") :announced '("mcp-sampling-1"))))
    (ok (equal "failed" (slot (first u) 'acp:status))))
  (let ((u (mcp-request-updates (%sampling-event "allowed" :id "mcp-sampling-2") :announced '("mcp-sampling-1"))))
    (ok (= 1 (length u)))
    (ok (typep (first u) 'acp:update-tool-call) "one never asked is a finished tool call")
    (ok (equal "mcp-sampling-2" (acp:tool-call-id (first u))))
    (ok (equal "completed" (slot (first u) 'acp:status))))
  (ok (null (mcp-request-updates (args "type" "system" "subtype" "mcp_elicitation" "server" "f2"
                                       "request_id" "mcp-elicitation-1" "outcome" "accepted"
                                       "fields" #()))))
  (ok (null (mcp-request-updates (args "type" "system" "subtype" "init")))))

(deftest acp-h3e2b-elicitation-request
  (let ((r (elicitation-create-request (%elicitation-object) "sess-1")))
    (ok (typep r 'acp:create-elicitation-request))
    (ok (equal "form" (slot r 'acp:mode)))
    (ok (equal "MCP server f2 asks: Which colour?" (slot r 'acp:message)))
    (ok (equal "sess-1" (slot r 'acp:session-id)))
    (ok (equal "call-1-1" (slot r 'acp:tool-call-id)))
    (ok (equal "integer" (jget (slot r 'acp:requested-schema) "properties" "count" "type"))))
  (let ((r (elicitation-create-request (%elicitation-object :tool-use-id nil) "sess-1")))
    (ok (null (slot r 'acp:tool-call-id)) "no tool call: absent")))

(deftest-parametrize acp-h3e2b-elicitation-response
    ((action decision has-content)
     ("accept" :accept t)
     ("decline" :decline nil)
     ("cancel" :cancel nil)
     ("frobnicate" :decline nil))
  (let ((response (if has-content
                      (acp:make-acp 'acp:create-elicitation-response :action action
                                                                     :content (args "colour" "red"))
                      (acp:make-acp 'acp:create-elicitation-response :action action))))
    (multiple-value-bind (d content) (elicitation-response-decision response)
      (ok (eq decision d))
      (when has-content
        (ok (equal "red" (jget content "colour"))))))
  (multiple-value-bind (d content)
      (elicitation-response-decision (acp:make-acp 'acp:create-elicitation-response :action "accept"))
    (ok (eq :accept d))
    (ok (and (hash-table-p content) (zerop (hash-table-count content))) "accept without content: {}")))

;;; Loopback

(deftest acp-h3e2b-sampling-loopback
  (with-project (project config :base base) '()
    (%f2-settings config base :sampling t)
    (with-loopback (ra client project config :permission 'acp:allow-once
                    :settings (%allow "mcp__f2__ask_model")
                    :steps (list (%f2-call "ask_model") "Lisp in the morning" "Done."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "write a poem"))))
        (let ((announced (tool-calls client "mcp-sampling-1")))
          (ok (= 1 (length announced)) "the request is a tool call")
          (when announced
            (ok (equal "other" (slot (first announced) 'acp:kind)))))
        (let ((request (find "mcp-sampling-1" (permission-requests client)
                             :key (lambda (r) (acp:tool-call-id (acp:tool-call r))) :test #'equal)))
          (ok request "asked with session/request_permission")
          (when request
            (ok (equal +acp-permission-options+
                       (map 'list (lambda (o) (list (acp:option-id o) (acp:name o) (acp:kind o)))
                            (acp:options request))))))
        (ok (equal "completed" (final-status client "mcp-sampling-1")))
        (ok (has "sampled: Lisp in the morning" (%tool-text client "call-1-1"))
            "the MCP tool's result")
        (ok (equal "Done." (message-text client)))))))

(deftest acp-h3e2b-sampling-reject
  (with-project (project config :base base) '()
    (%f2-settings config base :sampling t)
    (with-loopback (ra client project config :permission 'acp:reject-once
                    :settings (%allow "mcp__f2__ask_model")
                    :steps (list (%f2-call "ask_model") "Done."))
      (let ((sid (req (new-session-id ra project))))
        (req (stop-reason ra sid "write a poem"))
        (ok (equal "failed" (final-status client "mcp-sampling-1")))
        (ok (has "sampling error -1" (%tool-text client "call-1-1")))))))

(deftest acp-h3e2b-elicitation-loopback
  (with-project (project config :base base) '()
    (%f2-settings config base)
    (unwind-protect
        (progn
          ;; Global, not LET: the recording client answers on its own thread.
          (setf *elicitation-answer* (list "accept" (args "colour" "blue")))
          (with-loopback (ra client project config :caps *zed-client-caps*
                                                   :settings (%allow "mcp__f2__ask_user")
                                                   :steps (list (%f2-call "ask_user") "Done."))
            (let ((sid (req (new-session-id ra project))))
              (ok (equal "end_turn" (req (stop-reason ra sid "ask me"))))
              (let ((calls (client-calls client "elicitation/create")))
                (ok (= 1 (length calls)) "elicitation/create on the editor")
                (when calls
                  (let ((r (cdr (first calls))))
                    (ok (equal "form" (slot r 'acp:mode)))
                    (ok (equal "MCP server f2 asks: Which colour?" (slot r 'acp:message)))
                    (ok (equal sid (slot r 'acp:session-id)))
                    (ok (equal "call-1-1" (slot r 'acp:tool-call-id))))))
              (ok (has "elicited: accept colour=blue" (%tool-text client "call-1-1"))))))
      (setf *elicitation-answer* nil))))

(deftest acp-h3e2b-elicitation-invalid-answer
  (with-project (project config :base base) '()
    (%f2-settings config base)
    (unwind-protect
        (progn
          ;; Global, not LET: the recording client answers on its own thread.
          (setf *elicitation-answer* (list "accept" (args "colour" "pink")))
          (with-loopback (ra client project config :caps *zed-client-caps*
                                                   :settings (%allow "mcp__f2__ask_user")
                                                   :steps (list (%f2-call "ask_user") "Done."))
            (let ((sid (req (new-session-id ra project))))
              (req (stop-reason ra sid "ask me"))
              (ok (has "elicited: decline" (%tool-text client "call-1-1"))
                  "content that does not match the schema is declined"))))
      (setf *elicitation-answer* nil))))

(deftest acp-h3e2b-elicitation-fallback
  (with-project (project config :base base) '()
    (%f2-settings config base)
    (unwind-protect
        (progn
          ;; Global, not LET: the recording client answers on its own thread.
          (setf *elicitation-answer* (list "accept" (args "colour" "blue")))
          (with-loopback (ra client project config :caps *bare-client-caps*
                                                   :settings (%allow "mcp__f2__ask_user")
                                                   :steps (list (%f2-call "ask_user") "Done."))
            (let ((sid (req (new-session-id ra project))))
              (ok (equal "end_turn" (req (stop-reason ra sid "ask me"))))
              (ok (null (client-calls client "elicitation/create")) "never asked without elicitation.form")
              (ok (has "elicited: decline" (%tool-text client "call-1-1"))
                  "declined, the documented fallback"))))
      (setf *elicitation-answer* nil))))
