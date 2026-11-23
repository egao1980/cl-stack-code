(in-package #:cl-stack-code/acp)

;;; H3e-2b (cl-stack-code 0.16.0): an MCP server's sampling and elicitation
;;; requests in ACP. The core's rules are src/mcp-requests.lisp; here only how
;;; the SDK's approval_request objects of kind mcp_* reach the editor. GIVEN:
;;; nothing but the header. STUBBED: the functions below. The agent's wiring
;;; (agent.lisp) is the implementation's.
;;;
;;; Like a tool approval, an MCP request reaches the prompt thread of the
;;; session's running session/prompt through the turn's event queue, and is
;;; asked from there (the "Threads (locked)" rule of agent.lisp). A request
;;; that comes while no prompt of its session runs is answered as headless -p
;;; answers it (sampling rejected, elicitation declined).
;;;
;;; Sampling (approval_request kind "mcp_sampling")
;;;   1. A tool_call session/update announces the request: MCP-SAMPLING-TOOL-CALL
;;;      object → an UPDATE-TOOL-CALL with toolCallId the request id, title the
;;;      object's "summary", kind "other", status "pending", rawInput the
;;;      object's "input", content one CONTENT whose TEXT-CONTENT is the
;;;      messages, one "ROLE: TEXT" line each (the system prompt first as
;;;      "system: TEXT" when there is one).
;;;   2. session/request_permission with toolCall MCP-SAMPLING-PERMISSION-TOOL-
;;;      CALL object (a TOOL-CALL-UPDATE: the same id, title, kind, status
;;;      "pending" and rawInput) and +ACP-PERMISSION-OPTIONS+ (as for tools);
;;;      PERMISSION-KIND-DECISION of the chosen kind → CLIENT-RESPOND-APPROVAL
;;;      (:always saves mcp_sampling(SERVER) as the TUI does). A cancelled
;;;      outcome answers nothing (the cancel interrupts, which rejects it).
;;;   3. The request's system event (subtype mcp_sampling) → MCP-REQUEST-
;;;      UPDATES event :announced ids → for an announced id an UPDATE-TOOL-
;;;      CALL-UPDATE of it, status "completed" (outcome allowed or approved)
;;;      or "failed" (any other), content one CONTENT with MCP-REQUEST-NOTICE
;;;      of the event; for an id not announced (allowed or denied by a rule,
;;;      never asked) one finished UPDATE-TOOL-CALL with that id, the notice as
;;;      title, kind "other", the same status. An mcp_elicitation event → no
;;;      update. Any other event → NIL (EVENT-UPDATES handles it).
;;; Elicitation (approval_request kind "mcp_elicitation")
;;;   With CLIENT-SUPPORTS-P of the client's capabilities :ELICITATION-FORM
;;;   (Zed advertises elicitation.form): elicitation/create on the client,
;;;   ELICITATION-CREATE-REQUEST object session-id → a CREATE-ELICITATION-
;;;   REQUEST: mode "form", message "MCP server S asks: MESSAGE", requestedSchema
;;;   the object's "requested_schema", sessionId SESSION-ID, toolCallId the
;;;   object's "tool_use_id" when it is a string. The response →
;;;   ELICITATION-RESPONSE-DECISION response → (values decision content):
;;;   action "accept" → :ACCEPT and the content (a hash table; absent → an
;;;   empty object), "decline" → :DECLINE, "cancel" → :CANCEL, anything else
;;;   → :DECLINE. Then CLIENT-RESPOND-APPROVAL :CONTENT; content that does not
;;;   match the schema (MCP-ELICITATION-CONTENT-ERROR) is answered :DECLINE.
;;;   An error from the client (it does not implement the method) → :DECLINE.
;;;   Without the capability (the documented fallback): :DECLINE at once, and
;;;   the system event's "reason" is "unsupported". Nothing is shown: an
;;;   editor that cannot render a form gets no half-form through
;;;   request_permission.
;;; tool_search (src/mcp-context.lisp): TOOL-KIND "tool_search" → "search".

(defun mcp-sampling-tool-call (object)
  "→ the UPDATE-TOOL-CALL announcing the sampling approval_request OBJECT."
  (declare (ignore object))
  (code::%h3e2b-pending "mcp-sampling-tool-call"))

(defun mcp-sampling-permission-tool-call (object)
  "→ the TOOL-CALL-UPDATE of OBJECT's session/request_permission."
  (declare (ignore object))
  (code::%h3e2b-pending "mcp-sampling-permission-tool-call"))

(defun mcp-request-updates (event &key announced)
  "→ the session/update objects for a system event of subtype mcp_sampling /
mcp_elicitation (see the header); ANNOUNCED: the request ids announced so far."
  (declare (ignore event announced))
  (code::%h3e2b-pending "mcp-request-updates"))

(defun elicitation-create-request (object session-id)
  "→ the CREATE-ELICITATION-REQUEST for the elicitation approval_request OBJECT."
  (declare (ignore object session-id))
  (code::%h3e2b-pending "elicitation-create-request"))

(defun elicitation-response-decision (response)
  "→ (values decision content) of a CREATE-ELICITATION-RESPONSE."
  (declare (ignore response))
  (code::%h3e2b-pending "elicitation-response-decision"))

(export '(mcp-sampling-tool-call mcp-sampling-permission-tool-call mcp-request-updates
          elicitation-create-request elicitation-response-decision))
