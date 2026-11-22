(in-package #:cl-stack-code)

;;; R4d-4b: plan mode's shell runs confined (brief: cl-stack
;;; docs/capabilities/confinement.md § R4d-4; .team-solve/task.md). This file
;;; header gives the exact rules; the tests in tests/sandbox-*.lisp define them.
;;;
;;; THE BACKEND. *PLAN-COMPUTE-BACKEND* is :DEFAULT (the per-OS backend,
;;; DEFAULT-PLAN-COMPUTE-BACKEND), NIL (no backend: plan mode asks) or a
;;; STACK-COMPUTE:CONFINING-BACKEND (tests, embedders). PLAN-COMPUTE-BACKEND
;;; resolves it. DEFAULT-PLAN-COMPUTE-BACKEND makes a fresh backend each call:
;;;   macOS   → (STACK-COMPUTE-SEATBELT:MAKE-SEATBELT-BACKEND)  (#+darwin)
;;;   Linux   → (STACK-COMPUTE-LANDLOCK:MAKE-LANDLOCK-BACKEND)  (#+linux)
;;;   Windows → NIL (compute-backend-mxc is R4e-1), other platforms → NIL.
;;; The backends are (:feature …) dependencies of the .asd, so their packages
;;; exist only on their OS; refer to them under the same feature, read-time.
;;; A host (run-cli's -p run, MAKE-CODE-PROGRAM, MAKE-CLIENT) resolves
;;; PLAN-COMPUTE-BACKEND once, in the thread that makes it, and keeps it: plan
;;; areas open on other threads (the program's agent thread), and a LET
;;; binding of the variable is not seen there.
;;;
;;; THE CONFINEMENT. PLAN-CONFINEMENT PLAN SETTINGS →
;;;   (STACK-COMPUTE:MAKE-CONFINEMENT
;;;     :writable (<physical PLAN-ROOT> <physical PLAN-SCRATCH-DIRECTORY>
;;;                <physical sandbox.extraWritable entries, in order>)
;;;     :read :all :deny-read :default          ; the credential locations
;;;     :network <sandbox.network: :none (default) or :allow>
;;;     :env-mode :scrub                         ; +DEFAULT-ENV-ALLOW+
;;;     :env (("XDG_CACHE_HOME" . <native scratch>/cache/))
;;;     :tmp :private)
;;; and nothing else (no limits). The writable entries are native namestrings
;;; of STACK-COMPUTE:PHYSICAL-PATH of each directory (macOS /tmp →
;;; /private/tmp), the area first. PLAN-SCRATCH-DIRECTORY is
;;; <PLAN-DIRECTORY>/scratch/, created (with cache/ inside) by the first call;
;;; it is outside the area, so nothing in it is part of the projected diff, and
;;; it goes when the plan directory goes. An extraWritable entry that is not an
;;; existing directory → SETTINGS-ERROR, key "sandbox.extraWritable", FILE NIL,
;;; message "<native path> is not a directory" (exit 2). The settings env is
;;; NOT in the confinement: MAKE-CODE-TOOLS already gives it to the shell tools
;;; as :ENV, and agent-tools adds it after the scrub, so it wins over
;;; XDG_CACHE_HOME and over the scrub. --allow-network is the flag layer's
;;; sandbox.network "allow" (src/arguments.lisp), so it reaches here the same
;;; way. sandbox.* is read from the user file and the flag layer only
;;; (LOAD-SETTINGS).
;;;
;;; THE PROBE, when a plan opens or reopens (every host, every process):
;;; OPEN-PLAN-SANDBOX PLAN SETTINGS &KEY BACKEND → a PLAN-SANDBOX. In order:
;;;   1. BACKEND NIL → :UNAVAILABLE, reason +NO-SANDBOX-BACKEND-REASON+.
;;;   2. (PLAN-CONFINEMENT PLAN SETTINGS) — a SETTINGS-ERROR propagates.
;;;   3. STACK-COMPUTE:CONFINEMENT-AVAILABLE-P false → :UNAVAILABLE with its
;;;      reason (or "unavailable" when it gives none).
;;;   4. STACK-COMPUTE:CHECK-CONFINEMENT signals a STACK-COMPUTE:COMPUTE-ERROR
;;;      (unsupported features, unavailable, invalid) → :UNAVAILABLE, reason
;;;      its PRINC-TO-STRING. Nothing uses its USE-VALUE: there is no weaker
;;;      confinement plan mode would accept.
;;;   5. The canary: STACK-COMPUTE:RUN-CONFINED BACKEND CONFINEMENT
;;;      (append (AGENT-TOOLS:DEFAULT-SHELL) '("exit 0")) :DIRECTORY PLAN-ROOT
;;;      :WALL-CLOCK +PLAN-SANDBOX-CANARY-TIMEOUT+. A non-zero exit, NIL, or a
;;;      COMPUTE-ERROR → :UNAVAILABLE, reason
;;;      "the sandbox canary failed: exit N" (+ ": <first non-empty stderr
;;;      line>" when there is one), or "the sandbox canary failed: <condition>".
;;;      It catches a backend that is present but cannot work here (e.g. a
;;;      harness that is itself sandboxed, where sandbox-exec cannot apply).
;;;   6. Else :CONFINED, reason NIL.
;;; :UNAVAILABLE with sandbox.failIfUnavailable → PLAN-SANDBOX-UNAVAILABLE
;;; (plan PLAN, reason, backend) instead of a value: -p exits 1 before the model
;;; is called; the program and the SDK refuse to open the plan (the error is
;;; reported as other plan-open errors are). The sandbox's CONFINEMENT is the
;;; value of step 2 whenever step 2 ran (also when unavailable), else NIL.
;;;
;;; WHILE :CONFINED. The host passes (PLAN-SANDBOX-TOOL-KEYS SB) to
;;; MAKE-CODE-TOOLS (the shell tools confine every command; under the session's
;;; supervisor every bash is a confined :shell-job unit), keeps 0.4.1's plan
;;; base rules (bash and job_input allowed without asking:
;;; SETTINGS-PERMISSION-RULES … :PLAN-SHELL-ALLOWED T) and passes :SANDBOX SB to
;;; ASSEMBLE-SYSTEM-PROMPT, which puts PLAN-SANDBOX-SECTION right after the
;;; +PLAN-MODE-FEEDBACK+ section. The bash tool description states the policy
;;; too (agent-tools' CONFINEMENT-DESCRIPTION), and a blocked command's result
;;; carries agent-tools' "[sandbox: …]" note.
;;;
;;; WHILE :UNAVAILABLE (the 0.4.0 behaviour, never unconfined silently). The
;;; shell tools are made WITHOUT a confinement, the plan base rules lose the
;;; shell allows (:PLAN-SHELL-ALLOWED NIL), so bash and job_input ask before
;;; each call by the shell source's own default; -p refuses that ask with
;;; +HEADLESS-DENIAL-FEEDBACK+ as it refuses every ask. A settings or flag
;;; allow rule still allows (the user's explicit choice, after the notice).
;;; PLAN-SANDBOX-SECTION says there is no sandbox. The notice
;;; (PLAN-SANDBOX-NOTICE) is shown once per plan open:
;;;   -p                 stderr: "cl-stack-code: <notice>" + newline, after
;;;                      the plan is opened, before the model is called
;;;                      (every output format)
;;;   interactive        a :notice transcript entry with the notice text
;;;                      (the (:notice TEXT) event), when the plan opens
;;;   SDK / --rpc        the plan event's "sandbox" object (below) says it
;;; and every host's plan "opened" / "reopened" event (stream-json, the SDK's
;;; and --rpc's plan notifications) gains "sandbox": PLAN-SANDBOX-OBJECT, in
;;; every status. Other events and the result object are unchanged.
;;;
;;; A REFUSAL MID-SESSION. A confined bash whose launch the backend refuses
;;; (AGENT-TOOLS:SHELL-CONFINEMENT-REFUSED: nothing ran) reaches the agent loop
;;; as an AI-AGENT-PROTOCOL:AGENT-TOOL-ERROR whose cause is that condition. The
;;; host handles it with HANDLER-BIND, on the thread where the run's tool
;;; callbacks run: (PLAN-SANDBOX-REFUSED SB (SHELL-CONFINEMENT-REFUSED-CAUSE
;;; cause)); when that returns T, the notice is shown as above; then it invokes
;;; the agent's USE-VALUE restart with (PLAN-SANDBOX-REFUSAL-RESULT SB NAME),
;;; so the model gets that text as the tool's result. The rest of the turn keeps
;;; the confined shell tools (every further bash is refused again, the same
;;; way: fail closed). From the next turn (the program, the SDK; a -p run has
;;; one) the host rebuilds the shell tools without the confinement and with
;;; :PLAN-SHELL-ALLOWED NIL, as for :UNAVAILABLE: bash asks before each call.
;;; With sandbox.failIfUnavailable, the refusal is handled the same way, but
;;; from the next turn bash and job_input are denied (a deny rule with feedback
;;; the refusal result's text) instead of asking.
;;;
;;; Non-plan modes never reach this file: no sandbox, no confinement, no notice,
;;; no "sandbox" key, no prompt section. --lisp-image stays refused in plan
;;; mode (H4b's check): confining the area's image is H5d.
;;;
;;; Given code: the variable, the constants, the PLAN-SANDBOX class and
;;; readers, PLAN-SANDBOX-CONFINED-P, PLAN-SANDBOX-TOOL-KEYS. The functions
;;; below implement the rest; each host wires them (src/headless.lisp,
;;; src/program.lisp, src/client.lisp).

(defvar *plan-compute-backend* :default
  "R4d-4b: the confining backend plan mode uses: :DEFAULT (the per-OS backend,
DEFAULT-PLAN-COMPUTE-BACKEND), NIL (none: plan mode asks before each bash), or
a STACK-COMPUTE:CONFINING-BACKEND. Read once per host (PLAN-COMPUTE-BACKEND).")

(defparameter +no-sandbox-backend-reason+
  #+(or windows win32) "no confining backend on Windows yet (compute-backend-mxc arrives with R4e-1)"
  #-(or windows win32) "no confining backend for this platform"
  "R4d-4b: the reason of a sandbox that has no backend.")

(defparameter +plan-sandbox-statuses+ '(:confined :unavailable :refused)
  "R4d-4b: PLAN-SANDBOX-STATUS values.")

(defparameter +plan-sandbox-canary-timeout+ 10
  "R4d-4b: seconds the canary command may take (OPEN-PLAN-SANDBOX step 5).")

(defclass plan-sandbox ()
  ((plan :initarg :plan :reader plan-sandbox-plan
         :documentation "The PLAN whose shell this sandbox confines.")
   (status :initarg :status :accessor %plan-sandbox-status :reader plan-sandbox-status
           :type (member :confined :unavailable :refused)
           :documentation ":CONFINED (the shell runs confined), :UNAVAILABLE (the
probe failed when the plan opened: the shell asks) or :REFUSED (the backend
refused a command later: the shell asks from the next turn).")
   (backend :initarg :backend :initform nil :reader plan-sandbox-backend
            :documentation "The STACK-COMPUTE:CONFINING-BACKEND, or NIL.")
   (confinement :initarg :confinement :initform nil :reader plan-sandbox-confinement
                :documentation "PLAN-CONFINEMENT of the plan, or NIL when the probe
stopped before it was built.")
   (reason :initarg :reason :initform nil :accessor %plan-sandbox-reason
           :reader plan-sandbox-reason
           :documentation "NIL while :CONFINED, else why not (a string)."))
  (:documentation "R4d-4b: plan mode's sandbox for one plan in one host: the
result of OPEN-PLAN-SANDBOX, changed by PLAN-SANDBOX-REFUSED."))

(defmethod print-object ((sb plan-sandbox) stream)
  (print-unreadable-object (sb stream :type t)
    (format stream "~(~a~)~@[ ~s~]" (plan-sandbox-status sb) (plan-sandbox-reason sb))))

(defun plan-sandbox-p (x)
  (typep x 'plan-sandbox))

(defun plan-sandbox-confined-p (sandbox)
  "True when SANDBOX (a PLAN-SANDBOX or NIL) confines the shell (:CONFINED)."
  (and sandbox (eq :confined (plan-sandbox-status sandbox))))

(defun plan-sandbox-tool-keys (sandbox)
  "→ (:CONFINEMENT c :COMPUTE-BACKEND b) for MAKE-CODE-TOOLS while SANDBOX is
:CONFINED, else NIL (the shell tools are made unconfined and ask)."
  (and (plan-sandbox-confined-p sandbox)
       (list :confinement (plan-sandbox-confinement sandbox)
             :compute-backend (plan-sandbox-backend sandbox))))


;;; The backend.

(defun default-plan-compute-backend ()
  "→ a fresh confining backend for this OS (seatbelt on macOS, landlock on
Linux), or NIL (Windows until R4e-1, other platforms)."
  #+darwin (stack-compute-seatbelt:make-seatbelt-backend)
  #+linux (stack-compute-landlock:make-landlock-backend)
  #-(or darwin linux) nil)

(defun plan-compute-backend ()
  "→ *PLAN-COMPUTE-BACKEND* resolved: :DEFAULT → (DEFAULT-PLAN-COMPUTE-BACKEND),
NIL → NIL, a backend → itself; anything else → TYPE-ERROR."
  (let ((value *plan-compute-backend*))
    (etypecase value
      ((eql :default) (default-plan-compute-backend))
      (null nil)
      (sc:confining-backend value))))

;;; The confinement.

(defun plan-scratch-directory (plan)
  "→ <PLAN-DIRECTORY PLAN>/scratch/ (a directory pathname), created with its
cache/ subdirectory on the first call. Outside the area."
  (let ((scratch (merge-pathnames "scratch/"
                                  (uiop:ensure-directory-pathname (plan-directory plan)))))
    (ensure-directories-exist (merge-pathnames "cache/" scratch))
    scratch))

(defun plan-confinement (plan settings)
  "→ the STACK-COMPUTE:CONFINEMENT of PLAN's shell under SETTINGS (see the file
header, THE CONFINEMENT)."
  (multiple-value-bind (network extra) (sandbox-settings settings)
    (dolist (dir extra)
      (unless (uiop:directory-exists-p dir)
        (error 'settings-error :key "sandbox.extraWritable" :file nil
                               :message (format nil "~a is not a directory"
                                                (uiop:native-namestring dir)))))
    (let ((scratch (plan-scratch-directory plan)))
      (sc:make-confinement
       :writable (mapcar #'sc:physical-path (list* (plan-root plan) scratch extra))
       :read :all
       :deny-read :default
       :network network
       :env-mode :scrub
       :env (list (cons "XDG_CACHE_HOME"
                        (uiop:native-namestring (merge-pathnames "cache/" scratch))))
       :tmp :private))))

;;; The probe.

(defun %first-nonblank-line (text)
  "The first line of TEXT that is not blank, trimmed, or NIL."
  (and (stringp text)
       (loop with start = 0
             for end = (position-if (lambda (ch) (member ch '(#\Newline #\Return))) text
                                    :start start)
             for line = (string-trim '(#\Space #\Tab) (subseq text start end))
             when (plusp (length line)) return line
             while end
             do (setf start (1+ end)))))

(defun %plan-sandbox-canary (backend confinement plan)
  "Step 5 of the probe: → NIL when `exit 0` ran confined in PLAN's area and
exited 0, else the reason (a string)."
  (handler-case
      (let ((result (sc:run-confined backend confinement
                                     (append (tools:default-shell) (list "exit 0"))
                                     :directory (plan-root plan)
                                     :wall-clock +plan-sandbox-canary-timeout+)))
        (cond ((null result) "the sandbox canary failed: exit NIL")
              ((eql 0 (sc:sandbox-result-exit-code result)) nil)
              (t (format nil "the sandbox canary failed: exit ~a~@[: ~a~]"
                         (sc:sandbox-result-exit-code result)
                         (%first-nonblank-line (sc:sandbox-result-stderr result))))))
    ;; SANDBOX-TIMEOUT is a COMPUTE-ERROR: unwinding past it is fine (RUN-CONFINED
    ;; killed the tree and releases the launch). A launch that cannot even be
    ;; spawned (a PROCESS-ERROR) fails closed the same way.
    ((or sc:compute-error pp:process-error) (e)
      (format nil "the sandbox canary failed: ~a" e))))

(defun %plan-sandbox-probe (plan settings backend)
  "Steps 1-5 of the probe. → (values reason confinement); REASON NIL = confined."
  (let ((confinement nil))
    (flet ((fail (reason) (return-from %plan-sandbox-probe (values reason confinement))))
      (unless backend (fail +no-sandbox-backend-reason+))
      (setf confinement (plan-confinement plan settings))
      (multiple-value-bind (ok why) (sc:confinement-available-p backend)
        (unless ok (fail (if (and (stringp why) (plusp (length why))) why "unavailable"))))
      ;; Never CHECK-CONFINEMENT's USE-VALUE: no weaker policy is acceptable.
      (handler-case (sc:check-confinement backend confinement)
        (sc:compute-error (e) (fail (princ-to-string e))))
      (values (%plan-sandbox-canary backend confinement plan) confinement))))

(defun open-plan-sandbox (plan settings &key (backend (plan-compute-backend)))
  "→ a PLAN-SANDBOX for PLAN under SETTINGS, probed through BACKEND (see the
file header, THE PROBE); PLAN-SANDBOX-UNAVAILABLE with sandbox.failIfUnavailable."
  (multiple-value-bind (reason confinement) (%plan-sandbox-probe plan settings backend)
    (cond ((null reason)
           (make-instance 'plan-sandbox :plan plan :status :confined
                                        :backend backend :confinement confinement))
          ((nth-value 2 (sandbox-settings settings))
           (error 'plan-sandbox-unavailable :plan plan :reason reason :backend backend))
          (t
           (make-instance 'plan-sandbox :plan plan :status :unavailable
                                        :backend backend :confinement confinement
                                        :reason reason)))))

(defun plan-sandbox-refused (sandbox cause)
  "A confined command was refused mid-session: SANDBOX becomes :REFUSED with
reason (PRINC-TO-STRING CAUSE) (CAUSE: the STACK-COMPUTE:COMPUTE-ERROR, or a
string). → T the first time, NIL when SANDBOX was already :REFUSED (reason
kept). An :UNAVAILABLE sandbox is left as it is (→ NIL)."
  (when (eq :confined (plan-sandbox-status sandbox))
    (setf (%plan-sandbox-status sandbox) :refused
          (%plan-sandbox-reason sandbox) (princ-to-string cause))
    t))

;;; Texts.

(defun %plan-sandbox-id8 (sandbox)
  (let ((id (plan-id (plan-sandbox-plan sandbox))))
    (subseq id 0 (min 8 (length id)))))

(defun plan-sandbox-notice (sandbox)
  "→ the notice for SANDBOX, or NIL while :CONFINED:
  :UNAVAILABLE \"plan <id8>: no sandbox (<reason>); bash and job_input ask before each command\"
  :REFUSED     \"plan <id8>: the sandbox refused a command (<reason>); bash and job_input ask before each command from the next turn\"
<id8> = the first 8 characters of the plan id."
  (ecase (plan-sandbox-status sandbox)
    (:confined nil)
    (:unavailable
     (format nil "plan ~a: no sandbox (~a); bash and job_input ask before each command"
             (%plan-sandbox-id8 sandbox) (plan-sandbox-reason sandbox)))
    (:refused
     (format nil "plan ~a: the sandbox refused a command (~a); bash and job_input ask before each command from the next turn"
             (%plan-sandbox-id8 sandbox) (plan-sandbox-reason sandbox)))))

(defun plan-sandbox-section (sandbox)
  "→ the system prompt section for SANDBOX:
  :CONFINED  \"# Sandbox\" newline (AGENT-TOOLS:CONFINEMENT-DESCRIPTION confinement)
  otherwise  \"# Sandbox\" newline \"There is no sandbox: <reason>. Each bash and
             job_input call asks the user first, and a headless run (-p)
             refuses it. Prefer the file tools; they stay inside the plan area.\"
(one line after the heading)."
  (if (plan-sandbox-confined-p sandbox)
      (format nil "# Sandbox~%~a"
              (tools:confinement-description (plan-sandbox-confinement sandbox)))
      (format nil "# Sandbox~%There is no sandbox: ~a. Each bash and job_input call asks the user first, and a headless run (-p) refuses it. Prefer the file tools; they stay inside the plan area."
              (plan-sandbox-reason sandbox))))

(defun plan-sandbox-object (sandbox)
  "→ the JSON object (an EQUAL hash table) of SANDBOX for the plan events:
  \"status\"   \"confined\" | \"unavailable\" | \"refused\"
  \"backend\"  the backend's class name, downcased (\"seatbelt-backend\"), or :NULL
  \"network\"  \"none\" | \"allow\" (the confinement's), or :NULL without one
  \"writable\" the confinement's writable directories (a vector of native
             namestrings, the area first), or :NULL without one
  \"reason\"   the reason, or :NULL while :CONFINED"
  (let ((object (make-hash-table :test #'equal))
        (backend (plan-sandbox-backend sandbox))
        (confinement (plan-sandbox-confinement sandbox)))
    (flet ((network-name (network)
             (if (symbolp network)
                 (string-downcase (symbol-name network))
                 "policy")))
      (setf (gethash "status" object) (string-downcase (symbol-name (plan-sandbox-status sandbox)))
            (gethash "backend" object) (if backend
                                           (string-downcase
                                            (symbol-name (class-name (class-of backend))))
                                           :null)
            (gethash "network" object) (if confinement
                                           (network-name (sc:confinement-network confinement))
                                           :null)
            (gethash "writable" object) (if confinement
                                            (map 'vector #'uiop:native-namestring
                                                 (sc:confinement-writable confinement))
                                            :null)
            (gethash "reason" object) (or (plan-sandbox-reason sandbox) :null)))
    object))

(defun plan-sandbox-refusal-result (sandbox name)
  "→ the tool result text for tool NAME after a refusal of SANDBOX:
\"Tool <name> was not run: the sandbox refused it (<reason>). Nothing ran. From
the next turn, bash and job_input ask the user before each command; until
then, continue with the file tools.\""
  (format nil "Tool ~a was not run: the sandbox refused it (~a). Nothing ran. From the next turn, bash and job_input ask the user before each command; until then, continue with the file tools."
          name (plan-sandbox-reason sandbox)))

;;; Host helpers (not exported): the refusal handler and the shell's state.

(defun %plan-sandbox-refusal-handler (sandbox-fn notify)
  "→ a HANDLER-BIND function for AI-AGENT-PROTOCOL:AGENT-TOOL-ERROR (see the
file header, A REFUSAL MID-SESSION). SANDBOX-FN, of the condition, gives the
host's current PLAN-SANDBOX or NIL; NOTIFY (or NIL) gets the notice text the
first time. Declines every other tool error and every refusal outside a
plan sandbox that was confined (the default tool result stays)."
  (lambda (condition)
    (let ((cause (agent:agent-tool-error-cause condition)))
      (when (typep cause 'tools:shell-confinement-refused)
        (let ((sandbox (funcall sandbox-fn condition)))
          (when (and sandbox (member (plan-sandbox-status sandbox) '(:confined :refused)))
            (when (and (plan-sandbox-refused sandbox
                                             (or (tools:shell-confinement-refused-cause cause)
                                                 cause))
                       notify)
              (funcall notify (plan-sandbox-notice sandbox)))
            ;; The innermost USE-VALUE: the agent loop's tool restart.
            (use-value (plan-sandbox-refusal-result
                        sandbox (or (agent:agent-tool-error-name condition) "bash")))))))))

(defun %plan-shell-stale-p (sandbox sources)
  "True when SOURCES' shell tools are still confined but SANDBOX no longer is
(:REFUSED): the host rebuilds them at the next turn's start."
  (and sandbox
       (eq :refused (plan-sandbox-status sandbox))
       (tools:shell-tools-confinement (second sources))
       t))
