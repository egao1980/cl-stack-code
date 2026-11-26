(in-package #:cl-stack-code)

;;; H4b: the Lisp image layer: lisp-mcp/agent's tools next to the file and
;;; shell tools, one live image, and its debugger events in the agent's inbox.
;;;
;;; Settings and flags (given: src/settings.lisp, src/arguments.lisp)
;;;   "lispImage": {"image", "backend", "observe", "onDebugger"}, merged per
;;;   key; --lisp-image spawn|attach:[HOST:]PORT|off and --lisp-observe go to
;;;   the flag layer. LISP-IMAGE-SETTINGS → (values image backend observe
;;;   on-debugger); LISP-IMAGE-ENABLED-P. Nothing below runs when the merged
;;;   SETTINGS-LISP-IMAGE is NIL (no layer sets a lispImage key), so every
;;;   H3a–H5b path is unchanged.
;;;
;;; Checks (CHECK-LISP-IMAGE-SETTINGS SETTINGS MODE), in -p and in
;;; MAKE-CODE-PROGRAM whenever SETTINGS-LISP-IMAGE is not NIL, before anything
;;; starts (no session written, no model call), CODE-USAGE-ERROR (exit 2):
;;;   observe without attach   "--lisp-observe needs --lisp-image attach:[HOST:]PORT (an observer attaches; it does not spawn)"
;;;   MODE :PLAN, image on     "--lisp-image is not available in plan mode yet (the image would not see the plan area)"
;;;
;;; The source (MAKE-CODE-LISP-TOOLS CWD SETTINGS &key ON-IMAGE-EVENT)
;;;   LISP-MCP/AGENT:MAKE-LISP-TOOLS rooted at CWD, every group, :MODE :OBSERVE
;;;   when observe (else :FULL), :NEEDS-APPROVAL T, :IMAGE-EVENTS T,
;;;   :ON-IMAGE-EVENT as given, and :TOOLS = its catalog minus the names
;;;   HIDDEN-TOOL-NAMES hides (a resource-* deny rule hides a lisp tool as it
;;;   hides a file tool). MAKE-CODE-TOOLS returns it third, after the file and
;;;   shell tools, when LISP-IMAGE-ENABLED-P: (file-tools shell-tools
;;;   lisp-tools). The offered names are the three sources' in that order.
;;;   Permission rules use lisp-mcp's names and resources unchanged:
;;;   repl-eval(lisp:pure), debug-invoke-restart(restart:retry-later),
;;;   repl-load-system(system:my-app). A rule's SPEC is kept as written for
;;;   these tools (PARSE-PERMISSION-RULE's "any other tool" case).
;;;
;;; Starting the image (START-LISP-IMAGE TOOLS SETTINGS) → the tool's text
;;;   spawn   CALL-LISP-TOOL "repl-spawn" {"backend": B, "name": "image"}
;;;   attach  CALL-LISP-TOOL "repl-connect" {"host": H, "port": P,
;;;           "backend": B, "name": "image"}
;;;   The product starts the image itself, before the first turn: permission
;;;   rules do not apply (the user asked for it). Any error →
;;;   LISP-IMAGE-ERROR (exit 1): "cannot start the Lisp image: <cause>" or
;;;   "cannot attach to the Lisp image at H:P: <cause>". The connection is
;;;   named +LISP-IMAGE-CONNECTION+. At the end (headless) or on
;;;   CLOSE-CODE-PROGRAM, CLOSE-LISP-TOOLS: a spawned image is killed, an
;;;   attached one keeps running.
;;;
;;; LISP-IMAGE-DESCRIPTION SETTINGS
;;;   "image (spawned, swank)", "image (attached 127.0.0.1:4005, slynk)",
;;;   "image (attached 127.0.0.1:4005, swank, observe)".
;;;
;;; System prompt (ASSEMBLE-SYSTEM-PROMPT … :LISP-IMAGE TOOLS): after the
;;;   # Environment section (or the plan sections), one section
;;;     # Lisp image
;;;     - Image: <LISP-IMAGE-DESCRIPTION>
;;;     <LISP-MCP/AGENT:LISP-TOOLS-INSTRUCTIONS TOOLS>
;;;   %LISP-IMAGE-SECTIONS TOOLS SETTINGS → that list of one string.
;;;
;;; Events (the source's ON-IMAGE-EVENT; never on the UI thread)
;;;   A queued event (:debugger, :job) is described for people by
;;;   IMAGE-EVENT-NOTICE: "λ image entered the debugger (thread T, level L):
;;;   <the condition's first line>" or "λ image: job jN done" / "λ image: job
;;;   jN failed". IMAGE-EVENT-MESSAGE EVENT → the core event
;;;     (:image-event :kind K :connection C :thread T :level L
;;;                   :condition X :job J :notice N)
;;;   and a :debugger-return → (:image-return :connection C :thread T :level L).
;;;
;;; Headless (-p)
;;;   With the image on: CHECK-LISP-IMAGE-SETTINGS, the three sources,
;;;   START-LISP-IMAGE before the system event, the system prompt section.
;;;   stream-json: the system init event gains "lisp_image": {"name","kind"
;;;   ("spawn"|"attach"),"backend","host","port" (null for spawn),"observe"}
;;;   (only when the image is on). Each queued event, when it arrives, is a
;;;   line {"type":"image_event","kind":"debugger"|"job","connection",
;;;   "thread","level","job","text"} (null where the event has none), written
;;;   on the loop thread, and while the run is going (started, not finished)
;;;   it is posted into the run (LISP-MCP/AGENT:POST-IMAGE-EVENTS): the model
;;;   sees it before its next generate, and a post during the final answer
;;;   makes the loop take one more step (ai-agent-protocol). -p never waits
;;;   for events after the run: they are dropped when the tools close. A
;;;   restart asks (H4a) and -p denies the ask unless a rule allows it
;;;   (permission_denials reason "headless"). Observe mode refuses as a tool
;;;   result in every permission mode, bypassPermissions too. The result
;;;   object is unchanged.
;;;
;;; Interactive (see interactive.lisp "H4b" and program.lisp "H4b")
;;;   MAKE-CODE-PROGRAM does the headless setup (errors before the terminal:
;;;   exit 2 for the checks, 1 for LISP-IMAGE-ERROR) and gives the state
;;;   LISP-IMAGE-STATE. The callback TUI-SENDs IMAGE-EVENT-MESSAGE. The core's
;;;   effects: (:post-image-events) → on the agent thread, POST-IMAGE-EVENTS
;;;   into the run while it is going (else they stay queued);
;;;   (:image-turn) → take the queued events and start a turn (RUN-AI-AGENT-ASYNC
;;;   on the session's turns, or CONTINUE-AI-AGENT-ASYNC) whose message is the
;;;   first event's turn, the others posted right after; none queued → send
;;;   (:turn-end :reason :stop). Its session record's prompt is the first
;;;   event's text. Every :run also posts the queued events right after its
;;;   message (the "notice" policy's events reach the model with the user's
;;;   next message). At each turn end that leaves the program idle, queued
;;;   events → (:image-pending N). The banner (IMAGE-BANNER-TEXT) is one row
;;;   directly above the "─" rule while it is non-NIL. The status line shows
;;;   %IMAGE-MARKER.

(defparameter +lisp-image-connection+ "image"
  "H4b: the connection name of the product's image.")

(defparameter +observe-needs-attach+
  "--lisp-observe needs --lisp-image attach:[HOST:]PORT (an observer attaches; it does not spawn)"
  "The CODE-USAGE-ERROR message of observe without attach.")

(defparameter +image-not-in-plan+
  "--lisp-image is not available in plan mode yet (the image would not see the plan area)"
  "The CODE-USAGE-ERROR message of the image in plan mode.")

(defparameter +image-not-in-preview+
  "--lisp-image is not available in preview mode yet (the image would not see the preview area)"
  "H5c-0: the CODE-USAGE-ERROR message of the image in preview mode.")

(defun check-lisp-image-settings (settings mode)
  "→ T when SETTINGS's lispImage goes with permission MODE; otherwise
CODE-USAGE-ERROR (see the file header). H5c-0: refused in plan mode and in
preview mode, each with its own text."
  (multiple-value-bind (image backend observe) (lisp-image-settings settings)
    (declare (ignore backend))
    (cond ((and observe (not (eq :attach (first image))))
           (error 'code-usage-error :message +observe-needs-attach+))
          ((and (member mode '(:plan :preview)) (lisp-image-enabled-p settings))
           (error 'code-usage-error
                  :message (if (eq mode :plan) +image-not-in-plan+ +image-not-in-preview+)))
          (t t))))

(defun %condition-text (condition)
  "CONDITION's report, or its type when the report fails."
  (handler-case (princ-to-string condition)
    (error () (format nil "~a" (type-of condition)))))

(defun %lisp-image-failure (image cause text)
  "Signal LISP-IMAGE-ERROR for designator IMAGE with CAUSE (a condition or
NIL) and the cause's TEXT."
  (error 'lisp-image-error
         :image image :cause cause
         :message (if (eq :attach (first image))
                      (format nil "cannot attach to the Lisp image at ~a:~d: ~a"
                              (second image) (third image) text)
                      (format nil "cannot start the Lisp image: ~a" text))))

(defun make-code-lisp-tools (cwd settings &key on-image-event)
  "→ the LISP-MCP/AGENT:LISP-TOOLS for CWD and SETTINGS (see the file header)."
  (multiple-value-bind (image backend observe) (lisp-image-settings settings)
    (declare (ignore backend))
    (let ((root (uiop:ensure-directory-pathname cwd))
          (mode (if observe :observe :full)))
      (flet ((make (&optional tools)
               (lt:make-lisp-tools :root root :groups nil :tools tools :mode mode
                                   :needs-approval t :image-events t
                                   :on-image-event on-image-event)))
        ;; A source made without :TOOLS offers the catalog (filtered by MODE),
        ;; so its names are valid :TOOLS for the real one. It has no
        ;; connection yet: closing it is cheap.
        (let* ((source (make))
               (names (lt:lisp-tools-names source))
               (hidden (hidden-tool-names settings names)))
          (if (null hidden)
              source
              (let ((keep (remove-if (lambda (name) (member name hidden :test #'string=))
                                     names)))
                (lt:close-lisp-tools source)
                ;; :TOOLS NIL would mean "every tool".
                (when (null keep)
                  (%lisp-image-failure image nil "every lisp tool is hidden by a deny rule"))
                (make keep))))))))

(defun start-lisp-image (tools settings)
  "Spawn or attach SETTINGS's image on TOOLS. → the tool's result text;
LISP-IMAGE-ERROR when it fails."
  (multiple-value-bind (image backend) (lisp-image-settings settings)
    (destructuring-bind (kind &optional host port) image
      (handler-case
          (if (eq kind :attach)
              (lt:call-lisp-tool tools "repl-connect"
                                 (%json-object "host" host "port" port "backend" backend
                                               "name" +lisp-image-connection+))
              (lt:call-lisp-tool tools "repl-spawn"
                                 (%json-object "backend" backend
                                               "name" +lisp-image-connection+)))
        ;; ERROR, not SERIOUS-CONDITION: an interrupt keeps its own exit.
        (error (e)
          (%lisp-image-failure image e (%condition-text e)))))))

(defun lisp-image-description (settings)
  "\"image (spawned, swank)\", \"image (attached H:P, B[, observe])\"."
  (multiple-value-bind (image backend observe) (lisp-image-settings settings)
    (if (eq :attach (first image))
        (format nil "image (attached ~a:~d, ~a~:[~;, observe~])"
                (second image) (third image) backend observe)
        (format nil "image (spawned, ~a)" backend))))

(defun %lisp-image-sections (tools settings)
  "→ (\"# Lisp image…\"), the system prompt section for TOOLS."
  (list (format nil "# Lisp image~%- Image: ~a~%~a"
                (lisp-image-description settings)
                (lt:lisp-tools-instructions tools))))

(defun %lisp-image-object (settings)
  "The headless init event's \"lisp_image\" object for SETTINGS."
  (multiple-value-bind (image backend observe) (lisp-image-settings settings)
    (let ((attach (eq :attach (first image))))
      (%json-object "name" +lisp-image-connection+
                    "kind" (if attach "attach" "spawn")
                    "backend" backend
                    "host" (if attach (second image) :null)
                    "port" (if attach (third image) :null)
                    "observe" (and observe t)))))

(defun lisp-image-state (settings)
  "→ the interactive state's image plist for SETTINGS: (:name \"image\"
:description (LISP-IMAGE-DESCRIPTION) :observe B :on-debugger P :debuggers ()),
or NIL when the image is off."
  (when (lisp-image-enabled-p settings)
    (multiple-value-bind (image backend observe on-debugger) (lisp-image-settings settings)
      (declare (ignore image backend))
      (list :name +lisp-image-connection+
            :description (lisp-image-description settings)
            :observe (and observe t)
            :on-debugger on-debugger
            :debuggers '()))))

(defun %image-first-line (text)
  (let ((text (or text "")))
    (subseq text 0 (or (position #\Newline text) (length text)))))

(defun image-event-notice (event)
  "The transcript notice for a queued LISP-MCP/AGENT:IMAGE-EVENT."
  (ecase (lt:image-event-kind event)
    (:debugger
     (format nil "λ image entered the debugger (thread ~a, level ~a): ~a"
             (lt:image-event-thread event) (lt:image-event-level event)
             (%image-first-line (lt:image-event-condition event))))
    (:job
     (format nil "λ image: job ~a ~(~a~)"
             (lt:image-event-job event) (lt:image-event-job-state event)))
    (:debugger-return nil)))

(defun image-event-message (event)
  "The core event for EVENT: (:image-event …) or (:image-return …)."
  (if (eq :debugger-return (lt:image-event-kind event))
      (list :image-return
            :connection (lt:image-event-connection event)
            :thread (lt:image-event-thread event)
            :level (lt:image-event-level event))
      (list :image-event
            :kind (lt:image-event-kind event)
            :connection (lt:image-event-connection event)
            :thread (lt:image-event-thread event)
            :level (lt:image-event-level event)
            :condition (lt:image-event-condition event)
            :job (lt:image-event-job event)
            :notice (image-event-notice event))))

(defun image-banner-text (state)
  "NIL, or \"λ image is in the debugger: <condition> (thread T)\" for the
newest debugger of STATE-IMAGE, with \" (+K more)\" when K more wait."
  (let ((debuggers (getf (state-image state) :debuggers)))
    (when debuggers
      (let ((newest (first debuggers)))
        (format nil "λ image is in the debugger: ~a (thread ~a)~@[ (+~d more)~]"
                (%image-first-line (getf newest :condition))
                (getf newest :thread)
                (and (rest debuggers) (length (rest debuggers))))))))

(defun %image-marker (state)
  "The status line's image marker: \"λ image\", \"λ image (observe)\",
\"λ image (debugger)\" or \"λ image (observe, debugger)\"."
  (let ((image (state-image state)))
    (format nil "λ image~@[ (~{~a~^, ~})~]"
            (remove nil (list (and (getf image :observe) "observe")
                              (and (getf image :debuggers) "debugger"))))))

(defun %image-event (state event)
  "The core's H4b events (see interactive.lisp \"H4b\"). → effects."
  (flet ((debuggers () (getf (state-image state) :debuggers))
         (set-debuggers (value) (setf (getf (state-image state) :debuggers) value))
         (image-turn ()
           (setf (state-busy-p state) t)
           (list (list :image-turn)))
         (turn-policy-p () (eq :turn (getf (state-image state) :on-debugger))))
    (destructuring-bind (kind &rest args) event
      (ecase kind
        (:image-event
         (destructuring-bind (&key ((:kind event-kind)) connection thread level condition
                                   notice &allow-other-keys)
             args
           (%add-entry state :kind :notice :text notice)
           (when (eq event-kind :debugger)
             (set-debuggers
              (cons (list :connection connection :thread thread :level level
                          :condition condition)
                    (remove-if (lambda (d)
                                 (and (equal connection (getf d :connection))
                                      (equal thread (getf d :thread))
                                      (eql level (getf d :level))))
                               (debuggers)))))
           (cond ((state-busy-p state) (list (list :post-image-events)))
                 ((turn-policy-p) (image-turn))
                 (t '()))))
        (:image-return
         (destructuring-bind (&key connection thread level &allow-other-keys) args
           (set-debuggers
            (remove-if (lambda (d)
                         (and (equal connection (getf d :connection))
                              (equal thread (getf d :thread))
                              (realp level) (realp (getf d :level))
                              (>= (getf d :level) level)))
                       (debuggers)))
           '()))
        (:image-pending
         (let ((n (first args)))
           (if (and (not (state-busy-p state)) (integerp n) (plusp n) (turn-policy-p))
               (image-turn)
               '())))))))

;;; The image link (private): how the source's ON-IMAGE-EVENT reaches the
;;; product. One lock covers three states: buffering (no sink yet: before
;;; the TUI runs), attached (each event goes to the sink) and closed (events
;;; are dropped). The sink only queues (EVENT:WAKE-CALL or TUI:TUI-SEND), so
;;; holding the lock while it runs is short; after %LINK-CLOSE returns no sink
;;; call is in flight and none follows, so the caller may free its event loop.
;;; Lock order: lisp-mcp calls ON-IMAGE-EVENT outside its own lock, and
;;; %LINK-CLOSE releases this lock before CLOSE-LISP-TOOLS takes lisp-mcp's.

(defstruct (%image-link (:conc-name %link-) (:constructor %make-image-link ()))
  (tools nil)                           ; the LISP-TOOLS, once made
  (lock (bt:make-lock "cl-stack-code image link"))
  (sink nil)                            ; (lambda (event)), or NIL: buffer
  (buffer '())                          ; events before the sink, newest first
  (closed nil))

(defun %link-callback (link)
  "The source's :ON-IMAGE-EVENT for LINK (a reader or job thread)."
  (lambda (tools event)
    (declare (ignore tools))
    (bt:with-lock-held ((%link-lock link))
      (cond ((%link-closed link) nil)
            ((%link-sink link) (funcall (%link-sink link) event))
            (t (push event (%link-buffer link)))))
    nil))

(defun %link-attach (link sink)
  "Deliver LINK's events to SINK from now on; the buffered ones go first, in
order."
  (bt:with-lock-held ((%link-lock link))
    (unless (%link-closed link)
      (setf (%link-sink link) sink)
      (dolist (event (reverse (shiftf (%link-buffer link) '())))
        (funcall sink event))))
  link)

(defun %link-close (link)
  "Stop LINK's deliveries, then CLOSE-LISP-TOOLS its tools (a spawned image
is killed, an attached one keeps running). Idempotent. → NIL"
  (when link
    (bt:with-lock-held ((%link-lock link))
      (setf (%link-closed link) t
            (%link-sink link) nil
            (%link-buffer link) '()))
    (let ((tools (%link-tools link)))
      (when tools
        (lt:close-lisp-tools tools))))
  nil)

(defun %post-if-going (tools run)
  "POST-IMAGE-EVENTS of TOOLS into RUN while it is going (started, not
finished); otherwise the events stay queued."
  (when (and tools run (null (agent:agent-run-finish-reason run)))
    (lt:post-image-events tools run)))
