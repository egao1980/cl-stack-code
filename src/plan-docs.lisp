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

;;; Stubs. Every function below signals %H5C0-PENDING until implemented.

(defun open-plan-document (project-dir &key data-dir session-id id (template :default))
  (declare (ignore project-dir data-dir session-id id template))
  (%h5c0-pending 'open-plan-document))

(defun reopen-plan-document (directory id)
  (declare (ignore directory id))
  (%h5c0-pending 'reopen-plan-document))

(defun list-plan-documents (directory)
  (declare (ignore directory))
  (%h5c0-pending 'list-plan-documents))

(defun plan-document-markdown (doc)
  (declare (ignore doc))
  (%h5c0-pending 'plan-document-markdown))

(defun parse-plan-markdown (text &key (template :default))
  "→ (values title steps files), see the header."
  (declare (ignore text template))
  (%h5c0-pending 'parse-plan-markdown))

(defun plan-template-text (template)
  (declare (ignore template))
  (%h5c0-pending 'plan-template-text))

(defun propose-plan-revision (doc markdown &key (author :model) feedback)
  (declare (ignore doc markdown author feedback))
  (%h5c0-pending 'propose-plan-revision))

(defun sync-plan-document-edits (doc)
  (declare (ignore doc))
  (%h5c0-pending 'sync-plan-document-edits))

(defun plan-document-revisions (doc)
  (declare (ignore doc))
  (%h5c0-pending 'plan-document-revisions))

(defun approve-plan-document (doc &key (mode :accept-edits))
  (declare (ignore doc mode))
  (%h5c0-pending 'approve-plan-document))

(defun reject-plan-document (doc)
  (declare (ignore doc))
  (%h5c0-pending 'reject-plan-document))

(defun plan-execution-prompt (doc &optional extra)
  (declare (ignore doc extra))
  (%h5c0-pending 'plan-execution-prompt))

(defun set-plan-step (doc index status)
  (declare (ignore doc index status))
  (%h5c0-pending 'set-plan-step))

(defun finish-plan-execution (doc &key changes interrupted)
  (declare (ignore doc changes interrupted))
  (%h5c0-pending 'finish-plan-execution))

(defun plan-steps-lines (doc)
  (declare (ignore doc))
  (%h5c0-pending 'plan-steps-lines))

(defun plan-versus-diff (doc changes)
  (declare (ignore doc changes))
  (%h5c0-pending 'plan-versus-diff))

(defun plan-versus-diff-lines (doc changes)
  (declare (ignore doc changes))
  (%h5c0-pending 'plan-versus-diff-lines))

(defun save-plan-to-workspace (doc &key directory)
  (declare (ignore doc directory))
  (%h5c0-pending 'save-plan-to-workspace))

(defun plan-document-object (doc)
  (declare (ignore doc))
  (%h5c0-pending 'plan-document-object))

(defun plan-document-record (doc &key feedback)
  (declare (ignore doc feedback))
  (%h5c0-pending 'plan-document-record))

(defclass plan-tools ()
  ((document :initarg :document :reader plan-tools-document)
   (phase :initarg :phase :reader plan-tools-phase)
   (ask :initarg :ask :initform nil :reader plan-tools-ask))
  (:documentation "H5c-0: propose_plan / ask_user (phase :PLAN) or update_plan
(phase :EXECUTE). The implementation makes it an ai-agent-protocol tool
source (superclass and methods)."))

(defun plan-tools-p (x)
  (typep x 'plan-tools))

(defun make-plan-tools (doc &key (phase :plan) ask)
  (declare (ignore doc phase ask))
  (%h5c0-pending 'make-plan-tools))

(defun plan-mode-permission-policy (&key (policy 'plan-mode-tools))
  (declare (ignore policy))
  (%h5c0-pending 'plan-mode-permission-policy))

;;; Given SDK spellings for the preview (H5a) functions.

(defun client-apply-preview (session &key (on-drift :abort))
  "The preview's apply (H5a's CLIENT-APPROVE-PLAN), the preferred name."
  (client-approve-plan session :on-drift on-drift))

(defun client-reject-preview (session)
  "The preview's reject (H5a's CLIENT-REJECT-PLAN), the preferred name."
  (client-reject-plan session))
