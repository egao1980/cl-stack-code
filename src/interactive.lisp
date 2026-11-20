(in-package #:cl-stack-code)

;;; H3b: the interactive core. INTERACTIVE-UPDATE STATE EVENT → (values STATE
;;; EFFECTS). It changes STATE in place and returns it (as tui widgets do),
;;; does no I/O and never touches the agent: the program turns key presses
;;; and agent callbacks into EVENTS and carries out the EFFECTS, in order.
;;;
;;; Events
;;;   (:submit TEXT)          Enter on the input
;;;   (:interrupt)            Esc (no menu open), or Ctrl-C while busy
;;;   (:quit)                 Ctrl-D / Ctrl-C on an empty idle input
;;;   (:part TEXT)            streamed assistant text
;;;   (:usage (I O CR CW))    one response's token counts
;;;   (:invocation INV)       an AGENT-INVOCATION was proposed or changed
;;;   (:turn-end :reason R [:pending INVS] [:message M])
;;;                           R: :stop :max-steps :canceled :failed :approval
;;;   (:reply CHOICE [FEEDBACK])  the approval dialog's answer, CHOICE one of
;;;                           :once :always :reject :reject-all
;;;   (:model-set DESIGNATOR) the program switched the model
;;;   (:notice TEXT) (:error TEXT)  messages from the program
;;;
;;; Effects
;;;   (:run TEXT)             send TEXT (mentions expanded by the program) as
;;;                           the next user message, continuing the
;;;                           conversation, or starting it after
;;;                           :new-conversation or at first
;;;   (:cancel)               CANCEL-AGENT-RUN on the running turn
;;;   (:approve INV :always B)            APPROVE-INVOCATION
;;;   (:deny INV :feedback F :all B)      DENY-INVOCATION (F a string or NIL)
;;;   (:resume)               resume the paused run once it has no :proposed
;;;                           invocation left; otherwise nothing
;;;   (:restore-input TEXT)   put TEXT back into the input
;;;   (:new-conversation)     forget the run; the next :run starts afresh
;;;   (:set-model DESIGNATOR) switch the model from the next turn on; the
;;;                           program answers (:model-set D) or (:error M)
;;;   (:set-permission-mode MODE)  switch the mode from the next turn on
;;;   (:quit)                 end the program
;;;
;;; Rules
;;;   :submit   Blank text (only whitespace): nothing. Text starting with "/"
;;;             is a command (below). While busy: appended to the queue, no
;;;             entry, no effect. Idle: a :user entry, busy, effect (:run T).
;;;   :part     Appended to the last entry when that is :assistant, else a
;;;             new :assistant entry.
;;;   :usage    Added to STATE-USAGE element by element.
;;;   :invocation  Updates the :tool entry with the invocation's id (status,
;;;             result, error-p), or appends a new one; INPUT is the
;;;             invocation's arguments.
;;;   :turn-end :approval: still busy; STATE-APPROVALS becomes PENDING.
;;;             :stop / :max-steps: idle; :max-steps adds a :notice M. Then,
;;;             when the queue is not empty, its first message is sent as by
;;;             :submit (a :user entry, busy, (:run T)).
;;;             :canceled / :failed: idle, a :notice "interrupted" or an
;;;             :error M; the queue is emptied and, when it held messages,
;;;             effect (:restore-input <messages joined by LF>).
;;;   :reply    Answers the first of STATE-APPROVALS (nothing when there is
;;;             none): :once → (:approve I :always NIL), :always →
;;;             (:approve I :always T), :reject → (:deny I :feedback F
;;;             :all NIL), :reject-all → (:deny I :feedback F :all T); then
;;;             (:resume). The answered invocation (every one for :reject-all)
;;;             leaves STATE-APPROVALS.
;;;   :interrupt  With approvals: as (:reply :reject-all). Busy: (:cancel).
;;;             Idle: nothing.
;;;   :quit     quit-p; effects (:cancel) when busy, then (:quit).
;;;   :model-set  STATE-MODEL becomes D; :notice "model: D".
;;;   :notice / :error  an entry of that kind.
;;;
;;; Commands (the text's first word; the rest, trimmed, is the argument)
;;;   /help         :notice +HELP-TEXT+
;;;   /clear        transcript emptied, usage zeroed, (:new-conversation)
;;;   /model        no argument: :notice "model: <model>"; else
;;;                 (:set-model ARG) and nothing else changes yet
;;;   /permissions  no argument: :notice "permission mode: <name>", then one
;;;                 line per STATE-RULES rule "<allow|ask|deny> <rule>"
;;;                 (FORMAT-PERMISSION-RULE; an object form as compact JSON);
;;;                 a mode name: STATE-PERMISSION-MODE, (:set-permission-mode
;;;                 MODE), :notice "permission mode: <name>"; anything else:
;;;                 :error "unknown permission mode \"X\": use default,
;;;                 acceptEdits, bypassPermissions, plan"
;;;   /exit         as (:quit)
;;;   other         :error "unknown command /X: try /help"
;;; While busy only /help and /exit run; /clear, /model and /permissions add
;;; an :error naming the command (and saying Esc interrupts) and do nothing.

(defparameter +help-text+
  (format nil "~{~a~^~%~}"
          '("Commands:"
            "  /help                 this help"
            "  /clear                start a new conversation"
            "  /model [MODEL]        show or switch the model (provider or provider:model)"
            "  /permissions [MODE]   show the rules, or switch to default, acceptEdits, bypassPermissions or plan"
            "  /exit                 quit (also Ctrl-D, or Ctrl-C on an empty input)"
            "Keys:"
            "  Enter send · Alt+Enter, Shift+Enter or Ctrl+J newline · Up/Down history"
            "  @path attach a file (Tab completes) · PgUp/PgDn scroll"
            "  Esc interrupt the turn · a message sent while a turn runs is queued"))
  "The /help notice.")

(defparameter +approval-choices+
  '((:once "Allow once")
    (:always "Always allow")
    (:reject "Reject")
    (:reject-all "Reject all"))
  "The approval dialog's choices (W:CONFIRM-DIALOG :choices). :reject asks
for feedback.")

(defclass interactive-state ()
  ((transcript :initform '() :accessor state-transcript
               :documentation "ENTRY list, oldest first.")
   (busy :initform nil :accessor state-busy-p
         :documentation "True from a :run effect until the turn ends (also
while approvals wait).")
   (queue :initform '() :accessor state-queue
          :documentation "Messages submitted while busy, oldest first.")
   (pending :initform '() :accessor %state-pending
            :documentation "Invocations of the last :approval turn end.")
   (answered :initform '() :accessor %state-answered
             :documentation "Those answered with :reply since.")
   (model :initarg :model :initform +default-model+ :accessor state-model
          :documentation "The model designator.")
   (permission-mode :initarg :permission-mode :initform :default
                    :accessor state-permission-mode)
   (cwd :initarg :cwd :initform nil :reader state-cwd)
   (rules :initarg :rules :initform '() :reader state-rules
          :documentation "The settings rules (allows, asks, denies) at start.")
   (usage :initform (list 0 0 0 0) :accessor state-usage
          :documentation "(input output cache-read cache-write), summed.")
   (quit :initform nil :accessor state-quit-p))
  (:documentation "What the interactive mode knows; see INTERACTIVE-UPDATE."))

(defun make-interactive-state (&key (model +default-model+) (permission-mode :default)
                                    cwd rules)
  "→ a fresh INTERACTIVE-STATE: empty transcript, idle, usage zero."
  (make-instance 'interactive-state :model model :permission-mode permission-mode
                                    :cwd cwd :rules rules))

(defun state-approvals (state)
  "→ the invocations still waiting for an answer, oldest first: the pending
ones of the last :approval turn end that were not answered with :reply and
whose AGENT-INVOCATION-STATUS is still :proposed."
  (declare (ignore state))
  (%not-implemented 'state-approvals))

(defun interactive-update (state event)
  "→ (values STATE effects) after EVENT (see the file header)."
  (declare (ignore state event))
  (%not-implemented 'interactive-update))

(defun status-line-text (state)
  "→ (values left right) of the status line:
left  \" <model> · <permission mode name> · <cwd>\", the cwd as a native
      directory namestring with the user's home directory prefix shown as \"~/\";
right \"<input> in · <output> out \", the summed input and output tokens."
  (declare (ignore state))
  (%not-implemented 'status-line-text))
