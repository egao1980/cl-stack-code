(defsystem "cl-stack-code"
  :version "0.1.0"
  :description "Coding agent CLI on cl-stack: headless -p runs with text, JSON or stream-JSON output, layered settings, AGENTS.md discovery and permission rules over ai-agent-protocol and agent-tools"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "ai-agent-protocol" "0.12.0")
               (:version "agent-tools" "0.2.0")
               (:version "llm-protocol" "0.5.0")
               (:version "llm-protocol-anthropic" "0.3.0")
               (:version "llm-protocol-openai" "0.4.0")
               (:version "steer-protocol" "0.3.0")
               (:version "cli-protocol" "0.1.0")
               (:version "cli-backend-clingon" "0.1.0")
               "json-protocol"
               "json-backend-jzon"
               (:version "cl-stack-pathlib" "0.6.0")
               "event-protocol"
               "event-backend-libuv"
               "http-protocol"
               "http-backend-async")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "settings")
               (:file "permissions")
               (:file "instructions")
               (:file "providers")
               (:file "arguments")
               (:file "tools")
               (:file "headless"))
  :build-operation "program-op"
  :build-pathname "bin/cl-stack-code"
  :entry-point "cl-stack-code:main"
  :in-order-to ((test-op (test-op "cl-stack-code/tests"))))

(defsystem "cl-stack-code/tests"
  :depends-on ("cl-stack-code"
               "ai-agent-protocol"
               "agent-tools"
               "llm-protocol"
               "llm-protocol-anthropic"
               "llm-protocol-openai"
               "steer-protocol"
               "json-protocol"
               "json-backend-jzon"
               "bordeaux-threads"
               "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "mock-llm")
               (:file "support")
               (:file "args-test")
               (:file "settings-test")
               (:file "permissions-test")
               (:file "instructions-test")
               (:file "providers-test")
               (:file "cli-test")
               (:file "json-test")
               (:file "tools-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
