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

;;; Helpers.

(defun %mcp-p (object key)
  "KEY of the JSON OBJECT, NIL when absent, null or OBJECT is not an object."
  (and (hash-table-p object)
       (let ((value (gethash key object)))
         (if (eq value :null) nil value))))

(defun %mcp-items (value)
  "A JSON array (vector or list) as a list; another value as a one-element list."
  (cond ((null value) '())
        ((stringp value) (list value))
        ((vectorp value) (coerce value 'list))
        ((listp value) value)
        (t (list value))))

(defun %mcp-cut (text n)
  (if (> (length text) n) (subseq text 0 n) text))

(defun %mcp-content-text (content)
  "The text of a sampling message's CONTENT (one item or an array): text
items' texts, an image as \"[image MIME]\", joined."
  (format nil "~{~a~}"
          (loop for item in (if (hash-table-p content) (list content) (%mcp-items content))
                collect (cond ((stringp item) item)
                              ((not (hash-table-p item)) "")
                              ((member (%mcp-p item "type") '("image" "audio") :test #'equal)
                               (format nil "[~a ~a]" (%mcp-p item "type")
                                       (or (%mcp-p item "mimeType") "")))
                              (t (or (%mcp-p item "text") ""))))))

(defun %mcp-sampling-messages (params)
  "→ ((role . text) …) of the sampling PARAMS' messages."
  (loop for m in (%mcp-items (%mcp-p params "messages"))
        when (hash-table-p m)
          collect (cons (let ((role (%mcp-p m "role")))
                          (if (stringp role) role "user"))
                        (%mcp-content-text (%mcp-p m "content")))))

(defun %mcp-system-prompt (params)
  (let ((sys (%mcp-p params "systemPrompt")))
    (and (stringp sys) (plusp (length sys)) sys)))

(defun %mcp-kind-action (kind)
  (ecase kind
    (:sampling +mcp-sampling-action+)
    (:elicitation +mcp-elicitation-action+)))

(defun %mcp-json-or-null (value)
  (if (null value) :null value))

(defun mcp-request-effect (settings kind server)
  "→ :ALLOW, :ASK or :DENY for a KIND request of SERVER under SETTINGS."
  (let* ((settings (or settings (make-settings)))
         (action (ecase kind
                   (:sampling +mcp-sampling-action+)
                   (:elicitation +mcp-elicitation-action+)))
         (effect (or (agent:permission-rules-effect
                      (append +mcp-request-default-rules+ (settings-permission-rules settings))
                      action (list server))
                     :ask)))
    ;; The header's two mode transforms: bypassPermissions approves a sampling
    ;; ask; an elicitation always needs the user.
    (ecase kind
      (:sampling (if (and (eq effect :ask)
                          (eq :bypass-permissions (settings-permission-mode settings)))
                     :allow
                     effect))
      (:elicitation (if (eq effect :allow) :ask effect)))))

;;; The runtime (the implementation's). One primitive for every surface: a
;;; request being decided is an %MCP-WAIT on its manager's list (so interrupt,
;;; session close and connection close reach it), answered once by
;;; %MCP-WAIT-RESOLVE; the handler's thread blocks in %MCP-WAIT-AWAIT. The
;;; surfaces only publish the request (PUBLISH) and send the event (REPORT);
;;; %MCP-ANSWER is the one resolver they call (decision and content checks).

(defstruct (%mcp-wait (:constructor %make-mcp-wait (request connection)))
  request connection
  (object nil)    ; the approval_request object once published, else NIL
  (answer nil)    ; NIL, or (decision content feedback cause)
  (emitted nil)   ; true once its approval_resolved went out
  (lock (bt:make-lock "cl-stack-code mcp request"))
  (cv (bt:make-condition-variable)))

(defun %mcp-withdrawn (request)
  "The answer of a withdrawn REQUEST (interrupt, close): sampling rejected,
elicitation canceled."
  (if (eq :sampling (mcp-request-kind request)) :reject :cancel))

(defun %headless-mcp-answer (request)
  "The headless answer (-p, a manager without a broker)."
  (values (if (eq :sampling (mcp-request-kind request)) :reject :decline) nil nil "headless"))

(defun %mcp-wait-resolve (wait decision &key content feedback cause)
  "Any thread: the first answer wins → T when this call answered WAIT."
  (bt:with-lock-held ((%mcp-wait-lock wait))
    (unless (%mcp-wait-answer wait)
      (setf (%mcp-wait-answer wait) (list decision content feedback cause))
      (bt:condition-notify (%mcp-wait-cv wait))
      t)))

(defun %mcp-wait-await (wait manager)
  "The handler's thread: block until WAIT is answered → (values decision
content feedback cause). A manager closed meanwhile answers it \"closed\"."
  (loop
    (let ((answer (bt:with-lock-held ((%mcp-wait-lock wait))
                    (unless (%mcp-wait-answer wait)
                      (bt:condition-wait (%mcp-wait-cv wait) (%mcp-wait-lock wait) :timeout 0.5))
                    (%mcp-wait-answer wait))))
      (when answer
        (return (values-list answer)))
      (when (mcp-manager-closed-p manager)
        (%mcp-wait-resolve wait (%mcp-withdrawn (%mcp-wait-request wait)) :cause "closed")))))

(defun %mcp-next-id (manager kind)
  "\"mcp-sampling-N\" / \"mcp-elicitation-N\", N per manager and kind from 1."
  (let ((n (bt:with-lock-held ((%mcp-manager-lock manager))
             (incf (getf (%mcp-counters manager) kind 0)))))
    (format nil "~a~d" (if (eq kind :sampling) "mcp-sampling-" "mcp-elicitation-") n)))

(defun %mcp-tool-use-id (manager connection)
  "The id of CONNECTION's one running MCP tool call, or NIL (none, or several)."
  (let ((ids (bt:with-lock-held ((%mcp-manager-lock manager))
               (loop for (c . id) in (%mcp-running manager)
                     when (eq c connection) collect id))))
    (and ids (null (rest ids)) (first ids))))

(defun %mcp-register-wait (manager request connection)
  (let ((wait (%make-mcp-wait request connection)))
    (bt:with-lock-held ((%mcp-manager-lock manager))
      (setf (%mcp-waits manager) (append (%mcp-waits manager) (list wait))))
    wait))

(defun %mcp-unregister-wait (manager wait)
  (bt:with-lock-held ((%mcp-manager-lock manager))
    (setf (%mcp-waits manager) (remove wait (%mcp-waits manager) :test #'eq))))

(defun %mcp-all-waits (manager)
  (and manager
       (bt:with-lock-held ((%mcp-manager-lock manager))
         (copy-list (%mcp-waits manager)))))

(defun %mcp-find-wait (manager id)
  (find id (%mcp-all-waits manager) :key (lambda (w) (mcp-request-id (%mcp-wait-request w)))
                                    :test #'equal))

(defun %mcp-waiting-published (manager)
  "The published requests not answered yet, oldest first."
  (remove-if-not (lambda (w) (and (%mcp-wait-object w) (null (%mcp-wait-answer w))))
                 (%mcp-all-waits manager)))

(defun %mcp-answer-all (manager cause &key connection)
  "Interrupt / close: answer every waiting request (of CONNECTION when given)
as withdrawn, CAUSE \"interrupt\" or \"closed\". Any thread. → the waits answered."
  (loop for w in (%mcp-all-waits manager)
        when (and (or (null connection) (eq connection (%mcp-wait-connection w)))
                  (%mcp-wait-resolve w (%mcp-withdrawn (%mcp-wait-request w)) :cause cause))
          collect w))

(defparameter +mcp-request-decisions+
  '((:sampling (:once . :once) (:always . :always) (:reject . :reject) (:reject-all . :reject))
    (:elicitation (:accept . :accept) (:decline . :decline) (:reject . :decline)
                  (:cancel . :cancel) (:reject-all . :decline)))
  "Per kind, the decisions that answer it → the answer they give (the header's sets).")

(defun %mcp-decision (kind decision)
  "DECISION (a keyword, (:accept CONTENT) or (:reject FEEDBACK)) for a KIND
request → (values answer given content feedback); CODE-USAGE-ERROR when it
does not answer KIND."
  (let* ((given (if (consp decision) (first decision) decision))
         (answer (cdr (assoc given (cdr (assoc kind +mcp-request-decisions+))))))
    (unless answer
      (%usage-fail "~(~s~) does not answer an MCP ~(~a~) request" given kind))
    (values answer given
            (and (consp decision) (eq given :accept) (second decision))
            (and (consp decision) (eq given :reject) (second decision)))))

(defun %mcp-decision-name (given answer)
  "approval_resolved's \"decision\" of an answer (a name of +APPROVAL-DECISION-NAMES+)."
  (if (eq given :reject-all)
      "reject_all"
      (string-downcase (symbol-name answer))))

(defun %mcp-answer (manager id decision &key content feedback cause)
  "The one resolver: answer request ID of MANAGER with DECISION → (values wait
decision-name). APPROVAL-NOT-FOUND when ID is not waiting; CODE-USAGE-ERROR
for a decision of the other kind; MCP-ELICITATION-CONTENT-ERROR for content
that does not match the schema. A refused answer changes nothing: the
request keeps waiting."
  (let ((wait (and manager (%mcp-find-wait manager id))))
    (unless (and wait (null (%mcp-wait-answer wait)))
      (error 'approval-not-found :id id))
    (let ((request (%mcp-wait-request wait)))
      (multiple-value-bind (answer given given-content given-feedback)
          (%mcp-decision (mcp-request-kind request) decision)
        (let ((content (or given-content content))
              (feedback (let ((f (or given-feedback feedback)))
                          (and (stringp f) (plusp (length (string-trim " " f))) f))))
          (when (eq answer :accept)
            (unless content
              (setf content (%json-object)))
            (let ((errors (elicitation-content-errors
                           (%mcp-p (mcp-request-params request) "requestedSchema") content)))
              (when errors
                (error 'mcp-elicitation-content-error
                       :errors errors
                       :message (format nil "the content does not match the requested schema: ~{~a~^; ~}"
                                        errors)))))
          (unless (%mcp-wait-resolve wait answer :content content :feedback feedback :cause cause)
            (error 'approval-not-found :id id))
          (values wait (%mcp-decision-name given answer)))))))

(defun %make-publishing-broker (manager &key publish report)
  "An interactive broker: ASK publishes the request (PUBLISH, a function of
the %MCP-WAIT that only posts to its owner thread) and blocks until it is
answered; REPORT as the broker's."
  (make-instance 'mcp-request-broker
                 :interactive t
                 :report report
                 :ask (lambda (request)
                        (let ((wait (%mcp-find-wait manager (mcp-request-id request))))
                          (if (null wait)
                              (%headless-mcp-answer request)
                              (progn
                                (handler-case (funcall publish wait)
                                  (error ()
                                    (%mcp-wait-resolve wait (%mcp-withdrawn request) :cause "closed")))
                                (%mcp-wait-await wait manager)))))))

(defun %mcp-request-fail (code control &rest args)
  "The MCP error the server gets."
  (error 'mcp-protocol:mcp-error :code code :message (apply #'format nil control args)))

(defun %mcp-effective-settings (manager)
  "MANAGER's settings with the rules \"always\" added this session (allow layer)."
  (let ((base (mcp-manager-settings manager))
        (added (bt:with-lock-held ((%mcp-manager-lock manager))
                 (copy-list (%mcp-added-rules manager)))))
    (if added
        (merge-settings base (make-settings :allow added))
        base)))

(defun %mcp-request-decision (manager request)
  "→ (values decision content feedback reason): the rules first
(MCP-REQUEST-EFFECT), then the broker's ASK for an :ASK."
  (ecase (mcp-request-effect (%mcp-effective-settings manager)
                             (mcp-request-kind request) (mcp-request-server request))
    (:deny (values :deny nil nil "rule"))
    (:allow (values :allow nil nil nil))
    (:ask (let* ((broker (mcp-manager-broker manager))
                 (ask (and broker (mcp-broker-ask-function broker))))
            (if ask
                (funcall ask request)
                (%headless-mcp-answer request))))))

(defun %mcp-event-reason (reason)
  "The event's \"reason\": headless, rule, unsupported, else NIL (null)."
  (and (member reason '("headless" "rule" "unsupported") :test #'equal) reason))

(defun %mcp-report (manager request event)
  "The broker's REPORT, once per request. A failing reporter never changes the
server's answer."
  (let* ((broker (mcp-manager-broker manager))
         (report (and broker (mcp-broker-report-function broker))))
    (when report
      (handler-case (funcall report request event)
        (error () nil)))))

(defun %mcp-allow-always (manager server)
  "\"Always\": mcp_sampling(SERVER) joins the session's rules and is saved to
the rule store (settings.local.json); a store that cannot save keeps it for
the session."
  (let ((rule (agent:make-permission-rule +mcp-sampling-action+ server :allow)))
    (bt:with-lock-held ((%mcp-manager-lock manager))
      (setf (%mcp-added-rules manager) (append (%mcp-added-rules manager) (list rule))))
    (let ((store (%mcp-rule-store manager)))
      (when store
        (handler-case (agent:save-permission-rule store rule)
          (settings-error () nil))))))

(defclass %usage-tap ()
  ((inner :initarg :inner :reader %usage-tap-inner)
   (usage :initform nil :accessor %usage-tap-usage))
  (:documentation "An LLM backend that delegates GENERATE and keeps the
response's usage (the sampling event's)."))

(defmethod llm:generate ((tap %usage-tap) turns &rest keys &key &allow-other-keys)
  (let ((response (apply #'llm:generate (%usage-tap-inner tap) turns keys)))
    (setf (%usage-tap-usage tap) (and response (llm:llm-response-usage response)))
    response))

(defun %mcp-usage-object (usage)
  (and usage
       (%json-object "input_tokens" (or (llm:llm-usage-input-tokens usage) 0)
                     "output_tokens" (or (llm:llm-usage-output-tokens usage) 0))))

(defun %mcp-failure-text (condition)
  (if (typep condition 'model-error)
      (model-failure-message condition)
      (handler-case (princ-to-string condition)
        (error () (format nil "~a" (type-of condition))))))

(defun %mcp-generate (manager request model cap)
  "Step 4: GENERATE through ai-agent-protocol/mcp's handler → (values result
usage-object error-text). MODEL: the config's designator (resolved now), or
NIL for the session's model."
  (let* ((sampler (%mcp-sampler manager))
         (secrets (getf sampler :secrets)))
    (handler-case
        (multiple-value-bind (backend model-id)
            (if model
                (funcall (getf sampler :resolve) model)
                (values (getf sampler :backend) (getf sampler :model)))
          (let ((tap (make-instance '%usage-tap :inner backend))
                (http-protocol:*http-backend* (or (getf sampler :http)
                                                  (mcp-manager-http-backend manager)
                                                  http-protocol:*http-backend*))
                (http-backend-async:*event-backend-maker*
                  (or (getf sampler :maker) http-backend-async:*event-backend-maker*)))
            (let ((result (funcall (ai-agent-protocol/mcp:make-mcp-sampling-handler
                                    :backend tap :model model-id :max-tokens cap)
                                   (mcp-request-params request))))
              (values result (%mcp-usage-object (%usage-tap-usage tap)) nil))))
      (error (e)
        (values nil nil (redact-secrets (%mcp-failure-text e) secrets))))))

(defun %mcp-sampling-handler (manager connection)
  "The sampling handler of CONNECTION's server (the header's steps 1-4)."
  (lambda (params)
    (when (or (%mcp-p params "tools") (%mcp-p params "toolChoice"))
      (%mcp-request-fail -32602 "sampling with tools is not supported"))
    (unless (%mcp-items (%mcp-p params "messages"))
      (%mcp-request-fail -32602 "sampling/createMessage needs messages"))
    (multiple-value-bind (on model cap) (mcp-sampling-settings (mcp-connection-config connection))
      (declare (ignore on))
      (let* ((requested (%mcp-p params "maxTokens"))
             (request (make-instance 'mcp-request
                                     :id (%mcp-next-id manager :sampling)
                                     :kind :sampling
                                     :server (mcp-connection-name connection)
                                     :tool-use-id (%mcp-tool-use-id manager connection)
                                     :params params
                                     :model (or model (getf (%mcp-sampler manager) :designator))
                                     :max-tokens (if (integerp requested) (min requested cap) cap)))
             (wait (%mcp-register-wait manager request connection)))
        (unwind-protect
            (multiple-value-bind (decision content feedback reason) (%mcp-request-decision manager request)
              (declare (ignore content))
              (if (member decision '(:allow :once :always))
                  (progn
                    (when (eq decision :always)
                      (%mcp-allow-always manager (mcp-request-server request)))
                    (multiple-value-bind (result usage error)
                        (%mcp-generate manager request model (mcp-request-max-tokens request))
                      (%mcp-report manager request
                                   (mcp-request-event-object
                                    request (cond (error "failed")
                                                  ((eq decision :allow) "allowed")
                                                  (t "approved"))
                                    :usage usage :error error))
                      (or result (%mcp-request-fail -32603 "~a" error))))
                  (let ((denied (eq decision :deny))
                        (headless (equal reason "headless")))
                    (%mcp-report manager request
                                 (mcp-request-event-object
                                  request (if (or denied headless) "denied" "rejected")
                                  :reason (%mcp-event-reason reason)))
                    (%mcp-request-fail +mcp-sampling-rejected-code+ "~a"
                                       (cond (denied +mcp-sampling-denied-message+)
                                             (headless +mcp-sampling-headless-message+)
                                             (t (format nil "~a~@[ — ~a~]"
                                                        +mcp-sampling-rejected-message+
                                                        (and (stringp feedback) feedback))))))))
          (%mcp-unregister-wait manager wait))))))

(defun %mcp-elicitation-handler (manager connection)
  "The elicitation handler of CONNECTION's server (the header's steps 1-3)."
  (lambda (params)
    (when (equal "url" (%mcp-p params "mode"))
      (%mcp-request-fail -32602 "url elicitation is not supported"))
    (let* ((fields (elicitation-fields (%mcp-p params "requestedSchema")))
           (request (make-instance 'mcp-request
                                   :id (%mcp-next-id manager :elicitation)
                                   :kind :elicitation
                                   :server (mcp-connection-name connection)
                                   :tool-use-id (%mcp-tool-use-id manager connection)
                                   :params params
                                   :fields fields))
           (wait (%mcp-register-wait manager request connection)))
      (unwind-protect
          (multiple-value-bind (decision content feedback reason) (%mcp-request-decision manager request)
            (declare (ignore feedback))
            (flet ((report (outcome &rest keys)
                     (%mcp-report manager request
                                  (apply #'mcp-request-event-object request outcome keys))))
              (case decision
                (:accept
                 (let ((content (if (hash-table-p content) content (%json-object))))
                   (report "accepted" :fields (loop for k being the hash-keys of content collect k))
                   (%json-object "action" "accept" "content" content)))
                (:cancel
                 (report "canceled" :reason (%mcp-event-reason reason))
                 (%json-object "action" "cancel"))
                (t
                 (report (if (eq decision :deny) "denied" "declined")
                         :reason (%mcp-event-reason reason))
                 (%json-object "action" "decline")))))
        (%mcp-unregister-wait manager wait)))))

(defun make-mcp-request-handlers (manager connection)
  "→ (values sampling-handler elicitation-handler) for CONNECTION's server."
  (let ((config (mcp-connection-config connection)))
    (values (and (mcp-sampling-settings config) (%mcp-sampling-handler manager connection))
            (and (mcp-server-config-elicitation config)
                 (%mcp-elicitation-handler manager connection)))))

(defun make-headless-mcp-broker (&key report)
  "The -p broker: sampling rejected, elicitation declined, reason \"headless\"."
  (make-instance 'mcp-request-broker
                 :ask #'%headless-mcp-answer
                 :report report
                 :interactive nil))

(defun sampling-request-summary (params &key server model max-tokens)
  "\"MCP server S asks the model (M, ≤ N tokens): TEXT\" (the first user text,
at most 120 characters)."
  (let ((text (or (cdr (find "user" (%mcp-sampling-messages params) :key #'car :test #'equal))
                  "")))
    (format nil "MCP server ~a asks the model (~a, ≤ ~a tokens): ~a"
            server model max-tokens (%mcp-cut text 120))))

(defun %unsupported-schema (control &rest args)
  (error 'mcp-protocol:mcp-error
         :code -32602
         :message (format nil "unsupported elicitation schema: ~?" control args)))

(defun %elicitation-field (name property required)
  "One property of a requestedSchema → an ELICITATION-FIELD, or the -32602 error."
  (unless (hash-table-p property)
    (%unsupported-schema "property ~a is not an object" name))
  (let* ((type-name (%mcp-p property "type"))
         (type (and (stringp type-name)
                    (find type-name +elicitation-field-types+
                          :key (lambda (k) (string-downcase (symbol-name k))) :test #'string=)))
         (one-of (%mcp-p property "oneOf"))
         (enum (%mcp-p property "enum")))
    (unless type
      (%unsupported-schema "property ~a has type ~a (string, number, integer or boolean)"
                           name (if (stringp type-name) type-name "none")))
    (when (and (or enum one-of) (not (eq type :string)))
      (%unsupported-schema "property ~a: only a string can be an enum" name))
    (multiple-value-bind (values titles)
        (cond (one-of
               (let ((items (%mcp-items one-of)))
                 (unless (every (lambda (i) (and (hash-table-p i) (stringp (%mcp-p i "const"))))
                                items)
                   (%unsupported-schema "property ~a: oneOf needs {\"const\", \"title\"} items" name))
                 (values (mapcar (lambda (i) (%mcp-p i "const")) items)
                         (mapcar (lambda (i) (or (%mcp-p i "title") (%mcp-p i "const"))) items))))
              (enum
               (let ((items (%mcp-items enum))
                     (names (%mcp-items (%mcp-p property "enumNames"))))
                 (unless (every #'stringp items)
                   (%unsupported-schema "property ~a: enum values must be strings" name))
                 (values items (and names (= (length names) (length items)) names))))
              (t (values nil nil)))
      (flet ((num (key) (let ((v (%mcp-p property key))) (and (realp v) v)))
             (int (key) (let ((v (%mcp-p property key))) (and (integerp v) v)))
             (text (key) (let ((v (%mcp-p property key))) (and (stringp v) v))))
        (make-elicitation-field
         :name name :type type
         :title (text "title")
         :description (text "description")
         :required (and (member name required :test #'equal) t)
         :enum values :enum-titles titles
         :default (%mcp-p property "default")
         :minimum (num "minimum") :maximum (num "maximum")
         :min-length (int "minLength") :max-length (int "maxLength")
         :format (text "format"))))))

(defun elicitation-fields (schema)
  "SCHEMA (a requestedSchema object) → ELICITATION-FIELDs in property order, or
MCP-PROTOCOL:MCP-ERROR -32602 \"unsupported elicitation schema: …\"."
  (unless (and (hash-table-p schema) (equal "object" (%mcp-p schema "type")))
    (%unsupported-schema "the schema must be an object"))
  (let ((properties (%mcp-p schema "properties"))
        (required (remove-if-not #'stringp (%mcp-items (%mcp-p schema "required")))))
    (unless (and (hash-table-p properties) (plusp (hash-table-count properties)))
      (%unsupported-schema "the schema has no properties"))
    (loop for name being the hash-keys of properties using (hash-value property)
          collect (%elicitation-field name property required))))

(defun %parse-decimal (text)
  "TEXT as [+-]DIGITS[.DIGITS] → an integer, or a double-float with a
fraction; NIL for anything else (no READ)."
  (let* ((n (length text))
         (start (if (and (plusp n) (find (char text 0) "+-")) 1 0))
         (dot (position #\. text :start start))
         (int-part (subseq text start (or dot n)))
         (frac-part (if dot (subseq text (1+ dot)) "")))
    (when (and (every #'digit-char-p int-part)
               (every #'digit-char-p frac-part)
               (plusp (+ (length int-part) (length frac-part)))
               (or (null dot) (plusp (length frac-part))))
      (let* ((whole (if (plusp (length int-part)) (parse-integer int-part) 0))
             (value (if dot
                        (float (+ whole (/ (parse-integer frac-part) (expt 10 (length frac-part))))
                               1d0)
                        whole)))
        (if (and (plusp start) (char= #\- (char text 0))) (- value) value)))))

(defun parse-elicitation-input (field text)
  "→ (values value present-p error) for TEXT typed into FIELD (see the header)."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) (or text ""))))
    (flet ((fail (control &rest args)
             (values nil nil (apply #'format nil control args)))
           (range (n)
             (let ((low (elicitation-field-minimum field))
                   (high (elicitation-field-maximum field)))
               (cond ((and low (< n low)) (values nil nil (format nil "at least ~a" low)))
                     ((and high (> n high)) (values nil nil (format nil "at most ~a" high)))
                     (t (values n t nil))))))
      (cond
        ((zerop (length trimmed))
         (if (elicitation-field-required field)
             (values nil nil "required")
             (values nil nil nil)))
        ((elicitation-field-enum field)
         (let* ((values (elicitation-field-enum field))
                (titles (elicitation-field-enum-titles field))
                (hit (or (find trimmed values :test #'string=)
                         (let ((i (and titles (position trimmed titles :test #'equal))))
                           (and i (nth i values))))))
           (if hit
               (values hit t nil)
               (fail "one of ~{~a~^, ~}" values))))
        (t
         (ecase (elicitation-field-type field)
           (:string
            (let ((min (elicitation-field-min-length field))
                  (max (elicitation-field-max-length field))
                  (n (length text)))
              (cond ((and min (< n min)) (fail "at least ~d characters" min))
                    ((and max (> n max)) (fail "at most ~d characters" max))
                    (t (values text t nil)))))
           (:integer
            (let ((n (%parse-decimal trimmed)))
              (if (integerp n) (range n) (fail "a whole number"))))
           (:number
            (let ((n (%parse-decimal trimmed)))
              (if n (range n) (fail "a number"))))
           (:boolean
            (let ((word (string-downcase trimmed)))
              (cond ((member word '("y" "yes" "true" "1") :test #'string=) (values t t nil))
                    ((member word '("n" "no" "false" "0") :test #'string=) (values nil t nil))
                    (t (fail "yes or no")))))))))))

(defun elicitation-content-errors (schema content)
  "→ NIL when CONTENT satisfies SCHEMA, else a list of messages."
  (if (not (hash-table-p content))
      (list "the content must be an object")
      (let* ((properties (%mcp-p schema "properties"))
             (unknown (loop for key being the hash-keys of content
                            unless (and (hash-table-p properties)
                                        (nth-value 1 (gethash key properties)))
                              collect (format nil "~a is not a field of the requested schema" key)))
             (invalid (handler-case (progn (mcp-protocol:validate-json-schema schema content) nil)
                        (mcp-protocol:mcp-error (e)
                          (list (or (mcp-protocol:mcp-error-message e) (princ-to-string e)))))))
        (append invalid unknown))))

(defun mcp-request-object (request &key session-id step)
  "→ the approval_request object of REQUEST (see the header)."
  (let* ((kind (mcp-request-kind request))
         (server (mcp-request-server request))
         (params (mcp-request-params request))
         (action (%mcp-kind-action kind)))
    (%json-object
     "type" "approval_request"
     "kind" action
     "session_id" (%mcp-json-or-null session-id)
     "step" (%mcp-json-or-null step)
     "id" (mcp-request-id request)
     "name" action
     "server" server
     "tool_use_id" (%mcp-json-or-null (mcp-request-tool-use-id request))
     "input" (ecase kind
               (:sampling
                (%json-object "server" server
                              "messages" (map 'vector (lambda (m)
                                                        (%json-object "role" (car m) "text" (cdr m)))
                                              (%mcp-sampling-messages params))
                              "system_prompt" (%mcp-json-or-null (%mcp-system-prompt params))
                              "max_tokens" (%mcp-json-or-null (mcp-request-max-tokens request))
                              "model" (%mcp-json-or-null (mcp-request-model request))))
               (:elicitation
                (%json-object "server" server
                              "message" (or (%mcp-p params "message") "")
                              "requested_schema" (or (%mcp-p params "requestedSchema")
                                                     (%json-object)))))
     "summary" (ecase kind
                 (:sampling (sampling-request-summary params :server server
                                                             :model (mcp-request-model request)
                                                             :max-tokens (mcp-request-max-tokens request)))
                 (:elicitation (format nil "MCP server ~a asks: ~a" server
                                       (or (%mcp-p params "message") ""))))
     "preview" :null)))

(defun mcp-request-event-object (request outcome &key session-id reason usage error fields)
  "→ the system event object of REQUEST's OUTCOME (see the header)."
  (let ((kind (mcp-request-kind request)))
    (apply #'%json-object
           "type" "system"
           "subtype" (%mcp-kind-action kind)
           "session_id" (%mcp-json-or-null session-id)
           "server" (mcp-request-server request)
           "request_id" (mcp-request-id request)
           "tool_use_id" (%mcp-json-or-null (mcp-request-tool-use-id request))
           "outcome" outcome
           "reason" (%mcp-json-or-null reason)
           (ecase kind
             (:sampling
              (list "model" (%mcp-json-or-null (mcp-request-model request))
                    "max_tokens" (%mcp-json-or-null (mcp-request-max-tokens request))
                    "usage" (%mcp-json-or-null usage)
                    "error" (%mcp-json-or-null error)))
             (:elicitation
              (list "fields" (coerce (sort (copy-list fields) #'string<) 'vector)))))))

(defun mcp-request-notice (event)
  "→ the TUI notice of a system event object of subtype mcp_sampling / mcp_elicitation."
  (let ((server (%mcp-p event "server"))
        (outcome (%mcp-p event "outcome")))
    (if (equal +mcp-sampling-action+ (%mcp-p event "subtype"))
        (cond ((member outcome '("allowed" "approved") :test #'equal)
               (format nil "MCP server ~a sampled the model (~a, ~a tokens)" server
                       (or (%mcp-p event "model") "the session's model")
                       (or (%mcp-p (%mcp-p event "usage") "output_tokens") 0)))
              ((equal outcome "denied")
               (format nil "MCP server ~a may not sample the model (~a)" server
                       (or (%mcp-p event "reason") "denied")))
              ((equal outcome "failed")
               (format nil "MCP server ~a's sampling request failed: ~a" server
                       (or (%mcp-p event "error") "unknown error")))
              (t (format nil "MCP server ~a's sampling request was rejected" server)))
        (cond ((equal outcome "accepted")
               (format nil "MCP server ~a got your answer (~{~a~^, ~})" server
                       (%mcp-items (%mcp-p event "fields"))))
              ((equal outcome "canceled")
               (format nil "MCP server ~a's question was canceled" server))
              (t (format nil "MCP server ~a's question was declined" server))))))

(defun mcp-request-dialog-lines (object)
  "→ the dialog lines of an approval_request OBJECT of kind mcp_*."
  (let ((server (%mcp-p object "server"))
        (input (%mcp-p object "input")))
    (if (equal +mcp-sampling-action+ (%mcp-p object "kind"))
        (append (list (format nil "MCP server ~a asks the model" server)
                      (format nil "model ~a, at most ~a tokens"
                              (or (%mcp-p input "model") "the session's")
                              (or (%mcp-p input "max_tokens") "?")))
                (let ((sys (%mcp-p input "system_prompt")))
                  (and (stringp sys) (list (%mcp-cut (format nil "system: ~a" sys) 200))))
                (loop for m in (%mcp-items (%mcp-p input "messages"))
                      collect (%mcp-cut (format nil "~a: ~a" (%mcp-p m "role") (or (%mcp-p m "text") ""))
                                        200)))
        (list (format nil "MCP server ~a asks:" server)
              (or (%mcp-p input "message") "")))))

(defun %mcp-request-event (state event)
  "(:mcp-request …) (:mcp-request-reply …) (:mcp-request-resolved …) in the core."
  (flet ((queued (id)
           (find id (state-mcp-requests state) :key (lambda (o) (%mcp-p o "id")) :test #'equal))
         (drop (object)
           (setf (state-mcp-requests state) (remove object (state-mcp-requests state) :test #'eq))))
    (destructuring-bind (kind &rest args) event
      (ecase kind
        (:mcp-request
         (let ((object (first args)))
           (unless (queued (%mcp-p object "id"))
             (setf (state-mcp-requests state)
                   (append (state-mcp-requests state) (list object)))))
         '())
        (:mcp-request-reply
         (destructuring-bind (id decision &optional content) args
           (let ((object (queued id)))
             (when object
               (drop object)
               (list (list :mcp-respond id decision content))))))
        (:mcp-request-resolved
         (let ((object (queued (first args))))
           (when object (drop object)))
         '())))))

(defun %respond-mcp-request (session id decision &key feedback content)
  "CLIENT-RESPOND-APPROVAL for an MCP request id → the ids it resolved."
  (%sdk-respond-mcp session id decision :feedback feedback :content content))

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
