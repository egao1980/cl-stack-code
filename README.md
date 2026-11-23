# cl-stack-code

A coding agent CLI on [cl-stack](https://github.com/egao1980/cl-stack): an [`ai-agent-protocol`](https://github.com/egao1980/ai-agent-protocol) agent with the [`agent-tools`](https://github.com/egao1980/agent-tools) file and shell tools, layered settings, `AGENTS.md` discovery and permission rules.

Plan: [HARNESS-PLAN.md](https://github.com/egao1980/cl-workspace/blob/main/docs/HARNESS-PLAN.md), Track H, milestone H3. Brief: [`cl-stack-code.md`](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/cl-stack-code.md).

Version **0.13.2** (the built binary does TLS: cl-stack-ssl 3.5.9.4; macOS: clears Mach exception ports inherited from the editor): **H3a** headless `-p`, **H3b** the interactive TUI, **H3c** sessions, **H5a** plan mode, with its shell confined (**R4d-4b**), the SDK and `--rpc` (**H3d**), `--acp` (**ACP-2**), instruction files, skills and rules as a revisioned instruction set (**H3e-1**), and MCP servers (**H3e-2a**). Its contract is `cl-stack-code/tests` (and `cl-stack-code/acp/tests` for `--acp`).

```
cl-stack-code -p "fix the failing test" --output-format stream-json --permission-mode acceptEdits
```

- `-p` with a prompt (or stdin); `--output-format text | json | stream-json`; `--model provider:model`; `--max-turns`; `--cwd`; `--allowed-tools` / `--disallowed-tools` rules such as `bash(git *)` and `edit(src/*)`; `--permission-mode default | acceptEdits | bypassPermissions | plan`; `--append-system-prompt`; `--model-param KEY=VALUE` (repeatable) and the `modelParams` settings object for sampling parameters (`temperature`, `top_p`, `top_k`, `min_p`, `chat_template_kwargs`, …) sent on every model call.
- Settings: `~/.config/cl-stack-code/settings.json`, `.cl-stack-code/settings.json`, `.cl-stack-code/settings.local.json`, then the flags. Deny beats ask beats allow across all of them.
- Instructions: a user-level `AGENTS.md`, then `AGENTS.md` (or `CLAUDE.md`) from the git root down to the working directory; files below it are picked up as tools reach them.
- Headless: anything that would need approval is refused with a tool result that says which flag allows it.
- Plan mode (H5a): `--permission-mode plan` runs edits and shell commands in a copy of the project (a linked git worktree, or a folder copy), prints the projected diff, and applies it only on approval (`--apply`, or later `--resume ID --apply`; `--on-drift rebase | overwrite` when the project changed meanwhile). The shell (`bash`, `job_input`) runs in the area without asking (ask and deny rules still apply); since 0.10.0 (R4d-4b) it is confined to it — see below.
- Plan-mode sandbox (R4d-4b): every `bash` / `job_input` command runs under the OS sandbox — **Seatbelt** (`sandbox-exec`) on macOS, **Landlock** on Linux. Writable: the area, the plan's scratch directory and `sandbox.extraWritable`; reads are open except the default credential locations; the environment is scrubbed, `/tmp` is private, and the network is off. A blocked command's result carries a `[sandbox: …]` note. When no sandbox can be used (no backend, as on Windows for now, or the probe's canary fails), plan mode never runs the shell unconfined silently: it prints `cl-stack-code: plan ID: no sandbox (REASON); bash and job_input ask before each command` to stderr and falls back to asking before each call (headless `-p` refuses those asks). A command the sandbox refuses mid-session gets the same notice and the fallback from the next turn.
  - `--allow-network` (plan mode only) lets the confined shell reach the network; it is `sandbox.network: "allow"` in the flag layer.
  - Settings, read from the user file and the flags only (a project's own files cannot widen its sandbox): `"sandbox": {"network": "none" | "allow", "extraWritable": ["/abs/dir", "~/cache"], "failIfUnavailable": false}`. With `failIfUnavailable: true` a plan that cannot be confined is refused (`-p` exits 1 before the model is called), and a mid-session refusal denies `bash` / `job_input` from the next turn instead of asking.
  - stream-json: the plan `opened` / `reopened` event carries `"sandbox": {"status": "confined" | "unavailable" | "refused", "backend", "network", "writable", "reason"}`.

## Agent Client Protocol (`--acp`, ACP-2)

```
cl-stack-code --acp [--cwd DIR] [--model M] [--permission-mode MODE] …
```

Serves cl-stack-code as an [Agent Client Protocol](https://agentclientprotocol.com) agent on stdin / stdout, as editors launch one (Zed, JetBrains, Emacs agent-shell). Only JSON-RPC goes to stdout. The server is the system `cl-stack-code/acp` (an adapter over the SDK on `acp-protocol` and `acp-backend-stdio`); the core does not depend on it and loads it only when `--acp` is given (or build `bin/cl-stack-code-acp` from it). Its dependencies are install roots of the core's package, so an OCI install of `cl-stack-code` brings them; when one is missing, `--acp` says which and how to install it (exit 2) (#38). On macOS the binary first clears the Mach exception ports it inherits for the traps SBCL handles as signals: Zed passes its crash reporter's port to the agents it launches, and an SBCL image that inherits it spins on its first trap.

- Sessions: `session/new`, `session/load` (the record replayed as updates, then the conversation goes on), `session/list`, `session/close`; the ACP session id is the cl-stack-code session id. A session is written to disk with its first turn, so `session/load` of an id the agent handed out that has no record yet (a thread an editor restores after a restart) opens it again, empty, under that id (#44).
- Requests a client writes after `initialize` without waiting for its answer are handled after it (#45).
- Modes are the permission modes (`default`, `acceptEdits`, `bypassPermissions`, `plan`), switched with `session/set_mode` from the next turn.
- Turns stream message and thought chunks (the SDK's `text_delta` and `thinking_delta` events), tool calls with their kind, locations and whole-file diffs, tool results, and plan-mode plans. Approvals are `session/request_permission` with allow once / always (saved to `settings.local.json`) and reject once / all; `session/cancel` interrupts the turn (and a running bash).
- Prompts: text, `resource_link` to project files (attached as mentions) and embedded text resources; no images or audio.
- When the client advertises them, file reads and writes go through `fs/read_text_file` / `fs/write_text_file` (the editor's buffers) and `bash` runs in the client's terminal (`terminal/*`).
- What the session found shows as a finished read tool call "Context: …" before the first turn: its instruction files, skills and rules (path-scoped ones marked "on demand"). A rule or nested `AGENTS.md` loaded later shows as "Rule loaded: …" / "Instructions loaded: …", and a Lisp image event (the debugger entered, a job done) as a message line (#41).
- `mcpServers` from the editor connect as the session's MCP servers (scope `sdk`, trusted; stdio and HTTP, `mcpCapabilities.http: true`; legacy SSE is reported unsupported) (#40).

## License

MIT — see [LICENSE](LICENSE).
