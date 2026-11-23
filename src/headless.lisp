(in-package #:cl-stack-code)

;;; Headless runs: -p with text, json or stream-json output.
;;;
;;; H8d (left to the implementation): every run makes its supervisor
;;; (MAKE-CODE-SUPERVISOR on the working directory and the data directory)
;;; before the tools and passes it to MAKE-CODE-TOOLS, so the init event's
;;; "tools" end with the unit tools and bash commands are units; after the run
;;; (and when the setup fails) the unit tools, the shell tools and the
;;; supervisor are closed, in that order. The output is otherwise unchanged.
;;;
;;; H3c: every run is a turn of a session (src/sessions.lisp).
;;;   Before the run   CHECK-SESSION-FLAGS; then the session: --continue →
;;;                    LAST-SESSION of SESSIONS-DIRECTORY (none →
;;;                    SESSION-NOT-FOUND, exit 2); --resume ID → OPEN-SESSION
;;;                    (exit 2 when not found); otherwise CREATE-SESSION with
;;;                    --session-id (an existing id → CODE-USAGE-ERROR
;;;                    "session ID already exists: use --resume ID", exit 2)
;;;                    or a random id. --fork-session: CLONE-SESSION of the
;;;                    resumed session at its head, with --session-id when
;;;                    given; the run goes on in the clone.
;;;   Model            --model, else the resumed session's head record MODEL,
;;;                    else the settings files, else +DEFAULT-MODEL+. Nothing
;;;                    else is restored: rules, mode, env and max turns come
;;;                    from today's settings and flags.
;;;   The run          RUN-AI-AGENT on (SESSION-TURNS store) plus the prompt;
;;;                    every event's session_id is the store's id.
;;;   After the run    Once the run has started (its :started event), its
;;;                    turn is committed with COMMIT-TURN before the result is
;;;                    written: prompt, the run's turns past the ones it was
;;;                    given (without :system turns), finish (:stop,
;;;                    :max-steps, :canceled or :failed), the model
;;;                    designator, the mode and the summed usage. A
;;;                    SESSION-CONFLICT takes FORK-SESSION: error-output gets
;;;                    "cl-stack-code: session OLD changed in another process;
;;;                    this turn was saved as session NEW" and the result's
;;;                    session_id is NEW (the exit code is the run's).
;;;   --list-sessions  Without -p or a prompt: SESSION-SUMMARY-LINES, one per
;;;                    line on output, exit 0 (nothing when there are none).
;;;   Data directory   RUN-CLI :DATA-DIR, else USER-DATA-DIRECTORY with
;;;                    RUN-CLI's GETENV.
;;;
;;; H5a: plan mode (src/plans.lisp).
;;;   Which runs       The effective mode is :PLAN (flag or settings), or a
;;;                    plan flag is given: CHECK-PLAN-FLAGS first (exit 2 on
;;;                    a bad combination), before anything is written.
;;;   The plan         A resumed session whose head record has a PLAN with
;;;                    status :OPEN → REOPEN-PLAN of its id (subtype
;;;                    "reopened"). If it cannot be reopened (PLAN-NOT-FOUND),
;;;                    or there is none, OPEN-PLAN on the project directory
;;;                    (project root, else cwd) with :KIND from --plan-area
;;;                    (default :AUTO), :DATA-DIR and the session's id
;;;                    (subtype "opened"); a reopen that failed also writes
;;;                    "cl-stack-code: plan OLD is no longer open; opened plan
;;;                    NEW" to error-output. --plan-area git where the
;;;                    project is not a git worktree → CODE-USAGE-ERROR
;;;                    "--plan-area git: DIR is not a git worktree" (exit 2).
;;;   The run          Tools rooted at PLAN-TOOL-ROOT; ASSEMBLE-SYSTEM-PROMPT
;;;                    with :PLAN. Plan mode's base rules allow write, edit
;;;                    and multi_edit (they are jailed to the area), and since
;;;                    0.4.1 bash and job_input: the shell runs in the area
;;;                    without asking. Since 0.10.0 (R4d-4b) it is confined
;;;                    to the area (Seatbelt / Landlock; network off unless
;;;                    --allow-network or sandbox.network "allow"); when no
;;;                    sandbox can be used, bash and job_input ask before
;;;                    each call instead, after a stderr notice
;;;                    (src/sandbox.lisp has the rules). An ask rule still
;;;                    asks (-p refuses it); a deny wins.
;;;   stream-json      After "system" init: {"type":"plan","subtype":
;;;                    "opened"|"reopened","plan_id","kind" ("copy"|"git"),
;;;                    "area" (native namestring of PLAN-ROOT),"base"}. After
;;;                    the run, before "result": {"type":"plan","subtype":
;;;                    "projected","plan_id","changes":[{"path","kind"}],
;;;                    "diff"} (kind "added" "removed" "modified"
;;;                    "mode_changed"; diff = PLAN-DIFF-TEXT). With --apply,
;;;                    then one of {"subtype":"applied","plan_id","changes"},
;;;                    {"subtype":"rebased","plan_id","conflicts":[paths]},
;;;                    {"subtype":"drift","plan_id","paths":[paths]} (abort).
;;;   result           In plan runs only, "plan": {"id","kind","status"
;;;                    ("open" "applied" "rebased" "discarded"),"area",
;;;                    "base" (after a rebase: the new base),"changes" (as
;;;                    projected),"diff","conflicts" (rebase; else [])}.
;;;   text             The answer, then, when the projection has changes, one
;;;                    empty line and PLAN-DIFF-TEXT. error-output gets one
;;;                    line: "cl-stack-code: plan ID: N file[s] changed, not
;;;                    applied (cl-stack-code -p --resume SESSION --apply
;;;                    applies it)", "cl-stack-code: plan ID: no changes", or
;;;                    with --apply "cl-stack-code: plan ID: applied N
;;;                    file[s]" / the rebase line "cl-stack-code: plan ID:
;;;                    rebased onto the working copy (conflicts in P, Q);
;;;                    review it and --apply again" ("(no conflicts)" when
;;;                    there are none).
;;;   --apply          Only after a run whose subtype is "success": APPROVE-
;;;                    PLAN, PLAN-DRIFT answered per --on-drift (abort, the
;;;                    default → ABORT-APPROVAL; rebase → REBASE-PLAN;
;;;                    overwrite → OVERWRITE-PLAN). Anything but :APPLIED /
;;;                    :EMPTY fails the run (exit 1, subtype
;;;                    "error_during_execution"): abort with a message naming
;;;                    the paths and "--on-drift rebase or --on-drift
;;;                    overwrite"; rebase with the rebase line above. A failed
;;;                    or max-turns run applies nothing.
;;;   Action only      --apply or --reject with --resume / --continue and no
;;;                    prompt arguments: no run, no LLM call, INPUT not read,
;;;                    no turn committed. The head record's open plan (none,
;;;                    or not open → CODE-USAGE-ERROR "session ID has no open
;;;                    plan", exit 2) is approved (as --apply above; text mode
;;;                    prints the applied PLAN-DIFF-TEXT on output) or
;;;                    rejected ("cl-stack-code: plan ID: discarded" on
;;;                    error-output, nothing on output). json / stream-json:
;;;                    the plan event of the action, then a "result" with
;;;                    num_turns 0, "result" "", and "plan".
;;;   Turn record      PLAN-RECORD of the plan after --apply, so a later
;;;                    resume does not reopen an applied plan.
;;;
;;; H5b: checkpoints and rewind (src/checkpoints.lisp).
;;;   Checkpointer     Every run makes one (MAKE-CHECKPOINTER on the project
;;;                    directory with CHECKPOINT-SETTINGS and the data
;;;                    directory) after the session is resolved and before
;;;                    anything is written to OUTPUT; an explicit
;;;                    checkpoints.kind that does not fit → CHECKPOINT-ERROR,
;;;                    exit 1. CLOSE-CHECKPOINTER when the run ends.
;;;   Turns            BEGIN-CHECKPOINT-TURN before the run (after the plan
;;;                    is opened in plan mode), END-CHECKPOINT-TURN right
;;;                    after %COMMIT-HEADLESS-TURN with the committed revision
;;;                    and the store it went to. Nothing in the output
;;;                    changes.
;;;   --apply          APPROVE-PLAN :CHECKPOINTER, then RECORD-PLAN-CHECKPOINTS
;;;                    with the turn the plan belongs to: after a run, the
;;;                    revision %COMMIT-HEADLESS-TURN committed (before
;;;                    END-CHECKPOINT-TURN); action only, the head
;;;                    (src/checkpoints.lisp, "Plan mode").
;;;   --list-checkpoints  With --resume / --continue, with or without -p:
;;;                    CHECK-REWIND-FLAGS, then CHECKPOINT-SUMMARY-LINES of
;;;                    the session, one per line on output, exit 0 (one line
;;;                    "no checkpoints yet" when there are none).
;;;   --rewind TURN    Action only, after CHECK-SESSION-FLAGS: CHECK-REWIND-
;;;                    FLAGS (exit 2), the session (--resume / --continue),
;;;                    then REWIND-TO TURN with PARTS from --rewind-mode
;;;                    (both, the default → (:conversation :files);
;;;                    conversation; files). No run, no LLM call, INPUT not
;;;                    read, no turn committed. PLAN-DRIFT is answered per
;;;                    --on-drift: abort (default) → ABORT-APPROVAL, rebase →
;;;                    REBASE-PLAN, overwrite → OVERWRITE-PLAN.
;;;     text           OUTPUT: the unified diff of what was written (the
;;;                    rewind plan's PLAN-DIFF-TEXT before approval; after a
;;;                    rebase, the merged one); nothing for a conversation-
;;;                    only or empty rewind. ERROR-OUTPUT: "cl-stack-code:
;;;                    session S rewound to turn T: <REWIND-DESCRIPTION>".
;;;     stream-json    {"type":"rewind","session_id",<the rewind object>}
;;;                    then the "result"; json: only the "result". The result
;;;                    has num_turns 0, "result" "", and "rewind": the rewind
;;;                    object {"turn": T, "parts": ["conversation","files"],
;;;                    "conversation": "moved"|"unchanged"|"skipped",
;;;                    "files": "applied"|"merged"|"empty"|"aborted"|"skipped",
;;;                    "changes": [{"path","kind"}], "conflicts": [paths],
;;;                    "drift": [paths], "checkpoint": id or null}.
;;;     drift, abort   Exit 1, result subtype "error_during_execution",
;;;                    ERROR-OUTPUT "cl-stack-code: rewind to turn T: the
;;;                    working copy changed at P, Q; nothing restored (use
;;;                    --on-drift rebase or --on-drift overwrite)". Nothing
;;;                    written, the head not moved.
;;;     errors         No files state for TURN with files asked for →
;;;                    CHECKPOINT-NOT-FOUND ("session S has no checkpoint for
;;;                    turn T", exit 2); an expired one → CHECKPOINT-EXPIRED
;;;                    (exit 1); an unknown TURN → SESSION-TURN-NOT-FOUND
;;;                    (exit 1); nothing is written to OUTPUT before them.


;;; Outcomes of a run that started, as conditions. RUN-CLI handles them like
;;; every other error: the message goes to ERROR-OUTPUT, the exit code comes
;;; from CONDITION-EXIT-CODE.

(define-condition %run-interrupted (run-failed) ()
  (:documentation "SIGINT canceled the run (CANCEL-AGENT-RUN). Exit 130.")
  (:default-initargs :message "interrupted"))

(defmethod condition-exit-code ((condition %run-interrupted)) 130)

;;; JSON output (%JSON-OBJECT, %USAGE-OBJECT and %SESSION-ID are in
;;; sessions.lisp, which the views share).

(defun %usage-counts (usage)
  "(input output cache-read cache-write) of an LLM-USAGE (or NIL); a missing
count is 0."
  (if usage
      (list (or (llm:llm-usage-input-tokens usage) 0)
            (or (llm:llm-usage-output-tokens usage) 0)
            (or (llm:llm-usage-cache-read-tokens usage) 0)
            (or (llm:llm-usage-cache-write-tokens usage) 0))
      (list 0 0 0 0)))

(defun %finish-reason-name (reason)
  ":TOOL-USE → \"tool_use\"; NIL → \"stop\"."
  (substitute #\_ #\- (string-downcase (string (or reason :stop)))))

(defun %tool-input (arguments)
  "ARGUMENTS decoded as a JSON object, or the raw string when they are not one."
  (cond ((hash-table-p arguments) arguments)
        ((stringp arguments)
         (let ((value (handler-case (json:decode arguments)
                        (error () nil))))
           (if (hash-table-p value) value arguments)))
        ((null arguments) :null)
        (t (princ-to-string arguments))))

(defun %trim-answer (text)
  (string-right-trim '(#\Newline #\Return) (or text "")))

;;; The report: what one run has said so far, and where it says it.

(defstruct (%report (:conc-name %report-))
  (format :text)
  (output *standard-output*)
  (session (%session-id))
  (run nil)                                   ; the AGENT-RUN, from :started
  (step 0)
  (turns 0)                                   ; :response events
  (usage (list 0 0 0 0))
  (denials '())                               ; newest first
  (seen (make-hash-table :test #'equal))      ; ids with a tool_result
  (call-steps (make-hash-table :test #'equal))
  (failure nil)                               ; first error inside the sink
  ;; H5a
  (plan nil)                                  ; the result's "plan" object, or NIL
  (plan-text nil)                             ; text mode: the diff after the answer
  (plan-failure nil)                          ; a condition that fails a finished run
  ;; H5b
  (plan-pre nil)                              ; --apply: APPROVE-PLAN's PRE, recorded after the commit
  (rewind nil)                                ; the result's "rewind" object, or NIL
  ;; H4b
  (image-tools nil)                           ; the LISP-TOOLS, or NIL
  ;; H3e-1
  (instruction-set nil)                       ; the session's INSTRUCTION-SET, or NIL
  ;; H3e-2a
  (mcp nil)                                   ; the session's MCP-MANAGER, or NIL
  ;; H3d: one emitter, a sink per destination.
  (sink nil)                                  ; NIL: -p (stream-json lines); else (lambda (object))
  (denial-reason #'%headless-denial-reason))  ; decision → the denial's "reason"

(defun %headless-denial-reason (decision)
  "-p: the headless refusal of an ask is \"headless\", a rule or policy
\"denied\"."
  (if (member decision '(:unattended :rejected)) "headless" "denied"))

(defun %write-json-line (report object)
  (let ((out (%report-output report)))
    (json:encode object :stream out)
    (terpri out)
    (force-output out)))

(defun %emit-event (report type &rest keys-and-values)
  "Build one event object and hand it to the report's sink: -p writes it as a
stream-json line (only in stream-json); the SDK's sink delivers it to the
session's callbacks (src/client.lisp). → the object, or NIL when -p does not
write it."
  (let ((sink (%report-sink report)))
    (when (or sink (eq (%report-format report) :stream-json))
      (let ((object (apply #'%json-object "type" type
                           "session_id" (%report-session report)
                           keys-and-values)))
        (if sink
            (funcall sink object)
            (%write-json-line report object))
        object))))

(defun %step-tool-calls (report response)
  "Tool-call parts of the assistant turn RESPONSE committed (the run coalesced
streamed parts by then), else of RESPONSE itself."
  (let* ((run (%report-run report))
         (turn (and run (find :assistant (agent:agent-run-turns run)
                              :key #'llm:llm-turn-role :from-end t)))
         (parts (if turn (llm:llm-turn-parts turn) (llm:llm-response-parts response))))
    (remove-if-not #'llm:llm-tool-call-part-p parts)))

(defun %on-response (report response)
  (let ((counts (%usage-counts (llm:llm-response-usage response)))
        (step (%report-step report)))
    (incf (%report-turns report))
    (setf (%report-usage report) (mapcar #'+ (%report-usage report) counts))
    (%emit-event report "assistant"
                 "step" step
                 "text" (or (llm:llm-response-text response) "")
                 "finish_reason" (%finish-reason-name (llm:llm-response-finish-reason response))
                 "usage" (%usage-object counts))
    (dolist (call (%step-tool-calls report response))
      (let ((id (llm:llm-tool-call-part-id call)))
        (setf (gethash id (%report-call-steps report)) step)
        (%emit-event report "tool_use"
                     "step" step
                     "id" id
                     "name" (llm:llm-tool-call-part-name call)
                     "input" (%tool-input (llm:llm-tool-call-part-arguments call)))))))

(defun %on-permission (report payload)
  "A refused call (payload with a :CONDITION) goes on the denial list:
decision :UNATTENDED is the headless refusal of an ask (:REJECTED before
ai-agent-protocol 0.13), :DENY a rule or policy (or a tool's own refusal)."
  (let ((condition (getf payload :condition))
        (inv (getf payload :invocation)))
    (when (and condition inv)
      (%push-denial report inv (funcall (%report-denial-reason report)
                                        (agent:tool-permission-denied-decision condition))))))

(defun %push-denial (report inv reason)
  "Put INV on the report's permission_denials with REASON."
  (push (%json-object "id" (agent:agent-invocation-id inv)
                      "name" (agent:agent-invocation-name inv)
                      "input" (%tool-input (agent:agent-invocation-arguments inv))
                      "reason" reason)
        (%report-denials report)))

(defun %on-invocation (report inv)
  (let ((status (agent:agent-invocation-status inv))
        (id (agent:agent-invocation-id inv)))
    (when (and (member status '(:done :error :denied))
               (not (gethash id (%report-seen report))))
      (setf (gethash id (%report-seen report)) t)
      (apply #'%emit-event report "tool_result"
                   "step" (gethash id (%report-call-steps report) (%report-step report))
                   "id" id
                   "name" (agent:agent-invocation-name inv)
                   "status" (string-downcase (string status))
                   "is_error" (and (agent:agent-invocation-error-p inv) t)
                   "content" (let ((result (agent:agent-invocation-result inv)))
                               (cond ((null result) "")
                                     ((stringp result) result)
                                     (t (princ-to-string result))))
                   ;; H3e-2a: rich tool output (MCP), only when there is any.
                   (%invocation-output-keys inv)))))

(defun %invocation-output-keys (inv)
  "H3e-2a: \"images\" [{media_type, data}] and \"structured\" of INV's rich
output, each only when present."
  (let ((images (remove-if-not #'llm:llm-image-part-p (agent:agent-invocation-parts inv)))
        (structured (agent:agent-invocation-structured inv)))
    (append (and images
                 (list "images"
                       (map 'vector (lambda (part)
                                      (%json-object "media_type" (llm:llm-image-part-media-type part)
                                                    "data" (llm:llm-image-part-data part)))
                            images)))
            (and structured (list "structured" structured)))))

(defun %on-agent-event (report kind payload)
  "The run's :ON-EVENT. It runs inside event-loop callbacks, where an ERROR
would only become a warning, so it never signals: the first error is kept,
the run is canceled and the error fails the run afterwards."
  (handler-case
      (case kind
        (:started (setf (%report-run report) payload)
         ;; H4b: events queued before the run reach its first step.
         (%post-if-going (%report-image-tools report) payload))
        (:step (setf (%report-step report) payload)
         ;; H3e-2a: before the model call (the set's thread).
         (%mcp-before-model-call (%report-mcp report)))
        (:part (cond ((and (llm:llm-text-part-p payload)
                           (plusp (length (llm:llm-text-part-text payload))))
                      (%emit-event report "text_delta"
                                   "step" (%report-step report)
                                   "text" (llm:llm-text-part-text payload)))
                     ;; ACP-2: streamed thinking, the same shape.
                     ((and (llm:llm-thinking-part-p payload)
                           (stringp (llm:llm-thinking-part-text payload))
                           (plusp (length (llm:llm-thinking-part-text payload))))
                      (%emit-event report "thinking_delta"
                                   "step" (%report-step report)
                                   "text" (llm:llm-thinking-part-text payload)))))
        (:response (%on-response report payload))
        (:permission (%on-permission report payload))
        (:invocation (%on-invocation report payload))
        ;; H3e-1
        (:instructions (%on-instructions report payload)))
    (error (e)
      (unless (%report-failure report)
        (setf (%report-failure report) e))
      (let ((run (%report-run report)))
        (when run (agent:cancel-agent-run run))))))

(defun %directive-file-object (directive)
  (let ((path (steer:steer-directive-path directive)))
    (%json-object "path" (uiop:native-namestring (or (ignore-errors (probe-file path)) path))
                  "kind" (if (getf (steer:steer-directive-extra directive) :rule) "rule" "agents"))))

(defun %on-instructions (report directives)
  "H3e-1: the run injected DIRECTIVES (nested AGENTS.md, path-scoped rules)."
  (let ((set (%report-instruction-set report)))
    (%emit-event report "instructions"
                 "files" (map 'vector #'%directive-file-object directives)
                 "instruction_set" (or (and set (instruction-set-current set)) :null))))

(defun %result-object (report subtype text error-message duration-ms)
  (apply #'%json-object "type" "result"
                "subtype" subtype
                "is_error" (not (string= subtype "success"))
                "result" text
                "error" (or error-message :null)
                "num_turns" (%report-turns report)
                "duration_ms" duration-ms
                "usage" (%usage-object (%report-usage report))
                "permission_denials" (coerce (reverse (%report-denials report)) 'vector)
                "session_id" (%report-session report)
                ;; H5a: only in plan mode, so the other shapes are unchanged.
                (append
                 (if (%report-plan report)
                     (list "plan" (%report-plan report))
                     '())
                 ;; H5b: only in rewind actions.
                 (if (%report-rewind report)
                     (list "rewind" (%report-rewind report))
                     '()))))

;;; Working directory, environment, HTTP.

(defun %resolve-cwd (given)
  "The truename of the working directory: --cwd GIVEN (relative to the process
directory), else the process directory. Not a directory → CODE-USAGE-ERROR."
  (if (null given)
      (truename (uiop:getcwd))
      (let* ((path (and (plusp (length given))
                        (uiop:parse-native-namestring given :ensure-directory t)))
             (dir (and path (uiop:directory-exists-p
                             (uiop:merge-pathnames* path (uiop:getcwd))))))
        (or dir
            (error 'code-usage-error
                   :message (format nil "--cwd ~a is not a directory" given))))))

(defun %env-lookup (settings getenv)
  "Merged settings env first (an unset key → NIL), then GETENV. The process
environment is never modified."
  (let ((env (settings-env settings)))
    (lambda (name)
      (let ((entry (assoc name env :test #'string=)))
        (if entry (cdr entry) (funcall getenv name))))))

;;; H3c: the session of a run (shared with MAKE-CODE-PROGRAM).

(defun %sessions-dir (cwd data-dir getenv)
  (sessions-directory cwd :data-dir (or data-dir (user-data-directory :getenv getenv))))

(defun %session-source (inv sessions-dir)
  "→ the session INV resumes (--continue or --resume), or NIL. A missing one
→ SESSION-NOT-FOUND; a --session-id that names an existing session →
CODE-USAGE-ERROR."
  (check-session-flags inv)
  (let ((new-id (and (invocation-session-id inv)
                     (normalize-session-id (invocation-session-id inv)))))
    (when (and new-id (%session-exists-p sessions-dir new-id))
      (error 'code-usage-error
             :message (format nil "session ~a already exists: use --resume ~a" new-id new-id)))
    (cond ((invocation-continue-p inv)
           (or (last-session sessions-dir)
               (error 'session-not-found)))
          ((invocation-resume inv)
           (open-session sessions-dir (invocation-resume inv)))
          (t nil))))

(defun %session-model (inv source settings)
  "The model designator: --model, else SOURCE's head record model, else the
settings files, else +DEFAULT-MODEL+."
  (or (settings-model (invocation-settings inv))
      (let ((head (and source (session-head source))))
        (and head (record-model (revision-record head))))
      (settings-model settings)
      +default-model+))

(defun %session-for-run (inv source sessions-dir project-dir)
  "→ the store the run's turns go to: a clone of SOURCE (--fork-session),
SOURCE, or a new session (--session-id or a random id)."
  (cond ((and source (invocation-fork-session-p inv))
         (clone-session source :id (invocation-session-id inv)))
        (source source)
        (t (create-session sessions-dir :id (invocation-session-id inv)
                                        :project-dir project-dir))))

(defun %commit-forking (store record)
  "COMMIT-TURN RECORD on STORE; a SESSION-CONFLICT takes FORK-SESSION. →
(values revision store-it-went-to)."
  (handler-bind ((session-conflict
                   (lambda (c)
                     (let ((restart (find-restart 'fork-session c)))
                       (when restart (invoke-restart restart))))))
    (commit-turn store record)))

(defun %run-finish (run failure interrupted)
  "The turn record FINISH of a run that started."
  (let ((reason (and run (agent:agent-run-finish-reason run))))
    (cond (failure :failed)
          ((or interrupted (eq reason :canceled)) :canceled)
          ((eq reason :max-steps) :max-steps)
          ((member reason '(:approval :deferred)) :failed)
          (t :stop))))

(defun %new-turns (run history)
  "RUN's turns past HISTORY (compared by identity), without :system turns."
  (remove-if (lambda (turn)
               (or (eq :system (llm:llm-turn-role turn))
                   (member turn history :test #'eq)))
             (agent:agent-run-turns run)))

;;; The run.

(defun %agent-settings (cwd settings &key discovery)
  "The agent's settings. H3e-1: the instructions discovery is DISCOVERY (the
session's CODE-INSTRUCTION-DISCOVERY), else a new one for CWD with no rules."
  (agent:make-agent-settings
   :llm (model-params-llm-settings settings)
   :max-steps (or (settings-max-turns settings) +default-max-turns+)
   :extra (list :permission-policy (code-permission-policy settings)
                :max-steps-wrap-up nil
                :instructions-discovery
                (or discovery (make-code-instruction-discovery cwd)))))

(defun %agent-permissions (settings &key (plan-shell-allowed t))
  "The agent's rule list. The lowest rule makes a shell command's program:
resources neutral for allows, so bash(SPEC) decides a simple command whose
words match it (as in Claude Code); with no bash rule the call still asks,
and every settings or flag rule comes later and wins. R4d-4b:
PLAN-SHELL-ALLOWED goes to SETTINGS-PERMISSION-RULES."
  (cons (agent:make-permission-rule "bash" "program:*" :allow)
        (settings-permission-rules settings :plan-shell-allowed plan-shell-allowed)))

(defun %plan-permissions (settings sandbox)
  "R4d-4b: plan mode's rule list for SANDBOX (a PLAN-SANDBOX). The plan base
rules keep bash and job_input allowed only while SANDBOX is :CONFINED; else
they ask. After a refusal with sandbox.failIfUnavailable, bash and job_input
are denied (the last rules, so they win) with the refusal text as feedback."
  (append (%agent-permissions settings :plan-shell-allowed (plan-sandbox-confined-p sandbox))
          (and (eq :refused (plan-sandbox-status sandbox))
               (nth-value 2 (sandbox-settings settings))
               (mapcar (lambda (name)
                         (agent:make-permission-rule
                          name "*" :deny
                          :feedback (plan-sandbox-refusal-result sandbox name)))
                       +shell-tool-names+))))

(defun %drive (agent prompt report mode &key sandbox error-output)
  "Run AGENT on PROMPT on the bound loop. Approvals are answered headless.
R4d-4b: with a plan SANDBOX, a confined bash the backend refuses becomes
PLAN-SANDBOX-REFUSAL-RESULT, the notice going once to ERROR-OUTPUT.
→ (values run failure interrupted-p)."
  (let ((interrupted nil))
    (handler-bind ((agent:agent-tool-error
                     (%plan-sandbox-refusal-handler
                      (lambda (c) (declare (ignore c)) sandbox)
                      (lambda (notice) (%plan-stderr-line error-output "~a" notice))))
                   (agent:agent-approval-required
                     (lambda (c)
                       (if (eq mode :bypass-permissions)
                           (agent:invoke-approve c)
                           (agent:invoke-deny c +headless-denial-feedback+
                                              :by :unattended))))
                   #+sbcl
                   (sb-sys:interactive-interrupt
                     (lambda (c)
                       (setf interrupted t)
                       (let ((run (%report-run report)))
                         (when run (agent:cancel-agent-run run)))
                       (continue c))))
      (handler-case
          (values (agent:run-ai-agent agent prompt
                                      :on-event (lambda (kind payload)
                                                  (%on-agent-event report kind payload)))
                  nil
                  interrupted)
        (error (e) (values nil e interrupted))))))

(defun %outcome (run failure interrupted max-turns)
  "→ (values subtype condition) for a finished or failed run; CONDITION is NIL
on success."
  (let ((reason (and run (agent:agent-run-finish-reason run))))
    (cond (failure
           (values "error_during_execution" (make-condition 'run-failed :cause failure)))
          ((or interrupted (eq reason :canceled))
           (values "error_during_execution" (make-condition '%run-interrupted)))
          ((eq reason :max-steps)
           (values "error_max_turns"
                   (make-condition 'run-failed
                                   :message (format nil "reached max turns (~d)" max-turns))))
          ((member reason '(:approval :deferred))
           (values "error_during_execution"
                   (make-condition 'run-failed
                                   :message "the run paused for an answer headless mode cannot give")))
          (t (values "success" nil)))))

(defun %report-run-end (report run failure interrupted max-turns start)
  "Write the run's result to the report's output; signal the failure, if any."
  (multiple-value-bind (subtype condition)
      (%outcome run (or (%report-failure report) failure) interrupted max-turns)
    ;; H5a: a plan step that failed after a good run (--apply on drift) fails it.
    (when (and (null condition) (%report-plan-failure report))
      (setf subtype "error_during_execution"
            condition (%report-plan-failure report)))
    (let ((text (if (and run (not failure) (not (%report-failure report)))
                    (%trim-answer (agent:agent-run-text run))
                    ""))
          (duration (round (* 1000 (- (get-internal-real-time) start))
                           internal-time-units-per-second)))
      (case (%report-format report)
        (:text
         (unless condition
           (let ((out (%report-output report)))
             (write-string text out)
             (terpri out)
             ;; H5a: the projected diff, after one empty line.
             (let ((diff (%report-plan-text report)))
               (when (plusp (length diff))
                 (terpri out)
                 (write-string diff out)))
             (force-output out))))
        (t
         (%write-json-line report
                           (%result-object report subtype text
                                           (and condition (princ-to-string condition))
                                           duration))))
      (when condition
        (error condition))
      0)))

(defun %read-prompt (inv input)
  (let ((prompt (or (invocation-prompt inv)
                    (%trim-answer (uiop:slurp-stream-string input)))))
    (when (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return #\Page))) prompt)
      (error 'code-usage-error
             :message "no prompt: give it as arguments or on standard input"))
    prompt))

(defun %commit-headless-turn (report store prompt history failure interrupted
                              designator mode error-output &optional plan)
  "Commit the turn of the run REPORT saw start, before its result is written.
A conflict forks the turn into a new session: one stderr line, and the
report's session id becomes the new one. → (values revision store-it-went-to),
or NIL when no run started."
  (let ((run (%report-run report)))
    (when run
      (let ((record (make-turn-record :prompt prompt
                                      :turns (%new-turns run history)
                                      :finish (%run-finish run (or (%report-failure report) failure)
                                                           interrupted)
                                      :model designator
                                      :permission-mode mode
                                      :usage (copy-list (%report-usage report))
                                      :plan (and plan (plan-record plan))
                                      ;; H3e-1
                                      :instructions (let ((set (%report-instruction-set report)))
                                                      (and set (instruction-set-current set))))))
        (multiple-value-bind (revision went-to) (%commit-forking store record)
          (unless (eq went-to store)
            (format error-output "cl-stack-code: session ~a changed in another process; this turn was saved as session ~a~%"
                    (session-id store) (session-id went-to))
            (force-output error-output)
            (setf (%report-session report) (session-id went-to)))
          ;; H5b: the checkpoints go to the store the turn went to.
          (values revision went-to))))))

;;; H5a: plan mode in -p (see the "H5a" part of the file header).

(defun %plan-action-only-p (inv)
  "--apply or --reject with --resume / --continue and no prompt arguments:
act on the session's open plan, no run, INPUT not read."
  (and (or (invocation-apply-p inv) (invocation-reject-p inv))
       (null (invocation-prompt inv))
       (or (invocation-continue-p inv) (invocation-resume inv))
       t))

(defun %plan-run-p (inv mode)
  "True when the run is a plan run (MODE :PLAN) or a plan flag was given
(CHECK-PLAN-FLAGS then refuses the combination)."
  (and (or (eq mode :plan)
           (invocation-apply-p inv) (invocation-reject-p inv)
           (invocation-on-drift inv) (invocation-plan-area inv)
           ;; R4d-4b: CHECK-PLAN-FLAGS refuses it outside plan mode.
           (invocation-allow-network-p inv))
       t))

(defun %plans-dir (cwd data-dir getenv)
  (plans-directory cwd :data-dir (or data-dir (user-data-directory :getenv getenv))))

(defun %head-plan-entry (source)
  "The PLAN of SOURCE's head record (a plist), or NIL."
  (let ((head (and source (session-head source))))
    (and head (record-plan (revision-record head)))))

(defun %change-kind-name (kind)
  (substitute #\_ #\- (string-downcase (string kind))))

(defun %changes-json (changes)
  (map 'vector (lambda (c)
                 (%json-object "path" (second c) "kind" (%change-kind-name (first c))))
       changes))

(defun %plan-object (plan status changes diff conflicts)
  "The result's \"plan\" object."
  (%json-object "id" (plan-id plan)
                "kind" (string-downcase (string (plan-kind plan)))
                "status" (string-downcase (string status))
                "area" (uiop:native-namestring (plan-root plan))
                "base" (plan-base plan)
                "changes" (%changes-json changes)
                "diff" diff
                "conflicts" (coerce conflicts 'vector)))

(defun %files-count (n)
  (format nil "~d file~:p" n))

(defun %rebase-line (plan conflicts)
  (format nil "plan ~a: rebased onto the working copy (~:[no conflicts~;conflicts in ~:*~{~a~^, ~}~]); review it and --apply again"
          (plan-id plan) conflicts))

(defun %headless-approve (report plan inv &optional checkpointer)
  "--apply: APPROVE-PLAN with PLAN-DRIFT answered per --on-drift; the
applied / rebased / drift event; a failure for the report unless the plan
was applied. H5b: with CHECKPOINTER, APPROVE-PLAN :CHECKPOINTER, its PRE kept
in the report for RECORD-PLAN-CHECKPOINTS. → (values status result)."
  (let ((on-drift (or (invocation-on-drift inv) :abort))
        (drift '()))
    (multiple-value-bind (result status pre)
        (handler-bind ((plan-drift
                         (lambda (c)
                           (setf drift (plan-drift-paths c))
                           (invoke-restart
                            (find-restart (ecase on-drift
                                            (:rebase 'rebase-plan)
                                            (:overwrite 'overwrite-plan)
                                            (:abort 'abort-approval))
                                          c)))))
          (approve-plan plan :checkpointer checkpointer))
      (setf (%report-plan-pre report) pre)
      (let ((event nil))
        (ecase status
          ((:applied :empty)
           (setf event
                 (%emit-event report "plan" "subtype" "applied" "plan_id" (plan-id plan)
                                            "changes" (%changes-json result))))
          (:rebased
           (setf event
                 (%emit-event report "plan" "subtype" "rebased" "plan_id" (plan-id plan)
                                            "conflicts" (coerce result 'vector)))
           (setf (%report-plan-failure report)
                 (make-condition 'plan-error :plan plan :message (%rebase-line plan result))))
          (:aborted
           (setf event
                 (%emit-event report "plan" "subtype" "drift" "plan_id" (plan-id plan)
                                            "paths" (coerce drift 'vector)))
           (setf (%report-plan-failure report)
                 (make-condition 'plan-drift
                                 :plan plan :paths drift
                                 :message (format nil "plan ~a: the working copy changed at ~{~a~^, ~}; nothing applied (use --on-drift rebase or --on-drift overwrite)"
                                                  (plan-id plan) drift)))))
        ;; H3d: the event object too (the SDK returns it).
        (values status result event)))))

(defun %plan-stderr-line (error-output control &rest args)
  (format error-output "cl-stack-code: ~?~%" control args)
  (force-output error-output))

(defun %headless-plan (inv mode cwd store source sessions-dir data-dir getenv error-output)
  "Before a plan run: CHECK-PLAN-FLAGS, then the plan. → (values plan
reopened-p)."
  (declare (ignore sessions-dir))
  (check-plan-flags inv mode)
  (let ((plans-dir (%plans-dir cwd data-dir getenv))
        (entry (%head-plan-entry source))
        (lost nil))
    (when (and entry (eq :open (getf entry :status)))
      (handler-case
          (return-from %headless-plan (values (reopen-plan plans-dir (getf entry :id)) t))
        (plan-not-found ()
          (setf lost (getf entry :id)))))
    (let* ((project (or (find-project-root cwd) cwd))
           (kind (or (invocation-plan-area inv) :auto))
           (plan (handler-case
                     (open-plan project :kind kind
                                        :data-dir (or data-dir (user-data-directory :getenv getenv))
                                        :session-id (session-id store))
                   (plan-error (e)
                     (if (eq kind :git)
                         (%usage-fail "--plan-area git: ~a is not a git worktree"
                                      (uiop:native-namestring project))
                         (error e))))))
      (when lost
        (%plan-stderr-line error-output "plan ~a is no longer open; opened plan ~a"
                           lost (plan-id plan)))
      (values plan nil))))

(defun %headless-plan-finish (report plan inv run failure interrupted error-output
                              &optional checkpointer)
  "After a plan run, before its turn is committed: the projection, --apply,
the plan events, the result's plan object, the text-mode diff and the
stderr line (see the file header)."
  (let* ((changes (plan-changes plan))
         (diff (plan-diff-text plan))
         (status :open)
         (conflicts '()))
    (%emit-event report "plan" "subtype" "projected" "plan_id" (plan-id plan)
                               "changes" (%changes-json changes) "diff" diff)
    (when (and (invocation-apply-p inv)
               (string= "success" (%outcome run failure interrupted 0)))
      (multiple-value-bind (result-status result) (%headless-approve report plan inv checkpointer)
        (setf status (case result-status
                       ((:applied :empty) :applied)
                       (:rebased :rebased)
                       (t :open)))
        (when (eq result-status :rebased)
          (setf conflicts result))))
    (setf (%report-plan report) (%plan-object plan status changes diff conflicts)
          (%report-plan-text report) (if changes diff ""))
    (case status
      (:applied
       (if changes
           (%plan-stderr-line error-output "plan ~a: applied ~a" (plan-id plan)
                              (%files-count (length changes)))
           (%plan-stderr-line error-output "plan ~a: no changes" (plan-id plan))))
      (:open
       (unless (%report-plan-failure report)
         (if changes
             (%plan-stderr-line error-output
                                "plan ~a: ~a changed, not applied (cl-stack-code -p --resume ~a --apply applies it)"
                                (plan-id plan) (%files-count (length changes))
                                (%report-session report))
             (%plan-stderr-line error-output "plan ~a: no changes" (plan-id plan))))))
    plan))

(defun %run-plan-action (inv &key output getenv data-dir user-config-dir error-output start)
  "--apply / --reject on the resumed session's open plan, without a run.
→ exit code."
  (let* ((getenv (or getenv #'uiop:getenv))
         (cwd (%resolve-cwd (invocation-cwd inv)))
         (config (or user-config-dir (user-config-directory :getenv getenv)))
         (settings (load-settings cwd :user-config-dir config :cli (invocation-settings inv)))
         (mode (or (settings-permission-mode settings) :default))
         (sessions-dir (%sessions-dir cwd data-dir getenv))
         (source (progn (check-plan-flags inv mode)
                        (%session-source inv sessions-dir)))
         (entry (%head-plan-entry source))
         (plan (and entry (eq :open (getf entry :status))
                    (handler-case (reopen-plan (%plans-dir cwd data-dir getenv) (getf entry :id))
                      (plan-not-found () nil))))
         (report (make-%report :format (invocation-output-format inv) :output output
                               :session (session-id source))))
    (unless plan
      (%usage-fail "session ~a has no open plan" (session-id source)))
    ;; H5b: the approval's checkpoints belong to the head (the plan's turn).
    (let ((checkpointer (%make-run-checkpointer settings cwd data-dir getenv)))
      (unwind-protect
           (%run-plan-action-1 inv report plan source checkpointer output error-output start)
        (close-checkpointer checkpointer)))))

(defun %run-plan-action-1 (inv report plan source checkpointer output error-output start)
  (progn
    (let ((changes '()) (diff "") (status :open) (conflicts '()))
      (cond
        ((invocation-reject-p inv)
         (setf changes (plan-changes plan)
               diff (plan-diff-text plan))
         (reject-plan plan)
         (setf status :discarded)
         (%emit-event report "plan" "subtype" "discarded" "plan_id" (plan-id plan))
         (%plan-stderr-line error-output "plan ~a: discarded" (plan-id plan)))
        (t
         (setf changes (plan-changes plan)
               diff (plan-diff-text plan))
         (multiple-value-bind (result-status result) (%headless-approve report plan inv checkpointer)
           (record-plan-checkpoints checkpointer source (%report-plan-pre report)
                                    (session-head source))
           (case result-status
             ((:applied :empty)
              (setf status :applied)
              (if changes
                  (%plan-stderr-line error-output "plan ~a: applied ~a" (plan-id plan)
                                     (%files-count (length changes)))
                  (%plan-stderr-line error-output "plan ~a: no changes" (plan-id plan))))
             (:rebased (setf status :rebased conflicts result))))))
      (setf (%report-plan report) (%plan-object plan status changes diff conflicts))
      (let ((failure (%report-plan-failure report))
            (duration (round (* 1000 (- (get-internal-real-time) (or start (get-internal-real-time))))
                             internal-time-units-per-second)))
        (case (%report-format report)
          (:text
           (when (and (null failure) (eq status :applied))
             (write-string diff output)
             (force-output output)))
          (t
           (%write-json-line report (%result-object report
                                                    (if failure "error_during_execution" "success")
                                                    ""
                                                    (and failure (princ-to-string failure))
                                                    duration))))
        (when failure
          (error failure))
        0))))

(defun %make-run-checkpointer (settings cwd data-dir getenv)
  "H5b: the run's CHECKPOINTER: the project directory (project root, else CWD),
CHECKPOINT-SETTINGS and the data directory. An explicit checkpoints.kind that
does not fit → CHECKPOINT-ERROR."
  (multiple-value-bind (enabled keep kind) (checkpoint-settings settings)
    (make-checkpointer (or (find-project-root cwd) cwd)
                       :kind kind :keep keep :enabled enabled
                       :data-dir (or data-dir (user-data-directory :getenv getenv)))))

(defun %run-headless (inv &key output input providers user-config-dir getenv start data-dir
                               (error-output *error-output*))
  "The -p run of INV. Configuration errors signal before anything is written
to OUTPUT; a run that started is committed to its session, writes its
result, then signals its failure."
  (unless (invocation-print-p inv)
    (error 'code-usage-error
           :message "-p (--print) is required: cl-stack-code 0.1 runs headless only (the interactive mode arrives in H3b)"))
  (check-session-flags inv)
  ;; H5b: --rewind is an action of its own.
  (when (or (invocation-rewind inv) (invocation-rewind-mode inv))
    (return-from %run-headless
      (%run-rewind-action inv :output output :getenv getenv :data-dir data-dir
                              :user-config-dir user-config-dir :error-output error-output
                              :start start)))
  (when (%plan-action-only-p inv)
    (return-from %run-headless
      (%run-plan-action inv :output output :getenv getenv :data-dir data-dir
                            :user-config-dir user-config-dir :error-output error-output
                            :start start)))
  (let* ((prompt (%read-prompt inv input))
         (cwd (%resolve-cwd (invocation-cwd inv)))
         (config (or user-config-dir (user-config-directory :getenv getenv)))
         (settings (load-settings cwd :user-config-dir config
                                      :cli (invocation-settings inv)))
         ;; H3e-2a: the servers' configuration errors (exit 2) before anything is written.
         (mcp-configs (effective-mcp-servers cwd settings :user-config-dir config
                                                          :env (%env-lookup settings getenv)))
         (sessions-dir (%sessions-dir cwd data-dir getenv))
         (source (%session-source inv sessions-dir))
         (designator (%session-model inv source settings))
         (resolved (multiple-value-list
                    (resolve-model designator :providers providers
                                              :env (%env-lookup settings getenv))))
         (backend (first resolved))
         (model (third resolved))
         (mode (or (settings-permission-mode settings) :default))
         ;; H4b: the checks, before the session is written.
         (link (when (settings-lisp-image settings)
                 (check-lisp-image-settings settings mode)
                 (and (lisp-image-enabled-p settings) (%make-image-link))))
         (max-turns (or (settings-max-turns settings) +default-max-turns+))
         (store (%session-for-run inv source sessions-dir (or (find-project-root cwd) cwd)))
         ;; H5b: after the session, before anything is written to OUTPUT.
         (checkpointer (%make-run-checkpointer settings cwd data-dir getenv))
         (history (session-turns store))
         (report (make-%report :format (invocation-output-format inv) :output output
                               :session (session-id store)))
         ;; H5a: plan mode (or a plan flag) opens or reopens the session's plan.
         (plan-and-reopened
           (when (%plan-run-p inv mode)
             (handler-bind ((error (lambda (e)
                                     (declare (ignore e))
                                     (close-checkpointer checkpointer))))
               (multiple-value-list
                (%headless-plan inv mode cwd store source sessions-dir data-dir getenv
                                error-output)))))
         (plan (first plan-and-reopened))
         ;; R4d-4b: the plan's sandbox, probed through the backend resolved
         ;; here (this thread). failIfUnavailable (exit 1) and a bad
         ;; extraWritable (exit 2) signal before the model is called.
         (sandbox
           (when plan
             (handler-bind ((error (lambda (e)
                                     (close-checkpointer checkpointer)
                                     ;; A fresh plan does not stay open behind it.
                                     (when (and (typep e 'plan-sandbox-unavailable)
                                                (not (second plan-and-reopened)))
                                       (reject-plan plan)))))
               (open-plan-sandbox plan settings :backend (plan-compute-backend)))))
         (event-backend (event-backend-libuv:make-libuv-backend))
         (event-loop (event:make-event-loop event-backend))
         (supervisor nil)
         (mcp nil)
         (sources nil)
         (context nil)
         (discovery nil)
         (instruction-set nil))
    (unwind-protect
         (let ((event:*event-backend* event-backend)
               (event:*event-loop* event-loop)
               (http-protocol:*http-backend*
                 (or http-protocol:*http-backend* (http-backend-async:make-async-backend)))
               (http-backend-async:*event-backend-maker*
                 (or http-backend-async:*event-backend-maker*
                     #'event-backend-libuv:make-libuv-backend))
               (agent:*off-loop-specials*
                 (union '(http-protocol:*http-backend* http-backend-async:*event-backend-maker*)
                        agent:*off-loop-specials*)))
           ;; H8d: the run's supervisor, before the tools; H3e-2a: then the
           ;; MCP manager, before the instruction set opens.
           (setf supervisor (make-code-supervisor cwd :data-dir data-dir
                                                      :getenv (or getenv #'uiop:getenv))
                 mcp (make-mcp-manager mcp-configs :supervisor supervisor :settings settings
                                                   :env (%env-lookup settings getenv) :cwd cwd
                                                   :http-backend http-protocol:*http-backend*)
                 (%report-mcp report) mcp)
           ;; H3e-1: the session's instruction set (:start or :resume).
           (multiple-value-setq (context discovery instruction-set)
             (%open-session-instructions cwd settings store
                                         :user-config-dir config
                                         :components (list (mcp-manager-component mcp))))
           (setf (mcp-manager-instruction-set mcp) instruction-set
                 (%report-instruction-set report) instruction-set)
           (setf sources (append (apply #'make-code-tools (if plan (plan-tool-root plan cwd) cwd)
                                        :settings settings
                                        :on-image-event (and link (%link-callback link))
                                        :supervisor supervisor
                                        :scope (and plan (%plan-unit-scope supervisor plan))
                                        :skills (context-skills context)
                                        (plan-sandbox-tool-keys sandbox))
                                 ;; H3e-2a: the MCP source, last.
                                 (list (mcp-manager-tool-source mcp))))
           (%link-skill-tools instruction-set (code-skill-tools sources))
           ;; H4b: the image starts before the system event; its events are
           ;; written and posted on the loop thread.
           (when link
             (setf (%link-tools link) (third sources)
                   (%report-image-tools report) (third sources))
             (%link-attach link (lambda (event)
                                  (event:wake-call event-backend event-loop
                                                   (lambda ()
                                                     (%headless-image-event report event)))))
             (start-lisp-image (third sources) settings))
           ;; H3e-2a: the servers before the first model call (committed once
           ;; they settled); a notice per server that did not connect.
           (start-mcp-servers mcp)
           (dolist (c (mcp-manager-connections mcp))
             (let ((notice (mcp-status-notice c :user-config-dir config)))
               (when notice
                 (format error-output "~a~%" notice))))
           (force-output error-output)
           (let ((offered (loop for source in sources
                                append (mapcar #'llm:llm-tool-name
                                               (agent:list-agent-tools source)))))
             (dolist (notice (%take-mcp-notices mcp))
               (format error-output "~a~%" notice)
               (force-output error-output))
             (multiple-value-bind (instructions files)
                 (assemble-system-prompt cwd :tools offered :backend backend
                                             :settings settings :user-config-dir config
                                             :plan plan :sandbox sandbox
                                             :lisp-image (%sources-lisp-tools sources)
                                             :context context :instruction-set instruction-set)
               (let ((agent (agent:make-ai-agent
                             :name "cl-stack-code"
                             :backend backend
                             :model model
                             :instructions instructions
                             :tools sources
                             :permissions (if sandbox
                                              (%plan-permissions settings sandbox)
                                              (%agent-permissions settings))
                             :settings (%agent-settings cwd settings :discovery discovery)))
                     (root (find-project-root cwd)))
                 (apply #'%emit-event report "system"
                        (%system-init-keys cwd root designator mode offered files
                                           (and link settings)
                                           :context context :discovery discovery
                                           :instruction-set instruction-set
                                           :mcp-servers (mcp-manager-connections mcp)))
                 (when plan
                   (apply #'%emit-event report "plan"
                          (%plan-open-keys plan (second plan-and-reopened) sandbox)))
                 ;; R4d-4b: once, after the plan opened, before the model.
                 (let ((notice (and sandbox (plan-sandbox-notice sandbox))))
                   (when notice (%plan-stderr-line error-output "~a" notice)))
                 (let ((pre (begin-checkpoint-turn checkpointer store)))
                   (multiple-value-bind (run failure interrupted)
                       (%drive agent (append history (list (llm:user-turn prompt))) report mode
                               :sandbox sandbox :error-output error-output)
                     (when plan
                       (%headless-plan-finish report plan inv run
                                              (or (%report-failure report) failure)
                                              interrupted error-output checkpointer))
                     (multiple-value-bind (revision went-to)
                         (%commit-headless-turn report store prompt history failure interrupted
                                                designator mode error-output plan)
                       ;; H5b: --apply's checkpoints belong to this turn; then
                       ;; the turn's own (none after an approved plan).
                       (when revision
                         (record-plan-checkpoints checkpointer went-to (%report-plan-pre report)
                                                  revision)
                         (end-checkpoint-turn checkpointer went-to pre revision)))
                     (%report-run-end report run failure interrupted max-turns start)))))))
      ;; H4b: no event reaches the loop after this; -p never waits for
      ;; events after the run (the queue goes with the tools).
      (%link-close link)
      ;; H3e-2a: the MCP clients and their units, before the supervisor.
      (close-mcp-manager mcp)
      ;; H8d: unit tools, shell tools, then the supervisor.
      (%close-code-units supervisor :unit-tools (list (code-unit-tools sources))
                                    :shell-tools (list (second sources)))
      (close-checkpointer checkpointer)
      (event:close-event-loop event-backend event-loop))))

(defun %system-init-keys (cwd root designator mode offered files image-settings
                          &key context discovery instruction-set mcp-servers)
  "The \"system\" init event's keys and values (after \"type\" and
\"session_id\"); IMAGE-SETTINGS (the settings, when the image is on) adds
\"lisp_image\". Shared by -p and the SDK (src/client.lisp). H3e-1: CONTEXT,
DISCOVERY and INSTRUCTION-SET give \"imports\", \"skills\", \"rules\",
\"notes\" and \"instruction_set\" (always present)."
  (let ((loaded (cond (discovery (discovery-loaded-rules discovery))
                      (context (context-loaded-rules context)))))
    (list* "subtype" "init"
           "version" +version+
           "cwd" (uiop:native-namestring cwd)
           "project_root" (if root (uiop:native-namestring root) :null)
           "model" designator
           "permission_mode" (permission-mode-name mode)
           "tools" (coerce offered 'vector)
           "instructions" (map 'vector #'uiop:native-namestring files)
           ;; H3e-1
           "imports" (map 'vector (lambda (pair)
                                    (%json-object "path" (uiop:native-namestring (car pair))
                                                  "from" (uiop:native-namestring (cdr pair))))
                          (and context (context-imports context)))
           "skills" (map 'vector (lambda (skill)
                                   (%json-object "name" (steer:steer-directive-name skill)
                                                 "description" (steer:steer-directive-description skill)
                                                 "path" (uiop:native-namestring
                                                         (steer:steer-directive-path skill))
                                                 "source" (skill-source skill)))
                         (and context (context-skills context)))
           "rules" (map 'vector (lambda (rule)
                                  (let ((native (uiop:native-namestring (steer:steer-directive-path rule)))
                                        (patterns (rule-patterns rule)))
                                    (%json-object "path" native
                                                  "paths" (if patterns (coerce patterns 'vector) :null)
                                                  "loaded" (and (member native loaded :test #'string=) t))))
                        (and context (context-rules context)))
           "notes" (coerce (and context (context-notes context)) 'vector)
           "instruction_set" (or (and instruction-set (instruction-set-current instruction-set)) :null)
           (append
            ;; H4b: only with the image on.
            (and image-settings (list "lisp_image" (%lisp-image-object image-settings)))
            ;; H3e-2a: only with at least one server (MCP-SERVERS: the connections).
            (and mcp-servers
                 (list "mcp_servers" (map 'vector #'mcp-connection-object mcp-servers)))))))

(defun %plan-open-keys (plan reopened-p &optional sandbox)
  "The plan \"opened\" / \"reopened\" event's keys and values. R4d-4b: with
a SANDBOX, \"sandbox\" is its PLAN-SANDBOX-OBJECT."
  (list* "subtype" (if reopened-p "reopened" "opened")
         "plan_id" (plan-id plan)
         "kind" (string-downcase (string (plan-kind plan)))
         "area" (uiop:native-namestring (plan-root plan))
         "base" (plan-base plan)
         (and sandbox (list "sandbox" (plan-sandbox-object sandbox)))))

(defun %headless-image-event (report event)
  "H4b, loop thread: EVENT's image_event line (none for :debugger-return),
then the queued events posted into the run while it is going. Like
%ON-AGENT-EVENT it never signals: the first error is kept and fails the run."
  (handler-case
      (progn
        (unless (eq :debugger-return (lt:image-event-kind event))
          (flet ((value (x) (or x :null)))
            (%emit-event report "image_event"
                         "kind" (string-downcase (symbol-name (lt:image-event-kind event)))
                         "connection" (value (lt:image-event-connection event))
                         "thread" (value (lt:image-event-thread event))
                         "level" (value (lt:image-event-level event))
                         "job" (value (lt:image-event-job event))
                         "text" (lt:image-event-text event))))
        (%post-if-going (%report-image-tools report) (%report-run report)))
    (error (e)
      (unless (%report-failure report)
        (setf (%report-failure report) e))
      (let ((run (%report-run report)))
        (when run (agent:cancel-agent-run run))))))

(defun %list-sessions (inv &key output getenv data-dir)
  "--list-sessions: this project's SESSION-SUMMARY-LINES on OUTPUT. → 0."
  (check-session-flags inv)
  (let ((cwd (%resolve-cwd (invocation-cwd inv))))
    (dolist (line (session-summary-lines (%sessions-dir cwd data-dir getenv)))
      (write-line line output))
    (force-output output)
    0))

(defun run-cli (argv &key (output *standard-output*) (error-output *error-output*)
                       (input *standard-input*) providers user-config-dir
                       (getenv #'uiop:getenv) data-dir)
  "Run one invocation of ARGV and return its exit code (0, 1, 2 or 130); never
quits. OUTPUT gets the answer or JSON, ERROR-OUTPUT the diagnostics, INPUT the
prompt when ARGV has none. PROVIDERS (alist name → factory) come before the
built-in ones. USER-CONFIG-DIR defaults to USER-CONFIG-DIRECTORY. GETENV is the
process environment lookup under the settings env. DATA-DIR (H3c) defaults to
USER-DATA-DIRECTORY: sessions live under it."
  (let ((start (get-internal-real-time)))
    (handler-case
        (let ((inv (parse-arguments argv)))
          (cond ((invocation-help-p inv)
                 (%usage-text output)
                 0)
                ((invocation-version-p inv)
                 (format output "cl-stack-code ~a~%" +version+)
                 0)
                ;; ACP-2: an ACP agent until INPUT ends (cl-stack-code/acp,
                ;; through *ACP-SERVER*; src/rpc.lisp). Before --rpc, so
                ;; --acp --rpc is CHECK-ACP-FLAGS's usage error.
                ((invocation-acp-p inv)
                 (%run-acp inv :output output :input input :error-output error-output
                               :providers providers :user-config-dir user-config-dir
                               :getenv getenv :data-dir data-dir))
                ;; H3d: a JSON-RPC server until INPUT ends (src/rpc.lisp).
                ((invocation-rpc-p inv)
                 (%run-rpc inv :output output :input input :error-output error-output
                               :providers providers :user-config-dir user-config-dir
                               :getenv getenv :data-dir data-dir))
                ;; H5b
                ((invocation-list-checkpoints-p inv)
                 (%list-checkpoints inv :output output :getenv getenv :data-dir data-dir
                                        :user-config-dir user-config-dir))
                ((and (not (invocation-print-p inv))
                      (or (invocation-rewind inv) (invocation-rewind-mode inv)))
                 (error 'code-usage-error
                        :message "--rewind needs -p (use /rewind in the interactive mode)"))
                ((invocation-list-sessions-p inv)
                 (%list-sessions inv :output output :getenv getenv :data-dir data-dir))
                ((not (invocation-print-p inv))
                 (%run-interactive inv :output output :input input :providers providers
                                       :user-config-dir user-config-dir :getenv getenv
                                       :data-dir data-dir))
                (t
                 (%run-headless inv :output output :input input :providers providers
                                    :user-config-dir user-config-dir :getenv getenv
                                    :start start :data-dir data-dir
                                    :error-output error-output))))
      (error (c)
        (format error-output "cl-stack-code: ~a~%" c)
        (force-output error-output)
        (condition-exit-code c)))))

(defun main ()
  "Binary entry point: quit with RUN-CLI's exit code."
  (uiop:quit (run-cli (uiop:command-line-arguments))))

;;; H5b: --rewind and --list-checkpoints (see the "H5b" part of the file
;;; header).

(defun %keyword-name (keyword)
  (string-downcase (string keyword)))

(defun %rewind-keys (result)
  "The rewind object of a REWIND-TO RESULT as alternating keys and values."
  (let ((k (getf result :checkpoint)))
    (list "turn" (getf result :turn)
          "parts" (map 'vector #'%keyword-name (getf result :parts))
          "conversation" (%keyword-name (getf result :conversation))
          "files" (%keyword-name (getf result :files))
          "changes" (%changes-json (getf result :changes))
          "conflicts" (coerce (getf result :conflicts) 'vector)
          "drift" (coerce (getf result :drift) 'vector)
          "checkpoint" (if k (checkpoint-id k) :null))))

(defun %rewind-parts (mode)
  (ecase (or mode :both)
    (:both (copy-list +rewind-parts+))
    (:conversation (list :conversation))
    (:files (list :files))))

(defun %run-rewind-action (inv &key output getenv data-dir user-config-dir error-output start)
  "--rewind TURN on the resumed session, without a run. → exit code."
  (check-rewind-flags inv)
  (let* ((getenv (or getenv #'uiop:getenv))
         (cwd (%resolve-cwd (invocation-cwd inv)))
         (config (or user-config-dir (user-config-directory :getenv getenv)))
         (settings (load-settings cwd :user-config-dir config :cli (invocation-settings inv)))
         (source (%session-source inv (%sessions-dir cwd data-dir getenv)))
         (on-drift (or (invocation-on-drift inv) :abort))
         (report (make-%report :format (invocation-output-format inv) :output output
                               :session (session-id source)))
         (checkpointer (%make-run-checkpointer settings cwd data-dir getenv))
         (diff ""))
    (unwind-protect
         (let* ((result
                  ;; Text mode prints the rewind plan's diff (the merged one
                  ;; after a rebase).
                  (let ((*%rewind-diff-hook*
                          (and (eq :text (%report-format report))
                               (lambda (plan) (setf diff (plan-diff-text plan))))))
                    (handler-bind ((plan-drift
                                     (lambda (c)
                                       (invoke-restart
                                        (find-restart (ecase on-drift
                                                        (:abort 'abort-approval)
                                                        (:rebase 'rebase-plan)
                                                        (:overwrite 'overwrite-plan))
                                                      c)))))
                      (rewind-to checkpointer source (invocation-rewind inv)
                                 :parts (%rewind-parts (invocation-rewind-mode inv))))))
                (files (getf result :files))
                (failure
                  (and (eq files :aborted)
                       (make-condition
                        'plan-drift
                        :paths (getf result :drift)
                        :message (format nil "rewind to turn ~a: the working copy changed at ~{~a~^, ~}; nothing restored (use --on-drift rebase or --on-drift overwrite)"
                                         (getf result :turn) (getf result :drift)))))
                (keys (%rewind-keys result))
                (duration (round (* 1000 (- (get-internal-real-time)
                                            (or start (get-internal-real-time))))
                                 internal-time-units-per-second)))
           (setf (%report-rewind report) (apply #'%json-object keys))
           (apply #'%emit-event report "rewind" keys)
           (case (%report-format report)
             (:text
              (when (member files '(:applied :merged))
                (write-string diff output)
                (force-output output)))
             (t
              (%write-json-line report (%result-object report
                                                       (if failure "error_during_execution" "success")
                                                       ""
                                                       (and failure (princ-to-string failure))
                                                       duration))))
           (unless failure
             (format error-output "cl-stack-code: session ~a rewound to turn ~a: ~a~%"
                     (session-id source) (getf result :turn) (rewind-description result))
             (force-output error-output))
           (when failure
             (error failure))
           0)
      (close-checkpointer checkpointer))))

(defun %list-checkpoints (inv &key output getenv data-dir user-config-dir)
  "--list-checkpoints: the resumed session's CHECKPOINT-SUMMARY-LINES on
OUTPUT. → 0."
  (declare (ignore user-config-dir))
  (check-session-flags inv)
  (check-rewind-flags inv)
  (let* ((cwd (%resolve-cwd (invocation-cwd inv)))
         (source (%session-source inv (%sessions-dir cwd data-dir (or getenv #'uiop:getenv)))))
    (dolist (line (checkpoint-summary-lines source))
      (write-line line output))
    (force-output output)
    0))
