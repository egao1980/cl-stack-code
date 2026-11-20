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
                    :documentation "--list-sessions: print this project's sessions."))
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
           ;; H3c
           (opt "continue" "Continue the last session of this project" :short #\c :kind :flag)
           (opt "resume" "Resume the session with this id (or a unique prefix of it)" :short #\r)
           (opt "session-id" "Id for the new session (32 hex digits or a UUID)")
           (opt "fork-session" "With --resume or --continue: continue in a new session" :kind :flag)
           (opt "list-sessions" "Print this project's sessions, newest first" :kind :flag)))))

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
         :settings (make-settings
                    :model (get-opt :model)
                    :max-turns (%max-turns (get-opt :max-turns))
                    :permission-mode (%permission-mode (get-opt :permission-mode))
                    :append-system-prompt (get-opt :append-system-prompt)
                    :allow (%flag-rules (get-opt :allowed-tools) :allow)
                    :deny (%flag-rules (get-opt :disallowed-tools) :deny)))))))

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
