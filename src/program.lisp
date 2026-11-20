(in-package #:cl-stack-code)

;;; H3b: the interactive program, a tui-protocol program over the core in
;;; interactive.lisp.
;;;
;;; MAKE-CODE-PROGRAM INVOCATION &key PROVIDERS USER-CONFIG-DIR GETENV does
;;; what %RUN-HEADLESS does before a run, with the same functions and the
;;; same errors (signalled from MAKE-CODE-PROGRAM, before any terminal is
;;; touched): the working directory, LOAD-SETTINGS, RESOLVE-MODEL,
;;; MAKE-CODE-TOOLS, ASSEMBLE-SYSTEM-PROMPT (AGENTS.md), the agent with
;;; %AGENT-PERMISSIONS and %AGENT-SETTINGS, and its own libuv event loop.
;;; The agent's permission store is a SETTINGS-RULE-STORE on the local
;;; settings file (the third of SETTINGS-FILE-PATHS). CLOSE-CODE-PROGRAM
;;; closes the shell tools and the loop; it is idempotent.
;;;
;;; Threads. Agent work never runs on the UI thread. Agent events reach the
;;; program as messages sent with TUI-SEND, so only TUI-UPDATE touches the
;;; state and the widgets. No handler answers AGENT-APPROVAL-REQUIRED, so an
;;; ask pauses the run (:approval) and the dialog answers it, except in
;;; bypassPermissions, where every ask is approved as in -p.
;;;
;;; Effects (see interactive.lisp): :run expands mentions (EXPAND-MENTIONS
;;; on the working directory) and runs the first message with
;;; RUN-AI-AGENT-ASYNC, later ones with CONTINUE-AI-AGENT-ASYNC on the same
;;; run (history kept); :approve / :deny call APPROVE-INVOCATION /
;;; DENY-INVOCATION; :resume calls RESUME-AI-AGENT-ASYNC when the run has no
;;; :proposed invocation left; :cancel calls CANCEL-AGENT-RUN; :set-model
;;; resolves the designator with the program's providers and environment
;;; and uses that backend from the next turn on (answering (:model-set D) or
;;; (:error <the MODEL-NOT-FOUND message>)); :set-permission-mode rebuilds the
;;; mode's rules and policy for the next turn; :new-conversation drops the
;;; run; :quit makes TUI-UPDATE return :quit. Finish reasons map to turn
;;; ends: :approval / :deferred → :approval (pending = the run's :proposed
;;; invocations), :max-steps → :max-steps ("reached max turns (N)"),
;;; :canceled → :canceled, an error → :failed (its message), anything else →
;;; :stop. The @-completion list (PROJECT-FILES of the working directory) is
;;; read at start and after every turn end.
;;;
;;; Keys
;;;   approvals waiting   the dialog has the keys: Up/Down, 1-4, Enter; a
;;;                       confirm-event is (:reply CHOICE FEEDBACK); Escape
;;;                       (its cancel-event) is (:interrupt)
;;;   PgUp / PgDn, wheel  scroll the transcript (scrolled to the bottom it
;;;                       follows the tail again)
;;;   Ctrl-C              busy: (:interrupt); idle with text: clear the
;;;                       input; idle and empty: (:quit)
;;;   Ctrl-D              empty input: (:quit); otherwise nothing
;;;   everything else     the input (W:TEXT-INPUT, prompt "> ", placeholder
;;;                       "Message, @file, /help", history in memory,
;;;                       completion = MENTION-CANDIDATES, max 5 items):
;;;                       submit-event → (:submit TEXT), cancel-event (Esc
;;;                       with no menu) → (:interrupt); edit-event (Ctrl-G)
;;;                       is ignored in H3b
;;;
;;; Layout on W × H, from the bottom:
;;;   row H − 1     the status line (W:STATUS-LINE, inverse, STATUS-LINE-TEXT)
;;;   above it      approvals waiting: the dialog (W:CONFIRM-DIALOG, choices
;;;                 +APPROVAL-CHOICES+, feedback choice :reject, title
;;;                 "Permission", or "Permission (I of N)" when the :approval turn end
;;;                 had N > 1 pending, I = N − (length STATE-APPROVALS) + 1;
;;;                 message APPROVAL-MESSAGE of the first approval), min(H − 2, 7 + message rows wrapped at
;;;                 W − 4) rows; otherwise the input, min(8, lines + menu rows)
;;;                 rows
;;;   above it      one row of "─" × W
;;;   above it      busy and no dialog: one row per queued message (at most
;;;                 3) "  queued: <its first line>", then "  … +N queued"
;;;                 when more wait, then the spinner (W:SPINNER, label
;;;                 "Working… (Esc to interrupt)")
;;;   the rest      the transcript: a W:VIEWPORT that follows the tail, its
;;;                 lines (TRANSCRIPT-LINES entries W :streaming busy-p)
;;;
;;; RUN-CLI without -p: configuration errors exit 2 as in -p. When INPUT and
;;; OUTPUT are not the process's own standard streams, or TTY-AVAILABLE-P is
;;; false, the run is a CODE-USAGE-ERROR whose message names the terminal and
;;; -p (exit 2) and nothing is sent. Otherwise the program runs on a
;;; TTY-BACKEND (which restores the terminal on any exit) and RUN-CLI returns
;;; 0 when it quits. A prompt given as arguments is the first message.
;;; --output-format without -p is a CODE-USAGE-ERROR naming --output-format.
;;;
;;; H3c: sessions and steering.
;;;   Start            MAKE-CODE-PROGRAM resolves the session as -p does
;;;                    (src/headless.lisp: --continue, --resume, --session-id,
;;;                    --fork-session, the same errors, signalled before the
;;;                    terminal is touched) under :DATA-DIR (default
;;;                    USER-DATA-DIRECTORY). A resumed session starts with
;;;                    STATE-TRANSCRIPT = SESSION-ENTRIES, the input history
;;;                    = the prompts of the head's line (oldest first),
;;;                    STATE-SESSION-ID = its id, and the model as in -p. The
;;;                    first :run starts RUN-AI-AGENT-ASYNC on SESSION-TURNS
;;;                    plus the message.
;;;   Turns            At every turn end other than :approval the program
;;;                    commits the turn (COMMIT-TURN: the message as typed,
;;;                    the run's turns since the last commit without :system
;;;                    turns, the finish, model, mode, the turn's usage and
;;;                    the steering it took) on the agent thread, then sends
;;;                    the :turn-end. A SESSION-CONFLICT takes FORK-SESSION and
;;;                    sends (:session NEW) and (:notice "session OLD changed
;;;                    in another process; continuing as session NEW"). Any
;;;                    other commit error is an (:error M); those turns go
;;;                    into the next commit.
;;;   Effects          (:steer T): on the agent thread, when the run is still
;;;                    going (finish reason NIL, :approval or :deferred),
;;;                    AGENT-RUN-POST the expanded text; otherwise nothing
;;;                    (the core makes it a follow-up at the turn end). The
;;;                    run's :inbox event sends (:steered TEXTS) for the posts
;;;                    it took, in order. A canceled or failed turn empties the
;;;                    run's inbox. (:tree) → (:notice) of SESSION-TREE-LINES
;;;                    at the width of the last frame. (:fork AT) /
;;;                    (:rewind N) → FORK-TURN / REWIND-SESSION, the run is
;;;                    dropped, the next :run starts from SESSION-TURNS, and
;;;                    (:session-reset :entries (SESSION-ENTRIES) …): /fork
;;;                    with :input = AT's prompt and :notice "forked before
;;;                    turn <id8>: edit the message and press Enter"; /rewind
;;;                    with :notice "rewound N turn[s]". (:clone) →
;;;                    CLONE-SESSION, later turns go to the clone, (:session
;;;                    NEW) and (:notice "cloned session OLD as NEW").
;;;                    (:export FILE) → EXPORT-SESSION (FILE relative to the
;;;                    working directory, parent directories created, an
;;;                    existing file replaced). :new-conversation
;;;                    (/clear) also makes a new session (CREATE-SESSION) and
;;;                    sends (:session NEW). Errors from these are (:error M)
;;;                    with the condition's text.
;;;   Keys             Ctrl-T in the input: a non-blank value is taken from
;;;                    the input (cleared, added to the history as Enter does)
;;;                    and sent as (:steer TEXT). Enter is unchanged.
;;;   Layout           Busy and no dialog: above the queued rows, one row per
;;;                    pending steering message (at most 3) "  steering:
;;;                    <its first line>", then "  … +N steering" when more
;;;                    wait.
;;;
;;; H5a: plans (src/plans.lisp).
;;;   Opening          When a :run starts a turn and the program's mode is
;;;                    :plan with no plan open, %ENSURE-PLAN (loop thread)
;;;                    opens one before the turn: the resumed session's head
;;;                    record's open plan (REOPEN-PLAN), else OPEN-PLAN on the
;;;                    project directory (:KIND :AUTO, the program's data
;;;                    directory and session id). The agent gets tools rooted
;;;                    at PLAN-TOOL-ROOT and ASSEMBLE-SYSTEM-PROMPT :PLAN
;;;                    (SETF of AI-AGENT-TOOLS and AI-AGENT-INSTRUCTIONS; the
;;;                    working directory's tools are kept for later), the run
;;;                    is dropped so the turn starts a new run on
;;;                    SESSION-TURNS, and (:plan-opened :id :kind :root) is
;;;                    sent. An error opening it fails the turn (:turn-end
;;;                    :reason :failed with its message) and nothing runs.
;;;   Turn ends        After a :stop or :max-steps turn end of a turn that
;;;                    ran in the plan, (:plan-projected :id :changes
;;;                    (PLAN-CHANGES) :diff (PLAN-DIFF-TEXT)) is sent after
;;;                    the :turn-end. The turn record carries PLAN-RECORD.
;;;   Effects          (:show-plan) → (:plan-projected …). (:approve-plan
;;;                    :on-drift M) → APPROVE-PLAN with PLAN-DRIFT answered by
;;;                    M (:rebase → REBASE-PLAN, :overwrite → OVERWRITE-PLAN),
;;;                    or, without M, ABORT-APPROVAL after sending
;;;                    (:plan-drift :paths P); then (:plan-closed :status S
;;;                    :changes C :conflicts X) with APPROVE-PLAN's status
;;;                    (:aborted is not sent after a :plan-drift: the drift
;;;                    dialog answers). After :rebased, (:plan-projected …)
;;;                    follows. (:reject-plan) → REJECT-PLAN, (:plan-closed
;;;                    :status :discarded). A plan that closed (applied,
;;;                    empty, discarded) gives the agent back the working
;;;                    directory's tools and instructions and drops the run;
;;;                    the mode stays :plan, so the next message opens a new
;;;                    plan. Errors are (:error M).
;;;   Dialog           STATE-PLAN-PROMPT :plan (and no approvals waiting): a
;;;                    W:CONFIRM-DIALOG titled "Plan <id8>" with message
;;;                    "<N> file[s] changed. Approve to apply them to the
;;;                    project." and +PLAN-CHOICES+; :drift: titled "Plan
;;;                    <id8>: the working copy changed" with message "Changed
;;;                    in both: P1, P2" and +DRIFT-CHOICES+. Its confirm-event
;;;                    is (:reply CHOICE), its cancel-event (:interrupt), as
;;;                    for approvals.
;;;   Transcript       A :plan entry renders as "● plan <id8>: N file[s]
;;;                    changed", then its diff through MD:RENDER-DIFF-LINES
;;;                    at W − 2, indented by 2 (TRANSCRIPT-LINES).
;;;
;;; H5b: checkpoints and rewind (src/checkpoints.lisp).
;;;   Checkpointer     MAKE-CODE-PROGRAM makes one (as -p does: project
;;;                    directory, CHECKPOINT-SETTINGS, the data directory)
;;;                    before the terminal is touched; CLOSE-CODE-PROGRAM
;;;                    closes it.
;;;   Turns            On the agent thread: BEGIN-CHECKPOINT-TURN when a :run
;;;                    starts a turn (after %ENSURE-PLAN), END-CHECKPOINT-
;;;                    TURN right after the turn is committed (before the
;;;                    :turn-end reaches the UI, so disk state is current
;;;                    when the UI goes idle), with the store the turn went
;;;                    to. A checkpoint error is an (:error M); the turn
;;;                    stands.
;;;   Plans            (:approve-plan …) passes :CHECKPOINTER to APPROVE-PLAN,
;;;                    then RECORD-PLAN-CHECKPOINTS with the session's head.
;;;   Effects          (:checkpoints) → (:notice …) of CHECKPOINT-SUMMARY-
;;;                    LINES at the width of the last frame (see the core).
;;;                    (:tree) passes SESSION-TREE-LINES :MARKED the
;;;                    conversation revision ids of SESSION-CHECKPOINTS.
;;;                    (:rewind N) (H3c, no parts): T = the line's length −
;;;                    N; when TURN-CHECKPOINT T is a retained checkpoint
;;;                    whose files are not the same as the tip's, (:rewind-
;;;                    prompt :n N :turn T :paths P) with P the paths that
;;;                    differ; otherwise H3c's conversation rewind ("rewound
;;;                    N turn[s]"). (:rewind N :parts P :on-drift M) →
;;;                    REWIND-TO; a moved conversation drops the run and
;;;                    sends (:session-reset :entries (SESSION-ENTRIES)),
;;;                    then (:rewound …). A PLAN-DRIFT without M sends
;;;                    (:rewind-drift :paths P) and takes ABORT-APPROVAL
;;;                    (no :rewound follows). Errors are (:error M).
;;;   Dialog           STATE-REWIND-PROMPT :rewind: a W:CONFIRM-DIALOG
;;;                    titled "Rewind to turn T" with message "Files to
;;;                    restore: P1, P2" and +REWIND-CHOICES+; :drift: titled
;;;                    "Rewind: the working copy changed" with message
;;;                    "Changed in both: P1, P2" and +DRIFT-CHOICES+. Events
;;;                    as for the plan dialogs ((:reply CHOICE) /
;;;                    (:interrupt)).


(defclass code-program ()
  ((state :initarg :state :reader code-program-state
          :documentation "The INTERACTIVE-STATE.")
   (input :initarg :input :reader code-program-input
          :documentation "The W:TEXT-INPUT.")
   (dialog :initform nil :accessor code-program-dialog
           :documentation "The W:CONFIRM-DIALOG while approvals wait, else NIL.")
   ;; Configuration, from MAKE-CODE-PROGRAM (read-only afterwards).
   (cwd :initarg :cwd :reader %cp-cwd)
   (settings :initarg :settings :reader %cp-settings)
   (providers :initarg :providers :reader %cp-providers)
   (env :initarg :env :reader %cp-env)
   (agent :initarg :agent :reader %cp-agent)
   (sources :initarg :sources :reader %cp-sources)
   (max-turns :initarg :max-turns :reader %cp-max-turns)
   (prompt :initarg :prompt :reader %cp-prompt)
   (event-backend :initarg :event-backend :reader %cp-event-backend)
   (event-loop :initarg :event-loop :reader %cp-event-loop)
   (http-backend :initarg :http-backend :reader %cp-http-backend
                 :documentation "HTTP-PROTOCOL:*HTTP-BACKEND* when the program was made.")
   (event-maker :initarg :event-maker :reader %cp-event-maker
                :documentation "HTTP-BACKEND-ASYNC:*EVENT-BACKEND-MAKER* then.")
   ;; Lifecycle (any thread, set once).
   (thread :initform nil :accessor %cp-thread
           :documentation "The agent thread running the event loop, from TUI-INIT.")
   (stopping :initform nil :accessor %cp-stopping)
   (closed :initform nil :accessor %cp-closed)
   (tui :initform nil :accessor %cp-tui
        :documentation "The TUI-RUN (TUI:*TUI* in TUI-INIT), for TUI-SEND.")
   ;; Loop thread only.
   (run :initform nil :accessor %cp-run :documentation "The AGENT-RUN, or NIL.")
   (handle :initform nil :accessor %cp-handle
           :documentation "The handle of the last started, continued or resumed turn.")
   (mode :initarg :mode :accessor %cp-mode :documentation "The permission mode.")
   (data-dir :initarg :data-dir :initform nil :reader %cp-data-dir
             :documentation "H3c: RUN-CLI's :DATA-DIR, or NIL for USER-DATA-DIRECTORY.")
   ;; H3c, loop thread only (set up by MAKE-CODE-PROGRAM).
   (session :initarg :session :accessor %cp-session :documentation "The SESSION-STORE.")
   (sessions-dir :initarg :sessions-dir :reader %cp-sessions-dir)
   (project-dir :initarg :project-dir :reader %cp-project-dir)
   (designator :initarg :designator :accessor %cp-designator
               :documentation "The model designator turns run with.")
   (committed :initform (make-hash-table :test 'eq) :accessor %cp-committed
              :documentation "The run's turns that are in the session already.")
   (turn-prompt :initform "" :accessor %cp-turn-prompt
                :documentation "The running turn's message as typed.")
   (turn-usage :initform (list 0 0 0 0) :accessor %cp-turn-usage
               :documentation "Usage since the last commit.")
   (turn-steering :initform '() :accessor %cp-turn-steering
                  :documentation "Steering texts the run took since the last commit.")
   (posted :initform '() :accessor %cp-posted
           :documentation "(turn . typed text) of steering posted and not taken yet.")
   ;; UI thread only (read on the loop thread for /tree).
   (width :initform 80 :accessor %cp-width :documentation "The last frame's width.")
   ;; UI thread only.
   (files :initform '() :accessor %cp-files :documentation "The @-completion list.")
   (viewport :initarg :viewport :reader %cp-viewport)
   (spinner :initarg :spinner :reader %cp-spinner)
   (status :initarg :status :reader %cp-status)
   (dialog-invocation :initform nil :accessor %cp-dialog-invocation)
   (lines-key :initform nil :accessor %cp-lines-key
              :documentation "(generation width busy) the viewport lines were made for.")
   (generation :initform 0 :accessor %cp-generation)
   (interrupted :initform nil :accessor %cp-interrupted
                :documentation "True from a :cancel effect until the turn ends.")
   ;; H5a, loop thread only.
   (plan :initform nil :accessor %cp-plan :documentation "The open PLAN, or NIL.")
   (plan-sources :initform nil :accessor %cp-plan-sources
                 :documentation "The tool sources rooted in the plan's area, or NIL.")
   (turn-plan :initform nil :accessor %cp-turn-plan
              :documentation "True when the running turn runs in the plan.")
   (cwd-instructions :initform nil :accessor %cp-cwd-instructions
                     :documentation "The agent's working-directory instructions while a plan is open.")
   (user-config-dir :initarg :user-config-dir :initform nil :reader %cp-user-config-dir
                    :documentation "The user config directory (for ASSEMBLE-SYSTEM-PROMPT).")
   (drift-paths :initform '() :accessor %cp-drift-paths
                :documentation "The paths of the last (:plan-drift …) sent, for the drift dialog."))
  (:documentation "The interactive mode as a tui-protocol program."))

(defun %make-input (program-cell)
  "The prompt input; PROGRAM-CELL is a cons whose car becomes the program."
  (make-instance 'w:text-input
                 :prompt "> "
                 :placeholder "Message, @file, /help"
                 :completion-max-items 5
                 :completion-function
                 (lambda (token)
                   (let ((program (car program-cell)))
                     (and program (mention-candidates (%cp-files program) token))))))

(defun make-code-program (invocation &key providers user-config-dir
                                          (getenv #'uiop:getenv) data-dir)
  "→ a CODE-PROGRAM for INVOCATION (a parsed command line without -p). The
configuration errors of -p signal here."
  (let* ((getenv (or getenv #'uiop:getenv))
         (cwd (%resolve-cwd (invocation-cwd invocation)))
         (config (or user-config-dir (user-config-directory :getenv getenv)))
         (settings (load-settings cwd :user-config-dir config
                                      :cli (invocation-settings invocation)))
         (sessions-dir (%sessions-dir cwd data-dir getenv))
         (source (%session-source invocation sessions-dir))
         (designator (%session-model invocation source settings))
         (env (%env-lookup settings getenv))
         (resolved (multiple-value-list
                    (resolve-model designator :providers providers :env env)))
         (backend (first resolved))
         (mode (or (settings-permission-mode settings) :default))
         (project-dir (or (find-project-root cwd) cwd))
         (session (%session-for-run invocation source sessions-dir project-dir))
         (event-backend (event-backend-libuv:make-libuv-backend))
         (event-loop (event:make-event-loop event-backend))
         (sources nil)
         (done nil))
    (unwind-protect
         (let ((program
                 (let ((event:*event-backend* event-backend)
                       (event:*event-loop* event-loop))
                   (setf sources (make-code-tools cwd :settings settings))
                   (let* ((offered (loop for source in sources
                                         append (mapcar #'llm:llm-tool-name
                                                        (agent:list-agent-tools source))))
                          (instructions (assemble-system-prompt
                                         cwd :tools offered :backend backend
                                             :settings settings :user-config-dir config))
                          (store (make-settings-rule-store
                                  (third (settings-file-paths cwd :user-config-dir config))))
                          (agent (agent:make-ai-agent
                                  :name "cl-stack-code"
                                  :backend backend
                                  :model (third resolved)
                                  :instructions instructions
                                  :tools sources
                                  :permissions (%agent-permissions settings)
                                  :settings (%agent-settings cwd settings)
                                  :permission-store store))
                          (cell (list nil))
                          (program
                            (make-instance
                             'code-program
                             :state (make-interactive-state
                                     :model designator :permission-mode mode :cwd cwd
                                     :rules (append (settings-allow settings)
                                                    (settings-ask settings)
                                                    (settings-deny settings))
                                     :session-id (session-id session))
                             :input (%make-input cell)
                             :session session :sessions-dir sessions-dir
                             :project-dir project-dir :designator designator
                             :cwd cwd :settings settings :providers providers :env env
                             :agent agent :sources sources
                             :max-turns (or (settings-max-turns settings) +default-max-turns+)
                             :prompt (invocation-prompt invocation)
                             :event-backend event-backend :event-loop event-loop
                             :http-backend http-protocol:*http-backend*
                             :event-maker http-backend-async:*event-backend-maker*
                             :mode mode
                             :data-dir data-dir
                             :user-config-dir config
                             :viewport (make-instance 'w:viewport :follow t :wrap nil)
                             :spinner (make-instance 'w:spinner
                                                     :active nil
                                                     :label "Working… (Esc to interrupt)")
                             :status (make-instance 'w:status-line
                                                    :style (w:text-run-style
                                                            (w:text-run "" :inverse t))))))
                     (setf (car cell) program)
                     ;; A resumed session: its transcript and its prompts.
                     (setf (state-transcript (code-program-state program))
                           (session-entries session)
                           (w:text-input-history (code-program-input program))
                           (mapcar #'record-prompt (session-records session)))
                     program))))
           (setf done t)
           program)
      (unless done
        (when (second sources)
          (tools:close-shell-tools (second sources)))
        (event:close-event-loop event-backend event-loop)))))

;;; The agent thread: the program's event loop and everything on it.

(defun %send (program message)
  "Send MESSAGE to the program's TUI (from any thread)."
  (let ((run (%cp-tui program)))
    (when run
      (tui:tui-send message run))))

(defun %message-text (condition)
  (handler-case (princ-to-string condition)
    (error () (format nil "~a" (type-of condition)))))

(defun %on-loop (program function)
  "Run FUNCTION on the agent thread, after the work posted before it. An error
in it becomes an :error message."
  (unless (%cp-closed program)
    (event:wake-call (%cp-event-backend program) (%cp-event-loop program)
                     (lambda ()
                       (handler-case (funcall function)
                         (error (e) (%send program (list :error (%message-text e)))))))))

(defun %agent-thread-main (program)
  (let* ((null-stream (make-broadcast-stream))
         (*standard-output* null-stream)
         (*error-output* null-stream)
         (*trace-output* null-stream)
         (event:*event-backend* (%cp-event-backend program))
         (event:*event-loop* (%cp-event-loop program))
         (http-protocol:*http-backend*
           (or (%cp-http-backend program) (http-backend-async:make-async-backend)))
         (http-backend-async:*event-backend-maker*
           (or (%cp-event-maker program) #'event-backend-libuv:make-libuv-backend))
         (agent:*off-loop-specials*
           (union '(http-protocol:*http-backend* http-backend-async:*event-backend-maker*)
                  agent:*off-loop-specials*)))
    (handler-bind ((agent:agent-approval-required
                     (lambda (c)
                       ;; Only bypassPermissions answers; otherwise the run pauses.
                       (when (eq (%cp-mode program) :bypass-permissions)
                         (agent:invoke-approve c))))
                   (warning
                     (lambda (w)
                       (%send program (list :notice (%message-text w)))
                       (muffle-warning w))))
      (loop until (%cp-stopping program)
            do (handler-case
                   (event:run (%cp-event-backend program) (%cp-event-loop program)
                              :stop-when-idle nil)
                 (error (e)
                   (%send program (list :error (%message-text e)))
                   (return)))))))

(defun %proposed (run)
  (remove :proposed (agent:agent-run-invocations run)
          :key #'agent:agent-invocation-status :test-not #'eq))

(defun %refresh-files (program)
  "Read the @-completion list again (loop thread) and send it to the UI."
  (let ((files (handler-case (project-files (%cp-cwd program))
                 (error () nil))))
    (when files
      (%send program (list :%cp-files files)))))

(defun %end-steering (program run)
  "A terminal turn end: steering not taken stays with the core (it becomes a
follow-up or goes back to the input), so the run must not take it later."
  (when run
    ;; Atomic with AGENT-RUN-POST (ai-agent-protocol 0.14, #33): CONTINUE
    ;; would deliver what is left, and the core already sends it.
    (agent:drain-agent-run-inbox run))
  (setf (%cp-posted program) '()))

(defun %commit-run (program run finish)
  "Loop thread: commit RUN's turns since the last commit as one turn record,
before the turn end reaches the UI. A conflict forks the session; any other
error is an (:error M) and the turns go into the next commit."
  (let* ((committed (%cp-committed program))
         (new (remove-if (lambda (turn)
                           (or (eq :system (llm:llm-turn-role turn)) (gethash turn committed)))
                         (agent:agent-run-turns run))))
    (when new
      (handler-case
          (let ((old (%cp-session program))
                (record (make-turn-record :prompt (%cp-turn-prompt program)
                                          :turns new
                                          :finish finish
                                          :model (%cp-designator program)
                                          :permission-mode (or (%cp-mode program) :default)
                                          :usage (copy-list (%cp-turn-usage program))
                                          :steering (copy-list (%cp-turn-steering program))
                                          :plan (let ((plan (%cp-plan program)))
                                                  (and plan (%cp-turn-plan program)
                                                       (plan-record plan))))))
            (multiple-value-bind (revision store) (%commit-forking old record)
              (declare (ignore revision))
              (dolist (turn new) (setf (gethash turn committed) t))
              (setf (%cp-turn-usage program) (list 0 0 0 0)
                    (%cp-turn-steering program) '())
              (unless (eq store old)
                (setf (%cp-session program) store)
                (%send program (list :session (session-id store)))
                (%send program (list :notice (format nil "session ~a changed in another process; continuing as session ~a"
                                                     (session-id old) (session-id store)))))))
        (error (e) (%send program (list :error (%message-text e))))))))

(defun %turn-callback (program)
  (lambda (run)
    (%refresh-files program)
    (let ((reason (agent:agent-run-finish-reason run)))
      (unless (member reason '(:approval :deferred))
        (%end-steering program run)
        (%commit-run program run (case reason
                                   (:max-steps :max-steps)
                                   (:canceled :canceled)
                                   (t :stop))))
      (%send program
             (case reason
               ((:approval :deferred)
                (let ((pending (%proposed run)))
                  (dolist (inv pending)
                    (%send program (list :invocation inv)))
                  (list :turn-end :reason :approval :pending pending)))
               (:max-steps
                (list :turn-end :reason :max-steps
                      :message (format nil "reached max turns (~d)" (%cp-max-turns program))))
               (:canceled (list :turn-end :reason :canceled))
               (t (list :turn-end :reason :stop))))
      ;; H5a: the projection follows the turn end of a plan turn.
      (when (and (%cp-turn-plan program) (member reason '(:stop :max-steps)))
        (%plan-turn-end program)))))

(defun %turn-error-callback (program)
  (lambda (condition)
    (%refresh-files program)
    (let ((run (%cp-run program)))
      (%end-steering program run)
      (when run
        (%commit-run program run :failed)))
    (%send program (list :turn-end :reason :failed :message (%message-text condition)))))

(defun %on-inbox (program turns)
  "The run took TURNS from its inbox: the steering among them, as typed."
  (let ((texts '()))
    (dolist (turn turns)
      (let ((entry (assoc turn (%cp-posted program) :test #'eq)))
        (when entry
          (push (cdr entry) texts)
          (setf (%cp-posted program) (remove entry (%cp-posted program) :test #'eq)))))
    (when texts
      (setf texts (nreverse texts)
            (%cp-turn-steering program) (append (%cp-turn-steering program) texts))
      (%send program (list :steered texts)))))

(defun %program-agent-event (program)
  (lambda (kind payload)
    (handler-case
        (case kind
          (:started (setf (%cp-run program) payload))
          (:part (when (and (llm:llm-text-part-p payload)
                            (plusp (length (llm:llm-text-part-text payload))))
                   (%send program (list :part (llm:llm-text-part-text payload)))))
          (:response (let ((counts (%usage-counts (llm:llm-response-usage payload))))
                       (setf (%cp-turn-usage program)
                             (mapcar #'+ (%cp-turn-usage program) counts))
                       (%send program (list :usage counts))))
          (:inbox (%on-inbox program payload))
          (:invocation (%send program (list :invocation payload))))
      (error (e) (%send program (list :error (%message-text e)))))))

(defun %loop-start-turn (program text)
  "Loop thread: send TEXT (mentions expanded) as the next user message. A new
run starts on the session's conversation."
  (let ((ok (%turn-callback program))
        (err (%turn-error-callback program)))
    (setf (%cp-turn-prompt program) text)
    (handler-case
        (let* ((root (progn
                       ;; H5a: plan mode opens (or reopens) the plan first;
                       ;; mentions then read the area.
                       (when (eq :plan (%cp-mode program))
                         (%ensure-plan program))
                       (setf (%cp-turn-plan program) (and (%cp-plan program) t))
                       (if (%cp-plan program)
                           (plan-tool-root (%cp-plan program) (%cp-cwd program))
                           (%cp-cwd program))))
               (prompt (expand-mentions text root))
               (run (%cp-run program)))
          (setf (%cp-handle program)
                (if run
                    (agent:continue-ai-agent-async run prompt
                                                   :callback ok :error-callback err)
                    (let ((history (session-turns (%cp-session program)))
                          (committed (make-hash-table :test 'eq)))
                      (dolist (turn history) (setf (gethash turn committed) t))
                      (setf (%cp-committed program) committed
                            (%cp-turn-usage program) (list 0 0 0 0)
                            (%cp-turn-steering program) '())
                      (agent:run-ai-agent-async (%cp-agent program)
                                                (append history (list (llm:user-turn prompt)))
                                                :on-event (%program-agent-event program)
                                                :callback ok :error-callback err)))))
      (error (e) (funcall err e)))))

(defun %proposed-p (inv)
  (eq :proposed (agent:agent-invocation-status inv)))

(defun %approve (program inv always)
  (let ((run (%cp-run program)))
    (when (and run (%proposed-p inv))
      (handler-case (agent:approve-invocation run inv :always always)
        (settings-error (e)
          ;; The rule could not be saved; the user still said yes.
          (%send program (list :error (%message-text e)))
          (when (%proposed-p inv)
            (agent:approve-invocation run inv)))))))

(defun %deny (program inv feedback all)
  (let ((run (%cp-run program)))
    (when (and run (%proposed-p inv))
      (agent:deny-invocation run inv :feedback (and feedback (plusp (length feedback)) feedback)
                                     :all all))))

(defun %maybe-resume (program)
  (let ((run (%cp-run program)))
    (when (and run
               (member (agent:agent-run-finish-reason run) '(:approval :deferred))
               (notany #'%proposed-p (agent:agent-run-invocations run)))
      (let ((err (%turn-error-callback program)))
        (handler-case
            (setf (%cp-handle program)
                  (agent:resume-ai-agent-async run :callback (%turn-callback program)
                                                   :error-callback err))
          (error (e) (funcall err e)))))))

(defun %cancel (program)
  (let ((handle (%cp-handle program)))
    (when handle
      (agent:cancel-agent-run handle))))

(defun %set-model (program designator)
  (handler-case
      (multiple-value-bind (backend name model)
          (resolve-model designator :providers (%cp-providers program) :env (%cp-env program))
        (declare (ignore name))
        (let ((agent (%cp-agent program)))
          (setf (agent:ai-agent-backend agent) backend
                (agent:ai-agent-model agent) model
                (%cp-designator program) designator))
        (%send program (list :model-set designator)))
    (model-not-found (c)
      (%send program (list :error (%message-text c))))))

(defun %set-permission-mode (program mode)
  (let* ((settings (merge-settings (%cp-settings program) (make-settings :permission-mode mode)))
         (agent (%cp-agent program))
         (agent-settings (agent:ai-agent-settings agent)))
    (setf (%cp-mode program) mode
          (agent:ai-agent-permissions agent) (%agent-permissions settings)
          (getf (agent:agent-settings-extra agent-settings) :permission-policy)
          ;; The run's settings are this object (RUN-AI-AGENT-ASYNC without
          ;; :settings uses the agent's), read on every permission check.
          (settings-permission-policy settings))))

;;; H3c session effects (loop thread).

(defun %steer (program text)
  "Post TEXT (mentions expanded) into the running turn, when it still runs."
  (let ((run (%cp-run program)))
    (when (and run (member (agent:agent-run-finish-reason run) '(nil :approval :deferred)))
      (let ((turn (llm:user-turn (expand-mentions text (%cp-cwd program)))))
        (setf (%cp-posted program) (append (%cp-posted program) (list (cons turn text))))
        (agent:agent-run-post run turn)))))

(defun %drop-run (program)
  (setf (%cp-run program) nil
        (%cp-handle program) nil))

(defun %session-reset (program &rest keys)
  (%send program (list* :session-reset :entries (session-entries (%cp-session program)) keys)))

(defun %fork (program at)
  (let* ((session (%cp-session program))
         (revision (if at
                       (resolve-turn session at)
                       (or (session-head session)
                           (error 'session-turn-not-found :session (session-id session)))))
         (id (rev:revision-id revision)))
    (multiple-value-bind (head prompt) (fork-turn session id)
      (declare (ignore head))
      (%drop-run program)
      (%session-reset program :input prompt
                              :notice (format nil "forked before turn ~a: edit the message and press Enter"
                                              (subseq id 0 (min 8 (length id))))))))

(defun %rewind (program n)
  (rewind-session (%cp-session program) n)
  (%drop-run program)
  (%session-reset program :notice (format nil "rewound ~d turn~:p" n)))

(defun %clone (program)
  (let* ((old (%cp-session program))
         (new (clone-session old)))
    (setf (%cp-session program) new)
    (%send program (list :session (session-id new)))
    (%send program (list :notice (format nil "cloned session ~a as ~a"
                                         (session-id old) (session-id new))))))

(defun %export (program file)
  (let* ((path (uiop:merge-pathnames* (uiop:parse-native-namestring file) (%cp-cwd program)))
         (format (if (string-equal "json" (pathname-type path)) :json :markdown))
         (n 0)
         (text (with-output-to-string (s)
                 (setf n (export-session (%cp-session program) s :format format)))))
    (p:write-text path text :atomic t)
    (%send program (list :notice (format nil "exported ~d turn~:p to ~a"
                                         n (uiop:native-namestring path))))))

(defun %new-session (program)
  (%drop-run program)
  (let ((session (create-session (%cp-sessions-dir program)
                                 :project-dir (%cp-project-dir program))))
    (setf (%cp-session program) session)
    (%send program (list :session (session-id session)))))

;;; Effects (UI thread).

(defun %run-effect (program effect)
  (destructuring-bind (kind &rest args) effect
    (ecase kind
      (:run (setf (%cp-interrupted program) nil)
       (%on-loop program (lambda () (%loop-start-turn program (first args)))))
      (:cancel (setf (%cp-interrupted program) t)
       (%on-loop program (lambda () (%cancel program))))
      (:approve (destructuring-bind (inv &key always) args
                  (%on-loop program (lambda () (%approve program inv always)))))
      (:deny (destructuring-bind (inv &key feedback all) args
               (%on-loop program (lambda () (%deny program inv feedback all)))))
      (:resume (%on-loop program (lambda () (%maybe-resume program))))
      (:restore-input (setf (w:text-input-value (code-program-input program)) (first args)))
      (:new-conversation (%on-loop program (lambda () (%new-session program))))
      (:set-model (let ((designator (first args)))
                    (%on-loop program (lambda () (%set-model program designator)))))
      (:set-permission-mode (let ((mode (first args)))
                              (%on-loop program
                                        (lambda () (%set-permission-mode program mode)))))
      (:steer (let ((text (first args)))
                (%on-loop program (lambda () (%steer program text)))))
      (:tree (let ((width (%cp-width program)))
               (%on-loop program
                         (lambda ()
                           (%send program
                                  (list :notice
                                        (format nil "~{~a~^~%~}"
                                                (session-tree-lines (%cp-session program)
                                                                    :width width))))))))
      (:fork (let ((at (first args)))
               (%on-loop program (lambda () (%fork program at)))))
      (:rewind (destructuring-bind (n &key (parts nil parts-p) on-drift) args
                 (if parts-p
                     ;; H5b
                     (%on-loop program (lambda () (%rewind-parts-effect program n parts on-drift)))
                     (%on-loop program (lambda () (%rewind program n))))))
      (:checkpoints (%on-loop program (lambda () (%checkpoints-effect program))))
      (:clone (%on-loop program (lambda () (%clone program))))
      (:export (let ((file (first args)))
                 (%on-loop program (lambda () (%export program file)))))
      ;; H5a
      (:show-plan (%on-loop program (lambda () (%show-plan program))))
      (:approve-plan (destructuring-bind (&key on-drift) args
                       (%on-loop program (lambda () (%approve-plan-effect program on-drift)))))
      (:reject-plan (%on-loop program (lambda () (%reject-plan-effect program))))
      (:quit nil))))

(defun %interrupt-wins (program event)
  "EVENT, except that a turn end the user already interrupted is :canceled: an
Esc that raced the model's last answer still interrupts the turn (the queue
goes back to the input)."
  (if (and (eq :turn-end (first event))
           (%cp-interrupted program)
           (member (getf (rest event) :reason) '(:stop :max-steps)))
      (list :turn-end :reason :canceled)
      event))

(defun %apply-event (program event)
  "Feed EVENT to the core and carry out its effects. → NIL."
  (when (eq :turn-end (first event))
    (setf event (%interrupt-wins program event))
    (unless (eq :approval (getf (rest event) :reason))
      (setf (%cp-interrupted program) nil)))
  (multiple-value-bind (state effects) (interactive-update (code-program-state program) event)
    (declare (ignore state))
    (incf (%cp-generation program))
    (dolist (effect effects)
      (%run-effect program effect)))
  nil)

(defun %sync-widgets (program)
  "Make the dialog, focus and spinner match the state. → a command or NIL."
  (let* ((state (code-program-state program))
         (input (code-program-input program))
         (approvals (state-approvals state))
         (spinner (%cp-spinner program)))
    (cond ((and (null approvals) (state-plan-prompt state))
           ;; H5a: the plan or drift dialog.
           (%sync-plan-dialog program))
          ((null approvals)
           (setf (code-program-dialog program) nil
                 (%cp-dialog-invocation program) nil
                 (w:widget-focused-p input) t))
          ((not (eq (first approvals) (%cp-dialog-invocation program)))
           (let* ((n (length (%state-pending state)))
                  (i (1+ (- n (length approvals)))))
             (setf (code-program-dialog program)
                   (make-instance 'w:confirm-dialog
                                  :title (if (> n 1)
                                             (format nil "Permission (~d of ~d)" i n)
                                             "Permission")
                                  :message (approval-message (%cp-cwd program) (first approvals))
                                  :choices +approval-choices+
                                  :feedback-choice :reject)
                   (%cp-dialog-invocation program) (first approvals)
                   (w:widget-focused-p input) nil))))
    (cond ((and (state-busy-p state) (not (w:spinner-active-p spinner)))
           (w:spinner-start spinner))
          ((and (not (state-busy-p state)) (w:spinner-active-p spinner))
           (w:spinner-stop spinner))
          (t nil))))

(defun %commands (&rest commands)
  (let ((commands (remove nil commands)))
    (cond ((null commands) nil)
          ((null (rest commands)) (first commands))
          (t (apply #'tui:batch commands)))))

(defmethod tui:tui-init ((program code-program))
  (setf (%cp-tui program) tui:*tui*
        (%cp-files program) (handler-case (project-files (%cp-cwd program))
                           (error () '())))
  (setf (%cp-thread program)
        (bt:make-thread (lambda () (%agent-thread-main program))
                        :name "cl-stack-code agent"))
  (let ((prompt (%cp-prompt program)))
    (when prompt
      (%apply-event program (list :submit prompt))))
  (values program (%sync-widgets program)))

(defun %key-event (program message)
  "A key MESSAGE. → a command or NIL."
  (let* ((key (tui:key-message-key message))
         (ctrl (member :ctrl (tui:key-message-modifiers message)))
         (state (code-program-state program))
         (input (code-program-input program))
         (dialog (code-program-dialog program)))
    (cond
      ((eq :release (tui:key-message-action message)) nil)
      ((and ctrl (eq key :c))
       (cond ((state-busy-p state) (%apply-event program '(:interrupt)))
             ((plusp (length (w:text-input-value input)))
              (setf (w:text-input-value input) "")
              nil)
             (t (%apply-event program '(:quit)))))
      ((and ctrl (eq key :d))
       (when (and (null dialog) (string= "" (w:text-input-value input)))
         (%apply-event program '(:quit))))
      ((and ctrl (eq key :t) (null dialog))
       ;; Steering: the input's value goes into the running turn (idle: as Enter).
       (let ((text (w:text-input-value input)))
         (unless (%blank-text-p text)
           (unless (equal text (car (last (w:text-input-history input))))
             (setf (w:text-input-history input)
                   (append (w:text-input-history input) (list text))))
           (setf (w:text-input-value input) "")
           (%apply-event program (list :steer text))))
       nil)
      ((member key '(:page-up :page-down))
       (w:widget-update (%cp-viewport program) message)
       nil)
      (dialog
       (multiple-value-bind (widget command event) (w:widget-update dialog message)
         (declare (ignore widget))
         (cond ((w:confirm-event-p event)
                (%apply-event program (list :reply (w:confirm-event-choice event)
                                            (w:confirm-event-feedback event)))
                command)
               ((w:cancel-event-p event)
                (%apply-event program '(:interrupt))
                command)
               (t command))))
      (t
       (multiple-value-bind (widget command event) (w:widget-update input message)
         (declare (ignore widget))
         (cond ((w:submit-event-p event)
                (%apply-event program (list :submit (w:submit-event-text event)))
                command)
               ((w:cancel-event-p event)
                (%apply-event program '(:interrupt))
                command)
               (t command)))))))

(defmethod tui:tui-update ((program code-program) model message)
  (let ((command
          (cond ((consp message)
                 (if (eq :%cp-files (first message))
                     (progn (when (second message)
                              (setf (%cp-files program) (second message)))
                            nil)
                     (%apply-event program message)))
                ((tui:key-message-p message) (%key-event program message))
                ((tui:mouse-message-p message)
                 (w:widget-update (%cp-viewport program) message)
                 nil)
                ((tui:paste-message-p message)
                 (nth-value 1 (w:widget-update (or (code-program-dialog program)
                                                   (code-program-input program))
                                               message)))
                ((tui:tick-message-p message)
                 (nth-value 1 (w:widget-update (%cp-spinner program) message)))
                (t nil))))
    (let ((sync (%sync-widgets program)))
      (values model
              (if (state-quit-p (code-program-state program))
                  :quit
                  (%commands command sync))))))

;;; The view.

(defun %input-rows (input width)
  "Rows the text input draws its text in at WIDTH (as its view wraps)."
  (let ((tw (max 1 (- width (w:runs-width (w:text-input-prompt input))))))
    (multiple-value-bind (crow ccol) (w:text-input-cursor input)
      (loop for line in (w:text-input-lines input)
            for i from 0
            sum (let* ((cells (w:runs-width line))
                       (rows (max 1 (ceiling cells tw))))
                  (if (and (= i crow) (= ccol (length line)) (plusp cells) (zerop (mod cells tw)))
                      (1+ rows)
                      rows))))))

(defun %menu-rows (input)
  (if (w:text-input-completing-p input)
      (min (length (w:text-input-completion-candidates input))
           (w:text-input-completion-max-items input))
      0))

(defun %dialog-rows (dialog width)
  (+ 7
     (length (w:wrap-runs (w:confirm-dialog-message dialog) (max 1 (- width 4))))
     ;; The feedback prompt and its input row.
     (if (eq :feedback (w:confirm-dialog-mode dialog)) 2 0)))

(defun %first-line (text)
  (subseq text 0 (or (position #\Newline text) (length text))))

(defun %queued-rows (state)
  (let* ((queue (state-queue state))
         (shown (subseq queue 0 (min 3 (length queue))))
         (more (- (length queue) (length shown))))
    (append (mapcar (lambda (text) (format nil "  queued: ~a" (%first-line text))) shown)
            (when (plusp more)
              (list (format nil "  … +~d queued" more))))))

(defun %steering-rows (state)
  (let* ((steering (state-steering state))
         (shown (subseq steering 0 (min 3 (length steering))))
         (more (- (length steering) (length shown))))
    (append (mapcar (lambda (text) (format nil "  steering: ~a" (%first-line text))) shown)
            (when (plusp more)
              (list (format nil "  … +~d steering" more))))))

(defun %viewport-lines (program width)
  "Give the viewport the transcript lines for WIDTH when they changed."
  (let* ((state (code-program-state program))
         (key (list (%cp-generation program) width (state-busy-p state))))
    (unless (equal key (%cp-lines-key program))
      (setf (w:viewport-lines (%cp-viewport program))
            (transcript-lines (state-transcript state) width
                              :streaming (state-busy-p state))
            (%cp-lines-key program) key))))

(defmethod tui:tui-view ((program code-program) model canvas)
  (declare (ignore model))
  (let* ((width (tui:canvas-cols canvas))
         (height (tui:canvas-rows canvas))
         (state (code-program-state program))
         (busy (state-busy-p state))
         (dialog (code-program-dialog program))
         (input (code-program-input program))
         (status (%cp-status program))
         (bottom (max 0 (if dialog
                            (min (- height 2) (%dialog-rows dialog width))
                            (min 8 (+ (%input-rows input width) (%menu-rows input))))))
         (bottom-y (- height 1 bottom))
         (rule-y (1- bottom-y))
         (extra (if (and busy (not dialog))
                    (append (%steering-rows state) (%queued-rows state))
                    '()))
         (spinner-y (and busy (not dialog) (1- rule-y)))
         (top (max 0 (- rule-y (if spinner-y 1 0) (length extra)))))
    (when (or (zerop width) (zerop height))
      (return-from tui:tui-view nil))
    (setf (%cp-width program) width)
    (multiple-value-bind (left right) (status-line-text state width)
      (setf (w:status-line-left status) left
            (w:status-line-right status) right))
    (w:widget-view status (tui:sub-canvas canvas 0 (1- height) width 1))
    (when (plusp bottom)
      (w:widget-view (or dialog input) (tui:sub-canvas canvas 0 bottom-y width bottom)))
    (when (>= rule-y 0)
      (tui:draw-text canvas 0 rule-y (make-string width :initial-element #\─)))
    (when (and spinner-y (>= spinner-y 0))
      (w:widget-view (%cp-spinner program) (tui:sub-canvas canvas 0 spinner-y width 1))
      (loop for row in extra
            for y from (- spinner-y (length extra))
            when (>= y 0)
              do (tui:draw-text canvas 0 y row)))
    (%viewport-lines program width)
    (w:widget-view (%cp-viewport program) (tui:sub-canvas canvas 0 0 width top))))

;;; Closing.

(defun %join-thread (thread seconds)
  "Wait up to SECONDS for THREAD to end. → true when it ended."
  (let ((deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop while (and (bt:thread-alive-p thread) (< (get-internal-real-time) deadline))
          do (sleep 0.01))
    (not (bt:thread-alive-p thread))))

(defun close-code-program (program)
  "Close PROGRAM's shell tools and event loop. Idempotent. → NIL."
  (unless (%cp-closed program)
    (setf (%cp-stopping program) t)
    (let* ((thread (%cp-thread program))
           (eb (%cp-event-backend program))
           (el (%cp-event-loop program))
           (ended (or (null thread)
                      (progn
                        (when (bt:thread-alive-p thread)
                          (event:wake-call eb el (lambda ()
                                                   (%cancel program)
                                                   (event:stop eb el))))
                        (%join-thread thread 10)))))
      (setf (%cp-closed program) t)
      (let ((shell (second (%cp-sources program))))
        (when shell
          (tools:close-shell-tools shell)))
      ;; H5a: the plan's area tools, when a plan is open.
      (let ((shell (second (%cp-plan-sources program))))
        (when shell
          (tools:close-shell-tools shell)))
      ;; Never free a loop a thread may still run (CLOSE-EVENT-LOOP: "once RUN
      ;; has returned").
      (when ended
        (event:close-event-loop eb el))))
  nil)

(defun %run-interactive (inv &key output input providers user-config-dir getenv data-dir)
  "RUN-CLI without -p (see the file header). → exit code."
  (when (invocation-output-format-given-p inv)
    (error 'code-usage-error
           :message "--output-format needs -p (--print): the interactive mode has no output format"))
  (let ((program (make-code-program inv :providers providers :user-config-dir user-config-dir
                                        :getenv (or getenv #'uiop:getenv)
                                        :data-dir data-dir)))
    (unwind-protect
         (progn
           (unless (and (eq input *standard-input*)
                        (eq output *standard-output*)
                        (tty:tty-available-p))
             (error 'code-usage-error
                    :message "the interactive mode needs a terminal on standard input and output; use -p PROMPT for a headless run"))
           (handler-case (tui:run-tui program :backend (tty:make-tty-backend) :mouse t)
             (tty:tty-not-a-terminal (e)
               (error 'code-usage-error
                      :message (format nil "~a; the interactive mode needs a terminal: use -p PROMPT for a headless run" e))))
           0)
      (close-code-program program))))

;;; H5a: plans (see the file header). Loop thread unless said otherwise.

(defun %program-data-dir (program)
  "The data directory the program's sessions live under (<data>/sessions/<key>/)."
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname
    (uiop:ensure-directory-pathname (%cp-sessions-dir program)))))

(defun %ensure-plan (program)
  "Open or reopen the plan when none is open; swap the agent's tools and
instructions to the area and drop the run; send (:plan-opened …)."
  (unless (%cp-plan program)
    (let* ((cwd (%cp-cwd program))
           (data-dir (%program-data-dir program))
           (session (%cp-session program))
           (entry (%head-plan-entry session))
           (plan (or (and entry (eq :open (getf entry :status))
                          (handler-case (reopen-plan (plans-directory cwd :data-dir data-dir)
                                                     (getf entry :id))
                            (plan-not-found () nil)))
                     (open-plan (%cp-project-dir program) :kind :auto :data-dir data-dir
                                                          :session-id (session-id session))))
           (agent (%cp-agent program))
           (settings (merge-settings (%cp-settings program)
                                     (make-settings :permission-mode :plan)))
           (sources (make-code-tools (plan-tool-root plan cwd) :settings settings)))
      (handler-bind ((error (lambda (e)
                              (declare (ignore e))
                              (when (second sources)
                                (tools:close-shell-tools (second sources))))))
        (let* ((offered (loop for source in sources
                              append (mapcar #'llm:llm-tool-name
                                             (agent:list-agent-tools source))))
               (instructions (assemble-system-prompt
                              cwd :tools offered :backend (agent:ai-agent-backend agent)
                                  :settings settings
                                  :user-config-dir (%cp-user-config-dir program)
                                  :plan plan)))
          (setf (%cp-cwd-instructions program) (agent:ai-agent-instructions agent)
                (agent:ai-agent-tools agent) sources
                (agent:ai-agent-instructions agent) instructions
                (%cp-plan program) plan
                (%cp-plan-sources program) sources)))
      (%drop-run program)
      (%send program (list :plan-opened :id (plan-id plan) :kind (plan-kind plan)
                                        :root (uiop:native-namestring (plan-root plan)))))))

(defun %restore-cwd-agent (program)
  "The plan closed: the agent gets the working directory's tools and
instructions back, the run is dropped."
  (let ((agent (%cp-agent program))
        (sources (%cp-plan-sources program)))
    (setf (agent:ai-agent-tools agent) (%cp-sources program))
    (when (%cp-cwd-instructions program)
      (setf (agent:ai-agent-instructions agent) (%cp-cwd-instructions program)))
    (setf (%cp-plan program) nil
          (%cp-plan-sources program) nil
          (%cp-turn-plan program) nil)
    (when (second sources)
      (tools:close-shell-tools (second sources)))
    (%drop-run program)))

(defun %plan-turn-end (program)
  "Send (:plan-projected …) for the open plan."
  (let ((plan (%cp-plan program)))
    (when plan
      (%send program (list :plan-projected :id (plan-id plan)
                                           :changes (plan-changes plan)
                                           :diff (plan-diff-text plan))))))

(defun %show-plan (program)
  (if (%cp-plan program)
      (%plan-turn-end program)
      (%send program (list :error "no open plan"))))

(defun %approve-plan-effect (program on-drift)
  (let ((plan (%cp-plan program))
        (drifted nil))
    (unless plan
      (%send program (list :error "no open plan"))
      (return-from %approve-plan-effect nil))
    (multiple-value-bind (result status)
        (handler-bind ((plan-drift
                         (lambda (c)
                           (if on-drift
                               (invoke-restart (find-restart (ecase on-drift
                                                               (:rebase 'rebase-plan)
                                                               (:overwrite 'overwrite-plan))
                                                             c))
                               (progn
                                 (setf drifted t
                                       (%cp-drift-paths program) (plan-drift-paths c))
                                 (%send program (list :plan-drift :paths (plan-drift-paths c)))
                                 (invoke-restart (find-restart 'abort-approval c)))))))
          (approve-plan plan))
      (unless (and drifted (eq status :aborted))
        (%send program (list* :plan-closed :status status
                              (case status
                                (:applied (list :changes result))
                                (:rebased (list :conflicts result))
                                (t '())))))
      (case status
        (:rebased (%plan-turn-end program))
        ((:applied :empty) (%restore-cwd-agent program))))))

(defun %reject-plan-effect (program)
  (let ((plan (%cp-plan program)))
    (cond ((null plan) (%send program (list :error "no open plan")))
          (t (reject-plan plan)
             (%send program (list :plan-closed :status :discarded))
             (%restore-cwd-agent program)))))

(defun %sync-plan-dialog (program)
  "UI thread: make CODE-PROGRAM-DIALOG the plan or drift dialog of
STATE-PLAN-PROMPT (made once per prompt), focus it. → NIL."
  (let* ((state (code-program-state program))
         (prompt (state-plan-prompt state))
         (plan (state-plan state))
         (id (or (getf plan :id) ""))
         (id8 (subseq id 0 (min 8 (length id))))
         (key (list :plan-dialog prompt id)))
    (unless (equal key (%cp-dialog-invocation program))
      (setf (code-program-dialog program)
            (ecase prompt
              (:plan
               (make-instance 'w:confirm-dialog
                              :title (format nil "Plan ~a" id8)
                              :message (format nil "~d file~:p changed. Approve to apply them to the project."
                                               (length (getf plan :changes)))
                              :choices +plan-choices+))
              (:drift
               (make-instance 'w:confirm-dialog
                              :title (format nil "Plan ~a: the working copy changed" id8)
                              :message (format nil "Changed in both: ~{~a~^, ~}"
                                               (%cp-drift-paths program))
                              :choices +drift-choices+)))
            (%cp-dialog-invocation program) key))
    (setf (w:widget-focused-p (code-program-input program)) nil)
    nil))

;;; H5b: checkpoints and rewind (see the "H5b" part of the file header).

(defun %checkpoints-effect (program)
  "(:checkpoints): send the /checkpoints notice."
  (declare (ignore program))
  (%not-implemented '%checkpoints-effect))

(defun %rewind-parts-effect (program n parts on-drift)
  "(:rewind N :parts PARTS :on-drift M): REWIND-TO and its answers."
  (declare (ignore program n parts on-drift))
  (%not-implemented '%rewind-parts-effect))
