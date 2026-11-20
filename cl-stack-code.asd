(defsystem "cl-stack-code"
  :version "0.2.0"
  :description "Coding agent CLI on cl-stack: an interactive terminal mode (streamed markdown transcript, @ mentions, approval dialogs, queued follow-ups) and headless -p runs with text, JSON or stream-JSON output, layered settings, AGENTS.md discovery and permission rules over ai-agent-protocol and agent-tools"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "ai-agent-protocol" "0.12.0")
               (:version "agent-tools" "0.2.0")
               (:version "llm-protocol" "0.5.0")
               (:version "llm-protocol-anthropic" "0.3.0")
               (:version "llm-protocol-openai" "0.4.0")
               (:version "steer-protocol" "0.3.0")
               (:version "cli-protocol" "0.2.1")
               (:version "cli-backend-clingon" "0.2.0")
               "json-protocol"
               "json-backend-jzon"
               (:version "cl-stack-pathlib" "0.6.0")
               (:version "diff-protocol" "0.3.0")
               (:version "tui-protocol" "0.2.0")
               "tui-protocol/widgets"
               (:version "tui-markdown" "0.2.0")
               (:version "tui-backend-tty" "0.1.1")
               "bordeaux-threads"
               "event-protocol"
               "event-backend-libuv"
               "http-protocol"
               (:version "http-backend-async" "0.2.20"))
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
               (:file "rule-store")
               (:file "mentions")
               (:file "transcript")
               (:file "interactive")
               (:file "headless")
               (:file "program"))
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
               "diff-protocol"
               "tui-protocol"
               "tui-protocol/widgets"
               "tui-markdown"
               (:version "tui-backend-terminal" "0.1.0")
               (:version "terminal-protocol" "0.2.0")
               (:version "terminal-backend-lisp" "0.2.0")
               (:version "pty-protocol" "0.1.0")
               (:version "pty-backend-native" "0.2.1")
               "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "mock-llm")
               (:file "support")
               (:file "interactive-support")
               (:file "args-test")
               (:file "settings-test")
               (:file "permissions-test")
               (:file "instructions-test")
               (:file "providers-test")
               (:file "cli-test")
               (:file "json-test")
               (:file "tools-test")
               ;; H3b
               (:file "core-test")
               (:file "transcript-test")
               (:file "mentions-test")
               (:file "rule-store-test")
               (:file "program-test")
               (:file "interactive-cli-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
