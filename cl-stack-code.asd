(defsystem "cl-stack-code"
  :version "0.7.0"
  :description "Coding agent CLI on cl-stack: an SDK and a JSON-RPC 2.0 server over stdio (--rpc) on one core: sessions, turns with streamed events, approvals answered by the caller, steering, interrupts, plans, checkpoints and rewinds, the same event shapes as stream-JSON; a live Lisp image for the agent (lisp-mcp/agent tools, debugger entries in other threads delivered to the agent's inbox, restarts gated by permission rules), checkpoints (every turn that changes files records a composite revision of the conversation and the files: a pathlib snapshot, a git commit on a private ref, or a jj working-copy commit) and per-part rewinds (conversation, files or both, drift-checked), plan mode (edits and shell commands in a copy of the project, a projected diff, approve / reject / continue, drift detection and rebase; git worktrees or folder copies), an interactive terminal mode (streamed markdown transcript, @ mentions, approval dialogs, queued follow-ups and steering), sessions kept as a revision-protocol store per conversation (--continue, --resume, /tree, /fork, /rewind, /clone, /export) and headless -p runs with text, JSON or stream-JSON output, layered settings, AGENTS.md discovery and permission rules over ai-agent-protocol and agent-tools"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "ai-agent-protocol" "0.14.0")
               (:version "agent-tools" "0.2.0")
               (:version "llm-protocol" "0.5.0")
               (:version "llm-protocol-anthropic" "0.3.0")
               (:version "llm-protocol-openai" "0.4.0")
               (:version "steer-protocol" "0.3.0")
               (:version "cli-protocol" "0.2.1")
               (:version "cli-backend-clingon" "0.2.0")
               "json-protocol"
               "json-backend-jzon"
               (:version "cl-stack-pathlib" "0.8.0")
               (:version "diff-protocol" "0.3.0")
               (:version "revision-protocol" "0.4.0")
               (:version "revision-backend-git" "0.5.1")
               (:version "revision-backend-jj" "0.3.1")
               (:version "datetime-protocol" "0.1.3")
               (:version "tui-protocol" "0.2.0")
               "tui-protocol/widgets"
               (:version "tui-markdown" "0.2.0")
               (:version "tui-backend-tty" "0.1.1")
               "bordeaux-threads"
               "event-protocol"
               "event-backend-libuv"
               "http-protocol"
               (:version "http-backend-async" "0.2.20")
               ;; H4b
               (:version "lisp-mcp" "0.7.0")
               (:version "lisp-mcp/agent" "0.7.0")
               ;; H3d
               (:version "rpc-protocol" "0.2.0")
               (:version "rpc-protocol-json" "0.1.1")
               (:version "rpc-backend-stdio" "0.2.0")
               "process-backend-uiop")
  ;; H4b: --lisp-image spawn starts ros +Q run images that load swank / slynk
  ;; (install roots, as in lisp-mcp; never dependencies).
  :properties (:cl-repo (:ci (:with ("swank" "slynk"))))
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
               (:file "sessions")
               (:file "session-views")
               (:file "plans")
               (:file "checkpoints")
               (:file "lisp-image")
               (:file "interactive")
               (:file "headless")
               (:file "program")
               ;; H3d
               (:file "client")
               (:file "rpc"))
  :build-operation "program-op"
  :build-pathname "bin/cl-stack-code"
  :entry-point "cl-stack-code:main"
  :in-order-to ((test-op (test-op "cl-stack-code/tests"))))

(defsystem "cl-stack-code/tests"
  :depends-on ("cl-stack-code"
               "lisp-mcp/agent"
               "repl-protocol"
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
               "revision-protocol"
               "revision-backend-git"
               "revision-backend-jj"
               "cl-stack-pathlib"
               "datetime-protocol"
               "tui-protocol"
               "tui-protocol/widgets"
               "tui-markdown"
               (:version "tui-backend-terminal" "0.1.0")
               (:version "terminal-protocol" "0.2.0")
               (:version "terminal-backend-lisp" "0.2.0")
               (:version "pty-protocol" "0.1.0")
               (:version "pty-backend-native" "0.2.1")
               ;; H3d
               "rpc-protocol"
               "rpc-backend-stdio"
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
               (:file "interactive-cli-test")
               ;; H3c
               (:file "session-support")
               (:file "session-store-test")
               (:file "session-view-test")
               (:file "session-cli-test")
               (:file "session-core-test")
               (:file "session-program-test")
               ;; H5a
               (:file "plan-support")
               (:file "plan-test")
               (:file "plan-cli-test")
               (:file "plan-core-test")
               (:file "plan-program-test")
               ;; H5b
               (:file "checkpoint-support")
               (:file "checkpoint-test")
               (:file "checkpoint-cli-test")
               (:file "checkpoint-core-test")
               (:file "checkpoint-program-test")
               ;; H4b
               (:file "lisp-image-support")
               (:file "lisp-image-test")
               (:file "lisp-image-cli-test")
               (:file "lisp-image-program-test")
               ;; H3d
               (:file "rpc-support")
               (:file "client-test")
               (:file "client-approval-test")
               (:file "client-plan-test")
               (:file "rpc-test")
               (:file "rpc-process-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
