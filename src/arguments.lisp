(in-package #:cl-stack-code)

;;; The command line, parsed with cli-protocol on a clingon backend.

(defclass invocation ()
  ((print-p :initarg :print-p :reader invocation-print-p :initform nil)
   (prompt :initarg :prompt :reader invocation-prompt :initform nil
           :documentation "The free arguments joined with single spaces, or
NIL to read the prompt from input (no free argument, or \"-\").")
   (output-format :initarg :output-format :reader invocation-output-format
                  :initform :text
                  :documentation ":TEXT, :JSON or :STREAM-JSON.")
   (output-format-given-p :initarg :output-format-given-p
                          :reader invocation-output-format-given-p :initform nil
                          :documentation "True when --output-format was on the command line.")
   (cwd :initarg :cwd :reader invocation-cwd :initform nil
        :documentation "--cwd as given, or NIL.")
   (help-p :initarg :help-p :reader invocation-help-p :initform nil)
   (version-p :initarg :version-p :reader invocation-version-p :initform nil)
   (settings :initarg :settings :reader invocation-settings
             :documentation "The flag layer: a SETTINGS.")
   ;; H3c
   (continue-p :initarg :continue-p :reader invocation-continue-p :initform nil
               :documentation "-c / --continue: the last session of this project.")
   (resume :initarg :resume :reader invocation-resume :initform nil
           :documentation "-r / --resume ID as given (an id, a prefix or a UUID), or NIL.")
   (session-id :initarg :session-id :reader invocation-session-id :initform nil
               :documentation "--session-id ID as given, or NIL.")
   (fork-session-p :initarg :fork-session-p :reader invocation-fork-session-p
                   :initform nil
                   :documentation "--fork-session: resume into a new session.")
   (list-sessions-p :initarg :list-sessions-p :reader invocation-list-sessions-p
                    :initform nil
                    :documentation "--list-sessions: print this project's sessions.")
   ;; H5a
   (apply-p :initarg :apply-p :reader invocation-apply-p :initform nil
            :documentation "--apply: approve the plan (after the run, or alone with --resume).")
   (reject-p :initarg :reject-p :reader invocation-reject-p :initform nil
             :documentation "--reject: discard the resumed session's open plan.")
   (on-drift :initarg :on-drift :reader invocation-on-drift :initform nil
             :documentation "--on-drift: :ABORT, :REBASE or :OVERWRITE, or NIL (not given).")
   (plan-area :initarg :plan-area :reader invocation-plan-area :initform nil
              :documentation "--plan-area: :AUTO, :GIT or :COPY, or NIL (not given).")
   ;; H5b
   (rewind :initarg :rewind :reader invocation-rewind :initform nil
           :documentation "--rewind TURN as given (\"0\", a turn number, or a turn id prefix), or NIL.")
   (rewind-mode :initarg :rewind-mode :reader invocation-rewind-mode :initform nil
                :documentation "--rewind-mode: :BOTH, :CONVERSATION or :FILES, or NIL (not given).")
   (list-checkpoints-p :initarg :list-checkpoints-p :reader invocation-list-checkpoints-p
                       :initform nil
                       :documentation "--list-checkpoints: print the resumed session's checkpoints.")
   ;; H3d
   (rpc-p :initarg :rpc-p :reader invocation-rpc-p :initform nil
          :documentation "--rpc: serve JSON-RPC 2.0 on standard input and output.")
   ;; ACP-2
   (acp-p :initarg :acp-p :reader invocation-acp-p :initform nil
          :documentation "--acp: serve the Agent Client Protocol on standard input and output."))
  (:documentation "One parsed command line."))

(defparameter +output-format-names+ '("text" "json" "stream-json")
  "The --output-format values, in this order.")

(defun %usage-fail (control &rest args)
  (error 'code-usage-error :message (apply #'format nil control args)))

(defun %make-command (backend)
  "The cl-stack-code command on the cli-protocol BACKEND (*CLI-BACKEND* is not
ours to rebind, so it goes in as :BACKEND)."
  (flet ((opt (name help &rest keys)
           (apply #'cli:make-option :backend backend :name name :help help
                  :key (intern (string-upcase name) :keyword)
                  keys)))
    (cli:make-command
     :backend backend
     :name "cl-stack-code"
     :version +version+
     :description "Coding agent on cl-stack: an interactive terminal session, or -p PROMPT for a headless run."
     :options
     (list (opt "print" "Run headless and print the result (without it: the interactive session)"
                :short #\p :kind :flag)
           (opt "output-format" "text (default), json or stream-json")
           (opt "model" "Model: provider or provider:model (default anthropic)")
           (opt "max-turns" "Model calls before the run stops (an integer >= 1)")
           (opt "cwd" "Working directory (default: the current directory)")
           (opt "allowed-tools" "Allow rules TOOL or TOOL(SPEC), comma or space separated; repeatable"
                :kind :list)
           (opt "disallowed-tools" "Deny rules, same syntax; repeatable" :kind :list)
           (opt "permission-mode" "default, acceptEdits, bypassPermissions or plan")
           (opt "append-system-prompt" "Text appended to the system prompt")
           (opt "model-param" "Model parameter KEY=VALUE for every model call (VALUE as JSON, else a string), e.g. top_k=20; repeatable"
                :kind :list)
           ;; H3c
           (opt "continue" "Continue the last session of this project" :short #\c :kind :flag)
           (opt "resume" "Resume the session with this id (or a unique prefix of it)" :short #\r)
           (opt "session-id" "Id for the new session (32 hex digits or a UUID)")
           (opt "fork-session" "With --resume or --continue: continue in a new session" :kind :flag)
           (opt "list-sessions" "Print this project's sessions, newest first" :kind :flag)
           ;; H5a
           (opt "apply" "Plan mode: apply the projected change (after the run; with --resume and no prompt, at once)"
                :kind :flag)
           (opt "reject" "With --resume or --continue and no prompt: discard the session's open plan"
                :kind :flag)
           (opt "on-drift" "With --apply, when the working copy changed under the plan: abort (default), rebase or overwrite")
           (opt "plan-area" "Plan mode: auto (default), git or copy")
           ;; R4d-4b
           (opt "allow-network" "Plan mode: let the confined shell reach the network (sandbox.network allow)"
                :kind :flag)
           ;; H3e-1
           (opt "skill-dir" "Another skill directory (holding NAME/SKILL.md), absolute or ~/; repeatable (skillDirs)"
                :kind :list)
           (opt "context-file" "Another user-level instruction file, absolute or ~/; repeatable (contextFiles)"
                :kind :list)
           ;; H5b
           (opt "rewind" "With --resume or --continue and no prompt: rewind the session to turn N (0 = its start)")
           (opt "rewind-mode" "With --rewind: both (default), conversation or files")
           (opt "list-checkpoints" "With --resume or --continue: print the session's checkpoints, newest first"
                :kind :flag)
           ;; H4b
           (opt "lisp-image" "Live Lisp image for the lisp tools: spawn, attach:[HOST:]PORT or off")
           (opt "lisp-observe" "With --lisp-image attach:…: the lisp tools only observe the image"
                :kind :flag)
           ;; H3d
           (opt "rpc" "Serve JSON-RPC 2.0 on stdin/stdout (sessions, turns, approvals; see the docs)"
                :kind :flag)
           ;; ACP-2
           (opt "acp" "Serve the Agent Client Protocol on stdin/stdout (for editors: Zed, JetBrains, Emacs)"
                :kind :flag)
           ;; H3e-2a
           (opt "mcp-config" "MCP servers from a file (or JSON text) in .mcp.json shape; repeatable"
                :kind :list)
           (opt "strict-mcp-config" "Use only the --mcp-config servers (ignore .mcp.json and settings)"
                :kind :flag)))))

(defun %lisp-image-flag (value observe)
  "H4b: the flag layer's lispImage plist from --lisp-image VALUE and
--lisp-observe; a VALUE PARSE-LISP-IMAGE-DESIGNATOR refuses →
CODE-USAGE-ERROR \"unknown --lisp-image \\\"X\\\": use spawn, attach:[HOST:]PORT or off\"."
  (append (when value
            (list :image (or (parse-lisp-image-designator value)
                             (%usage-fail "unknown --lisp-image ~s: use spawn, attach:[HOST:]PORT or off"
                                          value))))
          (when observe (list :observe t))))

(defun %model-param-flags (values)
  "The flag layer's modelParams alist from --model-param KEY=VALUE strings,
later ones winning. VALUE is read as JSON, else taken as a string. No \"=\",
an empty KEY, or a non-number temperature / top_p → CODE-USAGE-ERROR."
  (%merge-env
   (list
    (loop for text in values
          collect (let ((sign (position #\= text)))
                    (unless (and sign (plusp sign))
                      (%usage-fail "bad --model-param ~s: use KEY=VALUE" text))
                    (let* ((key (subseq text 0 sign))
                           (raw (subseq text (1+ sign)))
                           (value (handler-case (json:decode raw)
                                    (error () raw))))
                      (handler-case (%check-model-param nil key value)
                        (settings-error ()
                          (%usage-fail "bad --model-param ~s: ~a must be a number"
                                       text key)))))))))

(defun %path-flags (flag values directory)
  "H3e-1: --skill-dir / --context-file VALUES as pathnames (SETTINGS-PATH); a
value that is neither absolute nor \"~/…\" → CODE-USAGE-ERROR
\"FLAG must be an absolute path or start with ~/: \\\"X\\\"\"."
  (loop for value in values
        collect (or (settings-path value :directory directory)
                    (%usage-fail "~a must be an absolute path or start with ~~/: ~s" flag value))))

(defun %output-format (value)
  (cond ((null value) :text)
        ((member value +output-format-names+ :test #'string=)
         (intern (string-upcase value) :keyword))
        (t (%usage-fail "unknown --output-format ~s: use ~{~a~^, ~}"
                        value +output-format-names+))))

(defun %max-turns (value)
  (when value
    (let ((n (handler-case (parse-integer value)
               (error () nil))))
      (unless (and n (>= n 1))
        (%usage-fail "--max-turns must be an integer >= 1, not ~s" value))
      n)))

(defun %permission-mode (value)
  (when value
    (or (parse-permission-mode value)
        (%usage-fail "unknown --permission-mode ~s: use ~{~a~^, ~}"
                     value +permission-mode-names+))))

(defun %flag-rules (values effect)
  (loop for value in values
        append (mapcar (lambda (text) (parse-permission-rule text effect))
                       (split-rule-list value))))

(defparameter +on-drift-names+ '("abort" "rebase" "overwrite")
  "H5a: the --on-drift values.")

(defparameter +plan-area-names+ '("auto" "git" "copy")
  "H5a: the --plan-area values.")

(defparameter +rewind-mode-names+ '("both" "conversation" "files")
  "H5b: the --rewind-mode values.")

(defun %choice-flag (flag value names)
  "VALUE (one of NAMES) as a keyword, NIL when not given; anything else →
CODE-USAGE-ERROR \"unknown FLAG \\\"X\\\": use a, b, c\"."
  (cond ((null value) nil)
        ((member value names :test #'string=) (intern (string-upcase value) :keyword))
        (t (%usage-fail "unknown ~a ~s: use ~{~a~^, ~}" flag value names))))

(defun %prompt (free)
  (and free
       (not (equal free '("-")))
       (format nil "~{~a~^ ~}" free)))

(defun parse-arguments (argv)
  "→ INVOCATION for ARGV (strings, without the program name). Bad values and
unknown options signal CODE-USAGE-ERROR; a bad --allowed-tools /
--disallowed-tools rule signals PERMISSION-RULE-ERROR. Whether -p and a prompt
are present is checked by RUN-CLI, not here."
  (let* ((backend (cli-backend-clingon:make-clingon-backend)) ; *cli-backend* untouched
         (command (%make-command backend)))
    (multiple-value-bind (options free)
        (handler-case (cli:parse command argv :backend backend)
          (cli:cli-error (e)
            (%usage-fail "~a" e)))
      (flet ((get-opt (key) (cli:get-option options key)))
        ;; clingon's built-in --help / --version come back as :HELP / :VERSION
        ;; (cli-protocol 0.2); the other options are not validated then.
        (when (or (get-opt :help) (get-opt :version))
          (return-from parse-arguments
            (make-instance 'invocation :help-p (and (get-opt :help) t)
                                       :version-p (and (get-opt :version) t)
                                       :settings (make-settings))))
        (make-instance
         'invocation
         :print-p (and (get-opt :print) t)
         :prompt (%prompt free)
         :output-format (%output-format (get-opt :output-format))
         :output-format-given-p (and (get-opt :output-format) t)
         :cwd (get-opt :cwd)
         :continue-p (and (get-opt :continue) t)
         :resume (get-opt :resume)
         :session-id (get-opt :session-id)
         :fork-session-p (and (get-opt :fork-session) t)
         :list-sessions-p (and (get-opt :list-sessions) t)
         :apply-p (and (get-opt :apply) t)
         :reject-p (and (get-opt :reject) t)
         :on-drift (%choice-flag "--on-drift" (get-opt :on-drift) +on-drift-names+)
         :plan-area (%choice-flag "--plan-area" (get-opt :plan-area) +plan-area-names+)
         :rewind (get-opt :rewind)
         :rewind-mode (%choice-flag "--rewind-mode" (get-opt :rewind-mode) +rewind-mode-names+)
         :list-checkpoints-p (and (get-opt :list-checkpoints) t)
         :rpc-p (and (get-opt :rpc) t)
         :acp-p (and (get-opt :acp) t)
         :settings (make-settings
                    :model (get-opt :model)
                    :max-turns (%max-turns (get-opt :max-turns))
                    :permission-mode (%permission-mode (get-opt :permission-mode))
                    :append-system-prompt (get-opt :append-system-prompt)
                    :allow (%flag-rules (get-opt :allowed-tools) :allow)
                    :deny (%flag-rules (get-opt :disallowed-tools) :deny)
                    :model-params (%model-param-flags (get-opt :model-param))
                    ;; H4b
                    :lisp-image (%lisp-image-flag (get-opt :lisp-image)
                                                  (get-opt :lisp-observe))
                    ;; R4d-4b
                    :sandbox (and (get-opt :allow-network) (list :network :allow))
                    ;; H3e-1
                    :skill-dirs (%path-flags "--skill-dir" (get-opt :skill-dir) t)
                    :context-files (%path-flags "--context-file" (get-opt :context-file) nil)
                    ;; H3e-2a
                    :mcp (%mcp-flags (get-opt :mcp-config) (get-opt :strict-mcp-config))))))))

(defun %usage-text (stream)
  "Write the --help text to STREAM."
  (let ((backend (cli-backend-clingon:make-clingon-backend)))
    (cli:format-usage (%make-command backend) :stream stream :backend backend)))

;;; H3c: session flags.

(defun check-session-flags (invocation)
  "→ T when INVOCATION's session flags go together; otherwise CODE-USAGE-ERROR:
  --continue with --resume                → \"--continue and --resume cannot be used together\"
  --fork-session without either           → \"--fork-session needs --resume or --continue\"
  --session-id with either, no --fork-session
                                          → \"--session-id with --resume or --continue needs --fork-session\"
  --session-id that NORMALIZE-SESSION-ID refuses
                                          → \"bad session id \\\"X\\\": use 32 hex digits or a UUID\"
  --resume X that is neither a hex prefix of at least 4 characters nor a UUID
                                          → \"bad session id \\\"X\\\": …\" (the same text)
  --list-sessions with any of --continue, --resume, --session-id, --fork-session
                                          → \"--list-sessions cannot be combined with --continue, --resume, --session-id or --fork-session\"
Whether the sessions exist is checked later (SESSION-NOT-FOUND)."
  (let ((continue-p (invocation-continue-p invocation))
        (resume (invocation-resume invocation))
        (session-id (invocation-session-id invocation))
        (fork-p (invocation-fork-session-p invocation)))
    (flet ((bad-id (text)
             (%usage-fail "bad session id ~s: use 32 hex digits or a UUID" text)))
      (when (and (invocation-list-sessions-p invocation)
                 (or continue-p resume session-id fork-p))
        (%usage-fail "--list-sessions cannot be combined with --continue, --resume, --session-id or --fork-session"))
      (when (and continue-p resume)
        (%usage-fail "--continue and --resume cannot be used together"))
      (when (and fork-p (not (or continue-p resume)))
        (%usage-fail "--fork-session needs --resume or --continue"))
      (when (and session-id (or continue-p resume) (not fork-p))
        (%usage-fail "--session-id with --resume or --continue needs --fork-session"))
      (when (and session-id (not (normalize-session-id session-id)))
        (bad-id session-id))
      (when (and resume
                 (not (normalize-session-id resume))
                 (not (and (<= 4 (length resume) 32)
                           (every (lambda (c) (digit-char-p c 16)) resume))))
        (bad-id resume))
      t)))

;;; H5a: plan flags.

(defun check-plan-flags (invocation mode)
  "→ T when INVOCATION's plan flags go together, MODE being the effective
permission mode (flags over settings); otherwise CODE-USAGE-ERROR:
  --apply with --reject                   → \"--apply and --reject cannot be used together\"
  --reject with a prompt, or without --resume / --continue
                                          → \"--reject needs --resume or --continue and no prompt\"
  --on-drift without --apply or --rewind  → \"--on-drift needs --apply or --rewind\"
  --apply with a prompt and MODE not :PLAN, or --plan-area with MODE not :PLAN
                                          → \"--apply and --plan-area need --permission-mode plan\"
  --allow-network with MODE not :PLAN     → \"--allow-network needs --permission-mode plan\"
An action-only invocation (--apply or --reject, --resume or --continue, no
prompt) does not need plan mode; it acts on the session's open plan."
  (let* ((apply-p (invocation-apply-p invocation))
         (reject-p (invocation-reject-p invocation))
         (prompt (invocation-prompt invocation))
         (resumed (or (invocation-continue-p invocation) (invocation-resume invocation)))
         (plan-mode-p (eq mode :plan)))
    (when (and apply-p reject-p)
      (%usage-fail "--apply and --reject cannot be used together"))
    (when (and reject-p (or prompt (not resumed)))
      (%usage-fail "--reject needs --resume or --continue and no prompt"))
    (when (and (invocation-on-drift invocation) (not apply-p) (not (invocation-rewind invocation)))
      (%usage-fail "--on-drift needs --apply or --rewind"))
    (when (and (not plan-mode-p)
               (or (and apply-p (or prompt (not resumed)))
                   (invocation-plan-area invocation)))
      (%usage-fail "--apply and --plan-area need --permission-mode plan"))
    ;; R4d-4b
    (when (and (not plan-mode-p) (invocation-allow-network-p invocation))
      (%usage-fail "--allow-network needs --permission-mode plan"))
    t))

(defun invocation-allow-network-p (invocation)
  "R4d-4b: true when INVOCATION has --allow-network (the flag layer's
sandbox.network \"allow\")."
  (eq :allow (getf (settings-sandbox (invocation-settings invocation)) :network)))

;;; H5b: rewind flags.

(defun check-rewind-flags (invocation)
  "→ T when INVOCATION's rewind flags go together; otherwise CODE-USAGE-ERROR,
checked in this order:
  --rewind-mode without --rewind          → \"--rewind-mode needs --rewind\"
  --rewind or --list-checkpoints with --fork-session
                                          → \"--rewind and --list-checkpoints cannot be combined with --fork-session\"
  --rewind with --apply or --reject       → \"--rewind cannot be combined with --apply or --reject\"
  --rewind with a prompt, or without --resume / --continue
                                          → \"--rewind needs --resume or --continue and no prompt\"
  --rewind X where X is neither a decimal number (0 included) nor a hex
  prefix of at least 4 characters         → \"bad --rewind \\\"X\\\": use a turn number or a turn id from /tree\"
  --list-checkpoints with --rewind or a prompt
                                          → \"--list-checkpoints cannot be combined with --rewind or a prompt\"
  --list-checkpoints without --resume / --continue
                                          → \"--list-checkpoints needs --resume or --continue\"
Without any rewind flag → T. Whether the session and the turn exist is
checked later (SESSION-NOT-FOUND, SESSION-TURN-NOT-FOUND,
CHECKPOINT-NOT-FOUND). RUN-CLI refuses --rewind without -p itself (\"--rewind
needs -p (use /rewind in the interactive mode)\")."
  (let* ((rewind (invocation-rewind invocation))
         (listp (invocation-list-checkpoints-p invocation))
         (prompt (invocation-prompt invocation))
         (resumed (or (invocation-continue-p invocation) (invocation-resume invocation))))
    (when (and (invocation-rewind-mode invocation) (not rewind))
      (%usage-fail "--rewind-mode needs --rewind"))
    (when (and (or rewind listp) (invocation-fork-session-p invocation))
      (%usage-fail "--rewind and --list-checkpoints cannot be combined with --fork-session"))
    (when rewind
      (when (or (invocation-apply-p invocation) (invocation-reject-p invocation))
        (%usage-fail "--rewind cannot be combined with --apply or --reject"))
      (when (or prompt (not resumed))
        (%usage-fail "--rewind needs --resume or --continue and no prompt"))
      (unless (and (stringp rewind)
                   (plusp (length rewind))
                   (or (every #'digit-char-p rewind)
                       (and (>= (length rewind) rev:+minimum-id-prefix+)
                            (every (lambda (c) (digit-char-p c 16)) rewind))))
        (%usage-fail "bad --rewind ~s: use a turn number or a turn id from /tree" rewind)))
    (when listp
      (when (or rewind prompt)
        (%usage-fail "--list-checkpoints cannot be combined with --rewind or a prompt"))
      (unless resumed
        (%usage-fail "--list-checkpoints needs --resume or --continue")))
    t))


;;; H3d: --rpc.

(defun check-rpc-flags (invocation)
  "→ T when INVOCATION's flags go with --rpc (or --rpc is not given);
otherwise CODE-USAGE-ERROR, checked in this order:
  --rpc with -p                → \"--rpc and -p cannot be used together\"
  --rpc with a prompt          → \"--rpc takes no prompt (send turn/start)\"
  --rpc with --output-format   → \"--rpc writes JSON-RPC; --output-format is for -p\"
  --rpc with any of --continue, --resume, --session-id, --fork-session,
  --list-sessions              → \"--rpc opens sessions with session/new and session/resume, not --continue, --resume, --session-id, --fork-session or --list-sessions\"
  --rpc with any of --apply, --reject, --on-drift, --rewind, --rewind-mode,
  --list-checkpoints           → \"--rpc approves plans and rewinds with plan/approve, plan/reject and rewind, not --apply, --reject, --on-drift, --rewind, --rewind-mode or --list-checkpoints\"
Every other flag goes with --rpc: --cwd (the default working directory of
new sessions), --model, --max-turns, --permission-mode, --allowed-tools,
--disallowed-tools, --append-system-prompt, --model-param, --lisp-image, --lisp-observe
(the flag layer of every session) and --plan-area (the area kind of plan
sessions, whatever the mode)."
  (let ((i invocation))
    (when (invocation-rpc-p i)
      (when (invocation-print-p i)
        (%usage-fail "--rpc and -p cannot be used together"))
      (when (invocation-prompt i)
        (%usage-fail "--rpc takes no prompt (send turn/start)"))
      (when (invocation-output-format-given-p i)
        (%usage-fail "--rpc writes JSON-RPC; --output-format is for -p"))
      (when (or (invocation-continue-p i) (invocation-resume i) (invocation-session-id i)
                (invocation-fork-session-p i) (invocation-list-sessions-p i))
        (%usage-fail "--rpc opens sessions with session/new and session/resume, not --continue, --resume, --session-id, --fork-session or --list-sessions"))
      (when (or (invocation-apply-p i) (invocation-reject-p i) (invocation-on-drift i)
                (invocation-rewind i) (invocation-rewind-mode i)
                (invocation-list-checkpoints-p i))
        (%usage-fail "--rpc approves plans and rewinds with plan/approve, plan/reject and rewind, not --apply, --reject, --on-drift, --rewind, --rewind-mode or --list-checkpoints")))
    t))

;;; ACP-2: --acp.

(defun check-acp-flags (invocation)
  "→ T when INVOCATION's flags go with --acp (or --acp is not given);
otherwise CODE-USAGE-ERROR, checked in this order:
  --acp with --rpc             → \"--acp and --rpc cannot be used together\"
  --acp with -p                → \"--acp and -p cannot be used together\"
  --acp with a prompt          → \"--acp takes no prompt (send session/prompt)\"
  --acp with --output-format   → \"--acp writes ACP JSON-RPC; --output-format is for -p\"
  --acp with any of --continue, --resume, --session-id, --fork-session,
  --list-sessions              → \"--acp opens sessions with session/new and session/load, not --continue, --resume, --session-id, --fork-session or --list-sessions\"
  --acp with any of --apply, --reject, --on-drift, --rewind, --rewind-mode,
  --list-checkpoints           → \"--acp takes none of --apply, --reject, --on-drift, --rewind, --rewind-mode or --list-checkpoints: they are for -p\"
Every other flag goes with --acp, as with --rpc: --cwd (the default
working directory of sessions whose session/new gives none), --model,
--max-turns, --permission-mode (the mode new sessions start in),
--allowed-tools, --disallowed-tools, --append-system-prompt, --model-param,
--lisp-image, --lisp-observe and --plan-area."
  (let ((i invocation))
    (when (invocation-acp-p i)
      (when (invocation-rpc-p i)
        (%usage-fail "--acp and --rpc cannot be used together"))
      (when (invocation-print-p i)
        (%usage-fail "--acp and -p cannot be used together"))
      (when (invocation-prompt i)
        (%usage-fail "--acp takes no prompt (send session/prompt)"))
      (when (invocation-output-format-given-p i)
        (%usage-fail "--acp writes ACP JSON-RPC; --output-format is for -p"))
      (when (or (invocation-continue-p i) (invocation-resume i) (invocation-session-id i)
                (invocation-fork-session-p i) (invocation-list-sessions-p i))
        (%usage-fail "--acp opens sessions with session/new and session/load, not --continue, --resume, --session-id, --fork-session or --list-sessions"))
      (when (or (invocation-apply-p i) (invocation-reject-p i) (invocation-on-drift i)
                (invocation-rewind i) (invocation-rewind-mode i)
                (invocation-list-checkpoints-p i))
        (%usage-fail "--acp takes none of --apply, --reject, --on-drift, --rewind, --rewind-mode or --list-checkpoints: they are for -p")))
    t))
