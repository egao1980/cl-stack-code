(in-package #:cl-stack-code)

;;; H3e-2b (0.16.0), part 1: the servers' requests to the client. Brief:
;;; cl-stack docs/capabilities/cl-stack-code.md, "H3e-2b — locked". Part 2
;;; (server instructions, deferred tool loading) is src/mcp-context.lisp; the
;;; configuration keys are src/mcp-config.lisp's H3e-2b paragraph.
;;;
;;; A server may ask its client two things while it runs (usually inside one
;;; of its tool calls): to sample the model (sampling/createMessage) and to ask
;;; the user (elicitation/create). Both go through the session's permission
;;; rules (ai-agent-protocol's engine, as every tool call; the rules-and-logic
;;; rule: no table of our own) and, when the answer is "ask", through the
;;; session's approval channel: the TUI dialog, the SDK's approval_request
;;; events and CLIENT-RESPOND-APPROVAL, --rpc approval/respond, ACP's
;;; session/request_permission and elicitation/create. Headless -p never asks.
;;;
;;; Building blocks (stack first; the names their contracts lock):
;;;   mcp-protocol 0.5.0 (egao1980/mcp-protocol, H3e-2b issue): a client
;;;     advertises "sampling": {} when it has a sampling handler and
;;;     "elicitation": {"form": {}} when it has an elicitation handler, in
;;;     initialize and in every 2026-07-28 request's _meta; a server tool that
;;;     asks with REQUEST-SAMPLING / REQUEST-ELICITATION gets the client's
;;;     answer on the retry (MRTR). A handler is (lambda (params)) → the result
;;;     object; an MCP-PROTOCOL:MCP-ERROR it signals goes back to the server
;;;     with its code and message. It runs on the transport's dispatch thread
;;;     (a 2025-11-25 server's JSON-RPC request; mcp-backend-stdio
;;;     :DISPATCH :CONCURRENT) or on the thread of the tool call (a 2026-07-28
;;;     server's input_required): never on the session's loop thread.
;;;     MCP-PROTOCOL:VALIDATE-JSON-SCHEMA checks elicited content.
;;;   ai-agent-protocol/mcp 0.3.0 (ai-agent-protocol 0.17.0, H3e-2b issue):
;;;     MAKE-MCP-SAMPLING-HANDLER &key BACKEND MODEL MAX-TOKENS: GENERATE on
;;;     BACKEND with MODEL (the server's modelPreferences hints are never a
;;;     model name), maxTokens capped at MAX-TOKENS, text and image content,
;;;     the result's "model" the model used.
;;;
;;; THE HANDLERS
;;;   MAKE-MCP-REQUEST-HANDLERS manager connection → (values sampling-handler
;;;   elicitation-handler), each NIL when off: sampling only when the server's
;;;   config opts in (MCP-SAMPLING-SETTINGS), elicitation unless its config
;;;   says "elicitation": false. %MCP-OPEN-CLIENT passes them to MCP-CONNECT
;;;   (:SAMPLING-HANDLER, :ELICITATION-HANDLER) for every transport, so the
;;;   capabilities follow (mcp-protocol 0.5.0). -p, the TUI, the SDK, --rpc and
;;;   ACP install the same two; only the broker (below) differs.
;;;
;;; REQUEST IDS. Each request gets "mcp-sampling-N" or "mcp-elicitation-N",
;;;   N counting from 1 per manager (MCP-REQUEST-ID-P recognises both; given).
;;;   TOOL-USE-ID: the id of the server's MCP tool call running when the
;;;   request came, when exactly one runs (the manager knows its servers'
;;;   running calls), else NIL.
;;;
;;; THE DECISION (MCP-REQUEST-EFFECT settings kind server → :ALLOW :ASK :DENY)
;;;   KIND :SAMPLING → action +MCP-SAMPLING-ACTION+ ("mcp_sampling"), :ELICITATION
;;;   → +MCP-ELICITATION-ACTION+ ("mcp_elicitation"); resource the server's
;;;   name. The rules are +MCP-REQUEST-DEFAULT-RULES+ (both actions ask) then
;;;   SETTINGS-PERMISSION-RULES of the session, evaluated by
;;;   AGENT:PERMISSION-RULES-EFFECT (last match per resource; across layers
;;;   deny > ask > allow, as for tools). So "mcp_sampling(lisp)" in
;;;   permissions.allow lets server lisp sample without asking,
;;;   "mcp_sampling" in deny refuses every server, --allowed-tools and
;;;   --disallowed-tools work too. bypassPermissions turns a sampling :ASK into
;;;   :ALLOW (as it approves every tool ask); an elicitation is never allowed
;;;   without the user (a form needs answers): its :ALLOW is reported as :ASK.
;;;   Plan mode and preview change nothing (a sample has no side effect, a
;;;   question neither).
;;;
;;; SAMPLING (the sampling handler, PARAMS the request's params object)
;;;   1. "tools" or "toolChoice" present → MCP error -32602 "sampling with tools
;;;      is not supported" (sampling.tools is not advertised). No "messages" →
;;;      -32602 "sampling/createMessage needs messages".
;;;   2. The request: model = the config's "model", else the session's
;;;      designator; max tokens = min(params maxTokens, the cap) (the cap when
;;;      the params have none). includeContext is ignored (treated as "none":
;;;      a server never sees the conversation). modelPreferences are ignored.
;;;   3. MCP-REQUEST-EFFECT: :DENY → MCP error +MCP-SAMPLING-REJECTED-CODE+ (-1,
;;;      the spec's "User rejected sampling request" code) with
;;;      +MCP-SAMPLING-DENIED-MESSAGE+, outcome "denied". :ASK → the broker
;;;      asks; headless: -1 with +MCP-SAMPLING-HEADLESS-MESSAGE+, outcome
;;;      "denied", reason "headless"; the user rejects: -1 with
;;;      +MCP-SAMPLING-REJECTED-MESSAGE+ (plus " — FEEDBACK" when given),
;;;      outcome "rejected"; approves: outcome "approved". :ALLOW: outcome
;;;      "allowed".
;;;   4. Allowed or approved: GENERATE through ai-agent-protocol/mcp's handler
;;;      on the model's backend (the session's backend for its own designator;
;;;      another designator through RESOLVE-MODEL and the session's providers,
;;;      once per request), with the session's HTTP backend bound. The server
;;;      gets {"role": "assistant", "content": {"type": "text", "text"},
;;;      "model": the model id, "stopReason"}. A failed call (a bad designator
;;;      included) → MCP error -32603 with the failure's text
;;;      (MODEL-FAILURE-MESSAGE when H3f is in, secrets redacted), outcome
;;;      "failed". The usage is the event's, not the turn's.
;;;   "Always" (TUI "Yes, always for this server", SDK :ALWAYS, ACP
;;;   allow_always) adds the allow rule "mcp_sampling(SERVER)" to the session's
;;;   rules for the rest of the session and saves it to settings.local.json
;;;   (the session's rule store), as "always" does for tools.
;;;
;;; ELICITATION (the elicitation handler)
;;;   1. "mode" "url" → MCP error -32602 "url elicitation is not supported"
;;;      (only form mode is advertised). The schema: ELICITATION-FIELDS
;;;      requestedSchema → the fields, or MCP error -32602 "unsupported
;;;      elicitation schema: …" (the spec's flat object of primitive
;;;      properties: string (enum, enumNames, oneOf [{const, title}], format,
;;;      minLength, maxLength), number and integer (minimum, maximum), boolean;
;;;      title, description, default on each; "required").
;;;   2. MCP-REQUEST-EFFECT :DENY → {"action": "decline"}, outcome "denied",
;;;      nobody asked. Otherwise the broker asks; headless → {"action":
;;;      "decline"}, outcome "declined", reason "headless".
;;;   3. Answers: accept with CONTENT → CONTENT is checked
;;;      (ELICITATION-CONTENT-ERRORS: MCP-PROTOCOL:VALIDATE-JSON-SCHEMA of the
;;;      requested schema, then no key outside its properties); errors →
;;;      MCP-ELICITATION-CONTENT-ERROR (a CODE-USAGE-ERROR: the caller's
;;;      mistake; RPC -32602 with data "errors") and the request keeps
;;;      waiting; valid → {"action": "accept", "content": CONTENT}, outcome
;;;      "accepted". Decline → {"action": "decline"}, "declined". Cancel →
;;;      {"action": "cancel"}, "canceled".
;;;
;;; THE BROKER (MCP-REQUEST-BROKER, the manager's :BROKER; given class)
;;;   Answers what the rules leave to the user. Slots: ASK, a function
;;;   (request) → (values decision content), called on the handler's thread,
;;;   blocking until the answer; REPORT, a function (request event-object)
;;;   called once per request when it is answered (the system event, below);
;;;   INTERACTIVE-P. MAKE-HEADLESS-MCP-BROKER &key report → sampling :REJECT,
;;;   elicitation :DECLINE, at once, with reason "headless". A manager without
;;;   a broker answers as the headless one with no report. Every wait ends
;;;   when the request is answered, the turn is interrupted (sampling
;;;   rejected, elicitation canceled; approval_resolved "interrupt"), the
;;;   session closes (the same, decision "closed"), or the server's connection
;;;   closes (the same, "closed").
;;;   Where requests go:
;;;     -p        MAKE-HEADLESS-MCP-BROKER with -p's reporter (events below,
;;;               the denial in "permission_denials").
;;;     SDK/RPC   the request joins the session's approvals: an
;;;               approval_request event (MCP-REQUEST-OBJECT), ON-APPROVAL
;;;               called with it (its value answers at once, as for tools:
;;;               :ONCE :ALWAYS :REJECT :REJECT-ALL for sampling, :ACCEPT is
;;;               (:ACCEPT CONTENT), :DECLINE, :CANCEL for elicitation), and
;;;               CLIENT-PENDING-APPROVALS lists it until it is answered. It
;;;               works between turns too (the session idle: "step" null).
;;;               The run is not paused: the server's tool call is what waits.
;;;     TUI       the program feeds (:mcp-request OBJECT) to the core (below)
;;;               and answers with the dialog's choice.
;;;     ACP       the prompt thread asks the editor (src/acp/mapping.lisp,
;;;               "H3e-2b"); with no prompt running, as headless.
;;;
;;; APPROVAL OBJECTS (MCP-REQUEST-OBJECT request → the approval_request event)
;;;   {"type": "approval_request", "kind": "mcp_sampling" | "mcp_elicitation",
;;;    "session_id", "step" (the running turn's step, or null), "id",
;;;    "name": the action, "server", "tool_use_id" (or null),
;;;    "input": sampling {"server", "messages": [{"role", "text"}] (image
;;;      content as "[image MIME]"), "system_prompt" (or null), "max_tokens",
;;;      "model" (the designator used)};
;;;      elicitation {"server", "message", "requested_schema" (as given)},
;;;    "summary": SAMPLING-REQUEST-SUMMARY / "MCP server S asks: MESSAGE",
;;;    "preview": null}.
;;;   Tool approvals keep their 0.13 shape (no "kind"). Decisions
;;;   (CLIENT-RESPOND-APPROVAL session id decision &key feedback content):
;;;     sampling     :ONCE :ALWAYS :REJECT (FEEDBACK to the server's error
;;;                  text) :REJECT-ALL (every waiting call and request)
;;;     elicitation  :ACCEPT (CONTENT, a JSON object: hash table)
;;;                  :DECLINE :CANCEL; :REJECT = :DECLINE; :REJECT-ALL
;;;   Another decision for the kind → CODE-USAGE-ERROR "DECISION does not
;;;   answer an MCP sampling request" ("… an MCP elicitation request"). An id
;;;   not waiting → APPROVAL-NOT-FOUND, as for tools. +APPROVAL-DECISION-NAMES+
;;;   gains "accept" "decline" "cancel"; approval_resolved's "decision" takes
;;;   those, "interrupt" and "closed". --rpc approval/respond takes "content"
;;;   (an object) for accept.
;;;
;;; EVENTS (every surface: -p stream-json, the SDK, --rpc, through the one
;;;   emitter; MCP-REQUEST-EVENT-OBJECT request outcome &key reason usage error)
;;;   {"type": "system", "subtype": "mcp_sampling" | "mcp_elicitation",
;;;    "session_id", "server", "request_id", "tool_use_id" (or null),
;;;    "outcome", "reason" (or null: "headless", "rule", "unsupported"),
;;;    sampling also "model", "max_tokens", "usage" ({"input_tokens",
;;;    "output_tokens"} or null), "error" (or null);
;;;    elicitation also "fields" (the accepted content's keys, sorted; [] when
;;;    not accepted)}. Content values are never in an event or a record.
;;;   -p's result "permission_denials" gains, per denied sampling request,
;;;   {"name": "mcp_sampling", "id": REQUEST-ID, "input": {"server": S},
;;;   "reason": "headless" | "denied"}.
;;;
;;; THE TUI (core, pure)
;;;   (:mcp-request OBJECT)     OBJECT (an approval_request object of kind
;;;                             mcp_*) joins STATE-MCP-REQUESTS (once per id);
;;;                             the program shows the dialog of the first
;;;   (:mcp-request-reply ID DECISION [CONTENT])
;;;                             ID leaves the queue → effect (:mcp-respond ID
;;;                             DECISION CONTENT); an id not queued → nothing
;;;   (:mcp-request-resolved ID) ID leaves the queue (answered elsewhere,
;;;                             withdrawn), no effect
;;;   (:interrupt)              with no tool approval waiting and a request
;;;                             queued: answers the first (:reject for
;;;                             sampling, :cancel for elicitation), as a reply
;;;   The program turns each system event of kind mcp_* into a :notice entry,
;;;   MCP-REQUEST-NOTICE event-object:
;;;     "MCP server S sampled the model (MODEL, OUT tokens)"   allowed, approved
;;;     "MCP server S may not sample the model (REASON)"       denied
;;;     "MCP server S's sampling request was rejected"         rejected
;;;     "MCP server S's sampling request failed: ERROR"        failed
;;;     "MCP server S got your answer (FIELD, FIELD)"          accepted
;;;     "MCP server S's question was declined"                 declined, denied
;;;     "MCP server S's question was canceled"                 canceled
;;;   Dialog (the program): MCP-REQUEST-DIALOG-LINES object → the lines above
;;;   the choices: sampling "MCP server S asks the model" then "model M, at
;;;   most N tokens", the system prompt line "system: …" when there is one,
;;;   then each message as "ROLE: TEXT" (each cut to 200 characters);
;;;   elicitation "MCP server S asks:" then the message. Choices
;;;   +MCP-SAMPLING-CHOICES+ / +MCP-ELICITATION-CHOICES+. After "Answer" the
;;;   program asks each field in order: a boolean or enum field as a select
;;;   dialog (enum titles from enumNames / oneOf titles), any other as an
;;;   input line titled "TITLE (TYPE[, optional])" with the description
;;;   below; PARSE-ELICITATION-INPUT turns the text into the value, and an
;;;   error message keeps the field asking. An empty optional field is left
;;;   out. Then (:mcp-request-reply ID :accept CONTENT). Esc in a field
;;;   cancels the request.
;;;   PARSE-ELICITATION-INPUT field text → (values value present-p error):
;;;     "" → (values nil nil nil) when optional, (nil nil "required") else;
;;;     string → the text (minLength, maxLength checked: "at least N
;;;     characters" / "at most N characters");
;;;     integer → PARSE-INTEGER of the trimmed text ("a whole number");
;;;     number → an integer or a decimal ("a number"; no READ);
;;;     both: minimum / maximum ("at least N" / "at most N");
;;;     boolean → y yes true 1 → T, n no false 0 → NIL with present-p T (JSON
;;;     false, as json-protocol decodes it), case insensitive ("yes or no");
;;;     enum → a value or its title, exact ("one of A, B, C").
;;;
;;; ACP: src/acp/mapping.lisp's "H3e-2b" paragraph.
;;;
;;; Non-goals: sampling with tools (sampling.tools), url-mode elicitation,
;;; includeContext, a server's model preferences, per-turn sampling budgets,
;;; sampling usage in the result's "usage", roots, resources and prompts.

;;; Given: constants, the condition, the broker and request classes, the
;;; field struct, the id predicate.

(defparameter +mcp-sampling-action+ "mcp_sampling")

(defparameter +mcp-elicitation-action+ "mcp_elicitation")

(defparameter +mcp-request-kinds+ '(:sampling :elicitation))

(defparameter +mcp-request-default-rules+
  (list (agent:make-permission-rule "mcp_sampling" "*" :ask)
        (agent:make-permission-rule "mcp_elicitation" "*" :ask))
  "The lowest rules of MCP-REQUEST-EFFECT: both kinds ask.")

(defparameter +mcp-sampling-rejected-code+ -1
  "The MCP error code of a sampling request the user or the rules refused
(the spec's example for \"User rejected sampling request\").")

(defparameter +mcp-sampling-rejected-message+ "User rejected sampling request")

(defparameter +mcp-sampling-denied-message+
  "Sampling is denied by a permission rule (mcp_sampling)")

(defparameter +mcp-sampling-headless-message+
  "Sampling needs approval and cl-stack-code is running headless (-p); allow it with an mcp_sampling rule")

(defparameter +mcp-sampling-choices+
  '((:once "Yes")
    (:always "Yes, always for this server")
    (:reject "No"))
  "The TUI's sampling dialog.")

(defparameter +mcp-elicitation-choices+
  '((:accept "Answer")
    (:decline "Decline")
    (:cancel "Cancel"))
  "The TUI's elicitation dialog.")

(defparameter +elicitation-field-types+ '(:string :number :integer :boolean))

(defparameter +mcp-request-id-prefixes+ '("mcp-sampling-" "mcp-elicitation-"))

(defun mcp-request-id-p (id)
  "True when ID names an MCP sampling or elicitation request."
  (and (stringp id)
       (some (lambda (prefix) (uiop:string-prefix-p prefix id)) +mcp-request-id-prefixes+)
       t))

(define-condition mcp-elicitation-content-error (code-usage-error)
  ((errors :initarg :errors :initform '() :reader mcp-elicitation-content-error-errors
           :documentation "The messages, strings."))
  (:report (lambda (c s)
             (format s "the content does not match the requested schema: ~{~a~^; ~}"
                     (mcp-elicitation-content-error-errors c)))))

(defclass mcp-request ()
  ((id :initarg :id :reader mcp-request-id)
   (kind :initarg :kind :reader mcp-request-kind :documentation ":SAMPLING or :ELICITATION.")
   (server :initarg :server :reader mcp-request-server)
   (tool-use-id :initarg :tool-use-id :initform nil :reader mcp-request-tool-use-id)
   (params :initarg :params :reader mcp-request-params
           :documentation "The request's params object as decoded (a hash table).")
   (model :initarg :model :initform nil :reader mcp-request-model
          :documentation "Sampling: the designator it will use.")
   (max-tokens :initarg :max-tokens :initform nil :reader mcp-request-max-tokens
               :documentation "Sampling: the capped maxTokens.")
   (fields :initarg :fields :initform '() :reader mcp-request-fields
           :documentation "Elicitation: its ELICITATION-FIELDs."))
  (:documentation "One sampling or elicitation request of a server, while it is decided."))

(defclass mcp-request-broker ()
  ((ask :initarg :ask :initform nil :reader mcp-broker-ask-function)
   (report :initarg :report :initform nil :reader mcp-broker-report-function)
   (interactive :initarg :interactive :initform nil :reader mcp-broker-interactive-p))
  (:documentation "Answers the requests the rules leave to the user (see the header)."))

(defstruct (elicitation-field (:constructor make-elicitation-field
                                  (&key name type title description required
                                        enum enum-titles default minimum maximum
                                        min-length max-length format)))
  "One property of an elicitation's requestedSchema."
  name          ; the property's key
  type          ; :STRING :NUMBER :INTEGER :BOOLEAN
  title         ; "title", else NIL
  description   ; "description", else NIL
  required      ; T when listed in "required"
  enum          ; the allowed values (strings) of an enum, else NIL
  enum-titles   ; their titles (enumNames / oneOf titles), else NIL
  default       ; "default" as decoded, else NIL
  minimum maximum min-length max-length
  format)       ; "email" "uri" "date" "date-time" or NIL

;;; Stubbed (the header's rules).

(defun mcp-request-effect (settings kind server)
  "→ :ALLOW, :ASK or :DENY for a KIND request of SERVER under SETTINGS."
  (declare (ignore settings kind server))
  (%h3e2b-pending "mcp-request-effect"))

(defun make-mcp-request-handlers (manager connection)
  "→ (values sampling-handler elicitation-handler) for CONNECTION's server."
  (declare (ignore manager connection))
  (%h3e2b-pending "make-mcp-request-handlers"))

(defun make-headless-mcp-broker (&key report)
  "The -p broker: sampling rejected, elicitation declined, reason \"headless\"."
  (declare (ignore report))
  (%h3e2b-pending "make-headless-mcp-broker"))

(defun sampling-request-summary (params &key server model max-tokens)
  "\"MCP server S asks the model (M, ≤ N tokens): TEXT\" (the first user text,
at most 120 characters)."
  (declare (ignore params server model max-tokens))
  (%h3e2b-pending "sampling-request-summary"))

(defun elicitation-fields (schema)
  "SCHEMA (a requestedSchema object) → ELICITATION-FIELDs in property order, or
MCP-PROTOCOL:MCP-ERROR -32602 \"unsupported elicitation schema: …\"."
  (declare (ignore schema))
  (%h3e2b-pending "elicitation-fields"))

(defun parse-elicitation-input (field text)
  "→ (values value present-p error) for TEXT typed into FIELD (see the header)."
  (declare (ignore field text))
  (%h3e2b-pending "parse-elicitation-input"))

(defun elicitation-content-errors (schema content)
  "→ NIL when CONTENT satisfies SCHEMA, else a list of messages."
  (declare (ignore schema content))
  (%h3e2b-pending "elicitation-content-errors"))

(defun mcp-request-object (request &key session-id step)
  "→ the approval_request object of REQUEST (see the header)."
  (declare (ignore request session-id step))
  (%h3e2b-pending "mcp-request-object"))

(defun mcp-request-event-object (request outcome &key session-id reason usage error fields)
  "→ the system event object of REQUEST's OUTCOME (see the header)."
  (declare (ignore request outcome session-id reason usage error fields))
  (%h3e2b-pending "mcp-request-event-object"))

(defun mcp-request-notice (event)
  "→ the TUI notice of a system event object of subtype mcp_sampling / mcp_elicitation."
  (declare (ignore event))
  (%h3e2b-pending "mcp-request-notice"))

(defun mcp-request-dialog-lines (object)
  "→ the dialog lines of an approval_request OBJECT of kind mcp_*."
  (declare (ignore object))
  (%h3e2b-pending "mcp-request-dialog-lines"))

(defun %mcp-request-event (state event)
  "(:mcp-request …) (:mcp-request-reply …) (:mcp-request-resolved …) in the core."
  (declare (ignore state event))
  (%h3e2b-pending "%mcp-request-event"))

(defun %respond-mcp-request (session id decision &key feedback content)
  "CLIENT-RESPOND-APPROVAL for an MCP request id → the ids it resolved."
  (declare (ignore session id decision feedback content))
  (%h3e2b-pending "%respond-mcp-request"))

;;; Exports.

(export '(+mcp-sampling-action+ +mcp-elicitation-action+ +mcp-request-kinds+
          +mcp-request-default-rules+ +mcp-sampling-rejected-code+
          +mcp-sampling-rejected-message+ +mcp-sampling-denied-message+
          +mcp-sampling-headless-message+ +mcp-sampling-choices+ +mcp-elicitation-choices+
          +elicitation-field-types+ mcp-request-id-p
          mcp-elicitation-content-error mcp-elicitation-content-error-errors
          mcp-request mcp-request-id mcp-request-kind mcp-request-server
          mcp-request-tool-use-id mcp-request-params mcp-request-model
          mcp-request-max-tokens mcp-request-fields
          mcp-request-broker mcp-broker-ask-function mcp-broker-report-function
          mcp-broker-interactive-p mcp-manager-broker
          elicitation-field make-elicitation-field elicitation-field-p
          elicitation-field-name elicitation-field-type elicitation-field-title
          elicitation-field-description elicitation-field-required elicitation-field-enum
          elicitation-field-enum-titles elicitation-field-default elicitation-field-minimum
          elicitation-field-maximum elicitation-field-min-length elicitation-field-max-length
          elicitation-field-format
          mcp-request-effect make-mcp-request-handlers make-headless-mcp-broker
          sampling-request-summary elicitation-fields parse-elicitation-input
          elicitation-content-errors mcp-request-object mcp-request-event-object
          mcp-request-notice mcp-request-dialog-lines state-mcp-requests
          ;; src/mcp-config.lisp (H3e-2b)
          +default-mcp-sampling-max-tokens+ +default-mcp-tool-search-threshold+
          +mcp-tool-search-modes+ +mcp-server-extra-keys+ +mcp-search-settings-keys+
          mcp-server-config-sampling mcp-server-config-elicitation
          mcp-server-config-include-instructions mcp-server-config-always-load
          mcp-sampling-settings mcp-server-includes-instructions-p mcp-tool-search-settings))
