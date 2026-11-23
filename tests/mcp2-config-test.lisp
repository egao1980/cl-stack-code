(in-package #:cl-stack-code/tests)

;;; H3e-2b without a server: the new configuration keys, the request
;;; decision (permission rules), elicitation schemas, input and content, the
;;; request and event objects, notices, dialog lines, the core's request
;;; queue, instruction blocks and the /mcp line suffixes.

(defun %server2 (json-object-text &key (scope :user))
  "The one server of {\"mcpServers\": {\"s\": OBJECT}}, parsed with SCOPE."
  (first (parse-mcp-servers (jget (json:decode (format nil "{\"mcpServers\":{\"s\":~a}}" json-object-text))
                                  "mcpServers")
                            :scope scope)))

(defun %parse2-error (json-object-text)
  "The SETTINGS-ERROR parsing server OBJECT signals → (values key message), or NIL."
  (handler-case (progn (%server2 json-object-text) nil)
    (settings-error (e) (values (settings-error-key e) (princ-to-string e)))))

(defun %settings2 (&rest kv)
  "SETTINGS parsed from alternating keys and values (one layer)."
  (parse-settings (json:encode (apply #'args kv))))

(defun %request (kind &key (id (if (eq kind :sampling) "mcp-sampling-1" "mcp-elicitation-1"))
                        (server "f2") (tool-use-id "call-1-1") params (model "mock")
                        (max-tokens 4096))
  (make-instance 'mcp-request :id id :kind kind :server server :tool-use-id tool-use-id
                              :params (or params (%sampling-params)) :model model
                              :max-tokens max-tokens
                              :fields (and (eq kind :elicitation)
                                           (ignore-errors
                                            (elicitation-fields (jget params "requestedSchema"))))))

(defun %sampling-params (&key (text "Write a haiku about Lisp") (system "You are fake2.") (max-tokens 10000))
  (json:decode (json:encode (args "messages" (vector (args "role" "user"
                                                           "content" (args "type" "text" "text" text)))
                                  "systemPrompt" system
                                  "maxTokens" max-tokens))))

(defparameter +fake2-schema-json+
  "{\"type\":\"object\",\"properties\":{\"colour\":{\"type\":\"string\",\"title\":\"Colour\",\"enum\":[\"red\",\"green\",\"blue\"]},\"count\":{\"type\":\"integer\",\"title\":\"How many\",\"minimum\":1,\"maximum\":10},\"note\":{\"type\":\"string\",\"description\":\"Anything else\"}},\"required\":[\"colour\"]}"
  "fake2's elicitation schema, as JSON.")

(defun %schema (&optional (json +fake2-schema-json+))
  (json:decode json))

(defun %elicitation-params (&key (message "Which colour?") (schema (%schema)))
  (let ((p (args "message" message "mode" "form")))
    (setf (gethash "requestedSchema" p) schema)
    p))

(defun %field (name)
  (find name (elicitation-fields (%schema)) :key #'elicitation-field-name :test #'equal))

;;; Constants (given).

(deftest h3e2b-constants
  (ok (equal "mcp_sampling" +mcp-sampling-action+))
  (ok (equal "mcp_elicitation" +mcp-elicitation-action+))
  (ok (eql -1 +mcp-sampling-rejected-code+))
  (ok (equal "User rejected sampling request" +mcp-sampling-rejected-message+))
  (ok (= 4096 +default-mcp-sampling-max-tokens+))
  (ok (= 40 +default-mcp-tool-search-threshold+))
  (ok (equal '(:auto :always :never) +mcp-tool-search-modes+))
  (ok (equal "tool_search" +tool-search-tool-name+))
  (ok (= 8000 +max-mcp-instructions-chars+))
  (ok (equal '(:once :always :reject) (mapcar #'first +mcp-sampling-choices+)))
  (ok (equal '(:accept :decline :cancel) (mapcar #'first +mcp-elicitation-choices+)))
  (ok (equal '(:accept :decline :cancel)
             (mapcar (lambda (n) (cdr (assoc n +approval-decision-names+ :test #'string=)))
                     '("accept" "decline" "cancel"))))
  (ok (mcp-request-id-p "mcp-sampling-3"))
  (ok (mcp-request-id-p "mcp-elicitation-12"))
  (ok (not (mcp-request-id-p "call-1-1")))
  (ok (not (mcp-request-id-p nil))))

;;; Server keys.

(deftest-parametrize h3e2b-parse-server-keys
    ((object sampling elicitation include always)
     ("{\"command\":\"x\"}" nil t :default nil)
     ("{\"command\":\"x\",\"sampling\":true}" '(:model nil :max-tokens nil) t :default nil)
     ("{\"command\":\"x\",\"sampling\":false}" nil t :default nil)
     ("{\"command\":\"x\",\"sampling\":{\"model\":\"mock:small\",\"maxTokens\":256,\"future\":1}}"
      '(:model "mock:small" :max-tokens 256) t :default nil)
     ("{\"command\":\"x\",\"sampling\":{\"maxTokens\":100}}" '(:model nil :max-tokens 100) t :default nil)
     ("{\"command\":\"x\",\"elicitation\":false}" nil nil :default nil)
     ("{\"command\":\"x\",\"includeInstructions\":false}" nil t nil nil)
     ("{\"command\":\"x\",\"includeInstructions\":true}" nil t t nil)
     ("{\"url\":\"https://h/mcp\",\"alwaysLoad\":true,\"sampling\":true}" '(:model nil :max-tokens nil) t :default t))
  (let ((c (%server2 object)))
    (ok (equal sampling (mcp-server-config-sampling c)))
    (ok (eq elicitation (mcp-server-config-elicitation c)))
    (ok (eq include (mcp-server-config-include-instructions c)))
    (ok (eq always (mcp-server-config-always-load c)))))

(deftest-parametrize h3e2b-parse-server-key-errors
    ((object key message)
     ("{\"command\":\"x\",\"sampling\":\"yes\"}" "mcpServers.s.sampling" "must be true, false or an object")
     ("{\"command\":\"x\",\"sampling\":{\"model\":3}}" "mcpServers.s.sampling.model" "must be a string")
     ("{\"command\":\"x\",\"sampling\":{\"maxTokens\":0}}" "mcpServers.s.sampling.maxTokens" "must be an integer >= 1")
     ("{\"command\":\"x\",\"elicitation\":1}" "mcpServers.s.elicitation" "must be true or false")
     ("{\"command\":\"x\",\"includeInstructions\":\"no\"}" "mcpServers.s.includeInstructions" "must be true or false")
     ("{\"command\":\"x\",\"alwaysLoad\":[]}" "mcpServers.s.alwaysLoad" "must be true or false"))
  (multiple-value-bind (k text) (%parse2-error object)
    (ok (equal key k))
    (ok (has message (or text "")))))

(deftest h3e2b-sampling-settings
  (multiple-value-bind (on model max) (mcp-sampling-settings (%server2 "{\"command\":\"x\"}"))
    (ok (null on))
    (ok (null model))
    (ok (= +default-mcp-sampling-max-tokens+ max)))
  (multiple-value-bind (on model max) (mcp-sampling-settings (%server2 "{\"command\":\"x\",\"sampling\":true}"))
    (ok on)
    (ok (null model) "the session's model")
    (ok (= 4096 max)))
  (multiple-value-bind (on model max)
      (mcp-sampling-settings (%server2 "{\"command\":\"x\",\"sampling\":{\"model\":\"mock:small\",\"maxTokens\":256}}"))
    (ok on)
    (ok (equal "mock:small" model))
    (ok (= 256 max))))

(deftest-parametrize h3e2b-includes-instructions
    ((scope object expected)
     (:user "{\"command\":\"x\"}" t)
     (:user "{\"command\":\"x\",\"includeInstructions\":false}" nil)
     (:flag "{\"command\":\"x\"}" t)
     (:sdk "{\"command\":\"x\"}" t)
     (:project "{\"command\":\"x\"}" nil)
     (:project "{\"command\":\"x\",\"includeInstructions\":true}" nil)
     (:local "{\"command\":\"x\",\"includeInstructions\":true}" nil))
  (ok (eq expected (and (mcp-server-includes-instructions-p (%server2 object :scope scope)) t))))

(deftest h3e2b-config-hash-stable
  (let ((plain (%server2 "{\"command\":\"x\",\"args\":[\"a\"]}"))
        (defaults (%server2 "{\"command\":\"x\",\"args\":[\"a\"],\"sampling\":false,\"elicitation\":true,\"alwaysLoad\":false}")))
    ;; given: the new keys enter the hash only when they are not the defaults,
    ;; so a 0.13 config hashes as it did
    (ok (equal (cl-stack-code::%mcp-config-hash plain) (cl-stack-code::%mcp-config-hash defaults))
        "explicit defaults hash as no keys")
    (ok (not (equal (cl-stack-code::%mcp-config-hash plain)
                    (cl-stack-code::%mcp-config-hash
                     (%server2 "{\"command\":\"x\",\"args\":[\"a\"],\"sampling\":true}"))))
        "opting in to sampling is another config")
    (ok (not (equal (cl-stack-code::%mcp-config-hash plain)
                    (cl-stack-code::%mcp-config-hash
                     (%server2 "{\"command\":\"x\",\"args\":[\"a\"],\"includeInstructions\":true}"))))
        "an explicit includeInstructions too")))

;;; Settings keys.

(deftest h3e2b-tool-search-settings
  (multiple-value-bind (mode threshold) (mcp-tool-search-settings (make-settings))
    (ok (eq :auto mode))
    (ok (= 40 threshold)))
  (multiple-value-bind (mode threshold)
      (mcp-tool-search-settings (%settings2 "mcpToolSearch" "always" "mcpToolSearchThreshold" 5))
    (ok (eq :always mode))
    (ok (= 5 threshold)))
  (multiple-value-bind (mode threshold)
      (mcp-tool-search-settings (merge-settings (%settings2 "mcpToolSearch" "never" "mcpToolSearchThreshold" 5)
                                                (%settings2 "mcpToolSearchThreshold" 7)))
    (ok (eq :never mode) "each key merges on its own")
    (ok (= 7 threshold) "the later layer wins")))

(deftest-parametrize h3e2b-tool-search-setting-errors
    ((key value message)
     ("mcpToolSearch" "sometimes" "must be \"auto\", \"always\" or \"never\"")
     ("mcpToolSearch" t "must be \"auto\", \"always\" or \"never\"")
     ("mcpToolSearchThreshold" -1 "must be an integer >= 0")
     ("mcpToolSearchThreshold" "5" "must be an integer >= 0"))
  (let ((c (handler-case (progn (%settings2 key value) nil)
             (settings-error (e) e))))
    (ok c)
    (when c
      (ok (equal key (settings-error-key c)))
      (ok (has message (princ-to-string c))))))

;;; The decision (permission rules).

(deftest-parametrize h3e2b-request-effect
    ((allow deny mode kind server effect)
     (() () :default :sampling "f2" :ask)
     ('("mcp_sampling(f2)") () :default :sampling "f2" :allow)
     ('("mcp_sampling(f2)") () :default :sampling "other" :ask)
     ('("mcp_sampling") () :default :sampling "any" :allow)
     ('("mcp_sampling") '("mcp_sampling(f2)") :default :sampling "f2" :deny)
     (() '("mcp_sampling") :default :sampling "f2" :deny)
     (() () :bypass-permissions :sampling "f2" :allow)
     (() '("mcp_sampling") :bypass-permissions :sampling "f2" :deny)
     (() () :plan :sampling "f2" :ask)
     (() () :default :elicitation "f2" :ask)
     ('("mcp_elicitation") () :default :elicitation "f2" :ask)
     (() () :bypass-permissions :elicitation "f2" :ask)
     (() '("mcp_elicitation(f2)") :default :elicitation "f2" :deny)
     (() '("mcp_elicitation(f2)") :default :elicitation "g" :ask))
  (let ((settings (make-settings :permission-mode mode
                                 :allow (mapcar (lambda (r) (parse-permission-rule r :allow)) allow)
                                 :deny (mapcar (lambda (r) (parse-permission-rule r :deny)) deny))))
    (ok (eq effect (mcp-request-effect settings kind server)))))

;;; Elicitation schemas, input and content.

(deftest h3e2b-elicitation-fields
  (let ((fields (elicitation-fields (%schema))))
    (ok (equal '("colour" "count" "note") (mapcar #'elicitation-field-name fields)) "the schema's order")
    (ok (equal '(:string :integer :string) (mapcar #'elicitation-field-type fields)))
    (ok (equal '(t nil nil) (mapcar (lambda (f) (and (elicitation-field-required f) t)) fields)))
    (ok (equal '("red" "green" "blue") (coerce (elicitation-field-enum (first fields)) 'list)))
    (ok (equal "Colour" (elicitation-field-title (first fields))))
    (ok (eql 1 (elicitation-field-minimum (second fields))))
    (ok (eql 10 (elicitation-field-maximum (second fields))))
    (ok (equal "Anything else" (elicitation-field-description (third fields)))))
  (let ((f (first (elicitation-fields
                   (%schema "{\"type\":\"object\",\"properties\":{\"size\":{\"type\":\"string\",\"oneOf\":[{\"const\":\"s\",\"title\":\"Small\"},{\"const\":\"l\",\"title\":\"Large\"}]}}}")))))
    (ok (equal '("s" "l") (coerce (elicitation-field-enum f) 'list)) "oneOf consts")
    (ok (equal '("Small" "Large") (coerce (elicitation-field-enum-titles f) 'list)) "and their titles"))
  (let ((f (first (elicitation-fields
                   (%schema "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\",\"default\":true}}}")))))
    (ok (eq :boolean (elicitation-field-type f)))
    (ok (eq t (elicitation-field-default f)))))

(deftest-parametrize h3e2b-elicitation-unsupported-schemas
    ((json)
     ("{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"object\",\"properties\":{}}}}")
     ("{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}")
     ("{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"null\"}}}")
     ("{\"type\":\"string\"}")
     ("{\"type\":\"object\"}"))
  (let ((c (handler-case (progn (elicitation-fields (%schema json)) nil)
             (mcp-protocol:mcp-error (e) e))))
    (ok c "an MCP error for the server")
    (when c
      (ok (eql -32602 (mcp-protocol:mcp-error-code c)))
      (ok (has "unsupported elicitation schema" (or (mcp-protocol:mcp-error-message c) ""))))))

(deftest-parametrize h3e2b-parse-elicitation-input
    ((field text value present error)
     ("colour" "green" "green" t nil)
     ("colour" "pink" nil nil "one of red, green, blue")
     ("colour" "" nil nil "required")
     ("count" " 3 " 3 t nil)
     ("count" "3.5" nil nil "a whole number")
     ("count" "0" nil nil "at least 1")
     ("count" "11" nil nil "at most 10")
     ("count" "" nil nil nil)
     ("note" "" nil nil nil)
     ("note" "blue skies" "blue skies" t nil))
  (multiple-value-bind (v p e) (parse-elicitation-input (%field field) text)
    (ok (equal value v))
    (ok (eq present (and p t)))
    (ok (if error (has error (or e "")) (null e)))))

(deftest-parametrize h3e2b-parse-elicitation-boolean-and-number
    ((type text value present error)
     ("boolean" "yes" t t nil)
     ("boolean" "N" nil t nil)
     ("boolean" "maybe" nil nil "yes or no")
     ("number" "2.5" 2.5 t nil)
     ("number" "-4" -4 t nil)
     ("number" "#.(boom)" nil nil "a number"))
  (let ((f (first (elicitation-fields
                   (%schema (format nil "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"~a\"}},\"required\":[\"x\"]}" type))))))
    (multiple-value-bind (v p e) (parse-elicitation-input f text)
      (ok (if (numberp value) (and (numberp v) (= value v)) (equal value v)))
      (ok (eq present (and p t)))
      (ok (if error (has error (or e "")) (null e))))))

(deftest-parametrize h3e2b-elicitation-content-errors
    ((content-json valid)
     ("{\"colour\":\"red\"}" t)
     ("{\"colour\":\"red\",\"count\":3,\"note\":\"x\"}" t)
     ("{\"count\":3}" nil)
     ("{\"colour\":\"pink\"}" nil)
     ("{\"colour\":\"red\",\"count\":20}" nil)
     ("{\"colour\":\"red\",\"count\":\"3\"}" nil)
     ("{\"colour\":\"red\",\"extra\":1}" nil))
  (let ((errors (elicitation-content-errors (%schema) (json:decode content-json))))
    (ok (if valid (null errors) (and errors (every #'stringp errors))))))

;;; Objects, notices, dialog lines.

(deftest h3e2b-sampling-summary
  (ok (equal "MCP server f2 asks the model (mock, ≤ 4096 tokens): Write a haiku about Lisp"
             (sampling-request-summary (%sampling-params) :server "f2" :model "mock" :max-tokens 4096)))
  (let ((long (sampling-request-summary (%sampling-params :text (make-string 300 :initial-element #\a))
                                        :server "f2" :model "mock" :max-tokens 10)))
    (ok (<= (length long) (+ 120 (length "MCP server f2 asks the model (mock, ≤ 10 tokens): ") 1))
        "the text is cut to 120 characters")))

(deftest h3e2b-request-object-sampling
  (let ((o (mcp-request-object (%request :sampling) :session-id "s1" :step 2)))
    (ok (equal '("id" "input" "kind" "name" "preview" "server" "session_id" "step" "summary"
                 "tool_use_id" "type")
               (jkeys o)))
    (ok (equal "approval_request" (jget o "type")))
    (ok (equal "mcp_sampling" (jget o "kind")))
    (ok (equal "mcp_sampling" (jget o "name")))
    (ok (equal "mcp-sampling-1" (jget o "id")))
    (ok (equal "f2" (jget o "server")))
    (ok (equal "call-1-1" (jget o "tool_use_id")))
    (ok (eql 2 (jget o "step")))
    (ok (eq :null (jget o "preview")))
    (ok (equal "f2" (jget o "input" "server")))
    (ok (equal "user" (jget o "input" "messages" 0 "role")))
    (ok (equal "Write a haiku about Lisp" (jget o "input" "messages" 0 "text")))
    (ok (equal "You are fake2." (jget o "input" "system_prompt")))
    (ok (eql 4096 (jget o "input" "max_tokens")))
    (ok (equal "mock" (jget o "input" "model")))
    (ok (has "MCP server f2 asks the model" (jget o "summary"))))
  (let ((o (mcp-request-object (%request :sampling :tool-use-id nil))))
    (ok (eq :null (jget o "tool_use_id")))
    (ok (eq :null (jget o "step")) "between turns")))

(deftest h3e2b-request-object-elicitation
  (let ((o (mcp-request-object (%request :elicitation :params (%elicitation-params)) :session-id "s1" :step 1)))
    (ok (equal "mcp_elicitation" (jget o "kind")))
    (ok (equal "mcp_elicitation" (jget o "name")))
    (ok (equal "Which colour?" (jget o "input" "message")))
    (ok (equal "object" (jget o "input" "requested_schema" "type")))
    (ok (equal "MCP server f2 asks: Which colour?" (jget o "summary")))))

(deftest h3e2b-event-objects
  (let ((e (mcp-request-event-object (%request :sampling) "allowed" :session-id "s1"
                                     :usage (args "input_tokens" 10 "output_tokens" 5))))
    (ok (equal "system" (jget e "type")))
    (ok (equal "mcp_sampling" (jget e "subtype")))
    (ok (equal '("error" "max_tokens" "model" "outcome" "reason" "request_id" "server" "session_id"
                 "subtype" "tool_use_id" "type" "usage")
               (jkeys e)))
    (ok (equal "allowed" (jget e "outcome")))
    (ok (equal "mcp-sampling-1" (jget e "request_id")))
    (ok (eql 5 (jget e "usage" "output_tokens"))))
  (let ((e (mcp-request-event-object (%request :elicitation :params (%elicitation-params)) "accepted"
                                     :session-id "s1" :fields '("count" "colour"))))
    (ok (equal "mcp_elicitation" (jget e "subtype")))
    (ok (equal '("colour" "count") (coerce (jget e "fields") 'list)) "sorted")
    (ok (not (member "content" (jkeys e) :test #'equal)) "no content values")))

(deftest-parametrize h3e2b-notices
    ((subtype outcome extra expected)
     ("mcp_sampling" "allowed" '("model" "mock" "usage" (:obj "output_tokens" 5))
      "MCP server f2 sampled the model (mock, 5 tokens)")
     ("mcp_sampling" "denied" '("reason" "headless") "MCP server f2 may not sample the model (headless)")
     ("mcp_sampling" "rejected" () "MCP server f2's sampling request was rejected")
     ("mcp_sampling" "failed" '("error" "boom") "MCP server f2's sampling request failed: boom")
     ("mcp_elicitation" "accepted" '("fields" (:vec "colour" "count")) "MCP server f2 got your answer (colour, count)")
     ("mcp_elicitation" "declined" () "MCP server f2's question was declined")
     ("mcp_elicitation" "canceled" () "MCP server f2's question was canceled"))
  (let ((e (args "type" "system" "subtype" subtype "server" "f2" "outcome" outcome
                 "request_id" "r" "reason" :null "error" :null "model" :null "usage" :null)))
    (loop for (k v) on extra by #'cddr
          do (setf (gethash k e)
                   (cond ((and (consp v) (eq :obj (car v))) (apply #'args (cdr v)))
                         ((and (consp v) (eq :vec (car v))) (coerce (cdr v) 'vector))
                         (t v))))
    (ok (equal expected (mcp-request-notice e)))))

(deftest h3e2b-dialog-lines
  (let ((lines (mcp-request-dialog-lines (mcp-request-object (%request :sampling)))))
    (ok (equal "MCP server f2 asks the model" (first lines)))
    (ok (equal "model mock, at most 4096 tokens" (second lines)))
    (ok (member "system: You are fake2." lines :test #'equal))
    (ok (member "user: Write a haiku about Lisp" lines :test #'equal)))
  (let ((lines (mcp-request-dialog-lines
                (mcp-request-object (%request :elicitation :params (%elicitation-params))))))
    (ok (equal '("MCP server f2 asks:" "Which colour?") lines))))

;;; The core's queue.

(deftest h3e2b-core-request-queue
  (let ((s (fresh-state))
        (sample (mcp-request-object (%request :sampling)))
        (ask (mcp-request-object (%request :elicitation :params (%elicitation-params)))))
    (ok (null (effects s (list :mcp-request sample))))
    (ok (null (effects s (list :mcp-request sample))) "once per id")
    (ok (null (effects s (list :mcp-request ask))))
    (ok (equal '("mcp-sampling-1" "mcp-elicitation-1")
               (mapcar (lambda (o) (jget o "id")) (state-mcp-requests s))))
    (ok (equal '((:mcp-respond "mcp-sampling-1" :once nil))
               (effects s '(:mcp-request-reply "mcp-sampling-1" :once))))
    (ok (equal '("mcp-elicitation-1") (mapcar (lambda (o) (jget o "id")) (state-mcp-requests s))))
    (let ((content (args "colour" "red")))
      (ok (equal (list (list :mcp-respond "mcp-elicitation-1" :accept content))
                 (effects s (list :mcp-request-reply "mcp-elicitation-1" :accept content)))))
    (ok (null (state-mcp-requests s)))
    (ok (null (effects s '(:mcp-request-reply "mcp-elicitation-1" :decline))) "not queued: nothing")))

(deftest h3e2b-core-request-resolved-and-esc
  (let ((s (busy-state))
        (sample (mcp-request-object (%request :sampling)))
        (ask (mcp-request-object (%request :elicitation :params (%elicitation-params)))))
    (feed s (list :mcp-request sample) (list :mcp-request ask))
    (ok (null (effects s '(:mcp-request-resolved "mcp-sampling-1"))) "answered elsewhere")
    (ok (equal '("mcp-elicitation-1") (mapcar (lambda (o) (jget o "id")) (state-mcp-requests s))))
    (ok (equal '((:mcp-respond "mcp-elicitation-1" :cancel nil)) (effects s '(:interrupt)))
        "Esc cancels the question, not the turn")
    (ok (state-busy-p s))
    (feed s (list :mcp-request sample))
    (ok (equal '((:mcp-respond "mcp-sampling-1" :reject nil)) (effects s '(:interrupt)))
        "Esc rejects a sampling request")
    (ok (equal '((:cancel)) (effects s '(:interrupt))) "then Esc interrupts as before")))

;;; Instructions and /mcp lines.

(deftest h3e2b-instruction-block
  (ok (equal (format nil "<mcp-instructions server=\"lisp\">~%Use repl-eval.~%</mcp-instructions>")
             (mcp-instruction-block "lisp" "Use repl-eval.")))
  (ok (equal (format nil "<mcp-instructions server=\"a&amp;b &quot;c&quot; &lt;d&gt;\">~%x~%</mcp-instructions>")
             (mcp-instruction-block "a&b \"c\" <d>" "x"))))

(deftest h3e2b-status-line-suffixes
  (flet ((o (name &rest kv)
           (let ((x (%status-object name "connected" :tools '("mcp__x__a"))))
             (loop for (k v) on kv by #'cddr do (setf (gethash k x) v))
             x)))
    (ok (equal (list "MCP servers:"
                     "  a (user, stdio): connected · 1 tool · sampling · instructions"
                     "    mcp__x__a"
                     "  b (user, stdio): connected · 1 tool · deferred (2 loaded)"
                     "    mcp__x__a"
                     "  c (user, stdio): connected · 1 tool"
                     "    mcp__x__a")
               (mcp-status-lines
                (list (o "a" "sampling" t "elicitation" t "instructions" t "deferred" nil "loaded" #())
                      (o "b" "sampling" nil "elicitation" t "instructions" nil "deferred" t
                             "loaded" (vector "mcp__b__x" "mcp__b__y"))
                      (o "c" "sampling" nil "elicitation" nil "instructions" nil "deferred" nil
                             "loaded" #())))))))
