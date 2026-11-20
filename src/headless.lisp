(in-package #:cl-stack-code)

;;; Headless runs: -p with text, json or stream-json output.

(defun run-cli (argv &key (output *standard-output*) (error-output *error-output*)
                       (input *standard-input*) providers user-config-dir
                       (getenv #'uiop:getenv))
  "Run one invocation of ARGV and return its exit code (0, 1, 2 or 130); never
quits. OUTPUT gets the answer or JSON, ERROR-OUTPUT the diagnostics, INPUT the
prompt when ARGV has none. PROVIDERS (alist name → factory) come before the
built-in ones. USER-CONFIG-DIR defaults to USER-CONFIG-DIRECTORY. GETENV is the
process environment lookup under the settings env."
  (declare (ignore argv output error-output input providers user-config-dir
                   getenv))
  (%not-implemented 'run-cli))

(defun main ()
  "Binary entry point: quit with RUN-CLI's exit code."
  (uiop:quit (run-cli (uiop:command-line-arguments))))
