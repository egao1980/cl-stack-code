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

(defun parse-arguments (argv)
  "→ INVOCATION for ARGV (strings, without the program name). Bad values and
unknown options signal CODE-USAGE-ERROR; a bad --allowed-tools /
--disallowed-tools rule signals PERMISSION-RULE-ERROR. Whether -p and a prompt
are present is checked by RUN-CLI, not here."
  (declare (ignore argv))
  (%not-implemented 'parse-arguments))
