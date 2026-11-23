---
system: cl-stack-code
test-system: cl-stack-code/tests
brief: ../cl-stack/docs/capabilities/cl-stack-code.md
---

# H3e-2b: MCP part 2 — sampling, elicitation, server instructions, deferred tool loading (cl-stack-code 0.16.0)

Brief section: "H3e-2b — locked". Rules: the H3e-2b paragraph of `src/mcp-config.lisp`
(the new server and settings keys), the header of `src/mcp-requests.lisp` (sampling,
elicitation, the decision through the permission rules, the broker, approval objects,
events, the TUI core and dialog), the header of `src/mcp-context.lisp` (server
instructions in the prompt, deferred tool loading, the snapshot additions, visibility) and
the header of `src/acp/requests.lisp` (ACP). The acp system's tests are
`cl-stack-code/acp/tests` (`tests/acp/mcp-requests-test.lisp`); run them too.

**Order (do not start before these are published):**
- mcp-protocol **0.5.0** (egao1980/mcp-protocol, the H3e-2b issue and its contract PR): the
  client advertises `sampling` / `elicitation` (form) / `roots` from the handlers it has, in
  initialize and in every 2026-07-28 request's `_meta`; a server tool's REQUEST-SAMPLING /
  REQUEST-ELICITATION gets the client's answer when the retried tools/call carries
  `inputResponses` (MRTR).
- ai-agent-protocol **0.17.0** with ai-agent-protocol/mcp **0.3.0** (egao1980/ai-agent-protocol,
  the H3e-2b issue and its contract PR), after 0.16.0 (H3f): `make-deferred-tool-source`
  (tool_search, the loaded set, `agent-deferred-tool-error`); `make-mcp-sampling-handler`
  `:model` (the server's hints never pick the model), `:max-tokens` (the cap), image content.
Raise the `.asd` versions to them. H3f (0.14.0) and H5c-0 (0.15.0) merge first; this lands as
0.16.0 (renumber in merge order).

Implement every stub (`%h3e2b-pending`, then remove it), and wire:
- configuration (`src/mcp-config.lisp`): `%parse-mcp-server-extras`, `%parse-mcp-search-keys`,
  `mcp-sampling-settings`, `mcp-server-includes-instructions-p`, `mcp-tool-search-settings`
  (the slots, the copy, the merge, the gated calls and the config hash are given).
- the manager (`src/mcp.lisp`): `make-mcp-request-handlers` passed to `mcp-connect`
  (`:sampling-handler`, `:elicitation-handler`) for stdio (both paths) and HTTP; the running
  MCP calls per server (for `tool_use_id`); the request counter; `mcp-manager-tool-source`
  wrapped in the deferred source; the snapshot's `:instructions`, `:deferred`, `:loaded` and
  their restore; `mcp-connection-object`'s five keys; `mcp-status-lines`' suffixes.
- -p (`src/headless.lisp`): `make-headless-mcp-broker` with -p's reporter, so the system events
  go out on the loop thread in order and denied samples join `permission_denials`; the
  init event's `mcp_tool_search`; the MCP instruction blocks last in the system prompt.
- `assemble-system-prompt` (`src/instructions.lisp`): `mcp-instruction-blocks` of the current
  revision as the last sections when an instruction set is given.
- the SDK (`src/client.lisp`) and --rpc (`src/rpc.lisp`): the session's broker (approval_request
  objects of kind `mcp_*`, ON-APPROVAL, `client-pending-approvals`, `%respond-mcp-request`,
  interrupt and close answers, the "always" rule saved to settings.local.json and added to the
  session's rules); `approval/respond`'s `content`; the init event as -p's.
- the TUI (`src/interactive.lisp`, `src/program.lisp`): `%mcp-request-event`, `(:interrupt)` with
  a request queued, the broker feeding `(:mcp-request …)`, the dialogs (`mcp-request-dialog-lines`,
  the field prompts through `parse-elicitation-input`), `(:mcp-respond …)`, the notices; the
  prompt rendered again when the background MCP start settles before the first run.
- ACP (`src/acp/agent.lisp`, `src/acp/mapping.lisp`): the stubs of `src/acp/requests.lisp`; the
  prompt thread asking sampling through a tool call and `session/request_permission`,
  elicitation through `elicitation/create` (with `:elicitation-form`) or declining;
  `tool-kind` "tool_search" → "search".

Measure with the published stack (the contract's `.asd` pins today's versions so it loads).
Run the suite with a 4 GB heap on macOS (`ros dynamic-space-size=4096 …`, #18). Given code
stays; tests/ and this file are read-only.
