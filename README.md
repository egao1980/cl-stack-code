# cl-stack-code

A coding agent CLI on [cl-stack](https://github.com/egao1980/cl-stack): an [`ai-agent-protocol`](https://github.com/egao1980/ai-agent-protocol) agent with the [`agent-tools`](https://github.com/egao1980/agent-tools) file and shell tools, layered settings, `AGENTS.md` discovery and permission rules.

Plan: [HARNESS-PLAN.md](https://github.com/egao1980/cl-workspace/blob/main/docs/HARNESS-PLAN.md), Track H, milestone H3. Brief: [`cl-stack-code.md`](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/cl-stack-code.md).

Version **0.4.1**: **H3a** headless `-p`, **H3b** the interactive TUI, **H3c** sessions, and **H5a** plan mode. Its contract is `cl-stack-code/tests`.

```
cl-stack-code -p "fix the failing test" --output-format stream-json --permission-mode acceptEdits
```

- `-p` with a prompt (or stdin); `--output-format text | json | stream-json`; `--model provider:model`; `--max-turns`; `--cwd`; `--allowed-tools` / `--disallowed-tools` rules such as `bash(git *)` and `edit(src/*)`; `--permission-mode default | acceptEdits | bypassPermissions | plan`; `--append-system-prompt`; `--model-param KEY=VALUE` (repeatable) and the `modelParams` settings object for sampling parameters (`temperature`, `top_p`, `top_k`, `min_p`, `chat_template_kwargs`, …) sent on every model call.
- Settings: `~/.config/cl-stack-code/settings.json`, `.cl-stack-code/settings.json`, `.cl-stack-code/settings.local.json`, then the flags. Deny beats ask beats allow across all of them.
- Instructions: a user-level `AGENTS.md`, then `AGENTS.md` (or `CLAUDE.md`) from the git root down to the working directory; files below it are picked up as tools reach them.
- Headless: anything that would need approval is refused with a tool result that says which flag allows it.
- Plan mode (H5a): `--permission-mode plan` runs edits and shell commands in a copy of the project (a linked git worktree, or a folder copy), prints the projected diff, and applies it only on approval (`--apply`, or later `--resume ID --apply`; `--on-drift rebase | overwrite` when the project changed meanwhile). Since 0.4.1 the shell runs in the area without asking (ask and deny rules still apply); it is not confined to the area until R4d.

RPC (H3d) and the SDK (H3e) come later.

## License

MIT — see [LICENSE](LICENSE).
