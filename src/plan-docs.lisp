(in-package #:cl-stack-code)

;;; H5c-0: plan mode plans (brief: cl-stack docs/capabilities/cl-stack-code.md,
;;; "H5c-0 — locked"; .team-solve/task.md). This header gives the exact rules;
;;; the tests in tests/plan-doc-*.lisp and tests/preview-*.lisp define them.
;;;
;;; TWO MODES (0.15.0). "plan" means only the new mode; the H5a behaviour
;;; keeps working under its own name.
;;;   plan     Explore and propose. Read-only file tools, exploratory shell
;;;            commands confined to a throwaway copy, scratch files, ask_user,
;;;            and a propose_plan call that writes plan.md. Nothing reaches the
;;;            project. The user approves, revises or rejects the DOCUMENT.
;;;   preview  The 0.4–0.14 "plan mode" (H5a + R4d-4b), renamed: edits and
;;;            confined shell commands in a copy, the projected diff, then
;;;            --apply / --reject / --on-drift (rebase, overwrite, abort).
;;;            Every H5a rule holds as written with "plan mode" read as
;;;            "preview mode". It is also an execution target of an approved
;;;            plan ("Approve, run in preview").
;;; +PERMISSION-MODE-NAMES+ becomes ("default" "acceptEdits"
;;; "bypassPermissions" "plan" "preview"); keywords :PLAN (new) and :PREVIEW
;;; (H5a). PARSE-PERMISSION-MODE / PERMISSION-MODE-NAME follow. The Lisp API
;;; of H5a keeps its names in 0.15.0 (PLAN, OPEN-PLAN, APPROVE-PLAN,
;;; PLAN-DRIFT, REBASE-PLAN, … are the preview's area); renaming it to
;;; PREVIEW-* waits until the in-flight slices have merged (issue on
;;; egao1980/cl-stack-code). New SDK names CLIENT-APPLY-PREVIEW and
;;; CLIENT-REJECT-PREVIEW are given below as the preferred spelling.
;;;
;;; USER-FACING RENAMES (left to the implementation; the moved tests define
;;; them). Everything the user sees of the H5a machinery says "preview":
;;;   --permission-mode plan (H5a)  → --permission-mode preview
;;;   --plan-area KIND              → --preview-area KIND; --plan-area stays an
;;;                                   alias through 0.15.x and prints
;;;                                   "cl-stack-code: --plan-area is deprecated; use --preview-area"
;;;                                   on stderr once per run
;;;   --apply --reject --on-drift   unchanged, scoped to preview; their usage
;;;                                   errors name preview ("--apply and
;;;                                   --preview-area need --permission-mode preview")
;;;   stream-json {"type":"plan",…,"plan_id"} (opened reopened projected
;;;     applied rebased drift discarded) → {"type":"preview",…,"preview_id"};
;;;     the result's "plan" object → "preview". No duplicate old events: "plan"
;;;     now carries plan documents (below). +EVENT-TYPES+ gains "preview"
;;;     right after "plan".
;;;   stderr "plan ID: N files changed, not applied (…)" → "preview ID: …",
;;;     likewise every "plan ID: …" line of a preview, and the sandbox notices
;;;     ("preview <id8>: no sandbox (…)").
;;;   TUI: dialog "Plan <id8>" → "Preview <id8>"; entry "● plan <id8>: …" →
;;;     "● preview <id8>: …"; notices "plan <id8> applied …" → "preview <id8>
;;;     applied …"; +PLAN-CHOICES+ "Keep planning" → "Keep working"; /plan
;;;     (show the projection) → /preview. /approve and /reject act on the
;;;     pending plan document first, else on the open preview.
;;;   RPC: preview/apply {session_id, on_drift?} and preview/reject
;;;     {session_id} are the H5a methods (result: the preview object, keys as
;;;     the old plan object). plan/approve and plan/reject act on the plan
;;;     document (below); on a session with no proposed plan and an open
;;;     preview they still apply / reject the preview through 0.15.x, and the
;;;     result gains "deprecated": "plan/approve on a preview is preview/apply;
;;;     the alias goes in 0.16.0" (resp. plan/reject, preview/reject). A
;;;     session cannot have both pending: a plan executing in preview has
;;;     already been approved.
;;;   ACP: the session modes are the five mode names (ACP-2's +ACP-MODE-IDS+).
;;;   Other texts: "--rpc applies previews with preview/apply" (--rpc with
;;;   --apply or --rewind); "--allow-network needs --permission-mode plan or
;;;   preview"; "--lisp-image is not available in preview mode yet (the image
;;;   would not see the preview area)" (plan mode keeps its own text, "… in
;;;   plan mode yet (the image would not see the plan area)"); "session ID has
;;;   no open preview" (H5a's "no open plan"); the system prompt line
;;;   "- Preview: ID (KIND), a copy of DIR" (H5a's "- Plan: …"); TUI "no open
;;;   preview" (/preview), "no proposed plan or open preview" (/approve,
;;;   /reject with neither), "preview <id8> is open: /approve or /reject it
;;;   first", "preview <id8> stays open: send a message to keep working,
;;;   /preview to review it". /help: "/permissions [MODE]" lists default,
;;;   acceptEdits, bypassPermissions, plan or preview; new lines /plan,
;;;   /approve [accept|ask|preview], /reject, /save-plan, /preview.
;;;   Left for the follow-up rename (internal or on disk, unchanged in
;;;   0.15.0): checkpoint reasons :plan-before / :plan-after and their labels,
;;;   the merge labels "plan" / "working copy", the core's :plan-opened …
;;;   events and :approve-plan … effects, +PLAN-CHOICES+'s keys.
;;;
;;; MIGRATION.
;;;   permissionMode "plan" (any settings file) and --permission-mode plan mean
;;;   the NEW plan mode. Both are strictly safer than before (nothing is
;;;   written to the project or to a copy that could be applied). The first
;;;   time a user runs in plan mode on 0.15.x, -p prints
;;;   "cl-stack-code: " + +PLAN-MODE-MIGRATION-NOTICE+ on stderr and the TUI
;;;   adds it as a notice; the marker file <data-dir>/notices/plan-mode-0.15
;;;   records that it was shown (one line: the ISO date), and it is never
;;;   shown again for that data directory.
;;;   Old sessions: a turn record whose content has the H5a :PLAN key reads
;;;   back with RECORD-PERMISSION-MODE :PREVIEW when its stored mode is :PLAN
;;;   (CONTENT-RECORD); new records store :PREVIEW. The :PLAN record key and
;;;   PLAN-RECORD stay the preview's (format unchanged), so --resume OLD
;;;   --apply / --reject and --resume OLD --permission-mode preview "…" (which
;;;   reopens the open area) work on sessions recorded by 0.4–0.14. Areas stay
;;;   in <data-dir>/plans/<key>/<id>/.
;;;
;;; PLAN DOCUMENTS. One per plan; at most one open per session.
;;;   Directory  PLAN-DOCUMENTS-DIRECTORY cwd → <data-dir>/plan-docs/<key>/
;;;              (H3c's project key), never inside the project. Each plan is
;;;              <id>/ (32 lowercase hex, H3c's format) holding
;;;              meta.sexp    (:format 1 :id :project-dir :session :status
;;;                            :revision :template :title :steps :files :area
;;;                            :mode :opened-at :version), written atomically,
;;;                            read with *READ-EVAL* NIL; :steps is a list of
;;;                            (:index I :text S :status ST)
;;;              plan.md      the current document (the user may edit it)
;;;              revisions/N.md  each revision, N from 1
;;;              scratch/     the planning scratch files, copied at approval
;;;   Statuses   +PLAN-DOCUMENT-STATUSES+: :DRAFTING (opened, nothing
;;;              proposed) → :PROPOSED (revision N waiting) → :APPROVED (its
;;;              execution runs) → :EXECUTED | :INTERRUPTED; :DRAFTING or
;;;              :PROPOSED → :REJECTED. :INTERRUPTED (a failed, interrupted or
;;;              max-turns execution turn) can be approved again: the next
;;;              execution prompt lists the steps already done.
;;;   OPEN-PLAN-DOCUMENT project-dir &key data-dir session-id id (template
;;;     :default) → a :DRAFTING PLAN-DOCUMENT, meta.sexp written, revision 0.
;;;   REOPEN-PLAN-DOCUMENT dir id → the document, or PLAN-DOCUMENT-NOT-FOUND
;;;     (no such directory, or an unreadable meta.sexp).
;;;   LIST-PLAN-DOCUMENTS dir → documents, oldest OPENED-AT first.
;;;
;;; THE DOCUMENT FORMAT. Markdown, parsed with markdown-protocol (no new
;;; parser). PARSE-PLAN-MARKDOWN text &key (template :default) →
;;; (values title steps files):
;;;   title  the text of the first level-1 heading, or NIL.
;;;   steps  the item texts (inline text, trimmed, soft breaks as spaces) of
;;;          the FIRST list after the steps heading and before the next heading
;;;          of the same or a higher level; nested lists are part of their item
;;;          and not steps. Steps heading: "Steps" (:default), "Tasks" (:spec).
;;;   files  for each item of the first list under "Files to change": its first
;;;          code span's text, else the item text up to the first whitespace.
;;;          No such heading → NIL.
;;; Headings match by text, case-insensitively, trimmed, at any level ≥ 2.
;;; Required: :default "Goal" and "Steps"; :spec "Requirements", "Design" and
;;; "Tasks". A missing required heading, or a steps list that is absent or
;;; empty → PLAN-FORMAT-ERROR (MISSING = the heading names, in the template's
;;; order). Optional (:default): "Findings", "Files to change", "Risks",
;;; "Test plan". PLAN-TEMPLATE-TEXT template → the skeleton shown to the
;;; model: +DEFAULT-PLAN-TEMPLATE+ or +SPEC-PLAN-TEMPLATE+ (Kiro-style:
;;; requirements as "WHEN … THE SYSTEM SHALL …", design, tasks).
;;;
;;; REVISIONS.
;;;   PROPOSE-PLAN-REVISION doc markdown &key (author :model) feedback → N:
;;;     parse first (a PLAN-FORMAT-ERROR writes nothing); then revisions/N.md
;;;     and plan.md, title, steps (all :PENDING), files, status :PROPOSED,
;;;     meta. FEEDBACK is the user text that asked for this revision (the
;;;     prompt of the plan turn, NIL for the first).
;;;   SYNC-PLAN-DOCUMENT-EDITS doc → NIL, or N+1 when plan.md differs (octet
;;;     for octet) from revisions/N.md: the edited text becomes revision N+1
;;;     with author :USER. A format error propagates and records nothing.
;;;     Called by approval and by every host before showing the document.
;;;   PLAN-DOCUMENT-REVISIONS doc → PLAN-REVISION structs, oldest first.
;;;   PLAN-DOCUMENT-MARKDOWN doc → plan.md's text.
;;;
;;; APPROVAL AND EXECUTION.
;;;   APPROVE-PLAN-DOCUMENT doc &key (mode :accept-edits) → doc. Status must
;;;     be :PROPOSED or :INTERRUPTED, else PLAN-DOCUMENT-STATE-ERROR. MODE one
;;;     of +PLAN-EXECUTION-MODES+ (:default :accept-edits :bypass-permissions
;;;     :preview), else CODE-USAGE-ERROR. In order: SYNC-PLAN-DOCUMENT-EDITS;
;;;     copy <area>/.plan-scratch/ (when the exploration area exists) to
;;;     <doc dir>/scratch/; discard the exploration area (REJECT-PLAN on its
;;;     H5a plan; a lost area is skipped); status :APPROVED, MODE recorded.
;;;   REJECT-PLAN-DOCUMENT doc → :REJECTED, the area discarded.
;;;   PLAN-EXECUTION-PROMPT doc &optional extra → the execution turn's user
;;;     text: +PLAN-EXECUTION-PREAMBLE+, LF LF, <plan id="ID" revision="N">,
;;;     LF, plan.md, LF, </plan>; then, when scratch/ has files, LF LF
;;;     "Scratch files from planning: NATIVE-DIR"; then, for an :INTERRUPTED
;;;     plan, LF LF "Steps already done: 1, 3"; then EXTRA (LF LF first) when
;;;     non-empty.
;;;   SET-PLAN-STEP doc index status → the steps; INDEX from 1; STATUS in
;;;     +PLAN-STEP-STATUSES+ (:pending :in-progress :done); a bad index →
;;;     PLAN-DOCUMENT-ERROR "plan has no step N (1–M)".
;;;   FINISH-PLAN-EXECUTION doc &key changes interrupted → :EXECUTED, or
;;;     :INTERRUPTED with INTERRUPTED.
;;;   PLAN-STEPS-LINES doc → one line per step: "☐ 1. text" (:pending),
;;;     "◐ 2. text" (:in-progress), "☑ 3. text" (:done).
;;;
;;; PLAN VERSUS DIFF.
;;;   PLAN-VERSUS-DIFF doc changes → ((path change planned) …) sorted by path:
;;;     CHANGES are H5a's ((kind path) …) of the execution (a preview's
;;;     projected changes, or the files changed between the execution turn's
;;;     H5b PRE and POST states, read with READ-FILES-STATE whether or not
;;;     checkpoints are enabled); CHANGE is the kind or NIL (planned, not
;;;     changed); PLANNED is T when the path is in the document's files.
;;;   PLAN-VERSUS-DIFF-LINES doc changes →
;;;     "plan <id8> r<N>: D of S steps done"
;;;     the PLAN-STEPS-LINES
;;;     "files: P planned, C changed"
;;;     then per row "  X PATH  NOTE": X = A (added) D (removed) M (modified)
;;;     T (mode changed) or a space; NOTE "planned", "not in the plan" or
;;;     "planned, unchanged".
;;;
;;; SAVE TO WORKSPACE. SAVE-PLAN-TO-WORKSPACE doc &key directory → the
;;; pathname written: <project dir>/<DIRECTORY, else planSaveDirectory, else
;;; "docs/plans">/<YYYY-MM-DD>-<slug>.md (local date of the save), the slug the
;;; title lower-cased, each run of characters outside [a-z0-9] as "-", trimmed
;;; of "-", at most 60 characters, "plan-<id8>" when empty; an existing name
;;; gets "-2", "-3", …. The content is plan.md as it is. The directory is
;;; created. It is the user's action, so no permission rule applies.
;;;
;;; THE TOOLS (MAKE-PLAN-TOOLS doc &key phase ask; a tool source after the
;;; others, so the source list is (file shell [lisp] units [skill] [mcp]
;;; plan)). They never need approval.
;;;   PHASE :PLAN → "propose_plan" and "ask_user"; :EXECUTE → "update_plan".
;;;   propose_plan {markdown: string}: PROPOSE-PLAN-REVISION (FEEDBACK: the
;;;     run's prompt when it is a revision). Result: "Plan <id8> revision N
;;;     saved to NATIVE-PLAN.md. Stop here: the user reviews it now." The
;;;     RUN ENDS after this call (no model step follows; the implementation
;;;     picks the mechanism, a stack fix in ai-agent-protocol if it has none).
;;;     A PLAN-FORMAT-ERROR is a tool error: "propose_plan: the plan is
;;;     missing <names joined by \", \">. Use this template:" LF the template.
;;;   ask_user {question: string, options?: [string]}: ASK (lambda (question
;;;     options) → string or NIL). A string → "The user answered: TEXT"; NIL
;;;     (headless, RPC, SDK and ACP in 0.15.0) → +ASK-USER-UNAVAILABLE+.
;;;   update_plan {step: integer, status: "pending"|"in_progress"|"done"}:
;;;     SET-PLAN-STEP, then the PLAN-STEPS-LINES joined by LF. Errors are tool
;;;     errors with the condition's text.
;;;
;;; PLAN MODE'S TOOL POLICY. PLAN-MODE-TOOLS (below, DEFPOLICY, policy-protocol
;;; 0.1.0, :last-match) is the new rule logic, per the workspace rule
;;; rules-and-logic: file edits are forbidden, with +PLAN-MODE-EDIT-FEEDBACK+,
;;; except under "path:.plan-scratch"; update_plan is forbidden. Everything
;;; else is undecided (no opinion). PLAN-MODE-PERMISSION-POLICY → (lambda
;;; (action resources effect)) for ai-agent-protocol's :permission-policy
;;; (SETTINGS-PERMISSION-POLICY returns it in plan mode and NIL otherwise): it
;;; evaluates PLAN-MODE-TOOLS on (:action ACTION :resources RESOURCES
;;; :context ((mode plan))); :FORBID → (values :deny RULE), RULE an
;;; ai-agent-protocol permission rule for the forbidden resource carrying the
;;; decision's feedback; :ASK → (values :ask RULE); otherwise NIL. A policy
;;; only tightens, so allow and ask rules from settings cannot lift the
;;; refusal; the tool result says why (H3a's denial feedback path).
;;; The rest of plan mode's permissions stay ai-agent-protocol rules, as today:
;;; %MODE-BASE-RULES :PLAN allows write / edit / multi_edit (the policy then
;;; confines them to the scratch directory) and, while the sandbox confines,
;;; bash and job_input (R4d-4b: unconfined → they ask, -p refuses). Moving
;;; those base rules and the sandbox states onto policy-protocol is L4b
;;; (logic.md), not done yet; when ai-agent-protocol/policy (0.15.0, H3e-2's
;;; row 2) ships its policy adapter, PLAN-MODE-PERMISSION-POLICY becomes a call
;;; of it.
;;;
;;; THE EXPLORATION AREA. A plan's shell and file tools work in an H5a area
;;; (OPEN-PLAN, kind auto / --preview-area) of the working copy, opened with
;;; the plan document, confined by R4d-4b's sandbox (same probe, same
;;; notices), kept across revisions (its id is the document's :AREA), and
;;; discarded at approval or rejection: it is NEVER applied. The file tools
;;; are rooted in it (reads see the project plus the experiments); the model's
;;; scratch directory is <area>/.plan-scratch/ (+PLAN-SCRATCH-DIRECTORY-NAME+),
;;; created when the area opens and named in the prompt. The sandbox's own
;;; scratch (PLAN-SCRATCH-DIRECTORY: caches, private tmp) is unchanged. Why
;;; a copy and not a read-only project: exploratory commands write (build
;;; outputs, caches, lock files, git's index), and a copy lets them run
;;; without failing or touching the project.
;;;
;;; THE PROMPT. In plan mode ASSEMBLE-SYSTEM-PROMPT points # Environment at
;;; the area (as H5a) and adds the section +PLAN-MODE-SECTION+ followed by the
;;; template (PLAN-TEMPLATE-TEXT of planTemplate). Preview mode keeps H5a's
;;; section, renamed +PREVIEW-MODE-FEEDBACK+ (same text, "preview mode" for
;;; "plan mode").
;;;
;;; SETTINGS. "planTemplate": "default" | "spec" (+PLAN-TEMPLATES+), and
;;; "planSaveDirectory": a relative path without "..", any layer; anything
;;; else → SETTINGS-ERROR with the key path. Readers SETTINGS-PLAN-TEMPLATE,
;;; SETTINGS-PLAN-SAVE-DIRECTORY.
;;;
;;; RECORDS. A turn record gains PLAN-DOCUMENT (RECORD-PLAN-DOCUMENT), content
;;; key :PLAN-DOCUMENT, present only in turns that changed the document:
;;; PLAN-DOCUMENT-RECORD doc → (:id :revision :status :author :markdown
;;; :feedback). A plan turn that proposed records the new revision; an
;;; approval turn (the execution) records the :APPROVED status and, when the
;;; user edited plan.md, that :USER revision; the execution's end records
;;; :EXECUTED or :INTERRUPTED; a reject records :REJECTED (action-only:
;;; a record with no prompt, as H5a's action-only apply does not commit one,
;;; so the reject is stored in meta.sexp and the next turn's record). Older
;;; records read with NIL. /tree lines of a turn with a revision end with
;;; " ✎ r<N>"; EXPORT-SESSION :MARKDOWN adds, after the turn's answer, a block
;;; "### Plan <id8> revision N" LF LF the markdown. A conversation rewind
;;; (H3c / H5b REWIND-TO, conversation part) to a turn T sets the document
;;; back to the latest revision on T's line (plan.md rewritten from
;;; revisions/N.md, status :PROPOSED), or :DRAFTING when T's line has none,
;;; unless the document is :EXECUTED (then it stays; the files part is H5b's).
;;;
;;; HEADLESS (-p).
;;;   Plan run: --permission-mode plan (or --propose-only). The session's open
;;;   document (head line's latest record with status :DRAFTING or :PROPOSED
;;;   whose directory exists) is reopened, else a new one opens; a resumed
;;;   :PROPOSED document makes the prompt revision feedback. stream-json:
;;;   after system init {"type":"plan","subtype":"opened"|"reopened",
;;;   "plan_id","revision","path","area","sandbox"}; on propose_plan
;;;   {"type":"plan","subtype":"proposed","plan_id","revision","title","path",
;;;   "steps":[{"index","text","status"}],"files":[…],"markdown"}. The result
;;;   gains "plan" in plan runs only: PLAN-DOCUMENT-OBJECT, or null when the
;;;   run proposed nothing. text: the answer; when proposed, an empty line and
;;;   the markdown. stderr: "plan ID r<N>: proposed; review PATH, then
;;;   cl-stack-code -p --resume SESSION --approve-plan (or --reject-plan; or
;;;   --resume SESSION --permission-mode plan \"…\" to revise)", or
;;;   "plan ID: no plan proposed yet". Exit 0 (the run's own exit otherwise).
;;;   A turn may end without a plan (an answer, a question): that is no error.
;;;   --approve-plan (needs --resume / --continue; a prompt is extra
;;;   instructions): the execution mode is --permission-mode when given (not
;;;   plan), else acceptEdits — headless cannot ask, and the user just
;;;   approved the plan. No proposed or interrupted document → exit 2
;;;   "session ID has no plan to approve". One execution turn in the project
;;;   (preview: in a new preview area, then H5a's output and --apply). Events:
;;;   {"type":"plan","subtype":"approved","plan_id","revision","mode"} after
;;;   init; {"subtype":"step","plan_id","step","status","steps"} per
;;;   update_plan; {"subtype":"executed","plan_id","status","steps",
;;;   "changes":[{path,kind}],"rows":[{"path","change","planned"}],"diff"}
;;;   before the result. text: the answer, an empty line,
;;;   PLAN-VERSUS-DIFF-LINES, and, with changes, an empty line and the diff
;;;   (H5a's PLAN-DIFF-TEXT rendering of PRE → POST).
;;;   --reject-plan and --save-plan: action only (resume, no prompt, no LLM
;;;   call). Reject: {"subtype":"rejected","plan_id"}, stderr "plan ID:
;;;   rejected". Save: stdout the native path written.
;;;   Usage errors (exit 2), checked before anything opens:
;;;     "--approve-plan and --reject-plan cannot be used together"
;;;     "--approve-plan needs --resume or --continue" (likewise --reject-plan,
;;;       --save-plan)
;;;     "--reject-plan takes no prompt" (likewise --save-plan)
;;;     "--approve-plan runs the plan: --permission-mode must be default,
;;;       acceptEdits, bypassPermissions or preview"
;;;     "--propose-only is --permission-mode plan" (with another mode)
;;;     "--propose-only and --approve-plan cannot be used together"
;;;     "--apply and --reject act on a preview: use --permission-mode preview"
;;;       (--apply / --reject in plan mode; --approve-plan --permission-mode
;;;       preview --apply is fine)
;;;   Readers INVOCATION-APPROVE-PLAN-P, -REJECT-PLAN-P, -SAVE-PLAN-P,
;;;   -PROPOSE-ONLY-P, INVOCATION-PREVIEW-AREA (H5a's INVOCATION-PLAN-AREA
;;;   stays as an alias).
;;;
;;; INTERACTIVE.
;;;   Core events (:plan-doc-opened :id :path :area), (:plan-proposed :id
;;;   :revision :title :markdown :steps), (:plan-step :id :steps), (:plan-
;;;   executed :id :status :lines :diff), (:plan-doc-closed :id :status).
;;;   State STATE-PLAN-DOCUMENT (plist :id :revision :status :title :steps
;;;   :path, or NIL) and STATE-PLAN-DOCUMENT-PROMPT (:plan-doc | :plan-result
;;;   | NIL). After a proposing turn, when idle: the dialog "Plan <id8> r<N>:
;;;   <title>" (the markdown rendered with tui-markdown) with
;;;   +PLAN-DOCUMENT-CHOICES+. Replies → effects:
;;;     :approve-accept   (:approve-plan-document :mode :accept-edits)
;;;     :approve-ask      (:approve-plan-document :mode :default)
;;;     :approve-preview  (:approve-plan-document :mode :preview)
;;;     :edit             (:edit-plan-document): $VISUAL, else $EDITOR, else
;;;                       "vi" on plan.md through process-protocol with the
;;;                       terminal suspended; afterwards SYNC-PLAN-DOCUMENT-
;;;                       EDITS and the dialog again (r<N+1> when edited)
;;;     :revise           notice "plan <id8> r<N>: send your feedback to
;;;                       revise it, /approve to run it"; the next message is
;;;                       a plan turn (feedback)
;;;     :reject           (:reject-plan-document) → notice "plan <id8> rejected"
;;;     :save             (:save-plan-document) → notice "plan <id8> saved to
;;;                       PATH", the dialog again
;;;   Esc is :revise. Approval switches the session's permission mode to the
;;;   execution mode and runs the execution turn (its message shows as
;;;   "execute plan <id8> r<N>"). The checklist is a :plan-steps transcript
;;;   entry (id = the plan id) replaced in place on every :plan-step. At the
;;;   end a :plan-result entry (PLAN-VERSUS-DIFF-LINES and the diff) and, when
;;;   idle, the dialog "Plan <id8> done" with +PLAN-RESULT-CHOICES+: :keep
;;;   (nothing), :rewind-files ((:rewind 1 :parts (:files)), H5b), :save. A
;;;   preview execution shows the preview dialog instead (H5a), and the
;;;   :plan-result entry before it.
;;;   Commands: /plan (the document dialog; "no plan yet" without one),
;;;   /approve [accept|ask|preview] (default accept; another word → :error
;;;   "usage: /approve [accept|ask|preview]"), /reject, /save-plan ("no plan
;;;   yet" without one), /preview (H5a's /plan). /permissions to another mode
;;;   while a document is :PROPOSED is allowed (the document waits); /clear is
;;;   refused while one is :PROPOSED ("plan <id8> is waiting: /approve or
;;;   /reject it first").
;;;   Event payloads: :STEPS is a list of (:index I :text S :status ST).
;;;   Transcript entries: :plan-document (id, the markdown), :plan-steps (id,
;;;   the PLAN-STEPS-LINES), :plan-result (id, the lines and the diff).
;;;   Notices: opened "plan <id8>: exploring in a copy of the project (AREA);
;;;   nothing there is ever applied"; closed :rejected "plan <id8> rejected",
;;;   :executed "plan <id8> done", :interrupted "plan <id8> stopped before its
;;;   end: /approve runs the remaining steps" (the document stays);
;;;   saved "plan <id8> saved to NATIVE".
;;;   ask_user in the TUI: a dialog with the question, one choice per option
;;;   and "Other…" (a typed answer); Esc answers NIL (+ASK-USER-UNAVAILABLE+).
;;;   The migration notice is a notice at startup when the effective mode is
;;;   plan (MIGRATION).
;;;
;;; SDK AND RPC (src/client.lisp, src/rpc.lisp; left to the implementation).
;;;   CLIENT-PLAN-DOCUMENT session → PLAN-DOCUMENT-OBJECT plus "markdown", or
;;;   NIL. CLIENT-APPROVE-PLAN-DOCUMENT session &key (mode :accept-edits)
;;;   prompt on-drift → (values object turn) once the execution turn has
;;;   started (TURN is a CODE-TURN for CLIENT-WAIT; its events stream as any
;;;   turn's). CLIENT-REJECT-PLAN-DOCUMENT session → object.
;;;   CLIENT-REVISE-PLAN-DOCUMENT session feedback → the plan turn's CODE-TURN.
;;;   CLIENT-UPDATE-PLAN-DOCUMENT session markdown → object (a :USER revision;
;;;   PLAN-FORMAT-ERROR). CLIENT-SAVE-PLAN-DOCUMENT session &key directory →
;;;   native path. A session with no document → PLAN-DOCUMENT-NOT-FOUND; a
;;;   wrong status → PLAN-DOCUMENT-STATE-ERROR; a running turn → TURN-BUSY.
;;;   ask_user has no answerer in the SDK in 0.15.0 (+ASK-USER-UNAVAILABLE+).
;;;   RPC (+RPC-METHODS+ gains them): plan/approve {session_id, mode?
;;;   ("default" "acceptEdits" "bypassPermissions" "preview"), prompt?,
;;;   on_drift?} → {"plan", "session_id"}; plan/reject {session_id} →
;;;   {"plan"}; plan/revise {session_id, feedback} → {"session_id"};
;;;   plan/get {session_id} → {"plan": object with "markdown" | null};
;;;   plan/update {session_id, markdown} → {"plan"}; plan/save {session_id,
;;;   directory?} → {"path"}; preview/apply, preview/reject (H5a's). Errors:
;;;   PLAN-DOCUMENT-NOT-FOUND -32030, PLAN-DOCUMENT-STATE-ERROR -32031 (data
;;;   "plan_id", "status"); PLAN-FORMAT-ERROR (plan/update) -32602 with
;;;   "missing".
;;;
;;; ACP (cl-stack-code/acp, ACP-2's adjustments; tests in .team-solve/task.md).
;;;   Modes: the five mode names. The "plan" events give ACP `plan` updates:
;;;   proposed → entries = steps, status "pending", priority "medium"; step →
;;;   the whole list again (ACP replaces it) with "pending" / "in_progress" /
;;;   "completed"; rejected → empty entries. Approval: inside the
;;;   session/prompt that proposed, a session/request_permission whose
;;;   toolCall is the propose_plan call (kind "switch_mode", content the
;;;   markdown) with +ACP-PLAN-APPROVAL-OPTIONS+; an approval runs the
;;;   execution turn in the same prompt after a current_mode_update; "keep
;;;   planning" ends the prompt (the next prompt is feedback); "reject" rejects.
;;;   session/set_mode out of plan while a document is :PROPOSED approves it
;;;   under that mode, and the next session/prompt executes it (its text as
;;;   extra instructions). Preview events are no longer ACP `plan` updates.

;;; Exports (kept in this file, so merges with the in-flight slices stay
;;; small).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(;; documents
            plan-document plan-document-p plan-document-id plan-document-project-dir
            plan-document-directory plan-document-session-id plan-document-status
            plan-document-revision plan-document-template plan-document-title
            plan-document-steps plan-document-files plan-document-area-id
            plan-document-execution-mode plan-document-opened-at
            plan-step plan-step-p make-plan-step plan-step-index plan-step-text plan-step-status
            plan-revision plan-revision-p plan-revision-index plan-revision-author
            plan-revision-markdown plan-revision-feedback plan-revision-recorded-at
            +plan-document-format+ +plan-document-statuses+ +plan-step-statuses+
            +plan-templates+ +plan-execution-modes+ +plan-scratch-directory-name+
            +plan-tool-names+ +plan-document-choices+ +plan-result-choices+
            +acp-plan-approval-options+
            +plan-mode-section+ +plan-mode-edit-feedback+ +plan-execution-preamble+
            +ask-user-unavailable+ +plan-mode-migration-notice+
            +default-plan-template+ +spec-plan-template+ +default-plan-save-directory+
            plan-documents-directory open-plan-document reopen-plan-document
            list-plan-documents plan-document-path plan-document-markdown
            parse-plan-markdown plan-template-text
            propose-plan-revision sync-plan-document-edits plan-document-revisions
            approve-plan-document reject-plan-document plan-execution-prompt
            set-plan-step finish-plan-execution plan-steps-lines
            plan-versus-diff plan-versus-diff-lines save-plan-to-workspace
            plan-document-object plan-document-record
            ;; tools and policy
            plan-tools plan-tools-p make-plan-tools plan-mode-tools
            plan-mode-permission-policy
            ;; conditions
            plan-document-error plan-document-error-document
            plan-document-not-found plan-document-not-found-designator
            plan-document-state-error plan-document-state-error-status
            plan-format-error plan-format-error-missing
            ;; elsewhere (src/settings.lisp, sessions, interactive, client, arguments)
            settings-plan-template settings-plan-save-directory
            record-plan-document
            state-plan-document state-plan-document-prompt
            invocation-approve-plan-p invocation-reject-plan-p invocation-save-plan-p
            invocation-propose-only-p invocation-preview-area
            client-plan-document client-approve-plan-document client-reject-plan-document
            client-revise-plan-document client-update-plan-document client-save-plan-document
            client-apply-preview client-reject-preview
            +preview-mode-feedback+)
          '#:cl-stack-code))

(defun %h5c0-pending (name)
  "The stub of every H5c-0 function not implemented yet."
  (error 'code-error :message (format nil "H5c-0: ~(~a~) is not implemented yet" name)))

;;; Constants (given).

(defparameter +plan-document-format+ 1
  "meta.sexp's :FORMAT.")

(defparameter +plan-document-statuses+
  '(:drafting :proposed :approved :executed :interrupted :rejected))

(defparameter +plan-step-statuses+ '(:pending :in-progress :done))

(defparameter +plan-templates+ '(:default :spec)
  "planTemplate values, as keywords.")

(defparameter +plan-execution-modes+ '(:default :accept-edits :bypass-permissions :preview)
  "The modes an approved plan can run under (never :PLAN).")

(defparameter +plan-scratch-directory-name+ ".plan-scratch"
  "The model's scratch directory, relative to the exploration area.")

(defparameter +default-plan-save-directory+ "docs/plans"
  "planSaveDirectory when no layer sets it.")

(defparameter +plan-tool-names+ '("propose_plan" "ask_user" "update_plan"))

(defparameter +plan-document-choices+
  '((:approve-accept "Approve, accept edits")
    (:approve-ask "Approve, ask before edits")
    (:approve-preview "Approve, run in preview")
    (:edit "Edit in $EDITOR")
    (:revise "Revise")
    (:reject "Reject")
    (:save "Save to workspace"))
  "The plan document dialog's choices, in order (keys 1–7).")

(defparameter +plan-result-choices+
  '((:keep "Keep the changes")
    (:rewind-files "Rewind the files")
    (:save "Save the plan to the workspace"))
  "The dialog after an execution, in order.")

(defparameter +acp-plan-approval-options+
  '(("acceptEdits" "allow_always" "Yes, and accept edits")
    ("default" "allow_once" "Yes, and ask before edits")
    ("preview" "allow_once" "Yes, in a preview copy")
    ("plan" "reject_once" "No, keep planning")
    ("reject" "reject_always" "Reject the plan"))
  "ACP-2: (optionId kind name) of the plan approval request, in order.")

(defparameter +plan-mode-section+
  "You are in plan mode: explore and propose, do not implement. Read files, search, and run exploratory commands; they run confined in a throwaway copy of the project (the working directory above), and nothing you do there is ever applied. Write scratch files only under .plan-scratch/; edits to project files are refused. Ask the user with ask_user when only they can decide. When you are ready, call propose_plan with the plan as markdown in this form, and stop:"
  "H5c-0: the system prompt section of a plan run; the template follows it.")

(defparameter +plan-mode-edit-feedback+
  "You are in plan mode: project files cannot be edited now. Describe the change in the plan instead (call propose_plan when it is ready). Scratch files may go under .plan-scratch/."
  "H5c-0: what the model is told when plan mode refuses an edit.")

(defparameter +plan-execution-preamble+
  "The user approved this plan. Carry it out in the project now. Call update_plan with in_progress when you start a step and done when it is finished. If you have to deviate from the plan, say why."
  "H5c-0: the start of an execution turn's prompt.")

(defparameter +ask-user-unavailable+
  "No user can answer questions in this session. Make a reasonable assumption, state it under Findings in the plan, and go on."
  "H5c-0: ask_user's result where nobody can answer.")

(defparameter +plan-mode-migration-notice+
  "\"plan\" mode now plans first: the agent explores and proposes a plan, and nothing changes until you approve it. The old behaviour (work in a copy of the project, then approve the diff) is the \"preview\" mode: use --permission-mode preview or \"permissionMode\": \"preview\" to keep it."
  "H5c-0: shown once per data directory on the first plan run of 0.15.x.")

(defparameter +default-plan-template+
  "# <title>

## Goal
<what the change achieves, one paragraph>

## Findings
<what you found while exploring: files, functions, behaviour, experiments>

## Steps
1. <a step the executor can check off>
2. <…>

## Files to change
- `<path>`: <why>

## Risks
<what could break, and how you would notice>

## Test plan
<the tests to add or run, and the expected result>
"
  "planTemplate \"default\".")

(defparameter +spec-plan-template+
  "# <title>

## Requirements
- WHEN <event> THE SYSTEM SHALL <response>

## Design
<components, data, interfaces, error handling>

## Files to change
- `<path>`: <why>

## Tasks
1. <an implementation task the executor can check off>
2. <…>
"
  "planTemplate \"spec\" (Kiro-style requirements, design, tasks).")

(defparameter +preview-mode-feedback+
  "You are in preview mode: your edits and shell commands run in a copy of the project (the working directory above), not in the project itself. Make the change there and run the tests there; nothing reaches the project until the user approves the projected change."
  "H5c-0: H5a's +PLAN-MODE-FEEDBACK+ under its new name (preview mode).")

;;; Conditions (given).

(define-condition plan-document-error (code-error)
  ((document :initarg :document :initform nil :reader plan-document-error-document
             :documentation "The PLAN-DOCUMENT, or NIL."))
  (:documentation "Root of the plan document errors. Exit 1.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c) "plan document error")))))

(define-condition plan-document-not-found (plan-document-error)
  ((designator :initarg :designator :initform nil
               :reader plan-document-not-found-designator))
  (:documentation "No such plan document, or the session has none. Exit 2.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "no plan ~a"
                                        (plan-document-not-found-designator c)))))))

(define-condition plan-document-state-error (plan-document-error)
  ((status :initarg :status :initform nil :reader plan-document-state-error-status))
  (:documentation "The operation needs another status (e.g. approving a plan
that is not :PROPOSED). Exit 2.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "the plan is ~(~a~)"
                                        (plan-document-state-error-status c)))))))

(define-condition plan-format-error (plan-document-error)
  ((missing :initarg :missing :initform nil :reader plan-format-error-missing
            :documentation "The required heading names that are missing, or
whose list is empty, in the template's order."))
  (:documentation "A plan's markdown lacks a required section.")
  (:report (lambda (c s)
             (format s "~a" (or (code-error-message c)
                                (format nil "the plan is missing ~{~a~^, ~}"
                                        (plan-format-error-missing c)))))))

;;; Values (given).

(defstruct (plan-step (:constructor make-plan-step (&key index text (status :pending))))
  (index 1 :type (integer 1))
  (text "" :type string)
  (status :pending :type (member :pending :in-progress :done)))

(defstruct (plan-revision (:constructor %make-plan-revision))
  (index 1 :type (integer 1))
  (author :model :type (member :model :user))
  (markdown "" :type string)
  (feedback nil :type (or null string))
  (recorded-at nil))

(defclass plan-document ()
  ((id :initarg :id :reader plan-document-id)
   (project-dir :initarg :project-dir :reader plan-document-project-dir)
   (directory :initarg :directory :reader plan-document-directory
              :documentation "<plan-docs dir>/<id>/, a directory pathname.")
   (session-id :initarg :session-id :initform nil :reader plan-document-session-id)
   (status :initarg :status :initform :drafting :accessor plan-document-status)
   (revision :initarg :revision :initform 0 :accessor plan-document-revision
             :documentation "The current revision's index; 0 before the first.")
   (template :initarg :template :initform :default :reader plan-document-template)
   (title :initarg :title :initform nil :accessor plan-document-title)
   (steps :initarg :steps :initform '() :accessor plan-document-steps
          :documentation "PLAN-STEP structs, in order.")
   (files :initarg :files :initform '() :accessor plan-document-files
          :documentation "Relative paths from \"Files to change\".")
   (area-id :initarg :area-id :initform nil :accessor plan-document-area-id
            :documentation "The exploration area's H5a plan id, or NIL.")
   (execution-mode :initarg :execution-mode :initform nil
                   :accessor plan-document-execution-mode)
   (opened-at :initarg :opened-at :initform nil :reader plan-document-opened-at))
  (:documentation "H5c-0: a plan document (see the file header)."))

(defun plan-document-p (x)
  (typep x 'plan-document))

(defmethod print-object ((d plan-document) stream)
  (print-unreadable-object (d stream :type t)
    (format stream "~a r~d ~(~a~)" (subseq (plan-document-id d) 0 8)
            (plan-document-revision d) (plan-document-status d))))

(defun plan-documents-directory (cwd &key data-dir)
  "→ <data-dir>/plan-docs/<project-key>/ for the project of CWD (DATA-DIR
defaults to USER-DATA-DIRECTORY). Given: PLANS-DIRECTORY's rule."
  (let* ((cwd (uiop:ensure-directory-pathname cwd))
         (project (or (find-project-root cwd) (probe-file cwd) cwd))
         (data (uiop:ensure-directory-pathname (or data-dir (user-data-directory)))))
    (uiop:merge-pathnames* (uiop:parse-unix-namestring
                            (format nil "plan-docs/~a/" (project-session-key project)))
                           data)))

(defun plan-document-path (doc)
  "→ <directory>/plan.md (given)."
  (merge-pathnames "plan.md" (uiop:ensure-directory-pathname (plan-document-directory doc))))

;;; The policy (given): new rule logic goes through policy-protocol.

(stack-policy:defpolicy plan-mode-tools (:combining :last-match)
  (forbid :id "no-edit" :action "write" :when (mode plan)
          :feedback "You are in plan mode: project files cannot be edited now. Describe the change in the plan instead (call propose_plan when it is ready). Scratch files may go under .plan-scratch/.")
  (forbid :id "no-edit-edit" :action "edit" :when (mode plan)
          :feedback "You are in plan mode: project files cannot be edited now. Describe the change in the plan instead (call propose_plan when it is ready). Scratch files may go under .plan-scratch/.")
  (forbid :id "no-edit-multi" :action "multi_edit" :when (mode plan)
          :feedback "You are in plan mode: project files cannot be edited now. Describe the change in the plan instead (call propose_plan when it is ready). Scratch files may go under .plan-scratch/.")
  (permit :id "scratch-write" :action "write" :resource (:path "path:.plan-scratch")
          :when (mode plan))
  (permit :id "scratch-edit" :action "edit" :resource (:path "path:.plan-scratch")
          :when (mode plan))
  (permit :id "scratch-multi" :action "multi_edit" :resource (:path "path:.plan-scratch")
          :when (mode plan))
  (forbid :id "no-update-plan" :action "update_plan" :when (mode plan)
          :feedback "update_plan marks steps while an approved plan runs; in plan mode, call propose_plan."))

;;; The implementation (%H5C0-PENDING, given, is no longer called).

(defclass plan-tools ()
  ((document :initarg :document :reader plan-tools-document)
   (phase :initarg :phase :reader plan-tools-phase)
   (ask :initarg :ask :initform nil :reader plan-tools-ask))
  (:documentation "H5c-0: propose_plan / ask_user (phase :PLAN) or update_plan
(phase :EXECUTE). The implementation makes it an ai-agent-protocol tool
source (superclass and methods)."))

(defun plan-tools-p (x)
  (typep x 'plan-tools))

(defun plan-mode-permission-policy (&key (policy 'plan-mode-tools))
  "→ (lambda (action resources effect)) for ai-agent-protocol's
:permission-policy: POLICY (policy-protocol) decides on (:action ACTION
:resources RESOURCES :context ((mode plan))). :FORBID → (values :deny RULE),
:ASK → (values :ask RULE), RULE naming the deciding resource and carrying the
decision's feedback; no opinion otherwise (a policy only tightens)."
  (lambda (action resources effect)
    (declare (ignore effect))
    (let* ((decision (stack-policy:evaluate-policy
                      policy (list :action action :resources (or resources '("*"))
                                   :context '((mode plan)))))
           (verdict (stack-policy:decision-effect decision)))
      (flet ((rule (effect)
               (agent:make-permission-rule
                action (or (stack-policy:decision-resource decision) (first resources) "*") effect
                :feedback (stack-policy:decision-feedback decision))))
        (case verdict
          (:forbid (values :deny (rule :deny)))
          (:ask (values :ask (rule :ask)))
          (t nil))))))

;;; ------------------------------------------------------------------
;;; Implementation (H5c-0). Internal helpers are %-prefixed.

;;; meta.sexp

(defun %plan-doc-subdir (doc name)
  (uiop:merge-pathnames* name (uiop:ensure-directory-pathname (plan-document-directory doc))))

(defun %plan-doc-meta-file (directory)
  (uiop:merge-pathnames* "meta.sexp" (uiop:ensure-directory-pathname directory)))

(defun %plan-doc-revision-file (doc n)
  (%plan-doc-subdir doc (format nil "revisions/~d.md" n)))

(defun %plan-doc-now-us ()
  "Microseconds since 1900 (orders documents opened in the same second)."
  #+sbcl (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
           ;; 2208988800: seconds from 1900 to the Unix epoch
           (+ (* (+ sec 2208988800) 1000000) usec))
  #-sbcl (* (get-universal-time) 1000000))

;;; Per-document state that is not in the given slots: the revision history,
;;; the ordering key. Kept in an EQ table, written to meta.sexp.

(defvar *plan-doc-extra* (make-hash-table :test 'eq #+sbcl :weakness #+sbcl :key
                                          #+sbcl :synchronized #+sbcl t)
  "PLAN-DOCUMENT → plist (:revisions (plist …) :opened-us N :data-dir D).")

(defun %doc-extra (doc key)
  (getf (gethash doc *plan-doc-extra*) key))

(defun (setf %doc-extra) (value doc key)
  (let ((plist (gethash doc *plan-doc-extra*)))
    (setf (getf plist key) value
          (gethash doc *plan-doc-extra*) plist)
    value))

(defun %step-plist (step)
  (list :index (plan-step-index step) :text (plan-step-text step) :status (plan-step-status step)))

(defun %plist-step (plist)
  (make-plan-step :index (getf plist :index) :text (getf plist :text)
                  :status (or (getf plist :status) :pending)))

(defun %write-plan-doc-meta (doc)
  "Write DOC's meta.sexp atomically (format 1; extra keys :OPENED-US,
:REVISIONS, :APPROVED-FROM, :EXECUTION-STARTED)."
  (let ((form (list :format +plan-document-format+
                    :id (plan-document-id doc)
                    :project-dir (uiop:native-namestring (plan-document-project-dir doc))
                    :session (plan-document-session-id doc)
                    :status (plan-document-status doc)
                    :revision (plan-document-revision doc)
                    :template (plan-document-template doc)
                    :title (plan-document-title doc)
                    :steps (mapcar #'%step-plist (plan-document-steps doc))
                    :files (copy-list (plan-document-files doc))
                    :area (plan-document-area-id doc)
                    :mode (plan-document-execution-mode doc)
                    :opened-at (plan-document-opened-at doc)
                    :opened-us (%doc-extra doc :opened-us)
                    :revisions (copy-list (%doc-extra doc :revisions))
                    :approved-from (%doc-extra doc :approved-from)
                    :execution-started (plan-execution-started-p doc)
                    :version +version+)))
    (ensure-directories-exist (plan-document-directory doc))
    (p:write-text (%plan-doc-meta-file (plan-document-directory doc))
                  (with-standard-io-syntax
                      (let ((*package* (find-package :keyword)))
                        (format nil "~s~%" form)))
                  :atomic t)
    doc))

(defun %read-plan-doc-meta (directory id)
  "The PLAN-DOCUMENT in DIRECTORY (its own <id>/ directory), or
PLAN-DOCUMENT-NOT-FOUND :DESIGNATOR ID when it is missing or unreadable."
  (let ((file (%plan-doc-meta-file directory)))
    (flet ((lost ()
             (error 'plan-document-not-found :designator id)))
      (unless (probe-file file)
        (lost))
      (let ((form (handler-case
                      (with-standard-io-syntax
                          (let ((*package* (find-package :keyword))
                                (*read-eval* nil))
                            (read-from-string (uiop:read-file-string file :external-format :utf-8))))
                    (error () (lost)))))
        (unless (%plist-p form) (lost))
        (destructuring-bind (&key format ((:id file-id)) project-dir session status revision template
                                  title steps files area mode opened-at opened-us revisions
                                  approved-from execution-started
                                  &allow-other-keys)
            form
          (unless (and (eql format +plan-document-format+)
                       (stringp file-id) (stringp project-dir)
                       (member status +plan-document-statuses+)
                       (integerp revision) (member template +plan-templates+)
                       (listp steps) (listp files) (listp revisions))
            (lost))
          (let ((doc (make-instance 'plan-document
                                    :id file-id
                                    :project-dir (uiop:parse-native-namestring project-dir
                                                                               :ensure-directory t)
                                    :directory (uiop:ensure-directory-pathname directory)
                                    :session-id session :status status :revision revision
                                    :template template :title title
                                    :steps (mapcar #'%plist-step steps)
                                    :files files :area-id area :execution-mode mode
                                    :opened-at opened-at)))
            (setf (%doc-extra doc :opened-us) (or opened-us (* (or opened-at 0) 1000000))
                  (%doc-extra doc :revisions) revisions
                  (%doc-extra doc :approved-from) approved-from
                  (%doc-extra doc :execution-started) (and execution-started t))
            doc))))))

;;; Opening, reading back.

(defun open-plan-document (project-dir &key data-dir session-id id (template :default))
  "→ a new :DRAFTING PLAN-DOCUMENT for PROJECT-DIR, meta.sexp written."
  (unless (member template +plan-templates+)
    (error 'code-usage-error
           :message (format nil "unknown plan template ~s: use ~{~(~a~)~^, ~}" template
                            +plan-templates+)))
  (let* ((project (%truename-directory project-dir))
         (dir (plan-documents-directory project :data-dir data-dir))
         (id (cond ((null id) (%session-id))
                   ((normalize-session-id id))
                   (t (error 'plan-document-error
                             :message (format nil "bad plan id ~s: use 32 hex digits" id)))))
         (directory (uiop:merge-pathnames* (format nil "~a/" id) dir)))
    (when (uiop:directory-exists-p directory)
      (error 'plan-document-error :message (format nil "plan ~a already exists" id)))
    (let ((doc (make-instance 'plan-document :id id :project-dir project :directory directory
                                             :session-id session-id :status :drafting
                                             :revision 0 :template template
                                             :opened-at (get-universal-time))))
      (setf (%doc-extra doc :opened-us) (%plan-doc-now-us)
            (%doc-extra doc :revisions) '())
      (%write-plan-doc-meta doc))))

(defun reopen-plan-document (directory id)
  "→ the PLAN-DOCUMENT ID under DIRECTORY (PLAN-DOCUMENTS-DIRECTORY), or
PLAN-DOCUMENT-NOT-FOUND."
  (let ((normal (and (stringp id) (normalize-session-id id))))
    (unless normal
      (error 'plan-document-not-found :designator id))
    (let ((sub (uiop:merge-pathnames* (format nil "~a/" normal)
                                      (uiop:ensure-directory-pathname directory))))
      (unless (uiop:directory-exists-p sub)
        (error 'plan-document-not-found :designator id))
      (%read-plan-doc-meta sub id))))

(defun list-plan-documents (directory)
  "→ every readable PLAN-DOCUMENT under DIRECTORY, oldest first."
  (let ((dir (uiop:directory-exists-p directory)))
    (and dir
         (sort (loop for sub in (uiop:subdirectories dir)
                     for id = (car (last (pathname-directory sub)))
                     for doc = (handler-case (%read-plan-doc-meta sub id)
                                 (plan-document-not-found () nil))
                     when doc collect doc)
               (lambda (a b)
                 (let ((x (%doc-extra a :opened-us)) (y (%doc-extra b :opened-us)))
                   (or (< x y)
                       (and (= x y) (string< (plan-document-id a) (plan-document-id b))))))))))

(defun plan-document-markdown (doc)
  "→ plan.md's text, or NIL before the first proposal."
  (let ((path (plan-document-path doc)))
    (and (probe-file path)
         (uiop:read-file-string path :external-format :utf-8))))

;;; The format (markdown-protocol's AST).

(defun %md-inline-text (inlines)
  "The plain text of INLINES: code spans as their text, breaks as spaces."
  (with-output-to-string (s)
    (labels ((walk (xs)
               (dolist (x xs)
                 (cond ((stringp x) (write-string x s))
                       ((consp x)
                        (case (first x)
                          ((:soft-break :hard-break) (write-char #\Space s))
                          (:code (write-string (second x) s))
                          ((:link :image) (walk (third x)))
                          (t (walk (second x)))))))))
      (walk inlines))))

(defun %md-trim (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun %md-list-items (block)
  (case (first block)
    (:bullet-list (third block))
    (:ordered-list (fifth block))))

(defun %md-item-text (blocks)
  "An item's text: its paragraphs (nested lists are not part of it)."
  (%md-trim (format nil "~{~a~^ ~}"
                    (loop for b in blocks
                          when (eq (first b) :paragraph)
                            collect (%md-trim (%md-inline-text (second b)))))))

(defun %md-first-code (blocks)
  "The text of the first code span in an item's paragraphs, or NIL."
  (labels ((walk (xs)
             (dolist (x xs)
               (when (consp x)
                 (case (first x)
                   (:code (return-from %md-first-code (second x)))
                   ((:soft-break :hard-break))
                   ((:link :image) (walk (third x)))
                   (t (walk (second x))))))))
    (dolist (b blocks)
      (when (eq (first b) :paragraph)
        (walk (second b))))
    nil))

(defun %md-section (blocks name)
  "→ (values items found-p): the items of the first list after the level ≥ 2
heading NAME, before the next heading of the same or a higher level."
  (loop for (b . rest) on blocks
        when (and (eq (first b) :heading) (>= (second b) 2)
                  (string-equal (%md-trim (%md-inline-text (third b))) name))
          do (let ((level (second b)))
               (return (values (loop for x in rest
                                     until (and (eq (first x) :heading) (<= (second x) level))
                                     thereis (%md-list-items x))
                               t)))
        finally (return (values nil nil))))

(defun %template-headings (template)
  "→ (values required steps-heading) of TEMPLATE."
  (ecase template
    (:default (values '("Goal" "Steps") "Steps"))
    (:spec (values '("Requirements" "Design" "Tasks") "Tasks"))))

(defun %parse-plan-markdown (text template doc)
  (check-type text string)
  (let ((blocks (mdp:parse-markdown text)))
    (multiple-value-bind (required steps-heading) (%template-headings template)
      (let ((missing (loop for name in required
                           unless (multiple-value-bind (items found) (%md-section blocks name)
                                    (and found (or (not (string= name steps-heading)) items)))
                             collect name)))
        (when missing
          (error 'plan-format-error :document doc :missing missing)))
      (let ((title (loop for b in blocks
                         when (and (eq (first b) :heading) (eql 1 (second b)))
                           return (%md-trim (%md-inline-text (third b)))))
            (steps (mapcar #'%md-item-text (%md-section blocks steps-heading)))
            (files (mapcar (lambda (item)
                             (or (%md-first-code item)
                                 (let ((text (%md-item-text item)))
                                   (subseq text 0 (or (position-if (lambda (c) (member c '(#\Space #\Tab)))
                                                                   text)
                                                      (length text))))))
                           (%md-section blocks "Files to change"))))
        (values title steps (remove "" files :test #'string=))))))

(defun parse-plan-markdown (text &key (template :default))
  "→ (values title steps files), see the header."
  (%parse-plan-markdown text template nil))

(defun plan-template-text (template)
  (ecase template
    (:default +default-plan-template+)
    (:spec +spec-plan-template+)))

(defun %plan-mode-prompt-section (settings)
  "H5c-0: the plan run's system prompt section: +PLAN-MODE-SECTION+, LF, the
template of planTemplate."
  (format nil "~a~%~a" +plan-mode-section+
          (plan-template-text (or (settings-plan-template settings) :default))))

;;; Revisions.

(defun %write-utf-8 (path text)
  (ensure-directories-exist path)
  (p:write-text path text :atomic t))

(defun %set-doc-content (doc text)
  "Title, steps (all :PENDING) and files from TEXT (already parsed fine)."
  (multiple-value-bind (title steps files)
      (%parse-plan-markdown text (plan-document-template doc) doc)
    (setf (plan-document-title doc) title
          (plan-document-steps doc) (loop for s in steps for i from 1
                                          collect (make-plan-step :index i :text s))
          (plan-document-files doc) files)))

(defun propose-plan-revision (doc markdown &key (author :model) feedback)
  "→ N, the new revision (see the header)."
  (check-type author (member :model :user))
  (%parse-plan-markdown markdown (plan-document-template doc) doc)
  (let ((n (1+ (plan-document-revision doc))))
    (%write-utf-8 (%plan-doc-revision-file doc n) markdown)
    (%write-utf-8 (plan-document-path doc) markdown)
    (%set-doc-content doc markdown)
    (setf (plan-document-revision doc) n
          (plan-document-status doc) :proposed
          (%doc-extra doc :revisions)
          (append (%doc-extra doc :revisions)
                  (list (list :index n :author author :feedback feedback
                              :recorded-at (get-universal-time)))))
    (%write-plan-doc-meta doc)
    n))

(defun %file-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun sync-plan-document-edits (doc)
  "→ NIL, or N+1 when plan.md differs from revisions/N.md (a :USER revision)."
  (let ((n (plan-document-revision doc))
        (path (plan-document-path doc)))
    (when (and (plusp n) (probe-file path))
      (let ((rev (%plan-doc-revision-file doc n)))
        (unless (and (probe-file rev) (equalp (%file-octets path) (%file-octets rev)))
          (let ((status (plan-document-status doc))
                (n2 (propose-plan-revision doc (uiop:read-file-string path :external-format :utf-8)
                                           :author :user)))
            ;; an edit of an interrupted plan keeps it approvable
            (unless (member status '(:drafting :proposed))
              (setf (plan-document-status doc) status)
              (%write-plan-doc-meta doc))
            n2))))))

(defun plan-document-revisions (doc)
  "→ PLAN-REVISION structs, oldest first."
  (loop for plist in (%doc-extra doc :revisions)
        for n = (getf plist :index)
        for file = (%plan-doc-revision-file doc n)
        collect (%make-plan-revision
                 :index n :author (or (getf plist :author) :model)
                 :markdown (if (probe-file file) (uiop:read-file-string file :external-format :utf-8) "")
                 :feedback (getf plist :feedback)
                 :recorded-at (getf plist :recorded-at))))

;;; Approval and execution.

(defun %doc-data-dir (doc)
  "The data directory DOC lives under (<data>/plan-docs/<key>/<id>/)."
  (let ((dir (pathname-directory (uiop:ensure-directory-pathname (plan-document-directory doc)))))
    (make-pathname :directory (butlast dir 3) :name nil :type nil
                   :defaults (plan-document-directory doc))))

(defun %doc-area (doc)
  "The exploration area (an open H5a PLAN) of DOC, or NIL when it is gone."
  (let ((id (plan-document-area-id doc)))
    (and id
         (handler-case (reopen-plan (plans-directory (plan-document-project-dir doc)
                                                     :data-dir (%doc-data-dir doc))
                                    id)
           (plan-error () nil)))))

(defun %plan-doc-state-fail (doc action)
  (error 'plan-document-state-error
         :document doc :status (plan-document-status doc)
         :message (format nil "plan ~a is ~(~a~): it cannot be ~a"
                          (subseq (plan-document-id doc) 0 8) (plan-document-status doc) action)))

(defun %copy-tree (from to)
  "Copy the files under directory FROM into directory TO."
  (dolist (file (uiop:directory-files from))
    (let ((target (uiop:merge-pathnames* (file-namestring file) to)))
      (ensure-directories-exist target)
      (uiop:copy-file file target)))
  (dolist (sub (uiop:subdirectories from))
    (%copy-tree sub (uiop:merge-pathnames* (format nil "~a/" (car (last (pathname-directory sub))))
                                           to))))

(defun %discard-doc-area (doc &key keep-scratch)
  "Copy the area's scratch (KEEP-SCRATCH), reject the area and remove its
directory (an exploration area is never applied, so nothing of it stays among
the previews); a lost area is skipped. DOC forgets the area."
  (let ((area (%doc-area doc)))
    (when area
      (when keep-scratch
        (let ((scratch (uiop:directory-exists-p
                        (uiop:merge-pathnames* (format nil "~a/" +plan-scratch-directory-name+)
                                               (plan-root area)))))
          (when scratch
            (%copy-tree scratch (%plan-doc-subdir doc "scratch/")))))
      (reject-plan area)
      (uiop:delete-directory-tree (uiop:ensure-directory-pathname (plan-directory area))
                                  :validate t :if-does-not-exist :ignore))
    (setf (plan-document-area-id doc) nil)))

(defun approve-plan-document (doc &key (mode :accept-edits))
  "→ DOC, :APPROVED under MODE (see the header). Its execution has not
started yet (PLAN-EXECUTION-STARTED-P is NIL)."
  (unless (member (plan-document-status doc) '(:proposed :interrupted))
    (%plan-doc-state-fail doc "approved"))
  (unless (member mode +plan-execution-modes+)
    (error 'code-usage-error
           :message (format nil "a plan runs in ~{~a~^, ~}, not ~a"
                            (mapcar #'permission-mode-name +plan-execution-modes+)
                            (if (member mode +permission-mode-keywords+)
                                (permission-mode-name mode)
                                mode))))
  (let ((status (plan-document-status doc)))
    (sync-plan-document-edits doc)
    (%discard-doc-area doc :keep-scratch t)
    (setf (plan-document-status doc) :approved
          (plan-document-execution-mode doc) mode
          (%doc-extra doc :approved-from) status
          (%doc-extra doc :execution-started) nil)
    (%write-plan-doc-meta doc)
    doc))

(defun plan-execution-started-p (doc)
  "0.16.4 (#65): true once the execution turn of DOC's current approval has
started (kept in meta.sexp). An :APPROVED document whose execution has not
started (approved with :EXECUTE NIL, ACP's session/set_mode) may be approved
again, which runs it; one whose execution started may not."
  (and (%doc-extra doc :execution-started) t))

(defun note-plan-execution-started (doc)
  "Record that DOC's execution turn starts now. → DOC."
  (setf (%doc-extra doc :execution-started) t)
  (%write-plan-doc-meta doc)
  doc)

(defun check-plan-approvable (doc)
  "PLAN-DOCUMENT-STATE-ERROR unless DOC may be approved now: :PROPOSED,
:INTERRUPTED, or :APPROVED with its execution not started. → DOC."
  (let ((status (plan-document-status doc)))
    (cond ((member status '(:proposed :interrupted)) doc)
          ((and (eq status :approved) (not (plan-execution-started-p doc))) doc)
          ((eq status :approved)
           (%plan-doc-state-fail doc "approved again: its execution has started"))
          (t (%plan-doc-state-fail doc "approved")))))

(defun reject-plan-document (doc)
  "→ :REJECTED, the area discarded."
  (unless (member (plan-document-status doc) '(:drafting :proposed))
    (%plan-doc-state-fail doc "rejected"))
  (%discard-doc-area doc)
  (setf (plan-document-status doc) :rejected)
  (%write-plan-doc-meta doc)
  :rejected)

(defun %doc-scratch-files-p (doc)
  (let ((dir (uiop:directory-exists-p (%plan-doc-subdir doc "scratch/"))))
    (and dir (or (uiop:directory-files dir) (uiop:subdirectories dir)) dir)))

(defun plan-execution-prompt (doc &optional extra)
  "→ the execution turn's user text (see the header)."
  (with-output-to-string (s)
    (format s "~a~%~%<plan id=\"~a\" revision=\"~d\">~%~a~%</plan>"
            +plan-execution-preamble+ (plan-document-id doc) (plan-document-revision doc)
            (or (plan-document-markdown doc) ""))
    (let ((scratch (%doc-scratch-files-p doc)))
      (when scratch
        (format s "~%~%Scratch files from planning: ~a" (uiop:native-namestring scratch))))
    (let ((done (loop for step in (plan-document-steps doc)
                      when (eq :done (plan-step-status step)) collect (plan-step-index step))))
      (when (and done (or (eq :interrupted (plan-document-status doc))
                          (eq :interrupted (%doc-extra doc :approved-from))))
        (format s "~%~%Steps already done: ~{~d~^, ~}" done)))
    (when (and extra (plusp (length extra)))
      (format s "~%~%~a" extra))))

(defun set-plan-step (doc index status)
  "→ the steps, step INDEX (from 1) set to STATUS."
  (unless (member status +plan-step-statuses+)
    (error 'plan-document-error :document doc
                                :message (format nil "bad step status ~s: use pending, in_progress or done"
                                                 status)))
  (let* ((steps (plan-document-steps doc))
         (step (and (integerp index) (find index steps :key #'plan-step-index))))
    (unless step
      (error 'plan-document-error :document doc
                                  :message (format nil "plan has no step ~a (1–~d)" index (length steps))))
    (setf (plan-step-status step) status)
    (%write-plan-doc-meta doc)
    steps))

(defun finish-plan-execution (doc &key changes interrupted)
  "→ :EXECUTED, or :INTERRUPTED with INTERRUPTED."
  (declare (ignore changes))
  (setf (plan-document-status doc) (if interrupted :interrupted :executed))
  (%write-plan-doc-meta doc)
  (plan-document-status doc))

(defun %step-mark (status)
  (ecase status (:pending "☐") (:in-progress "◐") (:done "☑")))

(defun plan-steps-lines (doc)
  (loop for step in (plan-document-steps doc)
        collect (format nil "~a ~d. ~a" (%step-mark (plan-step-status step))
                        (plan-step-index step) (plan-step-text step))))

;;; Plan versus diff.

(defun plan-versus-diff (doc changes)
  "→ ((path change planned) …) sorted by path."
  (let ((planned (plan-document-files doc))
        (rows '()))
    (dolist (c changes)
      (push (list (second c) (first c) (and (member (second c) planned :test #'string=) t)) rows))
    (dolist (path planned)
      (unless (find path rows :key #'first :test #'string=)
        (push (list path nil t) rows)))
    (sort rows #'string< :key #'first)))

(defun %change-letter (kind)
  (case kind (:added "A") (:removed "D") (:modified "M") (:mode-changed "T") (t " ")))

(defun plan-versus-diff-lines (doc changes)
  (let ((rows (plan-versus-diff doc changes))
        (steps (plan-document-steps doc)))
    (append
     (list (format nil "plan ~a r~d: ~d of ~d steps done" (subseq (plan-document-id doc) 0 8)
                   (plan-document-revision doc)
                   (count :done steps :key #'plan-step-status) (length steps)))
     (plan-steps-lines doc)
     (list (format nil "files: ~d planned, ~d changed"
                   (length (plan-document-files doc)) (length changes)))
     (loop for (path change planned) in rows
           collect (format nil "  ~a ~a  ~a" (%change-letter change) path
                           (cond ((and change planned) "planned")
                                 (change "not in the plan")
                                 (t "planned, unchanged")))))))

;;; Save to workspace.

(defun %plan-slug (doc)
  (let* ((title (string-downcase (or (plan-document-title doc) "")))
         (slug (with-output-to-string (s)
                 (let ((dash nil))
                   (loop for c across title
                         do (if (or (char<= #\a c #\z) (char<= #\0 c #\9))
                                (progn (when dash (write-char #\- s)) (setf dash nil)
                                  (write-char c s))
                                (setf dash t))))))
         (slug (string-left-trim "-" slug)))
    (when (> (length slug) 60)
      (setf slug (string-right-trim "-" (subseq slug 0 60))))
    (if (plusp (length slug))
        slug
        (format nil "plan-~a" (subseq (plan-document-id doc) 0 8)))))

(defun save-plan-to-workspace (doc &key directory)
  "→ the pathname written under the project (see the header). DIRECTORY: the
caller's planSaveDirectory (else +DEFAULT-PLAN-SAVE-DIRECTORY+)."
  (let* ((rel (or directory +default-plan-save-directory+))
         (dir (uiop:merge-pathnames* (uiop:parse-unix-namestring rel :ensure-directory t)
                                     (uiop:ensure-directory-pathname (plan-document-project-dir doc))))
         (date (multiple-value-bind (sec min hour day month year) (get-decoded-time)
                 (declare (ignore sec min hour))
                 (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))
         (base (format nil "~a-~a" date (%plan-slug doc)))
         (text (or (plan-document-markdown doc)
                   (error 'plan-document-state-error :document doc
                                                     :status (plan-document-status doc)
                                                     :message "no plan yet"))))
    (ensure-directories-exist dir)
    (loop for i from 1
          for name = (if (= i 1) (format nil "~a.md" base) (format nil "~a-~d.md" base i))
          for path = (uiop:merge-pathnames* name dir)
          unless (probe-file path)
            do (%write-utf-8 path text)
               (return path))))

;;; Objects and records.

(defun %status-name (keyword)
  (substitute #\_ #\- (string-downcase (string keyword))))

(defun %steps-json (doc)
  (map 'vector (lambda (s)
                 (%json-object "index" (plan-step-index s) "text" (plan-step-text s)
                               "status" (%status-name (plan-step-status s))))
       (plan-document-steps doc)))

(defun plan-document-object (doc)
  "→ the JSON object of DOC (stream-json, the result's \"plan\", SDK, RPC)."
  (%json-object "id" (plan-document-id doc)
                "revision" (plan-document-revision doc)
                "status" (%status-name (plan-document-status doc))
                "title" (or (plan-document-title doc) :null)
                "path" (uiop:native-namestring (plan-document-path doc))
                "template" (%status-name (plan-document-template doc))
                "mode" (if (plan-document-execution-mode doc)
                           (permission-mode-name (plan-document-execution-mode doc))
                           :null)
                "steps" (%steps-json doc)
                "files" (coerce (plan-document-files doc) 'vector)))

(defun plan-document-record (doc &key feedback)
  "→ (:id :revision :status :author :markdown :feedback) for a turn record."
  (let ((last (car (last (%doc-extra doc :revisions)))))
    (list :id (plan-document-id doc)
          :revision (plan-document-revision doc)
          :status (plan-document-status doc)
          :author (or (getf last :author) :model)
          :markdown (or (plan-document-markdown doc) "")
          :feedback (or feedback (getf last :feedback)))))

;;; The tools.

(defclass %code-plan-tools (plan-tools)
  ((feedback :initform nil :accessor %plan-tools-feedback
             :documentation "The run's prompt when it revises a proposed plan."))
  (:documentation "The PLAN-TOOLS MAKE-PLAN-TOOLS returns."))

(defparameter +propose-plan-parameters+
  "{\"type\":\"object\",\"properties\":{\"markdown\":{\"type\":\"string\",\"description\":\"The whole plan as markdown, in the template's form\"}},\"required\":[\"markdown\"]}")

(defparameter +ask-user-parameters+
  "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"},\"options\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Answers to offer (optional)\"}},\"required\":[\"question\"]}")

(defparameter +update-plan-parameters+
  "{\"type\":\"object\",\"properties\":{\"step\":{\"type\":\"integer\",\"description\":\"The step number, from 1\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"done\"]}},\"required\":[\"step\",\"status\"]}")

(defun %plan-tool-descriptors (source)
  (flet ((tool (name description parameters)
           (llm:make-llm-tool :name name :description description
                              :parameters (json:decode parameters))))
    (ecase (plan-tools-phase source)
      (:plan (list (tool "propose_plan"
                         "Propose the plan to the user as markdown (the template in the system prompt). The run ends here: the user reviews the plan."
                         +propose-plan-parameters+)
                   (tool "ask_user"
                         "Ask the user a question only they can answer; options are answers to offer."
                         +ask-user-parameters+)))
      (:execute (list (tool "update_plan"
                            "Mark a step of the approved plan: in_progress when you start it, done when it is finished."
                            +update-plan-parameters+))))))

(defun make-plan-tools (doc &key (phase :plan) ask)
  (check-type phase (member :plan :execute))
  (make-instance '%code-plan-tools :document doc :phase phase :ask ask))

(defun %plan-tool-args (arguments)
  (let ((table (typecase arguments
                 (string (handler-case (json:decode arguments)
                           (error () (%tool-input-fail "the arguments are not a JSON object"))))
                 (t arguments))))
    (unless (hash-table-p table)
      (%tool-input-fail "the arguments are not a JSON object"))
    table))

(defun %propose-plan-call (source arguments)
  (let* ((doc (plan-tools-document source))
         (markdown (gethash "markdown" (%plan-tool-args arguments))))
    (unless (stringp markdown)
      (%tool-input-fail "propose_plan needs markdown: the plan as a string"))
    (let ((n (propose-plan-revision doc markdown :feedback (%plan-tools-feedback source))))
      (agent:make-agent-tool-output
       :text (format nil "Plan ~a revision ~d saved to ~a. Stop here: the user reviews it now."
                     (subseq (plan-document-id doc) 0 8) n
                     (uiop:native-namestring (plan-document-path doc)))
       :end-run t))))

(defun %ask-user-call (source arguments)
  (let* ((args (%plan-tool-args arguments))
         (question (gethash "question" args))
         (options (gethash "options" args))
         (options (remove-if-not #'stringp
                                 (cond ((stringp options) '())
                                       ((listp options) options)
                                       ((vectorp options) (coerce options 'list))
                                       (t '())))))
    (unless (stringp question)
      (%tool-input-fail "ask_user needs question: a string"))
    (let* ((ask (plan-tools-ask source))
           (answer (and ask (funcall ask question options))))
      (if (and (stringp answer) (plusp (length answer)))
          (format nil "The user answered: ~a" answer)
          +ask-user-unavailable+))))

(defun %update-plan-call (source arguments)
  (let* ((doc (plan-tools-document source))
         (args (%plan-tool-args arguments))
         (step (gethash "step" args))
         (status (gethash "status" args))
         (keyword (cond ((equal status "pending") :pending)
                        ((equal status "in_progress") :in-progress)
                        ((equal status "done") :done))))
    (unless keyword
      (%tool-input-fail "update_plan: status must be pending, in_progress or done"))
    (set-plan-step doc step keyword)
    (format nil "~{~a~^~%~}" (plan-steps-lines doc))))

(defmethod agent:list-agent-tools ((source plan-tools) &key context)
  (declare (ignore context))
  (%plan-tool-descriptors source))

(defmethod agent:tool-executable-p ((source plan-tools) name &key context)
  (declare (ignore context))
  (and (find name (%plan-tool-descriptors source) :key #'llm:llm-tool-name :test #'equal) t))

(defmethod agent:tool-needs-approval-p ((source plan-tools) name arguments &key context)
  (declare (ignore name arguments context))
  nil)

(defmethod agent:invoke-tool-async ((source plan-tools) name arguments
                                    &key context callback error-callback)
  (let ((handler (and (agent:tool-executable-p source name)
                      (cond ((equal name "propose_plan") (lambda (a) (%propose-plan-call source a)))
                            ((equal name "ask_user") (lambda (a) (%ask-user-call source a)))
                            ((equal name "update_plan") (lambda (a) (%update-plan-call source a)))))))
    (if handler
        (agent:invoke-tool-async (agent:make-function-tool :name name :handler handler)
                                 name arguments
                                 :context context :callback callback :error-callback error-callback)
        (call-next-method))))

(defmethod agent:tool-failure-text ((condition plan-format-error) name)
  (let ((doc (plan-document-error-document condition)))
    (format nil "~a: the plan is missing ~{~a~^, ~}. Use this template:~%~a"
            name (plan-format-error-missing condition)
            (plan-template-text (if doc (plan-document-template doc) :default)))))

(defmethod agent:tool-failure-text ((condition plan-document-error) name)
  (format nil "~a: ~a" name condition))

;;; ------------------------------------------------------------------
;;; Host helpers shared by -p, the TUI and the SDK.

(defun %line-plan-doc-record (store &optional (designator +head-ref+))
  "The newest RECORD-PLAN-DOCUMENT on STORE's DESIGNATOR line, or NIL."
  (and store
       (find-if #'identity (reverse (mapcar #'record-plan-document
                                            (session-records store designator))))))

(defun %session-plan-doc (store project data-dir)
  "The plan document STORE's head line names last (reopened from disk), or
NIL when there is none or it is gone."
  (let ((record (%line-plan-doc-record store)))
    (and record
         (handler-case (reopen-plan-document (plan-documents-directory project :data-dir data-dir)
                                             (getf record :id))
           (plan-document-not-found () nil)))))

(defun %open-session-plan-doc (store project data-dir settings)
  "The session's open plan document (:DRAFTING or :PROPOSED), else a new one.
→ (values doc reopened-p)."
  (let ((doc (%session-plan-doc store project data-dir)))
    (if (and doc (member (plan-document-status doc) '(:drafting :proposed)))
        (values doc t)
        (values (open-plan-document project :data-dir data-dir
                                            :session-id (and store (session-id store))
                                            :template (or (settings-plan-template settings) :default))
                nil))))

(defun %plan-doc-exploration-area (doc open-area)
  "DOC's exploration area: reopened by its id, else (OPEN-AREA) → a new H5a
PLAN whose id DOC records. The model's scratch directory is created. → area."
  (let ((area (or (%doc-area doc)
                  (let ((new (funcall open-area)))
                    (setf (plan-document-area-id doc) (plan-id new))
                    (%write-plan-doc-meta doc)
                    new))))
    (ensure-directories-exist
     (uiop:merge-pathnames* (format nil "~a/" +plan-scratch-directory-name+) (plan-root area)))
    area))

(defun %plan-migration-notice-p (data-dir)
  "True the first time a plan run uses DATA-DIR (0.15.x): the marker
<data-dir>/notices/plan-mode-0.15 is written then."
  (let ((marker (uiop:merge-pathnames* "notices/plan-mode-0.15"
                                       (uiop:ensure-directory-pathname data-dir))))
    (unless (probe-file marker)
      (ensure-directories-exist marker)
      (multiple-value-bind (sec min hour day month year) (get-decoded-time)
        (declare (ignore sec min hour))
        (%write-utf-8 marker (format nil "~4,'0d-~2,'0d-~2,'0d~%" year month day)))
      t)))

(defun %plan-doc-step-plists (doc)
  (mapcar #'%step-plist (plan-document-steps doc)))

;;; Plan versus the diff of an execution in the project: a snapshot before and
;;; after the turn (pathlib, :ignore :auto), whatever the checkpoint settings.

(defun %execution-snapshot (project store)
  (p:fs-snapshot (%local-fs) (uiop:native-namestring (uiop:ensure-directory-pathname project))
                 :ignore :auto :store store))

(defun %execution-changes (store pre post)
  "→ (values changes diff-text) from snapshot PRE to POST in STORE."
  (let ((changes (mapcar (lambda (c) (list (p:fs-change-kind c) (p:fs-change-path c)))
                         (p:snapshot-changes pre post :store store))))
    (values changes
            (if changes
                (diff:render-diff (%compute-diff (%snapshot-view store pre)
                                                 (%snapshot-view store post)
                                                 changes)
                                  :unified nil)
                ""))))

(defun %plan-executed-keys (doc changes diff)
  "The \"executed\" event's keys and values after \"subtype\"."
  (list "plan_id" (plan-document-id doc)
        "status" (%status-name (plan-document-status doc))
        "steps" (%steps-json doc)
        "changes" (map 'vector (lambda (c)
                                 (%json-object "path" (second c)
                                               "kind" (%status-name (first c))))
                       changes)
        "rows" (map 'vector (lambda (row)
                              (destructuring-bind (path change planned) row
                                (%json-object "path" path
                                              "change" (if change (%status-name change) :null)
                                              "planned" (and planned t))))
                    (plan-versus-diff doc changes))
        "diff" diff))

;;; Conversation rewinds (H3c / H5b REWIND-TO, conversation part).

(defun %rewind-plan-document (store project data-dir)
  "After STORE's head moved: the plan document goes back to the latest
revision on the new head line (plan.md from revisions/N.md, :PROPOSED), or to
:DRAFTING when the line has none; an :EXECUTED document stays."
  (let* ((dir (plan-documents-directory project :data-dir data-dir))
         (docs (remove-if-not (lambda (d) (equal (plan-document-session-id d) (session-id store)))
                              (list-plan-documents dir)))
         (record (%line-plan-doc-record store)))
    (dolist (doc docs)
      (unless (eq :executed (plan-document-status doc))
        (let ((n (if (and record (equal (getf record :id) (plan-document-id doc)))
                     (getf record :revision)
                     0)))
          (cond ((and n (plusp n) (probe-file (%plan-doc-revision-file doc n)))
                 (let ((text (uiop:read-file-string (%plan-doc-revision-file doc n)
                                                    :external-format :utf-8)))
                   (%write-utf-8 (plan-document-path doc) text)
                   (%set-doc-content doc text)
                   (setf (plan-document-revision doc) n
                         (plan-document-status doc) :proposed)))
                (t
                 (when (probe-file (plan-document-path doc))
                   (delete-file (plan-document-path doc)))
                 (setf (plan-document-revision doc) 0
                       (plan-document-status doc) :drafting
                       (plan-document-title doc) nil
                       (plan-document-steps doc) '()
                       (plan-document-files doc) '())))
          (%write-plan-doc-meta doc))))))

;;; Given SDK spellings for the preview (H5a) functions.

(defun client-apply-preview (session &key (on-drift :abort))
  "The preview's apply (H5a's CLIENT-APPROVE-PLAN), the preferred name."
  (client-approve-plan session :on-drift on-drift))

(defun client-reject-preview (session)
  "The preview's reject (H5a's CLIENT-REJECT-PLAN), the preferred name."
  (client-reject-plan session))
