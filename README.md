# cl-stack-code

A coding agent CLI on [cl-stack](https://github.com/egao1980/cl-stack): an [`ai-agent-protocol`](https://github.com/egao1980/ai-agent-protocol) agent with the [`agent-tools`](https://github.com/egao1980/agent-tools) file and shell tools, layered settings, `AGENTS.md` discovery and permission rules.

Plan: [HARNESS-PLAN.md](https://github.com/egao1980/cl-workspace/blob/main/docs/HARNESS-PLAN.md), Track H, milestone H3. Brief: [`cl-stack-code.md`](https://github.com/egao1980/cl-stack/blob/main/docs/capabilities/cl-stack-code.md).

Version **0.1.1**: milestone **H3a**, the headless half (`cl-stack-code -p`). Its contract is `cl-stack-code/tests`.

```
cl-stack-code -p "fix the failing test" --output-format stream-json --permission-mode acceptEdits
```

- `-p` with a prompt (or stdin); `--output-format text | json | stream-json`; `--model provider:model`; `--max-turns`; `--cwd`; `--allowed-tools` / `--disallowed-tools` rules such as `bash(git *)` and `edit(src/*)`; `--permission-mode default | acceptEdits | bypassPermissions | plan`; `--append-system-prompt`.
- Settings: `~/.config/cl-stack-code/settings.json`, `.cl-stack-code/settings.json`, `.cl-stack-code/settings.local.json`, then the flags. Deny beats ask beats allow across all of them.
- Instructions: a user-level `AGENTS.md`, then `AGENTS.md` (or `CLAUDE.md`) from the git root down to the working directory; files below it are picked up as tools reach them.
- Headless: anything that would need approval is refused with a tool result that says which flag allows it.

The interactive TUI (H3b), sessions (H3c), RPC (H3d) and the SDK (H3e) come later.

## License

MIT — see [LICENSE](LICENSE).
