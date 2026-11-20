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
   (cwd :initarg :cwd :reader invocation-cwd :initform nil
        :documentation "--cwd as given, or NIL.")
   (help-p :initarg :help-p :reader invocation-help-p :initform nil)
   (version-p :initarg :version-p :reader invocation-version-p :initform nil)
   (settings :initarg :settings :reader invocation-settings
             :documentation "The flag layer: a SETTINGS."))
  (:documentation "One parsed command line."))

(defparameter +output-format-names+ '("text" "json" "stream-json")
  "The --output-format values, in this order.")

(defparameter +value-option-names+
  '("output-format" "model" "max-turns" "cwd" "allowed-tools" "disallowed-tools"
    "permission-mode" "append-system-prompt")
  "Long names of the options that take a value.")

(defun %usage-fail (control &rest args)
  (error 'code-usage-error :message (apply #'format nil control args)))

(defun %make-command (backend)
  "The cl-stack-code command on the cli-protocol BACKEND. It calls the
protocol's BACKEND-MAKE-OPTION / BACKEND-MAKE-COMMAND: cli-protocol 0.1.0's
MAKE-OPTION / MAKE-COMMAND pass their :BACKEND argument on to them, which
rejects it, and *CLI-BACKEND* is not ours to rebind."
  (flet ((opt (name help &rest keys)
           (apply #'cli:backend-make-option backend :name name :help help
                  :key (intern (string-upcase name) :keyword)
                  keys)))
    (cli:backend-make-command
     backend
     :name "cl-stack-code"
     :version +version+
     :description "Coding agent on cl-stack. 0.1 runs headless only: -p PROMPT."
     :options
     (list (opt "print" "Run headless and print the result (required in 0.1)"
                :short #\p :kind :flag)
           (opt "output-format" "text (default), json or stream-json")
           (opt "model" "Model: provider or provider:model (default anthropic)")
           (opt "max-turns" "Model calls before the run stops (an integer >= 1)")
           (opt "cwd" "Working directory (default: the current directory)")
           (opt "allowed-tools" "Allow rules TOOL or TOOL(SPEC), comma or space separated; repeatable"
                :kind :list)
           (opt "disallowed-tools" "Deny rules, same syntax; repeatable" :kind :list)
           (opt "permission-mode" "default, acceptEdits, bypassPermissions or plan")
           (opt "append-system-prompt" "Text appended to the system prompt")))))

(defun %builtin-flag (posix)
  "→ :HELP, :VERSION or NIL for the normalized argv POSIX. Option values and
everything after -- are skipped. clingon handles its own --help, --version and
--bash-completions by printing to *standard-output*, so they are taken here."
  (loop with skip = nil
        for token in posix
        do (cond (skip (setf skip nil))
                 ((string= token "--") (return nil))
                 ((string= token "--help") (return :help))
                 ((string= token "--version") (return :version))
                 ((string= token "--bash-completions")
                  (%usage-fail "unknown option --bash-completions"))
                 ((and (uiop:string-prefix-p "--" token)
                       (not (find #\= token))
                       (member (subseq token 2) +value-option-names+ :test #'string=))
                  (setf skip t)))))

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
         (command (%make-command backend))
         (flag (%builtin-flag (cli:normalize-argv
                               argv :options (cli:cli-command-options command)))))
    (when flag
      (return-from parse-arguments
        (make-instance 'invocation :help-p (eq flag :help)
                                   :version-p (eq flag :version)
                                   :settings (make-settings))))
    (multiple-value-bind (options free)
        (handler-case (cli:parse command argv :backend backend)
          (cli:cli-error (e)
            (%usage-fail "~a" e)))
      (flet ((get-opt (key) (cli:get-option options key)))
        (make-instance
         'invocation
         :print-p (and (get-opt :print) t)
         :prompt (%prompt free)
         :output-format (%output-format (get-opt :output-format))
         :cwd (get-opt :cwd)
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
