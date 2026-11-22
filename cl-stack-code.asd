(defsystem "cl-stack-code"
  :version "0.12.0"
  :description "Coding agent CLI on cl-stack: a supervisor per session (shell jobs, servers and subagents as units with capped rotated logs; a TUI process panel (/ps, Ctrl-P) to follow, search, stop, restart and feed them, the same model over --rpc units/* methods, both behind the agent's unit_control permission rules), an SDK and a JSON-RPC 2.0 server over stdio (--rpc) on one core: sessions, turns with streamed events, approvals answered by the caller, steering, interrupts, plans, checkpoints and rewinds, the same event shapes as stream-JSON; a live Lisp image for the agent (lisp-mcp/agent tools, debugger entries in other threads delivered to the agent's inbox, restarts gated by permission rules), checkpoints (every turn that changes files records a composite revision of the conversation and the files: a pathlib snapshot, a git commit on a private ref, or a jj working-copy commit) and per-part rewinds (conversation, files or both, drift-checked), plan mode (edits and shell commands in a copy of the project, the shell confined to it by a kernel sandbox: Seatbelt on macOS, Landlock on Linux, network off; asking before each command where there is none; a projected diff, approve / reject / continue, drift detection and rebase; git worktrees or folder copies), an interactive terminal mode (streamed markdown transcript, @ mentions, approval dialogs, queued follow-ups and steering), sessions kept as a revision-protocol store per conversation (--continue, --resume, /tree, /fork, /rewind, /clone, /export) and headless -p runs with text, JSON or stream-JSON output, layered settings, AGENTS.md discovery and permission rules over ai-agent-protocol and agent-tools"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "ai-agent-protocol" "0.14.0")
               (:version "agent-tools" "0.4.0")
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
               ;; H3e-1: @import tokens (text inlines only)
               (:version "markdown-protocol" "0.1.0")
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
               (:version "repl-protocol" "0.2.8")
               ;; 0.3.3: shell jobs do not inherit an --rpc child's stdio pipes on Windows
               ;; (egao1980/supervisor-protocol#9); 0.3.4: cmd.exe command lines verbatim
               (:version "process-backend-uiop" "0.3.4")
               ;; H8d; 0.4.1: shutdown closes finished units' logs (Windows could not
               ;; delete an open .idx, egao1980/supervisor-protocol#11)
               (:version "supervisor-protocol" "0.4.1")
               (:version "supervisor-protocol/search" "0.4.1")
               (:version "process-protocol" "0.4.1")
               ;; R4d-4b: plan mode's shell runs confined (Windows: none until R4e-1)
               (:version "compute-protocol" "0.3.2")
               (:feature :darwin (:version "compute-backend-seatbelt" "0.1.1"))
               (:feature :linux (:version "compute-backend-landlock" "0.1.0")))
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
               ;; H3e-1
               (:file "imports")
               (:file "skills")
               (:file "rules")
               (:file "providers")
               (:file "arguments")
               (:file "tools")
               (:file "rule-store")
               (:file "mentions")
               (:file "transcript")
               (:file "sessions")
               (:file "session-views")
               (:file "plans")
               ;; R4d-4b
               (:file "sandbox")
               (:file "checkpoints")
               (:file "lisp-image")
               ;; H8d
               (:file "units")
               (:file "unit-panel")
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
               ;; H8d
               "supervisor-protocol"
               "supervisor-protocol/search"
               ;; R4d-4b
               "compute-protocol"
               (:feature :darwin "compute-backend-seatbelt")
               (:feature :linux "compute-backend-landlock")
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
               (:file "rpc-process-test")
               ;; ACP-2: the --acp flag (the server is cl-stack-code/acp/tests)
               (:file "acp-flag-test")
               ;; H8d
               (:file "units-support")
               (:file "units-test")
               (:file "units-core-test")
               (:file "units-program-test")
               (:file "units-client-test")
               (:file "units-rpc-test")
               ;; R4d-4b
               (:file "sandbox-support")
               (:file "sandbox-test")
               (:file "sandbox-cli-test")
               (:file "sandbox-program-test")
               (:file "sandbox-real-support" :if-feature (:or :darwin :linux))
               (:file "sandbox-seatbelt-test" :if-feature :darwin)
               (:file "sandbox-landlock-test" :if-feature :linux)
               ;; H3e-1
               (:file "h3e1-support")
               (:file "imports-test")
               (:file "skills-test")
               (:file "rules-test")
               (:file "h3e1-cli-test")
               (:file "h3e1-client-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))

;;; ACP-2: an Agent Client Protocol agent over the SDK (src/client.lisp),
;;; served on stdio by cl-stack-code --acp. The core never depends on it: it
;;; sets CL-STACK-CODE:*ACP-SERVER* when it loads (src/rpc.lisp, "ACP-2").
(defsystem "cl-stack-code/acp"
  :description "cl-stack-code as an ACP agent (Zed, JetBrains, Emacs agent-shell): a code-acp-agent with methods on acp-protocol's agent-side generic functions over the SDK, served on stdio by acp-backend-stdio (cl-stack-code --acp)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("cl-stack-code"
               (:version "acp-protocol" "0.1.0")
               (:version "acp-backend-stdio" "0.1.0")
               "json-protocol"
               "bordeaux-threads"
               ;; the client-backed tool backends (fs/*, terminal/*)
               "ai-agent-protocol"
               "agent-tools"
               "cl-stack-pathlib"
               "datetime-protocol")
  :serial t
  :pathname "src/acp"
  :components ((:file "package")
               (:file "mapping")
               (:file "bridge")
               (:file "agent")
               (:file "serve"))
  ;; A binary that has --acp built in (the core's binary loads this system
  ;; at flag time when ASDF can find it).
  :build-operation "program-op"
  :build-pathname "bin/cl-stack-code-acp"
  :entry-point "cl-stack-code:main"
  :in-order-to ((test-op (test-op "cl-stack-code/acp/tests"))))

(defsystem "cl-stack-code/acp/tests"
  :depends-on ("cl-stack-code/acp"
               ;; the scripted mock LLM and the project helpers
               "cl-stack-code/tests"
               "acp-protocol"
               "acp-backend-stdio"
               "rpc-backend-stdio"
               "json-protocol"
               "bordeaux-threads"
               "rove")
  :pathname "tests/acp"
  :serial t
  :components ((:file "package")
               (:file "support")
               ;; the harness itself, against a stand-in agent (passes on the stubs)
               (:file "harness-test")
               (:file "mapping-test")
               (:file "loopback-test")
               (:file "loopback-tools-test")
               (:file "process-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
