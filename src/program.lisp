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
;;;
;;; H4b: the Lisp image (src/lisp-image.lisp; left to the implementation).
;;;   Start            With SETTINGS-LISP-IMAGE non-NIL, MAKE-CODE-PROGRAM
;;;                    runs CHECK-LISP-IMAGE-SETTINGS; with the image on it
;;;                    makes the three sources (MAKE-CODE-TOOLS, the lisp
;;;                    tools' :ON-IMAGE-EVENT sending IMAGE-EVENT-MESSAGE with
;;;                    TUI-SEND once the TUI runs; events before that are
;;;                    sent at TUI-INIT), runs START-LISP-IMAGE, adds the
;;;                    system prompt section, and gives the state
;;;                    LISP-IMAGE-STATE. All before the terminal is touched
;;;                    (CODE-USAGE-ERROR, LISP-IMAGE-ERROR).
;;;   Effects          (:post-image-events) → POST-IMAGE-EVENTS into the run
;;;                    on the agent thread while it is going.
;;;                    (:image-turn) → TAKE-IMAGE-EVENTS; none → (:turn-end
;;;                    :reason :stop); else a turn (as :run does, without
;;;                    EXPAND-MENTIONS) whose message is the first event's
;;;                    turn, the others posted right after; its record's
;;;                    prompt is the first event's text. Every :run posts the
;;;                    queued events right after starting its turn.
;;;   Turn ends        After a :turn-end that leaves the program idle, the
;;;                    queued events' count goes out as (:image-pending N)
;;;                    when it is > 0.
;;;   Layout           IMAGE-BANNER-TEXT, when non-NIL, is one row directly
;;;                    above the "─" rule (below the queued, steering and
;;;                    spinner rows), cut to the width.
;;;   Close            CLOSE-CODE-PROGRAM also runs CLOSE-LISP-TOOLS (a
;;;                    spawned image is killed, an attached one keeps
;;;                    running).
;;;
;;; H8d: units (src/units.lisp, src/unit-panel.lisp; left to the
;;; implementation).
;;;   Start            MAKE-CODE-PROGRAM makes the supervisor
;;;                    (MAKE-CODE-SUPERVISOR on the working directory and
;;;                    the program's data directory) before the tools, passes
;;;                    it to MAKE-CODE-TOOLS (and to the plan area's tools,
;;;                    under an :agent scope "plan-<id8>"), and sets
;;;                    CODE-PROGRAM-SUPERVISOR and CODE-PROGRAM-UNIT-TOOLS
;;;                    (CODE-UNIT-TOOLS of the working directory's sources).
;;;                    A configuration error after it was made shuts it down
;;;                    (nothing stays open, as before).
;;;   TUI-INIT         SUP:SUBSCRIBE from the current seq; each event goes to
;;;                    the UI with TUI-SEND, where the core gets (:units
;;;                    :running N) and, for UNIT-FAILURE-NOTICE, (:unit-failed
;;;                    :notice TEXT); the panel redraws when open.
;;;   Effects          (:units-panel) opens the panel (src/unit-panel.lisp).
;;;   Keys             Ctrl-P (+UNIT-PANEL-KEY+) opens or closes the panel
;;;                    when no dialog is shown; while it is open every key
;;;                    goes to it (file header of src/unit-panel.lisp), except
;;;                    that an approval dialog, when one appears, takes the
;;;                    keys first (the agent is never left waiting behind the
;;;                    panel).
;;;   Layout           While open, the panel replaces the transcript, the
;;;                    queued / steering / spinner / banner rows and the input
;;;                    (src/unit-panel.lisp); the status line stays.
;;;   Actions          UNIT-ACTION-PERMISSION with the agent, the unit tools
;;;                    and the program's mode; the confirm dialog is a
;;;                    W:CONFIRM-DIALOG titled "Unit control" (+UNIT-ACTION-
;;;                    CHOICES+); TOOLS:CALL-UNIT-TOOL runs on a worker thread
;;;                    and its text comes back with TUI-SEND.
;;;   Close            CLOSE-CODE-PROGRAM ends the subscription and the panel's
;;;                    threads, closes the unit tools and the shell tools, then
;;;                    shuts the supervisor down (units stopped, logs kept).


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
   ;; R4d-4b
   (plan-backend :initarg :plan-backend :initform nil :reader %cp-plan-backend
                 :documentation "PLAN-COMPUTE-BACKEND, resolved by MAKE-CODE-PROGRAM (its thread).")
   (plan-sandbox :initform nil :accessor %cp-plan-sandbox
                 :documentation "Loop thread: the open plan's PLAN-SANDBOX, or NIL.")
   (drift-paths :initform '() :accessor %cp-drift-paths
                :documentation "The paths of the last (:plan-drift …) sent, for the drift dialog.")
   ;; H5b
   (checkpointer :initarg :checkpointer :initform nil :reader %cp-checkpointer
                 :documentation "The CHECKPOINTER, from MAKE-CODE-PROGRAM.")
   (turn-pre :initform nil :accessor %cp-turn-pre
             :documentation "Loop thread: BEGIN-CHECKPOINT-TURN's state for the running turn.")
   ;; H4b
   (image-link :initarg :image-link :initform nil :reader %cp-image-link
               :documentation "The image link (src/lisp-image.lisp) when the image is on, else NIL.")
   ;; H8d (set by MAKE-CODE-PROGRAM; the readers are the API)
   (supervisor :initarg :supervisor :initform nil :accessor code-program-supervisor
               :documentation "The session's SUP:SUPERVISOR (MAKE-CODE-SUPERVISOR).")
   (unit-tools :initarg :unit-tools :initform nil :accessor code-program-unit-tools
               :documentation "The working directory's UNIT-TOOLS source (CODE-UNIT-TOOLS).")
   (panel :initform (make-instance 'unit-panel) :reader code-program-panel
          :documentation "The UNIT-PANEL (UI thread only).")
   (units-state :initform nil :accessor %cp-units-state
                :documentation "The implementation's: subscription, ticker, sampler, unit dialog."))
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
         ;; H4b: the checks, before the session is written.
         (link (when (settings-lisp-image settings)
                 (check-lisp-image-settings settings mode)
                 (and (lisp-image-enabled-p settings) (%make-image-link))))
         (project-dir (or (find-project-root cwd) cwd))
         (session (%session-for-run invocation source sessions-dir project-dir))
         ;; H5b: before the terminal is touched.
         (checkpointer (%make-run-checkpointer settings cwd data-dir getenv))
         (event-backend (event-backend-libuv:make-libuv-backend))
         (event-loop (event:make-event-loop event-backend))
         (supervisor nil)
         (sources nil)
         (done nil))
    (unwind-protect
         (let ((program
                 (let ((event:*event-backend* event-backend)
                       (event:*event-loop* event-loop))
                   ;; H8d: the session's supervisor, before the tools.
                   (setf supervisor (make-code-supervisor cwd :data-dir data-dir :getenv getenv)
                         sources (make-code-tools cwd :settings settings
                                                      :on-image-event (and link (%link-callback link))
                                                      :supervisor supervisor))
                   ;; H4b: the image starts before the terminal is touched; its
                   ;; events wait in the link until TUI-INIT.
                   (when link
                     (setf (%link-tools link) (third sources))
                     (start-lisp-image (third sources) settings))
                   (let* ((offered (loop for source in sources
                                         append (mapcar #'llm:llm-tool-name
                                                        (agent:list-agent-tools source))))
                          (instructions (assemble-system-prompt
                                         cwd :tools offered :backend backend
                                             :settings settings :user-config-dir config
                                             :lisp-image (%sources-lisp-tools sources)))
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
                                     :session-id (session-id session)
                                     :image (lisp-image-state settings))
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
                             :checkpointer checkpointer
                             ;; R4d-4b: here, not on the agent thread.
                             :plan-backend (plan-compute-backend)
                             :image-link link
                             :supervisor supervisor
                             :unit-tools (code-unit-tools sources)
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
        (%link-close link)
        ;; H8d: unit tools, shell tools, then the supervisor.
        (%close-code-units supervisor :unit-tools (list (code-unit-tools sources))
                                      :shell-tools (list (second sources)))
        (close-checkpointer checkpointer)
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
    (handler-bind ((agent:agent-tool-error
                     ;; R4d-4b: a confined bash the backend refused.
                     (%plan-sandbox-refusal-handler
                      (lambda (c) (declare (ignore c)) (%cp-plan-sandbox program))
                      (lambda (notice) (%send program (list :notice notice)))))
                   (agent:agent-approval-required
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
error is an (:error M) and the turns go into the next commit. → (values
revision store), or NIL when nothing was committed."
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
              (dolist (turn new) (setf (gethash turn committed) t))
              (setf (%cp-turn-usage program) (list 0 0 0 0)
                    (%cp-turn-steering program) '())
              (unless (eq store old)
                (setf (%cp-session program) store)
                (%send program (list :session (session-id store)))
                (%send program (list :notice (format nil "session ~a changed in another process; continuing as session ~a"
                                                     (session-id old) (session-id store)))))
              (values revision store)))
        (error (e) (%send program (list :error (%message-text e))))))))

(defun %end-checkpoint-turn (program revision store)
  "H5b, loop thread: END-CHECKPOINT-TURN for the turn just committed as
REVISION in STORE (nothing without a commit). A checkpoint error is an
(:error M); the turn stands."
  (let ((pre (shiftf (%cp-turn-pre program) nil)))
    (when (and pre revision)
      (handler-case (end-checkpoint-turn (%cp-checkpointer program) store pre revision)
        (error (e) (%send program (list :error (%message-text e))))))))

(defun %turn-callback (program)
  (lambda (run)
    (%refresh-files program)
    (let ((reason (agent:agent-run-finish-reason run)))
      (unless (member reason '(:approval :deferred))
        (%end-steering program run)
        (multiple-value-bind (revision store)
            (%commit-run program run (case reason
                                       (:max-steps :max-steps)
                                       (:canceled :canceled)
                                       (t :stop)))
          ;; H5b: before the :turn-end reaches the UI.
          (%end-checkpoint-turn program revision store)))
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
      (multiple-value-bind (revision store) (and run (%commit-run program run :failed))
        (%end-checkpoint-turn program revision store)))
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

(defun %loop-start-turn (program text &key message more)
  "Loop thread: send TEXT (mentions expanded) as the next user message. A new
run starts on the session's conversation. H4b: MESSAGE (an LLM-TURN) is sent
instead, as it is, with TEXT as the record's prompt, and the turns MORE are
posted right after it; then the queued image events are posted."
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
                       ;; H5b: the files before the turn (after the plan).
                       (setf (%cp-turn-pre program)
                             (handler-case (begin-checkpoint-turn (%cp-checkpointer program)
                                                                  (%cp-session program))
                               (error (e)
                                 (%send program (list :error (%message-text e)))
                                 nil)))
                       (if (%cp-plan program)
                           (plan-tool-root (%cp-plan program) (%cp-cwd program))
                           (%cp-cwd program))))
               (prompt (or message (expand-mentions text root)))
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
                                                (append history
                                                        (list (if (stringp prompt)
                                                                  (llm:user-turn prompt)
                                                                  prompt)))
                                                :on-event (%program-agent-event program)
                                                :callback ok :error-callback err))))
          ;; H4b: the run is going now (:started came synchronously, a
          ;; continued run's finish reason is cleared), and its first step is
          ;; still to come: these posts follow the turn's message.
          (let ((run (%cp-run program)))
            (when run
              (dolist (turn more)
                (agent:agent-run-post run turn))
              (%post-if-going (%cp-lisp-tools program) run))))
      (error (e) (funcall err e)))))

(defun %cp-lisp-tools (program)
  "H4b: PROGRAM's LISP-TOOLS, or NIL."
  (%sources-lisp-tools (%cp-sources program)))

(defun %loop-start-image-turn (program)
  "H4b, loop thread: a turn whose message is the first queued image event's
turn, the others posted right after; none queued → (:turn-end :reason :stop).
Events taken here and lost to a failing start stay in the transcript as
notices (lisp-mcp/agent has no way to queue them again)."
  (let* ((tools (%cp-lisp-tools program))
         (events (and tools (lt:take-image-events tools))))
    (if (null events)
        (%send program (list :turn-end :reason :stop))
        (%loop-start-turn program (lt:image-event-text (first events))
                          :message (lt:image-event-turn (first events))
                          :more (mapcar #'lt:image-event-turn (rest events))))))

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
          ;; R4d-4b: while a plan's sandbox is open its rules hold (the shell
          ;; allows only while confined).
          (agent:ai-agent-permissions agent) (let ((sandbox (%cp-plan-sandbox program)))
                                               (if (and sandbox (eq mode :plan))
                                                   (%plan-permissions settings sandbox)
                                                   (%agent-permissions settings)))
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
  "(:rewind N) without parts: the rewind dialog when turn T's files differ
from the tip's (H5b), else H3c's conversation rewind."
  (let* ((session (%cp-session program))
         (cp (%cp-checkpointer program))
         (len (length (session-line session)))
         (turn (- len n)))
    (when (and (integerp n) (<= 1 n len))
      (let ((target (turn-checkpoint session (princ-to-string turn)))
            (tip (tip-checkpoint session)))
        (when (and target tip
                   (not (checkpoint-expired-p target))
                   (not (%same-files-p cp target tip)))
          (%send program (list :rewind-prompt :n n :turn turn
                                              :paths (%checkpoint-paths cp session tip target)))
          (return-from %rewind nil)))))
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
                                                (let ((session (%cp-session program)))
                                                  (session-tree-lines
                                                   session :width width
                                                   ;; H5b: turns with a retained checkpoint.
                                                   :marked (remove nil (mapcar #'checkpoint-turn-id
                                                                               (session-checkpoints session))))))))))))
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
      ;; H4b
      (:post-image-events
       (%on-loop program (lambda () (%post-if-going (%cp-lisp-tools program) (%cp-run program)))))
      (:image-turn (setf (%cp-interrupted program) nil)
       (%on-loop program (lambda () (%loop-start-image-turn program))))
      ;; H8d
      (:units-panel (%panel-open program))
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
  ;; H4b: a turn end that leaves the program idle with image events queued.
  (when (eq :turn-end (first event))
    (let ((tools (%cp-lisp-tools program)))
      (when (and tools (not (state-busy-p (code-program-state program))))
        (let ((n (length (lt:lisp-tools-pending-events tools))))
          (when (plusp n)
            (%apply-event program (list :image-pending n)))))))
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
          ((and (null approvals) (state-rewind-prompt state))
           ;; H5b: the rewind or its drift dialog.
           (%sync-rewind-dialog program))
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
  ;; H4b: image events go to the TUI from now on; the ones that came before
  ;; it ran are sent first.
  (let ((link (%cp-image-link program))
        (run tui:*tui*))
    (when link
      (%link-attach link (lambda (event) (tui:tui-send (image-event-message event) run)))))
  ;; H8d: the supervisor's events from now on.
  (%start-units-ui program tui:*tui*)
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
      ;; H8d: an approval (or plan / rewind) dialog keeps the keys; then the
      ;; unit confirm dialog; Ctrl-P toggles the panel; an open panel has
      ;; every other key.
      ((and (null dialog) (%unit-dialog program))
       (%unit-dialog-key program message))
      ((and (null dialog) ctrl (eq key (first +unit-panel-key+))
            (equal (tui:key-message-modifiers message) (second +unit-panel-key+)))
       (if (unit-panel-open-p (code-program-panel program))
           (%panel-close program)
           (%panel-open program))
       nil)
      ((and (null dialog) (unit-panel-open-p (code-program-panel program)))
       (%panel-key program message))
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
                 (case (first message)
                   (:%cp-files (when (second message)
                                 (setf (%cp-files program) (second message)))
                    nil)
                   ;; H8d: supervisor events and the panel's threads.
                   (:%units (%units-message program (rest message)))
                   (t (%apply-event program message))))
                ((tui:key-message-p message) (%key-event program message))
                ((tui:mouse-message-p message)
                 (unless (unit-panel-open-p (code-program-panel program))
                   (w:widget-update (%cp-viewport program) message))
                 nil)
                ((tui:paste-message-p message)
                 (let ((target (or (code-program-dialog program)
                                   ;; H8d: while the panel is open, its prompt.
                                   (and (unit-panel-open-p (code-program-panel program))
                                        (or (%unit-dialog program) (%panel-prompt program)))
                                   (and (not (unit-panel-open-p (code-program-panel program)))
                                        (code-program-input program)))))
                   (and target (nth-value 1 (w:widget-update target message)))))
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
         ;; H4b: the banner row sits directly above the rule.
         (banner (image-banner-text state))
         (banner-y (and banner (1- rule-y)))
         (spinner-y (and busy (not dialog) (1- (or banner-y rule-y))))
         (top (max 0 (- rule-y (if banner-y 1 0) (if spinner-y 1 0) (length extra)))))
    (when (or (zerop width) (zerop height))
      (return-from tui:tui-view nil))
    (setf (%cp-width program) width)
    (multiple-value-bind (left right) (status-line-text state width)
      (setf (w:status-line-left status) left
            (w:status-line-right status) right))
    (w:widget-view status (tui:sub-canvas canvas 0 (1- height) width 1))
    ;; H8d: the open panel replaces everything above the status line.
    (when (unit-panel-open-p (code-program-panel program))
      (%units-view program canvas width height)
      (return-from tui:tui-view nil))
    (when (plusp bottom)
      (w:widget-view (or dialog input) (tui:sub-canvas canvas 0 bottom-y width bottom)))
    (when (>= rule-y 0)
      (tui:draw-text canvas 0 rule-y (make-string width :initial-element #\─)))
    (when (and banner-y (>= banner-y 0))
      (tui:draw-text canvas 0 banner-y (%cut banner width)))
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
  "Close PROGRAM's shell tools, lisp tools and event loop. Idempotent. → NIL."
  (unless (%cp-closed program)
    (setf (%cp-stopping program) t)
    ;; H8d: the subscription and the panel's threads end first.
    (%stop-units-ui program)
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
      ;; H4b: no event is sent after this; a spawned image is killed, an
      ;; attached one keeps running.
      (%link-close (%cp-image-link program))
      ;; H8d: the unit tools (the working directory's and, H5a, the open
      ;; plan area's), the shell tools, then the supervisor.
      (%close-code-units (code-program-supervisor program)
                         :unit-tools (list (code-program-unit-tools program)
                                           (code-unit-tools (%cp-plan-sources program)))
                         :shell-tools (list (second (%cp-sources program))
                                            (second (%cp-plan-sources program))))
      ;; H5b
      (when (%cp-checkpointer program)
        (close-checkpointer (%cp-checkpointer program)))
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

(defun %program-plan-settings (program)
  "The settings the plan's tools and rules use: mode :PLAN, the image off."
  (merge-settings (%cp-settings program)
                  (make-settings :permission-mode :plan
                                 ;; H4b: the image stays with the working
                                 ;; directory's sources.
                                 :lisp-image '(:image (:off)))))

(defun %program-plan-agent (program plan settings sandbox)
  "Make the area's tool sources for PLAN (confined while SANDBOX is), and
→ (values sources instructions). H8d: on the program's supervisor, under an
:agent scope \"plan-<id8>\"."
  (let* ((agent (%cp-agent program))
         (sup (code-program-supervisor program))
         (sources (apply #'make-code-tools (plan-tool-root plan (%cp-cwd program))
                         :settings settings
                         :supervisor sup
                         :scope (%plan-unit-scope sup plan)
                         (plan-sandbox-tool-keys sandbox))))
    (handler-bind ((error (lambda (e)
                            (declare (ignore e))
                            (%close-code-units nil :unit-tools (list (code-unit-tools sources))
                                                   :shell-tools (list (second sources))))))
      (let ((offered (loop for source in sources
                           append (mapcar #'llm:llm-tool-name
                                          (agent:list-agent-tools source)))))
        (values sources
                (assemble-system-prompt
                 (%cp-cwd program) :tools offered :backend (agent:ai-agent-backend agent)
                                   :settings settings
                                   :user-config-dir (%cp-user-config-dir program)
                                   :plan plan :sandbox sandbox))))))

(defun %ensure-plan (program)
  "Open or reopen the plan when none is open; swap the agent's tools and
instructions to the area and drop the run; send (:plan-opened …). R4d-4b: the
plan's sandbox is probed when it opens (failIfUnavailable: the plan does not
open); while a plan is open, a sandbox that refused a command gets unconfined
shell tools that ask (%REFRESH-PLAN-SHELL)."
  (if (%cp-plan program)
      (%refresh-plan-shell program)
      (let* ((cwd (%cp-cwd program))
             (data-dir (%program-data-dir program))
             (session (%cp-session program))
             (entry (%head-plan-entry session))
             (reopened (and entry (eq :open (getf entry :status))
                            (handler-case (reopen-plan (plans-directory cwd :data-dir data-dir)
                                                       (getf entry :id))
                              (plan-not-found () nil))))
             (plan (or reopened
                       (open-plan (%cp-project-dir program) :kind :auto :data-dir data-dir
                                                            :session-id (session-id session))))
             (agent (%cp-agent program))
             (settings (%program-plan-settings program))
             (sandbox (handler-bind ((plan-sandbox-unavailable
                                       (lambda (e)
                                         (declare (ignore e))
                                         ;; A fresh plan does not stay open behind it.
                                         (unless reopened (reject-plan plan)))))
                        (open-plan-sandbox plan settings :backend (%cp-plan-backend program)))))
        (multiple-value-bind (sources instructions)
            (%program-plan-agent program plan settings sandbox)
          (setf (%cp-cwd-instructions program) (agent:ai-agent-instructions agent)
                (agent:ai-agent-tools agent) sources
                (agent:ai-agent-instructions agent) instructions
                (agent:ai-agent-permissions agent) (%plan-permissions settings sandbox)
                (%cp-plan program) plan
                (%cp-plan-sources program) sources
                (%cp-plan-sandbox program) sandbox))
        (%drop-run program)
        (%send program (list :plan-opened :id (plan-id plan) :kind (plan-kind plan)
                                          :root (uiop:native-namestring (plan-root plan))))
        (let ((notice (plan-sandbox-notice sandbox)))
          (when notice
            (%send program (list :notice notice)))))))

(defun %refresh-plan-shell (program)
  "R4d-4b, at a turn's start: after a refusal the plan's shell tools are made
again without the confinement, the rules lose the shell allows (bash and
job_input ask; denied with failIfUnavailable), the old sources are closed and
the run is dropped (the agent sees the new tools)."
  (let ((sandbox (%cp-plan-sandbox program))
        (old (%cp-plan-sources program)))
    (when (%plan-shell-stale-p sandbox old)
      (let ((settings (%program-plan-settings program))
            (agent (%cp-agent program)))
        (multiple-value-bind (sources instructions)
            (%program-plan-agent program (%cp-plan program) settings sandbox)
          (setf (agent:ai-agent-tools agent) sources
                (agent:ai-agent-instructions agent) instructions
                (agent:ai-agent-permissions agent) (%plan-permissions settings sandbox)
                (%cp-plan-sources program) sources))
        (%close-code-units nil :unit-tools (list (code-unit-tools old))
                               :shell-tools (list (second old)))
        (%drop-run program)))))

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
          (%cp-plan-sandbox program) nil
          (%cp-turn-plan program) nil)
    ;; R4d-4b: the rules of the mode, without the plan's sandbox.
    (setf (agent:ai-agent-permissions agent)
          (%agent-permissions (merge-settings (%cp-settings program)
                                              (make-settings :permission-mode (%cp-mode program)))))
    ;; H8d: the area's unit tools, then its shell tools.
    (%close-code-units nil :unit-tools (list (code-unit-tools sources))
                           :shell-tools (list (second sources)))
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
    (multiple-value-bind (result status pre)
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
          (approve-plan plan :checkpointer (%cp-checkpointer program)))
      ;; H5b: the plan belongs to the session's head (its last turn).
      (when pre
        (handler-case (let ((session (%cp-session program)))
                        (record-plan-checkpoints (%cp-checkpointer program) session pre
                                                 (session-head session)))
          (error (e) (%send program (list :error (%message-text e))))))
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
  (let ((session (%cp-session program))
        (cp (%cp-checkpointer program)))
    (%send program
           (list :notice
                 (if (and (not (checkpointer-enabled-p cp)) (null (session-checkpoints session)))
                     "checkpoints are off"
                     (format nil "~{~a~^~%~}"
                             (checkpoint-summary-lines session :width (%cp-width program))))))))

(defun %rewind-parts-effect (program n parts on-drift)
  "(:rewind N :parts PARTS :on-drift M): REWIND-TO and its answers."
  (let* ((session (%cp-session program))
         (turn (- (length (session-line session)) n))
         (drifted nil))
    (unless (>= turn 0)
      (error 'session-turn-not-found :session (session-id session) :designator n))
    (let ((result
            (handler-bind ((plan-drift
                             (lambda (c)
                               (if on-drift
                                   (invoke-restart (find-restart (ecase on-drift
                                                                   (:rebase 'rebase-plan)
                                                                   (:overwrite 'overwrite-plan))
                                                                 c))
                                   (progn
                                     (setf drifted t)
                                     (%send program (list :rewind-drift :paths (plan-drift-paths c)))
                                     (invoke-restart (find-restart 'abort-approval c)))))))
              (rewind-to (%cp-checkpointer program) session (princ-to-string turn) :parts parts))))
      (when (eq :moved (getf result :conversation))
        (%drop-run program)
        (%session-reset program))
      ;; After a drift without an answer the drift dialog answers.
      (unless (and drifted (eq :aborted (getf result :files)))
        (%send program (list* :rewound result))))))

(defun %sync-rewind-dialog (program)
  "UI thread: make CODE-PROGRAM-DIALOG the rewind or drift dialog of
STATE-REWIND-PROMPT (made once per prompt), focus it. → NIL."
  (let* ((state (code-program-state program))
         (prompt (state-rewind-prompt state))
         (rewind (state-rewind state))
         (key (list :rewind-dialog prompt rewind)))
    (unless (equal key (%cp-dialog-invocation program))
      (setf (code-program-dialog program)
            (ecase prompt
              (:rewind
               (make-instance 'w:confirm-dialog
                              :title (format nil "Rewind to turn ~a" (getf rewind :turn))
                              :message (format nil "Files to restore: ~{~a~^, ~}" (getf rewind :paths))
                              :choices +rewind-choices+))
              (:drift
               (make-instance 'w:confirm-dialog
                              :title "Rewind: the working copy changed"
                              :message (format nil "Changed in both: ~{~a~^, ~}" (getf rewind :paths))
                              :choices +drift-choices+)))
            (%cp-dialog-invocation program) key))
    (setf (w:widget-focused-p (code-program-input program)) nil)
    nil))

;;; H8d: the unit panel (see the "H8d" part of the file header and
;;; src/unit-panel.lisp). UI thread unless said otherwise: the supervisor's
;;; dispatcher and the panel's threads only TUI-SEND (:%UNITS …) messages,
;;; which TUI-UPDATE hands to %UNITS-MESSAGE.

(defstruct (%units (:conc-name %us-))
  "The program's unit state (%CP-UNITS-STATE)."
  subscription                          ; SUP:SUBSCRIPTION from TUI-INIT
  dialog pending                        ; the unit confirm dialog, (action id input)
  (threads '())                         ; ((thread . stop-cell) …), joined at close
  ticker sampler reader                 ; stop cells of the running ones
  (gen 0)                               ; log reader generation
  (search-gen 0))                       ; search generation

(defstruct (%pv (:conc-name %pv-))
  "The panel's view state (%UNIT-PANEL-STATE)."
  (tick 0) lines-key lines              ; list view cache
  last-lines last-lines-tick            ; UNIT-LAST-LINE per unit, per tick
  stats cpu prev-sample prev-time       ; the last resource sample
  ;; log view
  (records '()) (gaps '()) memory
  (following t) (top 0) (windowed nil) (rows 1)
  prompt prompt-kind prompt-unit        ; the panel's W:TEXT-INPUT
  help)                                 ; the last action's text until the next key

(defparameter +unit-action-keys+
  '(("s" . "stop") ("r" . "restart") ("i" . "input") ("e" . "close_input"))
  "Panel keys → unit actions.")

(defun %us (program)
  (or (%cp-units-state program)
      (setf (%cp-units-state program) (make-%units))))

(defun %pv (program)
  (let ((panel (code-program-panel program)))
    (or (%unit-panel-state panel)
        (setf (%unit-panel-state panel) (make-%pv)))))

(defun %unit-dialog (program)
  "The unit confirm dialog, or NIL."
  (let ((us (%cp-units-state program)))
    (and us (%us-dialog us))))

(defun %panel-prompt (program)
  "The panel's prompt (W:TEXT-INPUT), or NIL."
  (let ((pv (%unit-panel-state (code-program-panel program))))
    (and pv (%pv-prompt pv))))

(defun %live-count (supervisor)
  (if supervisor (count-if #'sup:unit-live-p (sup:supervisor-units supervisor)) 0))

(defun %stop-cell (cell)
  (when cell (setf (car cell) t)))

(defun %sleep-unless (cell seconds)
  "Sleep SECONDS in slices; → true when CELL says stop."
  (let ((deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop until (or (car cell) (>= (get-internal-real-time) deadline))
          do (sleep 0.05))
    (car cell)))

(defun %units-thread (program name function)
  "Run FUNCTION (of its stop cell) on a new thread. → the stop cell. A
condition FUNCTION does not handle ends the thread quietly (an unhandled one
would enter the debugger of a non-interactive image)."
  (let* ((us (%us program))
         (cell (list nil))
         (thread (bt:make-thread (lambda ()
                                   (handler-case (funcall function cell)
                                     (error () nil)))
                                 :name name)))
    (setf (%us-threads us)
          (cons (cons thread cell)
                (remove-if-not (lambda (entry) (bt:thread-alive-p (car entry))) (%us-threads us))))
    cell))

(defun %units-send (program &rest message)
  (%send program (cons :%units message)))

;;; Start and stop.

(defun %start-units-ui (program run)
  "TUI-INIT: the live count now, then the supervisor's events (from the
current seq) to the UI."
  (let ((sup (code-program-supervisor program))
        (us (%us program)))
    (when sup
      (%apply-event program (list :units :running (%live-count sup)))
      ;; The dispatcher thread only queues the event for the UI.
      (setf (%us-subscription us)
            (sup:subscribe sup (lambda (event) (tui:tui-send (list :%units :event event) run))
                           :since (sup:supervisor-last-seq sup))))))

(defun %stop-units-ui (program)
  "CLOSE-CODE-PROGRAM (any thread): the subscription ends, every panel thread
is told to stop and joined (bounded)."
  (let ((us (%cp-units-state program)))
    (when us
      (let ((sub (shiftf (%us-subscription us) nil)))
        (when sub (sup:unsubscribe sub)))
      (setf (%us-dialog us) nil (%us-pending us) nil)
      (let ((threads (shiftf (%us-threads us) '())))
        (dolist (entry threads) (%stop-cell (cdr entry)))
        (dolist (entry threads) (%join-thread (car entry) 2))))))

;;; Opening and closing.

(defun %panel-unit-ids (program)
  (let ((sup (code-program-supervisor program)))
    (and sup (loop for row in (unit-tree sup)
                   when (getf row :unit) collect (sup:unit-id (getf row :unit))))))

(defun %panel-fix-selection (program)
  "The selection is a unit row: the first one when nothing (or an evicted
unit) is selected."
  (let ((panel (code-program-panel program))
        (ids (%panel-unit-ids program)))
    (unless (member (unit-panel-selected panel) ids :test #'equal)
      (setf (unit-panel-selected panel) (first ids)))))

(defun %panel-bump (program)
  (incf (%pv-tick (%pv program))))

(defun %panel-open (program)
  (let ((panel (code-program-panel program))
        (pv (%pv program))
        (us (%us program))
        (sup (code-program-supervisor program)))
    (unless (unit-panel-open-p panel)
      (setf (unit-panel-open-p panel) t
            (unit-panel-mode panel) :list
            (unit-panel-unit panel) nil
            (unit-panel-query panel) nil
            (unit-panel-hits panel) '()
            (unit-panel-hit-index panel) nil
            (%pv-help pv) nil
            (%pv-prompt pv) nil)
      (%panel-fix-selection program)
      (%panel-bump program)
      (when sup
        (setf (%us-ticker us)
              (%units-thread program "cl-stack-code unit ticker"
                             (lambda (cell)
                               (loop until (%sleep-unless cell +unit-tick-interval+)
                                     do (%units-send program :tick))))
              (%us-sampler us)
              (%units-thread program "cl-stack-code unit sampler"
                             (lambda (cell)
                               (loop until (car cell)
                                     do (let ((table (sample-unit-resources (sup:supervisor-units sup))))
                                          (unless (car cell)
                                            (%units-send program :sample table (get-internal-real-time))))
                                        (%sleep-unless cell +unit-stats-interval+))))))))
  nil)

(defun %panel-stop-reader (program)
  (let ((us (%us program)))
    (%stop-cell (shiftf (%us-reader us) nil))
    (incf (%us-gen us))))

(defun %panel-close (program)
  (let ((panel (code-program-panel program))
        (pv (%pv program))
        (us (%us program)))
    (setf (unit-panel-open-p panel) nil
          (unit-panel-mode panel) :list
          (unit-panel-unit panel) nil
          (unit-panel-query panel) nil
          (unit-panel-hits panel) '()
          (unit-panel-hit-index panel) nil
          (%pv-prompt pv) nil
          (%pv-help pv) nil
          (%us-dialog us) nil
          (%us-pending us) nil)
    (%stop-cell (shiftf (%us-ticker us) nil))
    (%stop-cell (shiftf (%us-sampler us) nil))
    (%panel-stop-reader program))
  nil)

;;; The log view's data.

(defun %panel-start-reader (program id &key start)
  "Load unit ID's log (the last +UNIT-LOG-SCROLLBACK+ lines, or from START),
then follow it, on a thread; a unit without a log file: its in-memory output."
  (%panel-stop-reader program)
  (let* ((us (%us program))
         (gen (%us-gen us))
         (sup (code-program-supervisor program)))
    (setf (%us-reader us)
          (%units-thread
           program "cl-stack-code unit log"
           (lambda (cell)
             (let* ((u (sup:find-unit sup id))
                    (log (and u (%unit-log-or-nil u))))
               (cond ((null u) nil)
                     (log
                      (let ((from (or start (max 1 (- (sup:log-last-line log) +unit-log-scrollback+)))))
                        (multiple-value-bind (records gaps next)
                            (sup:log-read log :start from :limit +unit-log-scrollback+)
                          (unless (car cell)
                            (%units-send program :records gen :reset records gaps))
                          (loop until (car cell)
                                do (multiple-value-bind (more more-gaps after ended)
                                       (sup:log-follow log :from next :wait 0.25)
                                     (when (car cell) (return))
                                     (when more
                                       (%units-send program :records gen :append more more-gaps))
                                     (setf next after)
                                     ;; Ended: a restart may continue it; poll slowly.
                                     (when (and ended (null more))
                                       (%sleep-unless cell 0.25)))))))
                     (t
                      (let ((seen nil))
                        (loop until (car cell)
                              do (let ((text (sup:unit-output u)))
                                   (unless (equal text seen)
                                     (setf seen text)
                                     (%units-send program :memory gen text)))
                                 (%sleep-unless cell 0.25)))))))))))

(defun %panel-take-records (program how records gaps)
  (let ((pv (%pv program)))
    (if (eq how :reset)
        (setf (%pv-records pv) records
              (%pv-gaps pv) gaps)
        (let* ((last (let ((r (car (last (%pv-records pv))))) (if r (sup:log-record-line r) 0)))
               (new (remove-if (lambda (r) (<= (sup:log-record-line r) last)) records))
               (all (append (%pv-records pv) new))
               (extra (- (length all) +unit-log-scrollback+)))
          (when (plusp extra)
            (setf all (nthcdr extra all)))
          (setf (%pv-records pv) all
                (%pv-gaps pv)
                (let ((first (if all (sup:log-record-line (first all)) 0)))
                  (remove-if (lambda (g) (< (sup:log-gap-last-line g) first))
                             (remove-duplicates (append (%pv-gaps pv) gaps)
                                                :key #'sup:log-gap-first-line :from-end t))))))))

(defun %panel-item-count (pv)
  (if (%pv-memory pv)
      (length (%unit-memory-lines (%pv-memory pv) 1))
      (+ (length (%pv-records pv)) (length (%pv-gaps pv)))))

(defun %panel-top (pv n body)
  "The first shown item of N with BODY rows."
  (if (%pv-following pv)
      (max 0 (- n body))
      (max 0 (min (%pv-top pv) (- n body)))))

(defun %panel-enter-log (program id)
  (let ((panel (code-program-panel program))
        (pv (%pv program)))
    (setf (unit-panel-mode panel) :log
          (unit-panel-unit panel) id
          (unit-panel-query panel) nil
          (unit-panel-hits panel) '()
          (unit-panel-hit-index panel) nil
          (%pv-records pv) '()
          (%pv-gaps pv) '()
          (%pv-memory pv) nil
          (%pv-following pv) t
          (%pv-top pv) 0
          (%pv-windowed pv) nil)
    (%panel-start-reader program id)))

(defun %panel-leave-log (program)
  (let ((panel (code-program-panel program)))
    (%panel-stop-reader program)
    (setf (unit-panel-mode panel) :list
          (unit-panel-unit panel) nil
          (unit-panel-query panel) nil
          (unit-panel-hits panel) '()
          (unit-panel-hit-index panel) nil)
    (%panel-bump program)))

(defun %panel-scroll (program delta &key to)
  "Move the log view by DELTA rows (or TO the first one); following stops."
  (let* ((pv (%pv program))
         (n (%panel-item-count pv))
         (body (%pv-rows pv))
         (top (%panel-top pv n body)))
    (setf (%pv-following pv) nil
          (%pv-top pv) (max 0 (min (if to to (+ top delta)) (max 0 (- n body)))))))

(defun %panel-follow (program)
  "End: the tail, following again (a window around a hit is left)."
  (let ((pv (%pv program))
        (panel (code-program-panel program)))
    (setf (%pv-following pv) t)
    (when (%pv-windowed pv)
      (setf (%pv-windowed pv) nil
            (%pv-records pv) '()
            (%pv-gaps pv) '())
      (%panel-start-reader program (unit-panel-unit panel)))))

(defun %panel-jump (program)
  "Show the current hit: in the loaded lines, or reload the window around it."
  (let* ((panel (code-program-panel program))
         (pv (%pv program))
         (index (unit-panel-hit-index panel))
         (hit (and index (nth index (unit-panel-hits panel)))))
    (when hit
      (let* ((line (ss:hit-line hit))
             (records (%pv-records pv))
             (first (and records (sup:log-record-line (first records))))
             (last (and records (sup:log-record-line (car (last records))))))
        (if (and first (<= first line last))
            (let ((position (or (position-if (lambda (item) (>= (%log-item-line item) line))
                                             (%log-items records (%pv-gaps pv)))
                                0)))
              (setf (%pv-following pv) nil
                    (%pv-top pv) (max 0 (- position 2))))
            (progn
              (setf (%pv-following pv) nil
                    (%pv-top pv) 0
                    (%pv-windowed pv) t
                    (%pv-records pv) '()
                    (%pv-gaps pv) '())
              (%panel-start-reader program (unit-panel-unit panel) :start (max 1 (- line 10)))))))))

(defun %panel-search (program query)
  "SS:SEARCH-LOGS of QUERY in the shown unit's log, on a thread."
  (let* ((us (%us program))
         (gen (incf (%us-search-gen us)))
         (tools (code-program-unit-tools program))
         (id (unit-panel-unit (code-program-panel program))))
    (when (and tools id)
      (%units-thread program "cl-stack-code unit search"
                     (lambda (cell)
                       (declare (ignore cell))
                       (handler-case
                           (%units-send program :search gen query
                                        (ss:search-logs (tools:unit-tools-index tools) query
                                                        :units (list id) :k 50))
                         (error (e)
                           (%units-send program :search-error gen (%message-text e)))))))))

;;; Actions.

(defun %panel-run-action (program action id input)
  "TOOLS:CALL-UNIT-TOOL \"unit_control\" on a worker thread; the text comes
back as (:%units :action-done …)."
  (let ((tools (code-program-unit-tools program)))
    (%units-thread
     program "cl-stack-code unit action"
     (lambda (cell)
       (declare (ignore cell))
       (apply #'%units-send program :action-done
              (handler-case
                  (list :ok (tools:call-unit-tool tools "unit_control"
                                                  (unit-control-arguments action id :input input)))
                (agent:tool-failure (c) (list :error (%message-text c)))
                ;; unit_control hidden by the settings (not an ERROR subtype).
                (agent:agent-unknown-tool (c) (list :error (%message-text c)))
                (error (c) (list :error (%message-text c)))))))))

(defun %panel-act (program action id &key input)
  "ACTION on unit ID: the input prompt first for input; then the agent's
unit_control decision (deny: help row and a transcript error; ask: the
confirm dialog; allow: run it)."
  (let* ((sup (code-program-supervisor program))
         (unit (and sup id (sup:find-unit sup id)))
         (pv (%pv program))
         (us (%us program)))
    (cond
      ((null unit) nil)
      ((and (equal action "input") (null input))
       (setf (%pv-prompt pv) (make-instance 'w:text-input :prompt "input> " :focused t
                                         :placeholder "a line for its stdin (Enter sends, Esc cancels)")
             (%pv-prompt-kind pv) :input
             (%pv-prompt-unit pv) id))
      (t
       (multiple-value-bind (effect rule)
           (unit-action-permission (%cp-agent program) (code-program-unit-tools program)
                                   action id :input input
                                   :mode (state-permission-mode (code-program-state program)))
         (ecase effect
           (:deny
            (let ((text (%text "~a ~a denied~@[ by ~a~]" action id (%unit-rule-text rule))))
              (setf (%pv-help pv) text)
              (%apply-event program (list :error text))))
           (:ask
            (let ((dialog (make-instance 'w:confirm-dialog
                                         :title "Unit control"
                                         :message (unit-action-message action unit :input input)
                                         :choices +unit-action-choices+
                                         :feedback-choice nil)))
              (setf (w:widget-focused-p dialog) t
                    (%us-dialog us) dialog
                    (%us-pending us) (list action id input))))
           (:allow (%panel-run-action program action id input))))))))

(defun %unit-dialog-key (program message)
  "A key for the unit confirm dialog: Yes runs the action, No or Esc drops it."
  (let ((us (%us program)))
    (multiple-value-bind (widget command event) (w:widget-update (%us-dialog us) message)
      (declare (ignore widget))
      (cond ((w:confirm-event-p event)
             (let ((pending (shiftf (%us-pending us) nil)))
               (setf (%us-dialog us) nil)
               (when (and pending (eq :yes (w:confirm-event-choice event)))
                 (destructuring-bind (action id input) pending
                   (%panel-run-action program action id input))))
             command)
            ((w:cancel-event-p event)
             (setf (%us-dialog us) nil (%us-pending us) nil)
             command)
            (t command)))))

;;; Keys.

(defun %printable (message)
  "The one character MESSAGE types (no Ctrl / Alt / Super), or NIL."
  (let ((text (tui:key-message-text message)))
    (and text (= 1 (length text))
         (null (intersection (tui:key-message-modifiers message) '(:ctrl :alt :super)))
         text)))

(defun %panel-prompt-submit (program text)
  (let* ((pv (%pv program))
         (kind (%pv-prompt-kind pv))
         (id (%pv-prompt-unit pv)))
    (setf (%pv-prompt pv) nil)
    (ecase kind
      (:search (unless (%blank-text-p text)
                 (%panel-search program text)))
      (:input (%panel-act program "input" id :input (format nil "~a~%" text))))))

(defun %panel-list-key (program key text)
  (let* ((panel (code-program-panel program))
         (ids (%panel-unit-ids program))
         (selected (unit-panel-selected panel))
         (index (position selected ids :test #'equal)))
    (cond ((member key '(:arrow-up :arrow-down))
           (when ids
             (setf (unit-panel-selected panel)
                   (nth (max 0 (min (1- (length ids))
                                    (+ (or index 0) (if (eq key :arrow-up) -1 1))))
                        ids))))
          ((eq key :home) (setf (unit-panel-selected panel) (first ids)))
          ((eq key :end) (setf (unit-panel-selected panel) (car (last ids))))
          ((eq key :enter) (when index (%panel-enter-log program selected)))
          ((or (eq key :escape) (equal text "q")) (%panel-close program))
          ((assoc text +unit-action-keys+ :test #'equal)
           (when index
             (%panel-act program (cdr (assoc text +unit-action-keys+ :test #'equal)) selected))))
    nil))

(defun %panel-log-key (program key text)
  (let* ((panel (code-program-panel program))
         (pv (%pv program))
         (hits (unit-panel-hits panel)))
    (cond ((eq key :arrow-up) (%panel-scroll program -1))
          ((eq key :arrow-down) (%panel-scroll program 1))
          ((eq key :page-up) (%panel-scroll program (- (max 1 (%pv-rows pv)))))
          ((eq key :page-down) (%panel-scroll program (max 1 (%pv-rows pv))))
          ((eq key :home) (%panel-scroll program 0 :to 0))
          ((eq key :end) (%panel-follow program))
          ((eq key :escape)
           (if (unit-panel-query panel)
               (setf (unit-panel-query panel) nil
                     (unit-panel-hits panel) '()
                     (unit-panel-hit-index panel) nil)
               (%panel-leave-log program)))
          ((equal text "/")
           (setf (%pv-prompt pv) (make-instance 'w:text-input :prompt "search> " :focused t
                                         :placeholder "words or \"a phrase\" (Enter searches, Esc cancels)")
                 (%pv-prompt-kind pv) :search
                 (%pv-prompt-unit pv) (unit-panel-unit panel)))
          ((member text '("n" "N") :test #'equal)
           (when hits
             (setf (unit-panel-hit-index panel)
                   (mod (+ (or (unit-panel-hit-index panel) 0) (if (equal text "n") 1 -1))
                        (length hits)))
             (%panel-jump program)))
          ((assoc text +unit-action-keys+ :test #'equal)
           (%panel-act program (cdr (assoc text +unit-action-keys+ :test #'equal))
                       (unit-panel-unit panel))))
    nil))

(defun %panel-key (program message)
  "A key while the panel is open (no dialog shown). → a command or NIL."
  (let* ((pv (%pv program))
         (panel (code-program-panel program))
         (key (tui:key-message-key message))
         (text (%printable message))
         (prompt (%pv-prompt pv)))
    (setf (%pv-help pv) nil)
    (cond (prompt
           (multiple-value-bind (widget command event) (w:widget-update prompt message)
             (declare (ignore widget))
             (cond ((w:submit-event-p event)
                    (%panel-prompt-submit program (w:submit-event-text event)))
                   ((w:cancel-event-p event)
                    (setf (%pv-prompt pv) nil)))
             command))
          ((eq :log (unit-panel-mode panel)) (%panel-log-key program key text))
          (t (%panel-list-key program key text)))))

;;; Messages from the dispatcher and the panel's threads.

(defun %units-message (program message)
  "(:event E) (:tick) (:sample TABLE TIME) (:records GEN HOW RECORDS GAPS)
(:memory GEN TEXT) (:action-done :ok|:error TEXT) (:search GEN QUERY HITS)
(:search-error GEN TEXT). → NIL."
  (let ((pv (%pv program))
        (us (%us program))
        (panel (code-program-panel program)))
    (destructuring-bind (kind &rest args) message
      (ecase kind
        (:event
         (let ((notice (unit-failure-notice (first args))))
           (%panel-bump program)
           (%apply-event program (list :units :running (%live-count (code-program-supervisor program))))
           (when notice
             (%apply-event program (list :unit-failed :notice notice)))))
        (:tick (%panel-bump program))
        (:sample
         (destructuring-bind (table time) args
           (setf (%pv-cpu pv) (and (%pv-prev-sample pv)
                                   (%cpu-table (%pv-prev-sample pv) table
                                               (/ (- time (%pv-prev-time pv))
                                                  internal-time-units-per-second)))
                 (%pv-stats pv) table
                 (%pv-prev-sample pv) table
                 (%pv-prev-time pv) time)
           (%panel-bump program)))
        (:records
         (destructuring-bind (gen how records gaps) args
           (when (= gen (%us-gen us))
             (%panel-take-records program how records gaps))))
        (:memory
         (destructuring-bind (gen text) args
           (when (= gen (%us-gen us))
             (setf (%pv-memory pv) text))))
        (:action-done
         (destructuring-bind (outcome text) args
           (setf (%pv-help pv) (%one-line text))
           (%panel-bump program)
           (%apply-event program (if (eq outcome :ok)
                                     (list :notice (%text "unit_control: ~a" text))
                                     (list :error text)))))
        (:search
         (destructuring-bind (gen query hits) args
           (when (and (= gen (%us-search-gen us)) (eq :log (unit-panel-mode panel)))
             (setf (unit-panel-query panel) query
                   (unit-panel-hits panel) hits
                   (unit-panel-hit-index panel) (and hits 0))
             (%panel-jump program))))
        (:search-error
         (destructuring-bind (gen text) args
           (when (= gen (%us-search-gen us))
             (setf (%pv-help pv) (%one-line text))))))))
  nil)

;;; The view.

(defun %draw-lines (canvas lines)
  (loop for line in lines
        for y from 0 below (tui:canvas-rows canvas)
        do (w:draw-runs canvas 0 y line)))

(defun %units-list-view (program canvas width rows)
  (let* ((panel (code-program-panel program))
         (pv (%pv program))
         (sup (code-program-supervisor program)))
    (%panel-fix-selection program)
    (let ((key (list (%pv-tick pv) width rows (unit-panel-selected panel))))
      (unless (eql (%pv-last-lines-tick pv) (%pv-tick pv))
        (setf (%pv-last-lines pv) (make-hash-table :test 'equal)
              (%pv-last-lines-tick pv) (%pv-tick pv)))
      (unless (equal key (%pv-lines-key pv))
        (setf (%pv-lines pv) (let ((*%unit-last-lines* (%pv-last-lines pv)))
                                (unit-panel-lines (and sup (unit-tree sup)) width rows
                                               :selected (unit-panel-selected panel)
                                               :stats (%pv-stats pv) :cpu (%pv-cpu pv)))
              (%pv-lines-key pv) key)))
    (%draw-lines (tui:sub-canvas canvas 0 0 width rows) (%pv-lines pv))))

(defun %units-log-view (program canvas width rows)
  (let* ((panel (code-program-panel program))
         (pv (%pv program))
         (sup (code-program-supervisor program))
         (unit (and sup (unit-panel-unit panel) (sup:find-unit sup (unit-panel-unit panel)))))
    (if (null unit)
        ;; Evicted while shown: back to the list.
        (progn (%panel-leave-log program)
               (%units-list-view program canvas width rows))
        (let* ((body (max 0 (1- rows)))
               (hits (mapcar #'ss:hit-line (unit-panel-hits panel)))
               (query (unit-panel-query panel))
               (memory (%pv-memory pv))
               (lines '()) (first nil) (last nil))
          (setf (%pv-rows pv) (max 1 body))
          (if memory
              (let* ((all (%unit-memory-lines memory width :hits hits :query query))
                     (n (length all))
                     (top (%panel-top pv n body)))
                (setf lines (subseq all top (min n (+ top body))))
                (when lines
                  (setf first (1+ top) last (+ top (length lines)))))
              (let* ((items (%log-items (%pv-records pv) (%pv-gaps pv)))
                     (n (length items))
                     (top (%panel-top pv n body))
                     (shown (subseq items top (min n (+ top body)))))
                (setf lines (unit-log-lines (remove-if (lambda (i) (typep i 'sup:log-gap)) shown)
                                            (remove-if-not (lambda (i) (typep i 'sup:log-gap)) shown)
                                            width :hits hits :query query))
                (when shown
                  (setf first (%log-item-line (first shown))
                        last (let ((item (car (last shown))))
                               (if (typep item 'sup:log-gap)
                                   (sup:log-gap-last-line item)
                                   (sup:log-record-line item)))))))
          (let ((title (concatenate 'string
                                    (unit-log-title unit :following (%pv-following pv)
                                                         :first-line first :last-line last
                                                         :query query
                                                         :hit-index (unit-panel-hit-index panel)
                                                         :hit-count (length hits))
                                    (if memory " · no log file" ""))))
            (tui:draw-text canvas 0 0 (%cut-row title width)))
          (%draw-lines (tui:sub-canvas canvas 0 1 width body) lines)))))

(defun %units-view (program canvas width height)
  "The open panel on CANVAS (W × H) above the status line (see
src/unit-panel.lisp)."
  (let* ((panel (code-program-panel program))
         (pv (%pv program))
         (dialog (or (code-program-dialog program) (%unit-dialog program)))
         (prompt (%pv-prompt pv))
         (bottom (if dialog (max 0 (min (- height 2) (%dialog-rows dialog width))) 1))
         (bottom-y (- height 1 bottom))
         (rule-y (1- bottom-y))
         (rows (max 0 rule-y)))
    (when (and (plusp bottom) (>= bottom-y 0))
      (cond (dialog (w:widget-view dialog (tui:sub-canvas canvas 0 bottom-y width bottom)))
            (prompt (w:widget-view prompt (tui:sub-canvas canvas 0 bottom-y width 1)))
            (t (tui:draw-text canvas 0 bottom-y
                              (%cut-row (or (%pv-help pv)
                                            (if (eq :log (unit-panel-mode panel))
                                                +unit-log-help+
                                                +unit-list-help+))
                                        width)))))
    (when (>= rule-y 0)
      (tui:draw-text canvas 0 rule-y (make-string width :initial-element #\─)))
    (when (plusp rows)
      (if (eq :log (unit-panel-mode panel))
          (%units-log-view program canvas width rows)
          (%units-list-view program canvas width rows)))))
