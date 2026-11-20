(in-package #:cl-stack-code)

;;; Model designators → backends. A provider is a factory
;;; (lambda (model env) …) → LLM-BACKEND; MODEL is the ref's model or NIL, ENV
;;; the effective environment lookup (name → string or NIL).

(defparameter +default-model+ "anthropic"
  "Model designator when no layer sets one: the provider's default model.")

(defun default-providers ()
  "→ alist ((\"anthropic\" . factory) (\"openai\" . factory)). anthropic reads
ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL and ANTHROPIC_MODEL
through ENV; openai reads OPENAI_API_KEY / LM_API_TOKEN, OPENAI_BASE_URL and
OPENAI_MODEL. A designator's model wins over the *_MODEL variable."
  (%not-implemented 'default-providers))

(defun resolve-model (designator &key providers (env (constantly nil)))
  "→ (values backend provider-name model) for DESIGNATOR (\"provider:model\" or
\"provider\"). PROVIDERS (an alist name → factory) is searched before
DEFAULT-PROVIDERS. No provider signals MODEL-NOT-FOUND with a USE-VALUE
restart (a backend, returned as the first value)."
  (declare (ignore designator providers env))
  (%not-implemented 'resolve-model))
