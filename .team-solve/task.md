---
system: cl-stack-code/acp
test-system: cl-stack-code/acp/tests
brief: ../cl-stack/docs/capabilities/acp.md
---

# ACP-2 — `cl-stack-code/acp` (cl-stack-code 0.11.0)

Implement the brief's "ACP-2 — cl-stack-code/acp" slice: cl-stack-code as an
Agent Client Protocol agent over its SDK (src/client.lisp), served on stdio by
`cl-stack-code --acp`. The brief's version line says "0.10.0 at today's 0.9.1";
today cl-stack-code is 0.10.1, so this slice is **0.11.0**: bump `:version` in
cl-stack-code.asd and `+version+` in src/package.lisp as part of the slice.

The contract is in the stub headers, which are the spec together with the tests:

- `src/acp/mapping.lisp` — modes, permission kinds ↔ decisions, stop reasons,
  tool kinds, `EVENT-UPDATES` (SDK event → session/update table).
- `src/acp/agent.lisp` — `CODE-ACP-AGENT`, every ACP method, threads, client
  capabilities (fs / terminal), MCP servers.
- `src/acp/serve.lisp` — `SERVE-ACP` (the `--acp` server).
- `src/rpc.lisp` "ACP-2" (given, done) — `*ACP-SERVER*`, `*ACP-SYSTEM*`,
  `%RUN-ACP`; `src/arguments.lisp` `CHECK-ACP-FLAGS` (given, done).

Every stub signals `CL-STACK-CODE/ACP:ACP2-PENDING`; replace them all.

## Given (done in the contract, tested by the core suite)

- `--acp` flag beside `--rpc` (src/arguments.lisp), `CHECK-ACP-FLAGS` with the
  same kind of conflict checks (`--acp --rpc`, `-p`, a prompt,
  `--output-format`, session flags, plan / rewind flags → exit 2).
- Routing: `RUN-CLI` (src/headless.lisp, where `--rpc` is routed; there is no
  routing in src/program.lisp) → `%RUN-ACP` (src/rpc.lisp).
- `tests/acp-flag-test.lisp` in `cl-stack-code/tests`; the mock LLM gains
  `(:think "thought" STEP)` steps (tests/mock-llm.lisp).

## Locked decisions

1. **The core never depends on ACP.** It reaches the server through the hook
   variable `CL-STACK-CODE:*ACP-SERVER*`, which `cl-stack-code/acp` sets when it
   loads (serve.lisp, given). When the hook is NIL at flag time, `%RUN-ACP`
   loads `*ACP-SYSTEM*` ("cl-stack-code/acp") with `ASDF:LOAD-SYSTEM` if ASDF is
   in the image and finds it (compiler output to stderr), else exit 2. Both
   mechanisms: the hook is the interface, the lazy load the fallback.
   `cl-stack-code/acp` also declares a `program-op` build (`bin/cl-stack-code-acp`)
   for a binary with `--acp` built in. Do not add acp-protocol to the core's
   `:depends-on`; the core must not mention acp-protocol symbols.
2. **Session ids**: the ACP sessionId is the SDK session id (the record's id).
3. **Mode ids are the permission mode names** (`+ACP-MODE-IDS+`).
4. **Permission options**: `+ACP-PERMISSION-OPTIONS+` (given), mapped
   allow_once / allow_always / reject_once / reject_always ↔ `:once` / `:always`
   / `:reject` / `:reject-all` (the brief's table; reject_always means "reject
   this and every waiting call", not a saved deny rule).
5. **Threads**: everything the agent sends goes out from the thread of the ACP
   GF that caused it (the prompt thread), never the SDK loop thread
   (agent.lisp header). The loopback is synchronous and not thread-safe.
6. **Thinking**: the core gains an SDK event `thinking_delta`
   `{"type","session_id","step","text"}`, emitted by the one emitter
   (`%ON-AGENT-EVENT`, src/headless.lisp) for each non-empty streamed
   `LLM-THINKING-PART`, in `+EVENT-TYPES+` right after `"text_delta"` ("unit"
   stays last). So -p's stream-json and --rpc get it too (one schema).
7. **Plans**: ACP `plan` updates come from H5a plan objects (projected /
   applied / discarded; mapping.lisp header). Approving a plan over ACP is not
   in this slice.
8. **Diffs** are whole-file oldText / newText (as Zed shows them), on the
   tool_call and on the permission request's toolCall.
9. **Stop reasons**: success → end_turn, max turns → max_turn_requests,
   interrupted → cancelled; another failure → ACP-INTERNAL-ERROR (-32603) with
   the result's error text. Unknown sessions → ACP-RESOURCE-NOT-FOUND (-32002).
10. **Capabilities advertised**: loadSession, promptCapabilities.embeddedContext,
    sessionCapabilities.list / close; mcpCapabilities `{http: false, sse:
    false}`; no auth methods. Nothing else.
11. **MCP servers from the editor** (session/new, session/load `mcpServers`):
    decoded, kept on the session (`CODE-ACP-AGENT-MCP-SERVERS`), never refused,
    not connected. **TODO (H3e-2, cl-stack-code 0.13.0)**: when H3e-2's SDK
    entry for a session's MCP servers lands (e.g. `:mcp-servers` on
    `CLIENT-NEW-SESSION`; name decided by that contract), pass the kept servers
    to it (stdio → command / args / env, http → url / headers) and advertise
    `mcpCapabilities.http` true (sse stays false unless H3e-2 supports it).
    ACP-2 does not wait for it.

## Left to the implementer (core changes are allowed; keep them ACP-free)

- **`session/set_mode`** needs an SDK function to change an open session's
  permission mode from its next turn (e.g. `CLIENT-SET-PERMISSION-MODE session
  mode`, exported and documented in the client.lisp header). Plan mode
  switched on this way must open the plan as a plan-mode session does.
- **fs / terminal delegation**: how the session's file tools read / write
  through `fs/*` (agent-tools' file tools take a cl-stack-pathlib
  `:FILESYSTEM`; a client-backed filesystem is one way) and how bash runs
  through `terminal/*`. An SDK hook for per-session tool backends may be added
  to `MAKE-CLIENT` / `CLIENT-NEW-SESSION` (documented, exported, no ACP types).
  Pathlib or agent-tools gaps are fixed in those repos (issue + PR), not
  worked around.
- **session/load replay**: read the record (sessions.lisp / session-views.lisp)
  and replay it as the agent.lisp header says.
- The exact titles of session modes, the embedded-resource framing in the
  prompt text, and the content of tool_call titles beyond
  `TOOL-CALL-SUMMARY`.
- Untested, may be skipped: session/delete, session/resume, set_config_option,
  `$/cancel_request`, available_commands_update, usage_update.
- Docs: the README's --acp section and the client.lisp / rpc.lisp headers for
  any core change; a demo in cl-stack-demos (`harness/acp/`, `cl-repo run`)
  per the brief, after the slice is green.

## Tests

`cl-stack-code/acp/tests` (Rove, tests/acp/): `harness-test` (the test harness
against a stand-in agent; passes on the stubs), `mapping-test` (pure tables),
`loopback-test` and `loopback-tools-test` (a `CODE-ACP-AGENT` on the mock LLM
over acp-protocol's loopback), `process-test` (a child `cl-stack-code --acp`
over real pipes, spawned with acp-backend-stdio; and a raw-pipe child whose
every stdout line must be JSON-RPC). The existing `cl-stack-code/tests` suite
must stay green.
