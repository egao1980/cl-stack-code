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
  (let ((answered (%state-answered state)))
    (remove-if-not (lambda (inv)
                     (and (not (member inv answered :test #'eq))
                          (eq :proposed (agent:agent-invocation-status inv))))
                   (%state-pending state))))

;;; Helpers. Each returns the effects it adds, as a list.

(defun %add-entry (state &rest initargs)
  (let ((entry (apply #'make-entry initargs)))
    (setf (state-transcript state) (append (state-transcript state) (list entry)))
    entry))

(defun %blank-text-p (text)
  (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return #\Page))) text))

(defun %core-start-turn (state text)
  "A :user entry for TEXT, busy, → ((:run TEXT))."
  (%add-entry state :kind :user :text text)
  (setf (state-busy-p state) t)
  (list (list :run text)))

(defun %split-command (text)
  "→ (values command argument) of a command line \"/NAME ARG\"."
  (let* ((text (string-trim '(#\Space #\Tab #\Newline #\Return) text))
         (gap (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return))) text)))
    (if gap
        (values (subseq text 0 gap)
                (string-trim '(#\Space #\Tab #\Newline #\Return) (subseq text gap)))
        (values text ""))))

(defun %quit-effects (state)
  (setf (state-quit-p state) t)
  (if (state-busy-p state)
      (list (list :cancel) (list :quit))
      (list (list :quit))))

(defun %rule-text (rule)
  (let ((form (format-permission-rule rule)))
    (format nil "~(~a~) ~a" (agent:permission-rule-effect rule)
            (if (stringp form) form (json:encode form)))))

(defun %permissions-notice (state)
  (format nil "permission mode: ~a~{~%~a~}"
          (permission-mode-name (state-permission-mode state))
          (mapcar #'%rule-text (state-rules state))))

(defun %command (state text)
  "Run the command line TEXT. → effects."
  (multiple-value-bind (command argument) (%split-command text)
    (let ((busy (state-busy-p state)))
      (cond
        ((string= command "/help")
         (%add-entry state :kind :notice :text +help-text+)
         '())
        ((string= command "/exit") (%quit-effects state))
        ((and busy (member command '("/clear" "/model" "/permissions") :test #'string=))
         (%add-entry state :kind :error
                         :text (format nil "~a is not available while a turn runs (Esc interrupts it)"
                                       command))
         '())
        ((string= command "/clear")
         (setf (state-transcript state) '()
               (state-usage state) (list 0 0 0 0))
         (list (list :new-conversation)))
        ((string= command "/model")
         (if (zerop (length argument))
             (progn (%add-entry state :kind :notice
                                      :text (format nil "model: ~a" (state-model state)))
                    '())
             (list (list :set-model argument))))
        ((string= command "/permissions")
         (cond ((zerop (length argument))
                (%add-entry state :kind :notice :text (%permissions-notice state))
                '())
               ((parse-permission-mode argument)
                (let ((mode (parse-permission-mode argument)))
                  (setf (state-permission-mode state) mode)
                  (%add-entry state :kind :notice
                                    :text (format nil "permission mode: ~a"
                                                  (permission-mode-name mode)))
                  (list (list :set-permission-mode mode))))
               (t
                (%add-entry state :kind :error
                                  :text (format nil "unknown permission mode ~s: use ~{~a~^, ~}"
                                                argument +permission-mode-names+))
                '())))
        (t
         (%add-entry state :kind :error
                           :text (format nil "unknown command ~a: try /help" command))
         '())))))

(defun %submit (state text)
  (cond ((%blank-text-p text) '())
        ((char= #\/ (char (string-left-trim '(#\Space #\Tab #\Newline #\Return) text) 0))
         (%command state text))
        ((state-busy-p state)
         (setf (state-queue state) (append (state-queue state) (list text)))
         '())
        (t (%core-start-turn state text))))

(defun %core-part (state text)
  (let ((last (car (last (state-transcript state)))))
    (if (and last (eq :assistant (entry-kind last)))
        (setf (entry-text last) (concatenate 'string (entry-text last) text))
        (%add-entry state :kind :assistant :text text)))
  '())

(defun %core-invocation (state inv)
  (let* ((id (agent:agent-invocation-id inv))
         (entry (find-if (lambda (e) (and (eq :tool (entry-kind e)) (equal id (entry-id e))))
                         (state-transcript state))))
    (unless entry
      (setf entry (%add-entry state :kind :tool :id id :name (agent:agent-invocation-name inv))))
    (setf (entry-input entry) (agent:agent-invocation-arguments inv)
          (entry-status entry) (agent:agent-invocation-status inv)
          (entry-result entry) (let ((r (agent:agent-invocation-result inv)))
                                 (if (or (null r) (stringp r)) r (princ-to-string r)))
          (entry-error-p entry) (and (agent:agent-invocation-error-p inv) t)))
  '())

(defun %on-turn-end (state reason pending message)
  (ecase reason
    (:approval
     (setf (%state-pending state) (copy-list pending)
           (%state-answered state) '())
     '())
    ((:stop :max-steps)
     (setf (state-busy-p state) nil
           (%state-pending state) '()
           (%state-answered state) '())
     (when (and (eq reason :max-steps) message)
       (%add-entry state :kind :notice :text message))
     (let ((next (pop (state-queue state))))
       (if next (%core-start-turn state next) '())))
    ((:canceled :failed)
     (setf (state-busy-p state) nil
           (%state-pending state) '()
           (%state-answered state) '())
     (if (eq reason :canceled)
         (%add-entry state :kind :notice :text "interrupted")
         (%add-entry state :kind :error :text (or message "the turn failed")))
     (let ((queued (shiftf (state-queue state) '())))
       (when queued
         (list (list :restore-input (format nil "~{~a~^~%~}" queued))))))))

(defun %reply (state choice feedback)
  (let ((approvals (state-approvals state)))
    (when approvals
      (let ((inv (first approvals)))
        (setf (%state-answered state)
              (append (%state-answered state)
                      (if (eq choice :reject-all) approvals (list inv))))
        (list (ecase choice
                (:once (list :approve inv :always nil))
                (:always (list :approve inv :always t))
                (:reject (list :deny inv :feedback feedback :all nil))
                (:reject-all (list :deny inv :feedback feedback :all t)))
              (list :resume))))))

(defun interactive-update (state event)
  "→ (values STATE effects) after EVENT (see the file header)."
  (let ((effects
          (destructuring-bind (kind &rest args) event
            (ecase kind
              (:submit (%submit state (first args)))
              (:interrupt (cond ((state-approvals state) (%reply state :reject-all nil))
                                ((state-busy-p state) (list (list :cancel)))
                                (t '())))
              (:quit (%quit-effects state))
              (:part (%core-part state (first args)))
              (:usage (setf (state-usage state) (mapcar #'+ (state-usage state) (first args)))
               '())
              (:invocation (%core-invocation state (first args)))
              (:turn-end (destructuring-bind (&key reason pending message) args
                           (%on-turn-end state reason pending message)))
              (:reply (%reply state (first args) (second args)))
              (:model-set (setf (state-model state) (first args))
               (%add-entry state :kind :notice :text (format nil "model: ~a" (first args)))
               '())
              (:notice (%add-entry state :kind :notice :text (first args)) '())
              (:error (%add-entry state :kind :error :text (first args)) '())))))
    (values state effects)))

(defun %home-relative (dir)
  "DIR (a native directory namestring) with the user's home shown as \"~/\"."
  (let ((home (uiop:native-namestring (user-homedir-pathname))))
    (if (and (plusp (length home)) (uiop:string-prefix-p home dir))
        (concatenate 'string "~" (subseq dir (1- (length home))))
        dir)))

(defun status-line-text (state)
  "→ (values left right) of the status line:
left  \" <model> · <permission mode name> · <cwd>\", the cwd as a native
      directory namestring with the user's home directory prefix shown as \"~/\";
right \"<input> in · <output> out \", the summed input and output tokens."
  (let ((cwd (state-cwd state)))
    (values (format nil " ~a · ~a · ~a"
                    (state-model state)
                    (permission-mode-name (state-permission-mode state))
                    (if cwd
                        (%home-relative (uiop:native-namestring
                                         (uiop:ensure-directory-pathname cwd)))
                        ""))
            (destructuring-bind (input output &rest more) (state-usage state)
              (declare (ignore more))
              (format nil "~d in · ~d out " input output)))))
