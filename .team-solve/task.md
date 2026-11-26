---
system: cl-stack-code
test-system: cl-stack-code/tests
brief: ../cl-stack/docs/capabilities/cl-stack-code.md
---

# H3f: resilience — transport errors and token limits (cl-stack-code 0.14.0)

Brief section: "H3f — locked". Rules: the headers of `src/resilience-config.lisp` (settings,
flags, conditions, the failure taxonomy, messages, exit codes, restarts) and
`src/resilience.lisp` (agent extras, context windows, events, failure results, --retry, the
turn timeout, compaction records, instructions after compaction, the tool-output cap, the TUI,
SDK and RPC).

**Order (do not start before these are published):**
- llm-protocol **0.7.0** (egao1980/llm-protocol#12, contract PR #13): typed errors, transport
  errors, Retry-After, jitter.
- llm-protocol-openai **0.7.0** (#20, contract PR #21) and llm-protocol-anthropic **0.5.0**
  (#7): the backends map onto those types.
- The request-timeout fix of llm-protocol-openai#13 (and anthropic's same cap), done
  separately: a request-timeout initarg and an idle timeout for streams.
- ai-agent-protocol **0.16.0** (#39, contract PR #40), after 0.15.0 (#37 / #38): backoff
  cancel, richer events, continuation, truncated tool calls, `compact-agent-run`.
- H3e-1's amended instruction-set API (cl-stack-code PR #32).
Raise the `.asd` versions to them. ACP-2 (0.11.0), H3e-1 (0.12.0) and H3e-2a (0.13.0) merge
first; this lands as 0.14.0 (renumber in merge order).

**PLACEHOLDERS** (replace with the real names once their owners land; keep the behaviour):
- `apply-request-timeout`'s methods for `openai-compat-backend` / `anthropic-backend`: the
  accessor of the request-timeout initarg that the llm-protocol-openai#13 fix adds.
- `%instruction-set-revision` (src/resilience.lisp): H3e-1's `instruction-set-current` of the
  session's `instruction-set` (cl-stack brief "H3e-1 — locked", instruction set rows). Compaction
  markers record it (`:instructions`); a compaction never commits the set.
- `%instruction-set-reinjection`: H3e-1's `instruction-set-loaded-rules store id` with each
  rule's text through `instruction-text`; the turn after a compaction re-injects those (not
  re-discovery, and not H3e-1's interim `forget-instructions` commit of `:forget`, which H3f
  replaces).

Implement every stub (`%h3f-pending`, then remove it), and wire:
- settings (`src/settings.lisp` glue is given) and flags (`src/arguments.lisp` glue is given);
  `check-retry-flags` in `run-cli` before anything runs.
- -p (`src/headless.lisp`): `apply-request-timeout` after the provider factory;
  `resilience-agent-extra` into `%agent-settings`; the capped tool source; the `:retry`,
  `:compacted`, `:continuation`, `:truncated` loop events as system events; the init keys; the
  result's `retries` / `compactions` / `continuations`, `error_class`, the subtype and exit code
  of `classify-model-failure`; the turn timer; compaction markers into the turn record;
  `--retry`.
- the TUI (`src/interactive.lisp`, `src/program.lisp`): the core events and effects, the retry
  notice in the spinner row, Esc during a backoff, `/compact`, `/retry`, the status line's
  `ctx P%`, the failure entry's "/retry" hint.
- the SDK (`src/client.lisp`) and --rpc (`src/rpc.lisp`): `client-compact`,
  `client-retry-turn`, `session/compact`, `turn/retry`, the three error codes.
- session views: `session-full-turns` for export, entries, tree and rewinds; continuation
  turns hidden; the compaction notice.

Measure with the published stack (the contract's `.asd` pins today's versions so it loads).
Run the suite with a 4 GB heap on macOS (`ros dynamic-space-size=4096 …`, #18). Given code
stays; tests/ and this file are read-only.
