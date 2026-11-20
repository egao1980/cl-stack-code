(in-package #:cl-stack-code)

;;; Model designators → backends. A provider is a factory
;;; (lambda (model env) …) → LLM-BACKEND; MODEL is the ref's model or NIL, ENV
;;; the effective environment lookup (name → string or NIL).

(defparameter +default-model+ "anthropic"
  "Model designator when no layer sets one: the provider's default model.")

(defun %env-value (env name)
  "NAME through ENV, or NIL when unset or empty."
  (let ((value (funcall env name)))
    (and (stringp value) (plusp (length value)) value)))

(defun %anthropic-provider (model env)
  (llm-protocol-anthropic:make-anthropic-backend
   :api-key (or (%env-value env "ANTHROPIC_API_KEY")
                (%env-value env "ANTHROPIC_AUTH_TOKEN"))
   :base-url (or (%env-value env "ANTHROPIC_BASE_URL")
                 llm-protocol-anthropic:+default-anthropic-base-url+)
   :default-model (or model (%env-value env "ANTHROPIC_MODEL"))))

(defun %openai-provider (model env)
  (llm-protocol-openai:make-openai-compat-backend
   :api-key (or (%env-value env "OPENAI_API_KEY")
                (%env-value env "LM_API_TOKEN"))
   :base-url (or (%env-value env "OPENAI_BASE_URL")
                 llm-protocol-openai:+default-openai-base-url+)
   :default-model (or model (%env-value env "OPENAI_MODEL"))))

(defun default-providers ()
  "→ alist ((\"anthropic\" . factory) (\"openai\" . factory)). anthropic reads
ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL and ANTHROPIC_MODEL
through ENV; openai reads OPENAI_API_KEY / LM_API_TOKEN, OPENAI_BASE_URL and
OPENAI_MODEL. A designator's model wins over the *_MODEL variable."
  (list (cons "anthropic" #'%anthropic-provider)
        (cons "openai" #'%openai-provider)))

(defun resolve-model (designator &key providers (env (constantly nil)))
  "→ (values backend provider-name model) for DESIGNATOR (\"provider:model\" or
\"provider\"). PROVIDERS (an alist name → factory) is searched before
DEFAULT-PROVIDERS. No provider signals MODEL-NOT-FOUND with a USE-VALUE
restart (a backend, returned as the first value)."
  (multiple-value-bind (name model)
      (handler-case (llm:parse-provider-ref designator)
        (error () (values nil nil)))
    (let* ((known (append providers (default-providers)))
           (entry (and name (assoc name known :test #'string-equal))))
      (if entry
          (values (funcall (cdr entry) model env) name model)
          (restart-case
              (error 'model-not-found
                     :designator designator
                     :message (format nil "unknown provider ~s in model ~s (known: ~{~a~^, ~})"
                                      (or name "") designator
                                      (remove-duplicates (mapcar #'car known)
                                                         :test #'string-equal
                                                         :from-end t)))
            (use-value (backend)
              :report "Use this LLM backend instead."
              (values backend name model)))))))
