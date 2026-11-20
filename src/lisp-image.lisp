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

(defun check-lisp-image-settings (settings mode)
  "→ T when SETTINGS's lispImage goes with permission MODE; otherwise
CODE-USAGE-ERROR (see the file header)."
  (declare (ignore settings mode))
  (%not-implemented 'check-lisp-image-settings))

(defun make-code-lisp-tools (cwd settings &key on-image-event)
  "→ the LISP-MCP/AGENT:LISP-TOOLS for CWD and SETTINGS (see the file header)."
  (declare (ignore cwd settings on-image-event))
  (%not-implemented 'make-code-lisp-tools))

(defun start-lisp-image (tools settings)
  "Spawn or attach SETTINGS's image on TOOLS. → the tool's result text;
LISP-IMAGE-ERROR when it fails."
  (declare (ignore tools settings))
  (%not-implemented 'start-lisp-image))

(defun lisp-image-description (settings)
  "\"image (spawned, swank)\", \"image (attached H:P, B[, observe])\"."
  (declare (ignore settings))
  (%not-implemented 'lisp-image-description))

(defun %lisp-image-sections (tools settings)
  "→ (\"# Lisp image…\"), the system prompt section for TOOLS."
  (declare (ignore tools settings))
  (%not-implemented '%lisp-image-sections))

(defun lisp-image-state (settings)
  "→ the interactive state's image plist for SETTINGS: (:name \"image\"
:description (LISP-IMAGE-DESCRIPTION) :observe B :on-debugger P :debuggers ()),
or NIL when the image is off."
  (declare (ignore settings))
  (%not-implemented 'lisp-image-state))

(defun image-event-notice (event)
  "The transcript notice for a queued LISP-MCP/AGENT:IMAGE-EVENT."
  (declare (ignore event))
  (%not-implemented 'image-event-notice))

(defun image-event-message (event)
  "The core event for EVENT: (:image-event …) or (:image-return …)."
  (declare (ignore event))
  (%not-implemented 'image-event-message))

(defun image-banner-text (state)
  "NIL, or \"λ image is in the debugger: <condition> (thread T)\" for the
newest debugger of STATE-IMAGE, with \" (+K more)\" when K more wait."
  (declare (ignore state))
  (%not-implemented 'image-banner-text))

(defun %image-marker (state)
  "The status line's image marker: \"λ image\", \"λ image (observe)\",
\"λ image (debugger)\" or \"λ image (observe, debugger)\"."
  (declare (ignore state))
  (%not-implemented '%image-marker))

(defun %image-event (state event)
  "The core's H4b events (see interactive.lisp \"H4b\"). → effects."
  (declare (ignore state event))
  (%not-implemented '%image-event))
