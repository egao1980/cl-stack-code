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
;;;                 acceptEdits, bypassPermissions, plan, preview"
;;;   /exit         as (:quit)
;;;   other         :error "unknown command /X: try /help"
;;; While busy only /help and /exit run; /clear, /model and /permissions add
;;; an :error naming the command (and saying Esc interrupts) and do nothing.
;;;
;;; H3c: sessions and steering
;;;
;;; Events
;;;   (:steer TEXT)           Ctrl-T on the input (or /steer TEXT)
;;;   (:steered TEXTS)        the agent took these steering messages into the
;;;                           running turn (its :inbox event), oldest first
;;;   (:session ID)           the program's session is now ID
;;;   (:session-reset :entries ENTRIES [:input TEXT] [:notice M])
;;;                           the head moved (/fork, /rewind): the transcript
;;;                           is now ENTRIES
;;;
;;; Effects
;;;   (:steer TEXT)           post TEXT (mentions expanded) into the running
;;;                           turn with AGENT-RUN-POST; the program answers
;;;                           (:steered (TEXT)) once the run takes it
;;;   (:tree)                 the program answers (:notice <SESSION-TREE-LINES
;;;                           joined by LF>)
;;;   (:fork AT)              FORK-TURN (AT a string or NIL); the program
;;;                           answers (:session-reset …) or (:error M)
;;;   (:rewind N)             REWIND-SESSION; same answers
;;;   (:clone)                CLONE-SESSION; the program answers (:session ID)
;;;                           and (:notice "cloned session OLD as NEW")
;;;   (:export FILE)          EXPORT-SESSION to FILE (relative to the working
;;;                           directory; .json → JSON, anything else →
;;;                           markdown); (:notice "exported N turn[s] to PATH")
;;;                           or (:error M)
;;;
;;; Rules
;;;   :steer    Blank: nothing. Text starting with "/" or idle: as :submit.
;;;             Busy: TEXT is appended to STATE-STEERING (no entry yet),
;;;             effect (:steer TEXT).
;;;   :steered  Each text leaves STATE-STEERING (the first equal one) and
;;;             becomes a :user entry, in order.
;;;   :turn-end :stop / :max-steps: steering still pending was not taken by
;;;             the turn; it goes to the front of the queue (in order) before
;;;             the queue's first message starts the next turn.
;;;             :canceled / :failed: the input gets the pending steering,
;;;             then the queue, joined by LF (one :restore-input); both are
;;;             emptied.
;;;   :session  STATE-SESSION-ID becomes ID.
;;;   :session-reset  The transcript becomes a copy of ENTRIES, then a
;;;             :notice M when given; queue and steering emptied; usage kept;
;;;             effect (:restore-input TEXT) when TEXT is given.
;;;
;;; Commands
;;;   /session      :notice "session <STATE-SESSION-ID>"
;;;   /tree         (:tree)
;;;   /fork [AT]    (:fork AT), AT NIL without an argument
;;;   /rewind [N]   N a positive decimal integer, default 1: (:rewind N);
;;;                 anything else: :error "usage: /rewind [N], N a positive
;;;                 number of turns"
;;;   /clone        (:clone)
;;;   /export FILE  (:export FILE); no argument: :error "usage: /export FILE
;;;                 (.md or .json)"
;;;   /steer TEXT   as (:steer TEXT); no argument: :error "usage: /steer
;;;                 MESSAGE"
;;; While busy /session, /tree and /steer run as well; /fork, /rewind,
;;; /clone and /export add the same :error as /clear does.
;;;
;;; H5a: plans (src/plans.lisp). <id8> is the plan id's first 8 characters.
;;;
;;; Events
;;;   (:plan-opened :id ID :kind K :root ROOT)
;;;                           the program opened (or reopened) the plan
;;;   (:plan-projected :id ID :changes C :diff TEXT)
;;;                           the projected change, C = PLAN-CHANGES
;;;   (:plan-drift :paths P)  approval found the working copy changed at P
;;;   (:plan-closed :status S [:changes C] [:conflicts X])
;;;                           S :applied :empty :discarded :rebased :aborted
;;;
;;; Effects
;;;   (:show-plan)            the program answers (:plan-projected …)
;;;   (:approve-plan [:on-drift M])
;;;                           APPROVE-PLAN; PLAN-DRIFT → (:plan-drift :paths
;;;                           P) unless M (:rebase / :overwrite) picks the
;;;                           restart; then (:plan-closed …), and after a
;;;                           rebase (:plan-projected …) again
;;;   (:reject-plan)          REJECT-PLAN; (:plan-closed :status :discarded)
;;;
;;; State
;;;   STATE-PLAN              NIL, or (:id ID :kind K :root ROOT :changes C
;;;                           :diff TEXT) of the open plan
;;;   STATE-PLAN-PROMPT       NIL, :plan (the plan dialog, +PLAN-CHOICES+) or
;;;                           :drift (the drift dialog, +DRIFT-CHOICES+)
;;;
;;; Rules
;;;   :plan-opened   STATE-PLAN = (:id :kind :root, no changes); :notice
;;;             "plan <id8> (<kind>): edits go to a copy of the project in
;;;             <ROOT>; the project changes only when you approve".
;;;   :plan-projected  STATE-PLAN gets :changes and :diff. C empty: :notice
;;;             "plan <id8>: no changes yet". Otherwise a :plan entry (ID =
;;;             the plan id, TEXT = the diff, INPUT = C) and, when idle,
;;;             STATE-PLAN-PROMPT :plan.
;;;   :plan-drift  STATE-PLAN-PROMPT :drift; :error "the working copy
;;;             changed since plan <id8> was opened: P1, P2".
;;;   :plan-closed  :applied → :notice "plan <id8> applied: N file[s]
;;;             changed", STATE-PLAN NIL; :empty → :notice "plan <id8> had no
;;;             changes", STATE-PLAN NIL; :discarded → :notice "plan <id8>
;;;             discarded", STATE-PLAN NIL; :rebased → :notice "plan <id8>
;;;             rebased onto the working copy" + "; conflicts in P1, P2" when
;;;             X; :aborted → :notice "nothing applied; plan <id8> stays
;;;             open". STATE-PLAN-PROMPT NIL in every case.
;;;   :reply    With no approvals waiting and STATE-PLAN-PROMPT :plan:
;;;             :approve → (:approve-plan); :reject → (:reject-plan);
;;;             :continue → :notice "plan <id8> stays open: send a message to
;;;             keep planning, /plan to review it". With :drift: :rebase →
;;;             (:approve-plan :on-drift :rebase); :overwrite →
;;;             (:approve-plan :on-drift :overwrite); :abort → nothing more.
;;;             Every answer sets STATE-PLAN-PROMPT NIL.
;;;   :interrupt  With no approvals and a plan prompt: :plan as :continue,
;;;             :drift as :abort.
;;;   :turn-end  Unchanged; the program sends :plan-projected after a :stop
;;;             or :max-steps turn end of a plan turn.
;;;
;;; Commands
;;;   /plan     no open plan: :notice "no open plan"; else (:show-plan)
;;;   /approve  no open plan: :error "no open plan"; else (:approve-plan)
;;;   /reject   no open plan: :error "no open plan"; else (:reject-plan)
;;;   /clear, and /permissions with a mode other than plan, while a plan is
;;;             open: :error "plan <id8> is open: /approve or /reject it
;;;             first" and nothing else.
;;; While busy /plan, /approve and /reject add the same :error as /clear.
;;;
;;; H5b: checkpoints and rewind (src/checkpoints.lisp).
;;;
;;; Events
;;;   (:rewind-prompt :n N :turn T :paths P)
;;;                           /rewind [N] without a part: the program found
;;;                           that turn T's files differ from the tip's at P
;;;   (:rewind-drift :paths P)  a files rewind found the working copy changed
;;;                           at P since the tip checkpoint
;;;   (:rewound :turn T :parts PARTS :conversation C :files F :changes CH
;;;             :conflicts X)  a rewind finished (REWIND-TO's result)
;;;
;;; Effects
;;;   (:checkpoints)          the program answers (:notice <CHECKPOINT-SUMMARY-
;;;                           LINES joined by LF>), "checkpoints are off" when
;;;                           the checkpointer is disabled and there are none
;;;   (:rewind N :parts P [:on-drift M])
;;;                           REWIND-TO the turn N back on the head's line
;;;                           (its line number, 0 when N is the line's
;;;                           length) with PARTS P; PLAN-DRIFT → (:rewind-
;;;                           drift :paths …) and ABORT-APPROVAL unless M
;;;                           (:rebase / :overwrite) picks the restart; then
;;;                           (:rewound …) and, when the conversation moved,
;;;                           H3c's (:session-reset :entries …) first.
;;;                           (:rewind N) without :parts stays H3c's effect;
;;;                           the program turns it into (:rewind-prompt …)
;;;                           when turn T has a checkpoint whose files differ
;;;                           from the tip's, and rewinds the conversation
;;;                           only (H3c) otherwise.
;;;
;;; State
;;;   STATE-REWIND            NIL, or (:n N :turn T :parts P :paths PATHS)
;;;   STATE-REWIND-PROMPT     NIL, :rewind (the rewind dialog,
;;;                           +REWIND-CHOICES+) or :drift (+DRIFT-CHOICES+)
;;;
;;; Commands
;;;   /checkpoints  (:checkpoints); also while busy (like /tree)
;;;   /rewind [N] [PART]
;;;             PART one of conversation, files, both (→ PARTS
;;;             (:conversation), (:files), (:conversation :files)); N as in
;;;             H3c (default 1). With a PART: (:rewind N :parts P) and
;;;             STATE-REWIND (:n N :parts P). Without a PART: H3c's (:rewind
;;;             N). A second word that is not a PART, or more words: :error
;;;             "usage: /rewind [N] [conversation|files|both]". A bad N keeps
;;;             H3c's error. PARTS with :files while a plan is open: :error
;;;             "plan <id8> is open: /approve or /reject it first". Busy:
;;;             H3c's "/rewind is not available while a turn runs (Esc
;;;             interrupts it)".
;;;
;;; Rules
;;;   :rewind-prompt  STATE-REWIND (:n N :turn T :paths P), STATE-REWIND-
;;;             PROMPT :rewind.
;;;   :reply    With no approvals and no plan prompt, and STATE-REWIND-PROMPT
;;;             :rewind: :both → (:rewind N :parts (:conversation :files)),
;;;             :conversation → (:rewind N :parts (:conversation)), :files →
;;;             (:rewind N :parts (:files)) (STATE-REWIND gets :parts);
;;;             :cancel → :notice "rewind canceled", STATE-REWIND NIL.
;;;             :drift: :rebase / :overwrite → (:rewind N :parts P :on-drift
;;;             :rebase / :overwrite) with STATE-REWIND's N and P; :abort →
;;;             :notice "nothing restored", STATE-REWIND NIL. Every answer sets
;;;             STATE-REWIND-PROMPT NIL.
;;;   :interrupt  With no approvals and no plan prompt: :rewind as :cancel,
;;;             :drift as :abort.
;;;   :rewind-drift  STATE-REWIND-PROMPT :drift (STATE-REWIND gets :paths);
;;;             :error "the working copy changed since the last checkpoint:
;;;             P1, P2".
;;;   :rewound  :notice "rewound to turn T: <REWIND-DESCRIPTION>", or
;;;             "nothing restored" for F :aborted; STATE-REWIND and
;;;             STATE-REWIND-PROMPT NIL.
;;;
;;; H4b: the Lisp image (src/lisp-image.lisp).
;;;
;;; State
;;;   STATE-IMAGE             NIL (no image), or (:name N :description D
;;;                           :observe B :on-debugger :turn|:notice
;;;                           :debuggers DS); DS is a list of (:connection C
;;;                           :thread T :level L :condition X), newest first
;;;
;;; Events
;;;   (:image-event :kind K :connection C :thread T :level L :condition X
;;;                 :job J :notice N)
;;;                           the source queued an image event (K :debugger
;;;                           or :job)
;;;   (:image-return :connection C :thread T :level L)
;;;                           the image left a debugger level
;;;   (:image-pending N)      a turn ended and N events are still queued
;;;
;;; Effects
;;;   (:post-image-events)    post the queued events into the running turn
;;;   (:image-turn)           start a turn whose message is the queued events
;;;
;;; Rules (STATE-IMAGE NIL: these events change nothing and give no effects)
;;;   :image-event  A :notice entry N. K :debugger: (:connection C :thread T
;;;             :level L :condition X) goes to the front of DS, replacing an
;;;             entry with the same connection, thread and level. Then: busy
;;;             → ((:post-image-events)); idle and :on-debugger :turn → busy,
;;;             ((:image-turn)); idle and :notice → no effect (the events
;;;             reach the model with the next message).
;;;   :image-return  Every DS entry of that connection and thread whose
;;;             level is >= L leaves DS. No entry, no effect.
;;;   :image-pending  Idle, N > 0 and :on-debugger :turn → busy,
;;;             ((:image-turn)); otherwise nothing.
;;;   Status line: with STATE-IMAGE, the left side is " <model> · <mode> ·
;;;   <%IMAGE-MARKER> · <cwd>"; the marker says (debugger) while DS is not
;;;   empty. IMAGE-BANNER-TEXT is the banner row.
;;;
;;; H8d: units (src/units.lisp, src/unit-panel.lisp).
;;;
;;; Events
;;;   (:units :running N)     the supervisor's live unit count changed
;;;   (:unit-failed :notice TEXT)  a unit failed (UNIT-FAILURE-NOTICE)
;;;
;;; Effects
;;;   (:units-panel)          the program opens the unit panel
;;;
;;; State
;;;   STATE-UNITS-RUNNING     the live count, 0 at first (given)
;;;
;;; Rules
;;;   :units        STATE-UNITS-RUNNING becomes N; no entry, no effect.
;;;   :unit-failed  a :notice TEXT; no effect (idle or busy).
;;;   Status line: the right side is "N running · <in> in · <out> out " while
;;;   N > 0, else unchanged (%UNITS-MARKER, given).
;;;
;;; Commands
;;;   /ps           no argument: (:units-panel); anything else: :error
;;;                 "usage: /ps". Also while busy (like /tree).


(defparameter +help-text+
  (format nil "~{~a~^~%~}"
          '("Commands:"
            "  /help                 this help"
            "  /clear                start a new conversation"
            "  /model [MODEL]        show or switch the model (provider or provider:model)"
            "  /permissions [MODE]   show the rules, or switch to default, acceptEdits, bypassPermissions, plan or preview"
            "  /session              show the session id"
            "  /tree                 show the session's turns as a tree"
            "  /fork [AT]            branch off before turn AT (a number or an id from /tree; default the last)"
            "  /rewind [N] [PART]    go back N turns (default 1): conversation, files or both; later turns stay in /tree"
            "  /checkpoints          list the session's checkpoints (the file states /rewind restores)"
            "  /clone                continue in a copy of this session"
            "  /export FILE          write the conversation as markdown, or JSON for a .json FILE"
            "  /steer MESSAGE        send MESSAGE into the running turn (also Ctrl-T)"
            "  /plan, /save-plan     show the plan document; save it under docs/plans/"
            "  /approve [accept|ask|preview]  run the plan, or apply the open preview"
            "  /reject               reject the plan, or discard the open preview"
            "  /preview              show the open preview's projected change"
            "  /ps                   the session's units (shell jobs, servers, subagents): logs, search, stop (also Ctrl-P)"
            "  /mcp [reconnect [N]]  MCP servers: status and tools; reconnect one or all"
            "  /compact [TEXT]       summarize the conversation now (TEXT: what the summary must keep)"
            "  /retry                re-send the last turn after it failed"
            "  /exit                 quit (also Ctrl-D, or Ctrl-C on an empty input)"
            "Keys:"
            "  Enter send · Alt+Enter, Shift+Enter or Ctrl+J newline · Up/Down history"
            "  @path attach a file (Tab completes) · PgUp/PgDn scroll"
            "  Esc interrupt the turn · Enter while a turn runs queues a follow-up"
            "  Ctrl-T while a turn runs steers it: the message reaches the model before its next step"))
  "The /help notice.")

(defparameter +approval-choices+
  '((:once "Allow once")
    (:always "Always allow")
    (:reject "Reject")
    (:reject-all "Reject all"))
  "The approval dialog's choices (W:CONFIRM-DIALOG :choices). :reject asks
for feedback.")

(defparameter +plan-choices+
  '((:approve "Approve")
    (:continue "Keep working")
    (:reject "Reject"))
  "H5a: the preview dialog's choices (H5c-0: \"Keep working\").")

(defparameter +drift-choices+
  '((:rebase "Rebase onto the working copy")
    (:overwrite "Overwrite")
    (:abort "Cancel"))
  "H5a: the drift dialog's choices.")

(defparameter +rewind-choices+
  '((:both "Conversation and files")
    (:conversation "Conversation only")
    (:files "Files only")
    (:cancel "Cancel"))
  "H5b: the rewind dialog's choices.")

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
   (quit :initform nil :accessor state-quit-p)
   ;; H3c
   (steering :initform '() :accessor state-steering
             :documentation "Steering messages sent into the running turn and
not taken yet, oldest first.")
   (session-id :initarg :session-id :initform nil :accessor state-session-id
               :documentation "The program's session id.")
   ;; H5a
   (plan :initform nil :accessor state-plan
         :documentation "NIL, or (:id ID :kind K :root ROOT :changes C :diff TEXT).")
   (plan-prompt :initform nil :accessor state-plan-prompt
                :documentation "NIL, :PLAN or :DRIFT: the plan dialog to show.")
   ;; H5c-0
   (plan-document :initform nil :accessor state-plan-document
                  :documentation "NIL, or (:id :revision :status :title :steps :path) of the
session's plan document (src/plan-docs.lisp header, INTERACTIVE).")
   (plan-document-prompt :initform nil :accessor state-plan-document-prompt
                         :documentation "NIL, :PLAN-DOC (+PLAN-DOCUMENT-CHOICES+) or :PLAN-RESULT
(+PLAN-RESULT-CHOICES+).")
   (plan-document-pending :initform nil :accessor %state-plan-document-pending
                          :documentation "The dialog to show when the running turn ends.")
   ;; H5b
   (rewind :initform nil :accessor state-rewind
           :documentation "NIL, or (:n N :turn T :parts P :paths PATHS) of the rewind being
asked about or run.")
   (rewind-prompt :initform nil :accessor state-rewind-prompt
                  :documentation "NIL, :REWIND (the rewind dialog, +REWIND-CHOICES+) or :DRIFT
(the rewind's drift dialog, +DRIFT-CHOICES+).")
   ;; H4b
   (image :initarg :image :initform nil :accessor state-image
          :documentation "NIL, or the image plist (see the \"H4b\" part of the file header).")
   ;; H8d
   (units-running :initform 0 :accessor state-units-running
                  :documentation "Live units of the session's supervisor (the status line).")
   ;; H3e-2a (src/mcp.lisp)
   (mcp :initform '() :accessor state-mcp
        :documentation "The MCP servers (MCP-CONNECTION-OBJECT hash tables), from (:mcp-status …).")
   (mcp-prompt :initform '() :accessor state-mcp-prompt
               :documentation "((NAME . MESSAGE) …): project servers waiting for the approval dialog.")
   ;; H3f (src/resilience.lisp, "TUI")
   (retry :initform nil :accessor state-retry
          :documentation "NIL, or (PLIST . DEADLINE): the retry waiting, DEADLINE an internal real time.")
   (context :initform nil :accessor state-context
            :documentation "NIL, or \"ctx P%\" of the last response.")
   ;; H3e-2b (src/mcp-requests.lisp)
   (mcp-requests :initform '() :accessor state-mcp-requests
                 :documentation "The MCP servers' sampling and elicitation requests waiting for
the dialog (their approval_request objects), oldest first."))
  (:documentation "What the interactive mode knows; see INTERACTIVE-UPDATE."))

(defun make-interactive-state (&key (model +default-model+) (permission-mode :default)
                                    cwd rules session-id image)
  "→ a fresh INTERACTIVE-STATE: empty transcript, idle, usage zero. IMAGE
(H4b): LISP-IMAGE-STATE's plist, or NIL."
  (make-instance 'interactive-state :model model :permission-mode permission-mode
                                    :cwd cwd :rules rules :session-id session-id
                                    :image (copy-tree image)))

(defun %session-command (state command argument)
  "H3c: run the session command COMMAND (\"/session\" \"/tree\" \"/fork\"
\"/rewind\" \"/clone\" \"/export\" \"/steer\") with ARGUMENT (trimmed, \"\" when
none). → effects (see the file header)."
  (flet ((fail (text)
           (%add-entry state :kind :error :text text)
           '()))
    (cond
      ((and (state-busy-p state)
            (member command '("/fork" "/rewind" "/clone" "/export") :test #'string=))
       (fail (format nil "~a is not available while a turn runs (Esc interrupts it)" command)))
      ((string= command "/session")
       (%add-entry state :kind :notice
                         :text (format nil "session ~a" (state-session-id state)))
       '())
      ((string= command "/tree") (list (list :tree)))
      ((string= command "/fork")
       (list (list :fork (if (zerop (length argument)) nil argument))))
      ;; H5b
      ((string= command "/checkpoints") (list (list :checkpoints)))
      ((and (string= command "/rewind") (%rewind-part-argument-p argument))
       (%rewind-command state argument))
      ((string= command "/rewind")
       (let ((n (cond ((zerop (length argument)) 1)
                      ((every #'digit-char-p argument) (parse-integer argument))
                      (t nil))))
         (if (and n (plusp n))
             (list (list :rewind n))
             (fail "usage: /rewind [N], N a positive number of turns"))))
      ((string= command "/clone") (list (list :clone)))
      ((string= command "/export")
       (if (zerop (length argument))
           (fail "usage: /export FILE (.md or .json)")
           (list (list :export argument))))
      ((string= command "/steer")
       (if (zerop (length argument))
           (fail "usage: /steer MESSAGE")
           (%session-event state (list :steer argument))))
      (t (fail (format nil "unknown command ~a: try /help" command))))))

(defun %remove-first (item list)
  "LIST without its first element EQUAL to ITEM."
  (let ((pos (position item list :test #'equal)))
    (if pos
        (append (subseq list 0 pos) (nthcdr (1+ pos) list))
        list)))

(defun %session-event (state event)
  "H3c: apply EVENT, one of (:steer …) (:steered …) (:session …)
(:session-reset …). → effects (see the file header)."
  (destructuring-bind (kind &rest args) event
    (ecase kind
      (:steer
       (let ((text (first args)))
         (cond ((%blank-text-p text) '())
               ((or (not (state-busy-p state))
                    (char= #\/ (char (string-left-trim '(#\Space #\Tab #\Newline #\Return) text) 0)))
                (%submit state text))
               (t
                (setf (state-steering state) (append (state-steering state) (list text)))
                (list (list :steer text))))))
      (:steered
       (dolist (text (first args))
         (setf (state-steering state) (%remove-first text (state-steering state)))
         (%add-entry state :kind :user :text text))
       '())
      (:session
       (setf (state-session-id state) (first args))
       '())
      (:session-reset
       (destructuring-bind (&key entries input notice) args
         (setf (state-transcript state) (copy-list entries)
               (state-queue state) '()
               (state-steering state) '())
         (when notice
           (%add-entry state :kind :notice :text notice))
         (and input (list (list :restore-input input))))))))

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
        ((member command '("/session" "/tree" "/fork" "/rewind" "/clone" "/export" "/steer"
                           "/checkpoints")
                 :test #'string=)
         (%session-command state command argument))
        ;; H5c-0: the plan document first, then the preview (H5a).
        ((member command '("/plan" "/approve" "/reject" "/save-plan" "/preview") :test #'string=)
         (%plan-doc-command state command argument))
        ;; H5a
        ((and (state-plan state)
              (or (string= command "/clear")
                  (and (string= command "/permissions")
                       (plusp (length argument))
                       (not (eq :preview (parse-permission-mode argument))))))
         (%plan-command state command argument))
        ;; H5c-0: a proposed plan waits for /approve or /reject.
        ((and (string= command "/clear") (not busy) (%plan-doc-waiting-p state))
         (%add-entry state :kind :error
                           :text (format nil "plan ~a is waiting: /approve or /reject it first"
                                         (%plan-doc-id8 state)))
         '())
        ;; H8d
        ((string= command "/ps") (%units-command state argument))
        ;; H3f
        ((member command '("/compact" "/retry") :test #'string=)
         (cond (busy
                (%add-entry state :kind :error
                                  :text (format nil "~a is not available while a turn runs (Esc interrupts it)"
                                                command))
                '())
               ((string= command "/compact")
                (setf (state-busy-p state) t)
                (list (list :compact (and (plusp (length argument)) argument))))
               (t
                (setf (state-busy-p state) t)
                (list (list :retry-turn)))))
        ;; H3e-2a
        ((string= command "/mcp") (%mcp-command state argument))
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
                (let* ((mode (parse-permission-mode argument))
                       ;; H5a: /permissions preview with a preview open stays in preview mode.
                       ;; H5c-0: with a plan waiting the mode changes in the state;
                       ;; the program takes it before the next turn.
                       (stays (or (and (state-plan state) (eq mode (state-permission-mode state)))
                                  (%plan-doc-waiting-p state))))
                  (setf (state-permission-mode state) mode)
                  (%add-entry state :kind :notice
                                    :text (format nil "permission mode: ~a"
                                                  (permission-mode-name mode)))
                  (unless stays
                    (list (list :set-permission-mode mode)))))
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
     ;; Steering the turn did not take is the first follow-up.
     (setf (state-queue state) (append (shiftf (state-steering state) '())
                                       (state-queue state)))
     (let ((next (pop (state-queue state))))
       (if next (%core-start-turn state next) '())))
    ((:canceled :failed)
     (setf (state-busy-p state) nil
           (%state-pending state) '()
           (%state-answered state) '())
     (if (eq reason :canceled)
         (%add-entry state :kind :notice :text "interrupted")
         (%add-entry state :kind :error :text (or message "the turn failed")))
     (let ((queued (append (shiftf (state-steering state) '())
                           (shiftf (state-queue state) '()))))
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
                                ;; H5c-0
                                ((state-plan-document-prompt state) (%plan-doc-event state event))
                                ((state-plan-prompt state) (%plan-event state event))
                                ((state-rewind-prompt state) (%rewind-event state event))
                                ((state-busy-p state) (list (list :cancel)))
                                (t '())))
              (:quit (%quit-effects state))
              (:part (setf (state-retry state) nil)
                     (%core-part state (first args)))
              (:usage (setf (state-usage state) (mapcar #'+ (state-usage state) (first args)))
                      '())
              (:invocation (%core-invocation state (first args)))
              (:turn-end (destructuring-bind (&key reason pending message retryable) args
                           (setf (state-retry state) nil)
                           (prog1 (%on-turn-end state reason pending
                                                (if (and retryable message (eq reason :failed))
                                                    (concatenate 'string message " — /retry to send it again")
                                                    message))
                             ;; H5c-0: the plan dialog waited for the turn's end.
                             (let ((pending (and (not (state-busy-p state))
                                                 (shiftf (%state-plan-document-pending state) nil))))
                               (when pending
                                 (setf (state-plan-document-prompt state) pending))))))
              ;; H3f
              ((:retry :compacted :continuation :truncated :context :retry-refused
                :compact-done)
               (%resilience-event state event))
              (:reply (cond ((state-approvals state) (%reply state (first args) (second args)))
                            ;; H5c-0
                            ((state-plan-document-prompt state) (%plan-doc-event state event))
                            ((state-plan-prompt state) (%plan-event state event))
                            ;; H5b
                            ((state-rewind-prompt state) (%rewind-event state event))
                            (t (%reply state (first args) (second args)))))
              (:model-set (setf (state-model state) (first args))
                          (%add-entry state :kind :notice :text (format nil "model: ~a" (first args)))
                          '())
              (:notice (%add-entry state :kind :notice :text (first args)) '())
              (:error (%add-entry state :kind :error :text (first args)) '())
              ((:steer :steered :session :session-reset) (%session-event state event))
              ((:plan-opened :plan-projected :plan-drift :plan-closed)
               (%plan-event state event))
              ;; H5c-0
              ((:plan-doc-opened :plan-proposed :plan-step :plan-executed :plan-doc-closed
                :plan-doc-saved :plan-doc-show :plan-execution)
               (%plan-doc-event state event))
              ;; H5b
              ((:rewind-prompt :rewind-drift :rewound) (%rewind-event state event))
              ;; H4b
              ((:image-event :image-return :image-pending)
               (if (state-image state) (%image-event state event) '()))
              ;; H8d
              ((:units :unit-failed) (%units-event state event))
              ;; H3e-2a
              ((:mcp-status :mcp-approval :mcp-reply) (%mcp-event state event))
              ;; H3e-2b
              ((:mcp-request :mcp-request-reply :mcp-request-resolved)
               (%mcp-request-event state event))))))
    (values state effects)))

;;; H3f: resilience events (src/resilience.lisp, "TUI").

(defun %resilience-event (state event)
  (destructuring-bind (kind &rest args) event
    (ecase kind
      (:retry (let* ((plist (first args))
                     (delay (or (getf plist :delay) 0)))
                (setf (state-retry state)
                      (cons plist (+ (get-internal-real-time)
                                     (round (* delay internal-time-units-per-second))))))
       '())
      (:compacted (%add-entry state :kind :notice :text (compact-notice-text (first args)))
       '())
      ((:continuation :truncated) '())
      (:context (setf (state-context state) (context-status-text (first args) (second args)))
       '())
      (:retry-refused (setf (state-busy-p state) nil)
       (%add-entry state :kind :error :text (first args))
       '())
      (:compact-done (setf (state-busy-p state) nil)
       (when (first args)
         (%add-entry state :kind :notice :text (first args)))
       '()))))

(defun state-retry-notice (state)
  "The spinner row's text while a retry waits, or NIL."
  (let ((retry (state-retry state)))
    (and retry
         (retry-notice-text (car retry)
                            (max 0 (/ (- (cdr retry) (get-internal-real-time))
                                      internal-time-units-per-second))))))

(defun %home-relative (dir)
  "DIR (a native directory namestring) with the user's home shown as \"~/\"."
  (let ((home (uiop:native-namestring (user-homedir-pathname))))
    (if (and (plusp (length home)) (uiop:string-prefix-p home dir))
        (concatenate 'string "~" (subseq dir (1- (length home))))
        dir)))

(defun %text-width (string)
  "Display width of STRING in cells."
  (w:runs-width string))

(defun %elide-directory (dir width)
  "DIR (a native directory namestring) in at most WIDTH columns: when it does
not fit, its middle becomes \"…\", keeping its first component (\"~/\", \"/srv/\",
\"C:\\\") and as many of its last components as fit, at least the last one,
the project directory (\"/srv/…/demo/app/\"). When that is still too wide the
head goes too (\"…/app/\"), and the status line cuts what remains."
  (if (<= (%text-width dir) width)
      dir
      (let* ((seps (loop for i from 0 below (length dir)
                         when (member (char dir i) '(#\/ #\\)) collect i))
             (n (length seps)))
        (if (< n 2)
            dir
            (let* ((head-end (1+ (if (and (>= n 3) (zerop (first seps)))
                                     (second seps)
                                     (first seps))))
                   (head (subseq dir 0 head-end)))
              (flet ((elided (k &optional (head head))
                       ;; HEAD, "…", then DIR from its K-th separator on.
                       (concatenate 'string head "…" (subseq dir (nth k seps)))))
                (or (loop with best = nil
                          for k from (- n 2) downto 0
                          while (>= (nth k seps) head-end)
                          do (let ((candidate (elided k)))
                               (if (<= (%text-width candidate) width)
                                   (setf best candidate)
                                   (loop-finish)))
                          finally (return best))
                    (elided (- n 2) ""))))))))

(defun %units-marker (state)
  "H8d: \"N running\" while STATE-UNITS-RUNNING is positive, else NIL."
  (let ((n (state-units-running state)))
    (and (plusp n) (format nil "~d running" n))))

(defun %token-count (n)
  "N tokens as the status line shows them: below 1000 as is, then 1.2k, 52k,
1.3M (truncated, not rounded)."
  (cond ((< n 1000) (format nil "~d" n))
        ((< n 10000) (multiple-value-bind (k r) (floor n 1000)
                       (format nil "~d.~dk" k (floor r 100))))
        ((< n 1000000) (format nil "~dk" (floor n 1000)))
        (t (multiple-value-bind (m r) (floor n 1000000)
             (format nil "~d.~dM" m (floor r 100000))))))

(defun status-line-text (state &optional width)
  "→ (values left right) of the status line:
left  \" <model> · <permission mode name> · <cwd>\", the cwd as a native
      directory namestring with the user's home directory prefix shown as \"~/\";
right \"<input> in[ (<cached> cached)] · <output> out \", the summed tokens:
      input is the whole prompt, uncached input plus cache reads and cache
      writes (LLM-USAGE-PROMPT-TOKENS; #50: Anthropic's input_tokens alone
      leaves the cached prefix out), cached the cache reads when there are
      any; counts from 1000 on as 1.2k, 52k, 1.3M (%TOKEN-COUNT);
      H8d: prefixed by \"N running · \" while N > 0 units are live.
With WIDTH (the status line's columns) a cwd that does not fit loses its
middle, not its end: the project directory name stays (#4)."
  (let* ((cwd (state-cwd state))
         (prefix (format nil " ~a · ~a · ~@[~a · ~]"
                         (state-model state)
                         (permission-mode-name (state-permission-mode state))
                         ;; H4b
                         (and (state-image state) (%image-marker state))))
         (dir (if cwd
                  (%home-relative (uiop:native-namestring
                                   (uiop:ensure-directory-pathname cwd)))
                  ""))
         (right (destructuring-bind (input output &optional (cache-read 0) (cache-write 0))
                    (state-usage state)
                  (format nil "~@[~a · ~]~a in~@[ (~a cached)~] · ~a out ~@[· ~a ~]"
                          (%units-marker state)
                          (%token-count (+ input cache-read cache-write))
                          (and (plusp cache-read) (%token-count cache-read))
                          (%token-count output)
                          ;; H3f
                          (state-context state)))))
    ;; The widget gives the left side WIDTH - right - 1 columns (all of
    ;; WIDTH when the right side is dropped, at right + 2 > WIDTH).
    (when (and width (plusp (length dir)))
      (let* ((rw (%text-width right))
             (room (- (if (> (+ rw 2) width) width (- width rw 1))
                      (%text-width prefix))))
        (setf dir (%elide-directory dir (max 0 room)))))
    (values (concatenate 'string prefix dir) right)))

;;; H5a: plans (see the file header).

(defun %plan-id8 (state)
  "The open plan's id, first 8 characters (\"\" without a plan)."
  (let ((id (or (getf (state-plan state) :id) "")))
    (subseq id 0 (min 8 (length id)))))

(defun %plan-command (state command argument)
  "Run the preview command COMMAND (\"/preview\" \"/approve\" \"/reject\"), or
refuse \"/clear\" / \"/permissions ARGUMENT\" while a preview is open. →
effects."
  (declare (ignore argument))
  (flet ((entry (kind text)
           (%add-entry state :kind kind :text text)
           '()))
    (cond
      ((state-busy-p state)
       (entry :error (format nil "~a is not available while a turn runs (Esc interrupts it)"
                             command)))
      ((member command '("/clear" "/permissions") :test #'string=)
       (entry :error (format nil "preview ~a is open: /approve or /reject it first"
                             (%plan-id8 state))))
      ((and (null (state-plan state)) (string= command "/preview"))
       (entry :notice "no open preview"))
      ((null (state-plan state))
       (entry :error "no proposed plan or open preview"))
      ((string= command "/preview") (list (list :show-plan)))
      ((string= command "/approve") (list (list :approve-plan)))
      (t (list (list :reject-plan))))))

(defun %plan-continue-notice (state)
  (%add-entry state :kind :notice
                    :text (format nil "preview ~a stays open: send a message to keep working, /preview to review it"
                                  (%plan-id8 state)))
  '())

(defun %plan-reply (state choice)
  "Answer the plan or drift dialog with CHOICE. → effects."
  (let ((prompt (shiftf (state-plan-prompt state) nil)))
    (ecase prompt
      (:plan
       (ecase choice
         (:approve (list (list :approve-plan)))
         (:reject (list (list :reject-plan)))
         (:continue (%plan-continue-notice state))))
      (:drift
       (ecase choice
         (:rebase (list (list :approve-plan :on-drift :rebase)))
         (:overwrite (list (list :approve-plan :on-drift :overwrite)))
         (:abort '()))))))

(defun %plan-closed (state status changes conflicts)
  (let ((id8 (%plan-id8 state)))
    (setf (state-plan-prompt state) nil)
    (%add-entry
     state :kind :notice
     :text (ecase status
             (:applied (format nil "preview ~a applied: ~d file~:p changed" id8 (length changes)))
             (:empty (format nil "preview ~a had no changes" id8))
             (:discarded (format nil "preview ~a discarded" id8))
             (:rebased (format nil "preview ~a rebased onto the working copy~@[; conflicts in ~{~a~^, ~}~]"
                               id8 conflicts))
             (:aborted (format nil "nothing applied; preview ~a stays open" id8))))
    (when (member status '(:applied :empty :discarded))
      (setf (state-plan state) nil))
    '()))

(defun %plan-event (state event)
  "Apply EVENT, one of (:plan-opened …) (:plan-projected …) (:plan-drift …)
(:plan-closed …), or a (:reply …) / (:interrupt) answering the preview prompt.
→ effects. (H5a's events; the user sees \"preview\".)"
  (destructuring-bind (kind &rest args) event
    (ecase kind
      (:plan-opened
       (destructuring-bind (&key id kind root) args
         (setf (state-plan state) (list :id id :kind kind :root root :changes '() :diff "")
               (state-plan-prompt state) nil)
         (%add-entry state :kind :notice
                           :text (format nil "preview ~a (~(~a~)): edits go to a copy of the project in ~a; the project changes only when you approve"
                                         (%plan-id8 state) kind root))
         '()))
      (:plan-projected
       (destructuring-bind (&key id changes diff) args
         (let ((plan (state-plan state)))
           (setf (state-plan state)
                 (list :id (or id (getf plan :id)) :kind (getf plan :kind) :root (getf plan :root)
                       :changes changes :diff (or diff ""))))
         (cond ((null changes)
                (%add-entry state :kind :notice
                                  :text (format nil "preview ~a: no changes yet" (%plan-id8 state))))
               (t
                (%add-entry state :kind :plan :id (getf (state-plan state) :id)
                                  :text (or diff "") :input changes)
                (unless (state-busy-p state)
                  (setf (state-plan-prompt state) :plan))))
         '()))
      (:plan-drift
       (destructuring-bind (&key paths) args
         (setf (state-plan-prompt state) :drift)
         (%add-entry state :kind :error
                           :text (format nil "the working copy changed since preview ~a was opened: ~{~a~^, ~}"
                                         (%plan-id8 state) paths))
         '()))
      (:plan-closed
       (destructuring-bind (&key status changes conflicts) args
         (%plan-closed state status changes conflicts)))
      (:reply (%plan-reply state (first args)))
      (:interrupt
       (%plan-reply state (if (eq :drift (state-plan-prompt state)) :abort :continue))))))

;;; H5c-0: plan documents (src/plan-docs.lisp header, INTERACTIVE).

(defun %plan-doc-id8 (state)
  (let ((id (or (getf (state-plan-document state) :id) "")))
    (subseq id 0 (min 8 (length id)))))

(defun %plan-doc-waiting-p (state)
  "True when the session's plan document is :PROPOSED."
  (eq :proposed (getf (state-plan-document state) :status)))

(defun %plan-doc-set (state &rest keys)
  (let ((doc (copy-list (state-plan-document state))))
    (loop for (k v) on keys by #'cddr do (setf (getf doc k) v))
    (setf (state-plan-document state) doc)))

(defun %plan-steps-text (steps)
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (s)
                    (format nil "~a ~d. ~a" (%step-mark (getf s :status)) (getf s :index)
                            (getf s :text)))
                  steps)))

(defun %plan-doc-dialog (state prompt)
  "Show PROMPT now when idle, else when the turn ends."
  (if (state-busy-p state)
      (setf (%state-plan-document-pending state) prompt)
      (setf (state-plan-document-prompt state) prompt)))

(defun %plan-doc-revise-notice (state)
  (%add-entry state :kind :notice
                    :text (format nil "plan ~a r~d: send your feedback to revise it, /approve to run it"
                                  (%plan-doc-id8 state)
                                  (or (getf (state-plan-document state) :revision) 0)))
  '())

(defun %plan-doc-approve (state mode)
  "Approve the plan document under MODE: the state's mode switches to it."
  (setf (state-plan-document-prompt state) nil
        (state-permission-mode state) mode)
  (list (list :approve-plan-document :mode mode)))

(defun %plan-doc-reply (state choice)
  (let ((prompt (shiftf (state-plan-document-prompt state) nil)))
    (ecase prompt
      (:plan-doc
       (ecase choice
         (:approve-accept (%plan-doc-approve state :accept-edits))
         (:approve-ask (%plan-doc-approve state :default))
         (:approve-preview (%plan-doc-approve state :preview))
         (:edit (list (list :edit-plan-document)))
         (:revise (%plan-doc-revise-notice state))
         (:reject (list (list :reject-plan-document)))
         (:save (list (list :save-plan-document)))))
      (:plan-result
       (ecase choice
         (:keep '())
         (:rewind-files (list (list :rewind 1 :parts '(:files))))
         (:save (list (list :save-plan-document))))))))

(defparameter +approve-mode-words+
  '(("accept" . :accept-edits) ("ask" . :default) ("preview" . :preview))
  "/approve WORD → the execution mode.")

(defun %plan-doc-command (state command argument)
  "/plan /approve /reject /save-plan act on the plan document; /approve and
/reject on the open preview when there is no document to act on; /preview is
H5a's /plan. → effects."
  (let* ((doc (state-plan-document state))
         (status (getf doc :status)))
    (flet ((entry (kind text)
             (%add-entry state :kind kind :text text)
             '()))
      (cond
        ((string= command "/preview") (%plan-command state command argument))
        ((state-busy-p state)
         (entry :error (format nil "~a is not available while a turn runs (Esc interrupts it)"
                               command)))
        ((string= command "/plan")
         (if (and doc (plusp (or (getf doc :revision) 0)))
             (list (list :show-plan-document))
             (entry :notice "no plan yet")))
        ((string= command "/save-plan")
         (if (and doc (plusp (or (getf doc :revision) 0)))
             (list (list :save-plan-document))
             (entry :notice "no plan yet")))
        ((and (string= command "/approve") (member status '(:proposed :interrupted)))
         (let ((mode (if (zerop (length argument))
                         :accept-edits
                         (cdr (assoc argument +approve-mode-words+ :test #'string-equal)))))
           (if mode
               (%plan-doc-approve state mode)
               (entry :error "usage: /approve [accept|ask|preview]"))))
        ((and (string= command "/reject") (member status '(:drafting :proposed)))
         (setf (state-plan-document-prompt state) nil)
         (list (list :reject-plan-document)))
        (t (%plan-command state command argument))))))

(defun %plan-doc-event (state event)
  "Apply a plan document EVENT (see the file header of src/plan-docs.lisp,
INTERACTIVE). → effects."
  (destructuring-bind (kind &rest args) event
    (ecase kind
      (:plan-doc-opened
       (destructuring-bind (&key id path area) args
         (setf (state-plan-document state)
               (list :id id :revision 0 :status :drafting :title nil :steps '() :path path))
         (%add-entry state :kind :notice
                           :text (format nil "plan ~a: exploring in a copy of the project (~a); nothing there is ever applied"
                                         (%plan-doc-id8 state) area))
         '()))
      (:plan-proposed
       (destructuring-bind (&key id revision title markdown steps) args
         (%plan-doc-set state :id id :revision revision :status :proposed :title title
                              :steps (copy-tree steps))
         (%add-entry state :kind :plan-document :id id :text (or markdown ""))
         (%plan-doc-dialog state :plan-doc)
         '()))
      (:plan-step
       (destructuring-bind (&key id steps) args
         (%plan-doc-set state :steps (copy-tree steps))
         (let ((entry (find-if (lambda (e) (and (eq :plan-steps (entry-kind e)) (equal id (entry-id e))))
                               (state-transcript state))))
           (if entry
               (setf (entry-text entry) (%plan-steps-text steps))
               (%add-entry state :kind :plan-steps :id id :text (%plan-steps-text steps))))
         '()))
      (:plan-executed
       ;; PREVIEW: an execution in preview shows the preview's dialog instead.
       (destructuring-bind (&key id status lines diff preview) args
         (%plan-doc-set state :id id :status status)
         (%add-entry state :kind :plan-result :id id
                           :text (format nil "~{~a~^~%~}~@[~%~%~a~]" lines
                                         (and diff (plusp (length diff)) diff)))
         (unless preview
           (%plan-doc-dialog state :plan-result))
         '()))
      (:plan-doc-closed
       (destructuring-bind (&key id status) args
         (declare (ignore id))
         (let ((id8 (%plan-doc-id8 state)))
           (%add-entry state :kind :notice
                             :text (ecase status
                                     (:rejected (format nil "plan ~a rejected" id8))
                                     (:executed (format nil "plan ~a done" id8))
                                     (:interrupted (format nil "plan ~a stopped before its end: /approve runs the remaining steps" id8))))
           (if (eq status :interrupted)
               (%plan-doc-set state :status :interrupted)
               (setf (state-plan-document state) nil
                     (state-plan-document-prompt state) nil)))
         '()))
      (:plan-doc-saved
       (destructuring-bind (&key path) args
         (%add-entry state :kind :notice
                           :text (format nil "plan ~a saved to ~a" (%plan-doc-id8 state) path))
         (when (%plan-doc-waiting-p state)
           (%plan-doc-dialog state :plan-doc))
         '()))
      (:plan-doc-show
       (%plan-doc-dialog state :plan-doc)
       '())
      (:plan-execution
       ;; The execution turn starts: its message, busy.
       (destructuring-bind (&key text) args
         (%add-entry state :kind :user :text text)
         (setf (state-busy-p state) t)
         '()))
      (:reply (%plan-doc-reply state (first args)))
      (:interrupt
       (if (eq :plan-doc (state-plan-document-prompt state))
           (%plan-doc-reply state :revise)
           (%plan-doc-reply state :keep))))))

;;; H5b: rewind (see the "H5b" part of the file header).

(defparameter +rewind-part-names+ '("conversation" "files" "both")
  "The PART words of /rewind [N] [PART].")

(defun %rewind-part-argument-p (argument)
  "True when the /rewind ARGUMENT is not H3c's: it has more than one word, or
its one word is a PART."
  (let ((words (remove "" (uiop:split-string argument :separator '(#\Space #\Tab))
                       :test #'string=)))
    (or (rest words)
        (and words (member (first words) +rewind-part-names+ :test #'string=)))))

(defun %rewind-command (state argument)
  "/rewind with a PART (or extra words): → effects."
  (flet ((fail (text)
           (%add-entry state :kind :error :text text)
           '()))
    (let* ((words (remove "" (uiop:split-string argument :separator '(#\Space #\Tab))
                          :test #'string=))
           (usage "usage: /rewind [N] [conversation|files|both]"))
      (when (> (length words) 2)
        (return-from %rewind-command (fail usage)))
      (let* ((n-word (and (rest words) (first words)))
             (part (car (last words)))
             (n (cond ((null n-word) 1)
                      ((every #'digit-char-p n-word) (parse-integer n-word))
                      (t nil))))
        (cond
          ((not (and n (plusp n)))
           (fail "usage: /rewind [N], N a positive number of turns"))
          ((not (member part +rewind-part-names+ :test #'string=))
           (fail usage))
          (t
           (let ((parts (cond ((string= part "conversation") (list :conversation))
                              ((string= part "files") (list :files))
                              (t (copy-list +rewind-parts+)))))
             (if (and (member :files parts) (state-plan state))
                 (fail (format nil "preview ~a is open: /approve or /reject it first"
                               (%plan-id8 state)))
                 (progn
                   (setf (state-rewind state) (list :n n :parts parts))
                   (list (list :rewind n :parts parts)))))))))))

(defun %rewind-reply (state choice)
  "Answer the rewind or its drift dialog with CHOICE. → effects."
  (let ((prompt (shiftf (state-rewind-prompt state) nil))
        (rewind (state-rewind state)))
    (flet ((notice (text)
             (setf (state-rewind state) nil)
             (%add-entry state :kind :notice :text text)
             '())
           (run (parts &rest more)
             (setf (getf (state-rewind state) :parts) parts)
             (list (list* :rewind (getf rewind :n) :parts parts more))))
      (ecase prompt
        (:rewind
         (ecase choice
           (:both (run (copy-list +rewind-parts+)))
           (:conversation (run (list :conversation)))
           (:files (run (list :files)))
           (:cancel (notice "rewind canceled"))))
        (:drift
         (ecase choice
           ((:rebase :overwrite) (run (getf rewind :parts) :on-drift choice))
           (:abort (notice "nothing restored"))))))))

(defun %rewind-event (state event)
  "Apply EVENT, one of (:rewind-prompt …) (:rewind-drift …) (:rewound …), or a
(:reply …) / (:interrupt) answering the rewind prompt. → effects."
  (destructuring-bind (kind &rest args) event
    (ecase kind
      (:rewind-prompt
       (destructuring-bind (&key n turn paths &allow-other-keys) args
         (setf (state-rewind state) (list :n n :turn turn :paths (copy-list paths))
               (state-rewind-prompt state) :rewind)
         '()))
      (:rewind-drift
       (destructuring-bind (&key paths &allow-other-keys) args
         (setf (state-rewind-prompt state) :drift
               (getf (state-rewind state) :paths) (copy-list paths))
         (%add-entry state :kind :error
                           :text (format nil "the working copy changed since the last checkpoint: ~{~a~^, ~}"
                                         paths))
         '()))
      (:rewound
       (setf (state-rewind state) nil
             (state-rewind-prompt state) nil)
       (%add-entry state :kind :notice
                         :text (if (eq :aborted (getf args :files))
                                   "nothing restored"
                                   (format nil "rewound to turn ~a: ~a"
                                           (getf args :turn) (rewind-description args))))
       '())
      (:reply (%rewind-reply state (first args)))
      (:interrupt
       (%rewind-reply state (if (eq :drift (state-rewind-prompt state)) :abort :cancel))))))
