# cl-stack-code

A coding agent CLI on [cl-stack](https://github.com/egao1980/cl-stack): an [`ai-agent-protocol`](https://github.com/egao1980/ai-agent-protocol) agent with the [`agent-tools`](https://github.com/egao1980/agent-tools) file and shell tools, layered settings, `AGENTS.md` discovery and permission rules.

Plan: [HARNESS-PLAN.md](https://github.com/egao1980/cl-workspace/blob/main/docs/HARNESS-PLAN.md), Track H, milestone H3. Brief: [`cl-stack-code.md`](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/cl-stack-code.md).

Version **0.12.1**: **H3a** headless `-p`, **H3b** the interactive TUI, **H3c** sessions, **H5a** plan mode, with its shell confined (**R4d-4b**), the SDK and `--rpc` (**H3d**), and `--acp` (**ACP-2**). Its contract is `cl-stack-code/tests` (and `cl-stack-code/acp/tests` for `--acp`).

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

Serves cl-stack-code as an [Agent Client Protocol](https://agentclientprotocol.com) agent on stdin / stdout, as editors launch one (Zed, JetBrains, Emacs agent-shell). Only JSON-RPC goes to stdout. The server is the system `cl-stack-code/acp` (an adapter over the SDK on `acp-protocol` and `acp-backend-stdio`); the core never depends on it and loads it when `--acp` is given (or build `bin/cl-stack-code-acp` from it).

- Sessions: `session/new`, `session/load` (the record replayed as updates, then the conversation goes on), `session/list`, `session/close`; the ACP session id is the cl-stack-code session id.
- Modes are the permission modes (`default`, `acceptEdits`, `bypassPermissions`, `plan`), switched with `session/set_mode` from the next turn.
- Turns stream message and thought chunks (the SDK's `text_delta` and `thinking_delta` events), tool calls with their kind, locations and whole-file diffs, tool results, and plan-mode plans. Approvals are `session/request_permission` with allow once / always (saved to `settings.local.json`) and reject once / all; `session/cancel` interrupts the turn (and a running bash).
- Prompts: text, `resource_link` to project files (attached as mentions) and embedded text resources; no images or audio.
- When the client advertises them, file reads and writes go through `fs/read_text_file` / `fs/write_text_file` (the editor's buffers) and `bash` runs in the client's terminal (`terminal/*`).
- `mcpServers` from the editor are accepted and kept, not connected yet (H3e-2).

## License

MIT — see [LICENSE](LICENSE).
