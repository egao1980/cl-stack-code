---
system: cl-stack-code
test-system: cl-stack-code/tests
brief: ../cl-stack/docs/capabilities/cl-stack-code.md
---

# H5c-0 — plan mode plans (cl-stack-code 0.15.0)

Implement the brief's "H5c-0 — locked" section. The spec is the header of
`src/plan-docs.lisp` together with the tests. The version is **0.15.0**
(ACP-2 0.11.0, H3e-1 0.12.0, H3e-2a 0.13.0 and H3f 0.14.0 land first; the
number follows merge order, so rebase on whatever main is and keep the version
checks in step).

The user's direction (2026-11-22): "Plan mode is supposed to _plan_ changes. It
can run exploratory scripts, but it's not for creating a full solution." And:
"the current plan behaviour is valuable but let's not call it plan mode."

So there are two modes:

- **plan**: explore and propose. File tools read the exploration area
  (an H5a area, never applied), shell commands run confined there (R4d-4b),
  writes only under `.plan-scratch/`, `ask_user`, and `propose_plan` writes
  `plan.md`. The user approves (accept edits / ask before edits / in preview),
  edits, revises or rejects the document. Approval runs the plan in the real
  project with an `update_plan` checklist, and ends with the plan next to the
  diff.
- **preview**: H5a + R4d-4b exactly as they are, renamed. Every user-facing
  "plan" of that machinery becomes "preview" (header: USER-FACING RENAMES).

Every stub calls `%H5C0-PENDING`; replace them all.

## Given (in the contract)

- `src/plan-docs.lisp`: exports, constants, conditions, the `plan-step` /
  `plan-revision` structs, the `plan-document` and `plan-tools` classes and
  their readers, `plan-documents-directory`, `plan-document-path`, the
  policy-protocol policy `plan-mode-tools`, and `client-apply-preview` /
  `client-reject-preview` (the preview's preferred SDK names, over H5a's
  functions). `+preview-mode-feedback+`.
- `.asd`: version 0.15.0, `policy-protocol` 0.1.0 and `logic-backend-datalog`
  0.1.0 (both published), the component after `checkpoints`, and the six test
  files.
- The moved tests (below).

## Left to the implementation

- Every function stubbed in `src/plan-docs.lisp`, plus making `plan-tools` an
  ai-agent-protocol tool source (propose_plan ends the run: when
  ai-agent-protocol has no way for a tool to end a run, add one there: issue +
  PR + publish, not a workaround).
- The renames in settings, arguments, headless, interactive, program, client,
  rpc, sandbox and transcript (header: USER-FACING RENAMES and its "Other
  texts"). Keep H5a's Lisp names; aliases where the header says so
  (`invocation-plan-area`, `--plan-area`, the RPC methods).
- `settings-permission-policy` returning `plan-mode-permission-policy` in plan
  mode; `%mode-base-rules :plan` = H5a's rules; `:preview` = H5a's rules.
- Settings keys `planTemplate`, `planSaveDirectory`; the record slot
  `plan-document` (content key `:plan-document`, `+session-format+` stays 1);
  old records read as preview (MIGRATION); the migration notice and its marker.
- The wiring: -p (plan runs, `--approve-plan`, `--reject-plan`,
  `--save-plan`, `--propose-only`), the TUI (dialogs, `$EDITOR`, checklist,
  result dialog, ask_user dialog), the SDK and RPC, /tree marks, export,
  conversation rewinds.
- Docs: README (plan mode, preview mode, the migration), the client.lisp /
  rpc.lisp headers. A demo in cl-stack-demos (`harness/plan/`: propose, edit,
  approve, the plan next to the diff), run locally with outputs committed.
- Follow-up issues to file when done: the Lisp API rename (`plan` → `preview`
  for H5a's class, functions, conditions, restarts, checkpoint reasons, merge
  labels, core events), with aliases for one minor; dropping the plan/approve
  alias in 0.16.0.

## Tests

New (Rove, `cl-stack-code/tests`): `plan-doc-support`, `plan-doc-test`
(API, format, policy, tools, settings, records), `plan-doc-cli-test` (-p),
`plan-doc-core-test` (pure core), `plan-doc-program-test` (TUI harness),
`plan-doc-client-test` (SDK, RPC, aliases).

Moved (H5a's meaning under the name preview; assertions otherwise unchanged):
`plan-cli-test`, `plan-core-test`, `plan-program-test`, `client-plan-test`,
`sandbox-test`, `sandbox-cli-test`, `sandbox-program-test`, `sandbox-support`,
`plan-support`, `rpc-test` (`rpc-preview-apply-and-reject`, flags, method
list), `tools-test` (`tools-preview-mode`), `permissions-test` (base rules for
both modes, the policy, the feedback constants), `lisp-image-test` (a preview
row), `checkpoint-core-test` (the open-preview refusal), `settings-test` (five
mode names). The version checks expect 0.15.0. `plan-test` (H5a's Lisp API)
does not change.

### ACP (cl-stack-code/acp; ACP-2 is not on main yet)

When ACP-2 is merged, add to `cl-stack-code/acp/tests` (loopback, mock LLM):

1. `session/new` modes list five ids, "plan" and "preview" separately, in
   `+permission-mode-names+` order.
2. A plan-mode prompt that calls propose_plan sends a `plan` update (entries
   = the steps, "pending", "medium") and then a `session/request_permission`
   whose toolCall has kind "switch_mode" and the markdown as content, with
   `+acp-plan-approval-options+` in order.
3. Answering "acceptEdits": a `current_mode_update` to acceptEdits, the
   execution turn in the same prompt (edits land in the project), `plan`
   updates per update_plan with "in_progress" / "completed", stop reason
   end_turn.
4. Answering "plan" (keep planning): the prompt ends end_turn, the document
   stays proposed; the next prompt is a revision (a new `plan` update).
5. Answering "reject": `plan` update with no entries; the document is rejected.
6. `session/set_mode` to "default" while a plan is proposed approves it; the
   next `session/prompt` executes it.
7. Preview-mode events produce no `plan` update.
