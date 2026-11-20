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

(defclass code-program ()
  ((state :initarg :state :reader code-program-state
          :documentation "The INTERACTIVE-STATE.")
   (input :initarg :input :reader code-program-input
          :documentation "The W:TEXT-INPUT.")
   (dialog :initform nil :accessor code-program-dialog
           :documentation "The W:CONFIRM-DIALOG while approvals wait, else NIL."))
  (:documentation "The interactive mode as a tui-protocol program."))

(defun make-code-program (invocation &key providers user-config-dir
                                          (getenv #'uiop:getenv))
  "→ a CODE-PROGRAM for INVOCATION (a parsed command line without -p). The
configuration errors of -p signal here."
  (declare (ignore invocation providers user-config-dir getenv))
  (%not-implemented 'make-code-program))

(defun close-code-program (program)
  "Close PROGRAM's shell tools and event loop. Idempotent. → NIL."
  (declare (ignore program))
  (%not-implemented 'close-code-program))

(defmethod tui:tui-init ((program code-program))
  (%not-implemented 'tui-init))

(defmethod tui:tui-update ((program code-program) model message)
  (declare (ignore model message))
  (%not-implemented 'tui-update))

(defmethod tui:tui-view ((program code-program) model canvas)
  (declare (ignore model canvas))
  (%not-implemented 'tui-view))

(defun %run-interactive (inv &key output input providers user-config-dir getenv)
  "RUN-CLI without -p (see the file header). → exit code."
  (declare (ignore inv output input providers user-config-dir getenv))
  (%not-implemented '%run-interactive))
