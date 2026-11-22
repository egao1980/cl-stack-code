# cl-stack-code

A coding agent CLI on [cl-stack](https://github.com/egao1980/cl-stack): an [`ai-agent-protocol`](https://github.com/egao1980/ai-agent-protocol) agent with the [`agent-tools`](https://github.com/egao1980/agent-tools) file and shell tools, layered settings, `AGENTS.md` discovery and permission rules.

Plan: [HARNESS-PLAN.md](https://github.com/egao1980/cl-workspace/blob/main/docs/HARNESS-PLAN.md), Track H, milestone H3. Brief: [`cl-stack-code.md`](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/cl-stack-code.md).

Version **0.10.0**: **H3a** headless `-p`, **H3b** the interactive TUI, **H3c** sessions, and **H5a** plan mode, with its shell confined (**R4d-4b**). Its contract is `cl-stack-code/tests`.

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

RPC (H3d) and the SDK (H3e) come later.

## License

MIT — see [LICENSE](LICENSE).
