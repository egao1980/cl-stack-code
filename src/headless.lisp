(in-package #:cl-stack-code)

;;; Headless runs: -p with text, json or stream-json output.
;;;
;;; H3c: every run is a turn of a session (src/sessions.lisp).
;;;   Before the run   CHECK-SESSION-FLAGS; then the session: --continue →
;;;                    LAST-SESSION of SESSIONS-DIRECTORY (none →
;;;                    SESSION-NOT-FOUND, exit 2); --resume ID → OPEN-SESSION
;;;                    (exit 2 when not found); otherwise CREATE-SESSION with
;;;                    --session-id (an existing id → CODE-USAGE-ERROR
;;;                    "session ID already exists: use --resume ID", exit 2)
;;;                    or a random id. --fork-session: CLONE-SESSION of the
;;;                    resumed session at its head, with --session-id when
;;;                    given; the run goes on in the clone.
;;;   Model            --model, else the resumed session's head record MODEL,
;;;                    else the settings files, else +DEFAULT-MODEL+. Nothing
;;;                    else is restored: rules, mode, env and max turns come
;;;                    from today's settings and flags.
;;;   The run          RUN-AI-AGENT on (SESSION-TURNS store) plus the prompt;
;;;                    every event's session_id is the store's id.
;;;   After the run    Once the run has started (its :started event), its
;;;                    turn is committed with COMMIT-TURN before the result is
;;;                    written: prompt, the run's turns past the ones it was
;;;                    given (without :system turns), finish (:stop,
;;;                    :max-steps, :canceled or :failed), the model
;;;                    designator, the mode and the summed usage. A
;;;                    SESSION-CONFLICT takes FORK-SESSION: error-output gets
;;;                    "cl-stack-code: session OLD changed in another process;
;;;                    this turn was saved as session NEW" and the result's
;;;                    session_id is NEW (the exit code is the run's).
;;;   --list-sessions  Without -p or a prompt: SESSION-SUMMARY-LINES, one per
;;;                    line on output, exit 0 (nothing when there are none).
;;;   Data directory   RUN-CLI :DATA-DIR, else USER-DATA-DIRECTORY with
;;;                    RUN-CLI's GETENV.

;;; Outcomes of a run that started, as conditions. RUN-CLI handles them like
;;; every other error: the message goes to ERROR-OUTPUT, the exit code comes
;;; from CONDITION-EXIT-CODE.

(define-condition %run-interrupted (run-failed) ()
  (:documentation "SIGINT canceled the run (CANCEL-AGENT-RUN). Exit 130.")
  (:default-initargs :message "interrupted"))

(defmethod condition-exit-code ((condition %run-interrupted)) 130)

;;; JSON output.

(defun %json-object (&rest keys-and-values)
  "A json-protocol object (EQUAL hash table) from alternating string keys and
values."
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on keys-and-values by #'cddr
          do (setf (gethash key object) value))
    object))

(defun %session-id ()
  "32 lowercase hex characters, random per run."
  (format nil "~(~32,'0x~)" (random (ash 1 128) (make-random-state t))))

(defun %usage-counts (usage)
  "(input output cache-read cache-write) of an LLM-USAGE (or NIL); a missing
count is 0."
  (if usage
      (list (or (llm:llm-usage-input-tokens usage) 0)
            (or (llm:llm-usage-output-tokens usage) 0)
            (or (llm:llm-usage-cache-read-tokens usage) 0)
            (or (llm:llm-usage-cache-write-tokens usage) 0))
      (list 0 0 0 0)))

(defun %usage-object (counts)
  (destructuring-bind (input output cache-read cache-write) counts
    (%json-object "input_tokens" input "output_tokens" output
                  "cache_read_tokens" cache-read "cache_write_tokens" cache-write)))

(defun %finish-reason-name (reason)
  ":TOOL-USE → \"tool_use\"; NIL → \"stop\"."
  (substitute #\_ #\- (string-downcase (string (or reason :stop)))))

(defun %tool-input (arguments)
  "ARGUMENTS decoded as a JSON object, or the raw string when they are not one."
  (cond ((hash-table-p arguments) arguments)
        ((stringp arguments)
         (let ((value (handler-case (json:decode arguments)
                        (error () nil))))
           (if (hash-table-p value) value arguments)))
        ((null arguments) :null)
        (t (princ-to-string arguments))))

(defun %trim-answer (text)
  (string-right-trim '(#\Newline #\Return) (or text "")))

;;; The report: what one run has said so far, and where it says it.

(defstruct (%report (:conc-name %report-))
  (format :text)
  (output *standard-output*)
  (session (%session-id))
  (run nil)                                   ; the AGENT-RUN, from :started
  (step 0)
  (turns 0)                                   ; :response events
  (usage (list 0 0 0 0))
  (denials '())                               ; newest first
  (seen (make-hash-table :test #'equal))      ; ids with a tool_result
  (call-steps (make-hash-table :test #'equal))
  (failure nil))                              ; first error inside the sink

(defun %write-json-line (report object)
  (let ((out (%report-output report)))
    (json:encode object :stream out)
    (terpri out)
    (force-output out)))

(defun %emit-event (report type &rest keys-and-values)
  "Write one stream-json event (only in stream-json)."
  (when (eq (%report-format report) :stream-json)
    (%write-json-line report (apply #'%json-object "type" type
                                    "session_id" (%report-session report)
                                    keys-and-values))))

(defun %step-tool-calls (report response)
  "Tool-call parts of the assistant turn RESPONSE committed (the run coalesced
streamed parts by then), else of RESPONSE itself."
  (let* ((run (%report-run report))
         (turn (and run (find :assistant (agent:agent-run-turns run)
                              :key #'llm:llm-turn-role :from-end t)))
         (parts (if turn (llm:llm-turn-parts turn) (llm:llm-response-parts response))))
    (remove-if-not #'llm:llm-tool-call-part-p parts)))

(defun %on-response (report response)
  (let ((counts (%usage-counts (llm:llm-response-usage response)))
        (step (%report-step report)))
    (incf (%report-turns report))
    (setf (%report-usage report) (mapcar #'+ (%report-usage report) counts))
    (%emit-event report "assistant"
                 "step" step
                 "text" (or (llm:llm-response-text response) "")
                 "finish_reason" (%finish-reason-name (llm:llm-response-finish-reason response))
                 "usage" (%usage-object counts))
    (dolist (call (%step-tool-calls report response))
      (let ((id (llm:llm-tool-call-part-id call)))
        (setf (gethash id (%report-call-steps report)) step)
        (%emit-event report "tool_use"
                     "step" step
                     "id" id
                     "name" (llm:llm-tool-call-part-name call)
                     "input" (%tool-input (llm:llm-tool-call-part-arguments call)))))))

(defun %on-permission (report payload)
  "A refused call (payload with a :CONDITION) goes on the denial list:
decision :REJECTED is the headless refusal of an ask, :DENY a rule or policy."
  (let ((condition (getf payload :condition))
        (inv (getf payload :invocation)))
    (when (and condition inv)
      (push (%json-object "id" (agent:agent-invocation-id inv)
                          "name" (agent:agent-invocation-name inv)
                          "input" (%tool-input (agent:agent-invocation-arguments inv))
                          "reason" (if (eq (agent:tool-permission-denied-decision condition)
                                           :rejected)
                                       "headless"
                                       "denied"))
            (%report-denials report)))))

(defun %on-invocation (report inv)
  (let ((status (agent:agent-invocation-status inv))
        (id (agent:agent-invocation-id inv)))
    (when (and (member status '(:done :error :denied))
               (not (gethash id (%report-seen report))))
      (setf (gethash id (%report-seen report)) t)
      (%emit-event report "tool_result"
                   "step" (gethash id (%report-call-steps report) (%report-step report))
                   "id" id
                   "name" (agent:agent-invocation-name inv)
                   "status" (string-downcase (string status))
                   "is_error" (and (agent:agent-invocation-error-p inv) t)
                   "content" (let ((result (agent:agent-invocation-result inv)))
                               (cond ((null result) "")
                                     ((stringp result) result)
                                     (t (princ-to-string result))))))))

(defun %on-agent-event (report kind payload)
  "The run's :ON-EVENT. It runs inside event-loop callbacks, where an ERROR
would only become a warning, so it never signals: the first error is kept,
the run is canceled and the error fails the run afterwards."
  (handler-case
      (case kind
        (:started (setf (%report-run report) payload))
        (:step (setf (%report-step report) payload))
        (:part (when (and (llm:llm-text-part-p payload)
                          (plusp (length (llm:llm-text-part-text payload))))
                 (%emit-event report "text_delta"
                              "step" (%report-step report)
                              "text" (llm:llm-text-part-text payload))))
        (:response (%on-response report payload))
        (:permission (%on-permission report payload))
        (:invocation (%on-invocation report payload)))
    (error (e)
      (unless (%report-failure report)
        (setf (%report-failure report) e))
      (let ((run (%report-run report)))
        (when run (agent:cancel-agent-run run))))))

(defun %result-object (report subtype text error-message duration-ms)
  (%json-object "type" "result"
                "subtype" subtype
                "is_error" (not (string= subtype "success"))
                "result" text
                "error" (or error-message :null)
                "num_turns" (%report-turns report)
                "duration_ms" duration-ms
                "usage" (%usage-object (%report-usage report))
                "permission_denials" (coerce (reverse (%report-denials report)) 'vector)
                "session_id" (%report-session report)))

;;; Working directory, environment, HTTP.

(defun %resolve-cwd (given)
  "The truename of the working directory: --cwd GIVEN (relative to the process
directory), else the process directory. Not a directory → CODE-USAGE-ERROR."
  (if (null given)
      (truename (uiop:getcwd))
      (let* ((path (and (plusp (length given))
                        (uiop:parse-native-namestring given :ensure-directory t)))
             (dir (and path (uiop:directory-exists-p
                             (uiop:merge-pathnames* path (uiop:getcwd))))))
        (or dir
            (error 'code-usage-error
                   :message (format nil "--cwd ~a is not a directory" given))))))

(defun %env-lookup (settings getenv)
  "Merged settings env first (an unset key → NIL), then GETENV. The process
environment is never modified."
  (let ((env (settings-env settings)))
    (lambda (name)
      (let ((entry (assoc name env :test #'string=)))
        (if entry (cdr entry) (funcall getenv name))))))

;;; The run.

(defun %agent-settings (cwd settings)
  (agent:make-agent-settings
   :max-steps (or (settings-max-turns settings) +default-max-turns+)
   :extra (list :permission-policy (settings-permission-policy settings)
                :max-steps-wrap-up nil
                :instructions-discovery
                (steer:make-instruction-discovery cwd :names +instruction-file-names+
                                                      :include-root nil))))

(defun %agent-permissions (settings)
  "The agent's rule list. The lowest rule makes a shell command's program:
resources neutral for allows, so bash(SPEC) decides a simple command whose
words match it (as in Claude Code); with no bash rule the call still asks,
and every settings or flag rule comes later and wins."
  (cons (agent:make-permission-rule "bash" "program:*" :allow)
        (settings-permission-rules settings)))

(defun %drive (agent prompt report mode)
  "Run AGENT on PROMPT on the bound loop. Approvals are answered headless.
→ (values run failure interrupted-p)."
  (let ((interrupted nil))
    (handler-bind ((agent:agent-approval-required
                     (lambda (c)
                       (if (eq mode :bypass-permissions)
                           (agent:invoke-approve c)
                           (agent:invoke-deny c +headless-denial-feedback+))))
                   #+sbcl
                   (sb-sys:interactive-interrupt
                     (lambda (c)
                       (setf interrupted t)
                       (let ((run (%report-run report)))
                         (when run (agent:cancel-agent-run run)))
                       (continue c))))
      (handler-case
          (values (agent:run-ai-agent agent prompt
                                      :on-event (lambda (kind payload)
                                                  (%on-agent-event report kind payload)))
                  nil
                  interrupted)
        (error (e) (values nil e interrupted))))))

(defun %outcome (run failure interrupted max-turns)
  "→ (values subtype condition) for a finished or failed run; CONDITION is NIL
on success."
  (let ((reason (and run (agent:agent-run-finish-reason run))))
    (cond (failure
           (values "error_during_execution" (make-condition 'run-failed :cause failure)))
          ((or interrupted (eq reason :canceled))
           (values "error_during_execution" (make-condition '%run-interrupted)))
          ((eq reason :max-steps)
           (values "error_max_turns"
                   (make-condition 'run-failed
                                   :message (format nil "reached max turns (~d)" max-turns))))
          ((member reason '(:approval :deferred))
           (values "error_during_execution"
                   (make-condition 'run-failed
                                   :message "the run paused for an answer headless mode cannot give")))
          (t (values "success" nil)))))

(defun %report-run-end (report run failure interrupted max-turns start)
  "Write the run's result to the report's output; signal the failure, if any."
  (multiple-value-bind (subtype condition)
      (%outcome run (or (%report-failure report) failure) interrupted max-turns)
    (let ((text (if (and run (not failure) (not (%report-failure report)))
                    (%trim-answer (agent:agent-run-text run))
                    ""))
          (duration (round (* 1000 (- (get-internal-real-time) start))
                           internal-time-units-per-second)))
      (case (%report-format report)
        (:text
         (unless condition
           (let ((out (%report-output report)))
             (write-string text out)
             (terpri out)
             (force-output out))))
        (t
         (%write-json-line report
                           (%result-object report subtype text
                                           (and condition (princ-to-string condition))
                                           duration))))
      (when condition
        (error condition))
      0)))

(defun %read-prompt (inv input)
  (let ((prompt (or (invocation-prompt inv)
                    (%trim-answer (uiop:slurp-stream-string input)))))
    (when (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return #\Page))) prompt)
      (error 'code-usage-error
             :message "no prompt: give it as arguments or on standard input"))
    prompt))

(defun %run-headless (inv &key output input providers user-config-dir getenv start data-dir)
  "The -p run of INV. Configuration errors signal before anything is written
to OUTPUT; a run that started writes its result, then signals its failure."
  (declare (ignore data-dir))           ; H3c: see the file header
  (unless (invocation-print-p inv)
    (error 'code-usage-error
           :message "-p (--print) is required: cl-stack-code 0.1 runs headless only (the interactive mode arrives in H3b)"))
  (let* ((prompt (%read-prompt inv input))
         (cwd (%resolve-cwd (invocation-cwd inv)))
         (config (or user-config-dir (user-config-directory :getenv getenv)))
         (settings (load-settings cwd :user-config-dir config
                                      :cli (invocation-settings inv)))
         (designator (or (settings-model settings) +default-model+))
         (resolved (multiple-value-list
                    (resolve-model designator :providers providers
                                              :env (%env-lookup settings getenv))))
         (backend (first resolved))
         (model (third resolved))
         (mode (or (settings-permission-mode settings) :default))
         (max-turns (or (settings-max-turns settings) +default-max-turns+))
         (report (make-%report :format (invocation-output-format inv) :output output))
         (event-backend (event-backend-libuv:make-libuv-backend))
         (event-loop (event:make-event-loop event-backend))
         (sources nil))
    (unwind-protect
         (let ((event:*event-backend* event-backend)
               (event:*event-loop* event-loop)
               (http-protocol:*http-backend*
                 (or http-protocol:*http-backend* (http-backend-async:make-async-backend)))
               (http-backend-async:*event-backend-maker*
                 (or http-backend-async:*event-backend-maker*
                     #'event-backend-libuv:make-libuv-backend))
               (agent:*off-loop-specials*
                 (union '(http-protocol:*http-backend* http-backend-async:*event-backend-maker*)
                        agent:*off-loop-specials*)))
           (setf sources (make-code-tools cwd :settings settings))
           (let ((offered (loop for source in sources
                                append (mapcar #'llm:llm-tool-name
                                               (agent:list-agent-tools source)))))
             (multiple-value-bind (instructions files)
                 (assemble-system-prompt cwd :tools offered :backend backend
                                             :settings settings :user-config-dir config)
               (let ((agent (agent:make-ai-agent
                             :name "cl-stack-code"
                             :backend backend
                             :model model
                             :instructions instructions
                             :tools sources
                             :permissions (%agent-permissions settings)
                             :settings (%agent-settings cwd settings)))
                     (root (find-project-root cwd)))
                 (%emit-event report "system"
                              "subtype" "init"
                              "version" +version+
                              "cwd" (uiop:native-namestring cwd)
                              "project_root" (if root (uiop:native-namestring root) :null)
                              "model" designator
                              "permission_mode" (permission-mode-name mode)
                              "tools" (coerce offered 'vector)
                              "instructions" (map 'vector #'uiop:native-namestring files))
                 (multiple-value-bind (run failure interrupted)
                     (%drive agent prompt report mode)
                   (%report-run-end report run failure interrupted max-turns start))))))
      (when (second sources)
        (tools:close-shell-tools (second sources)))
      (event:close-event-loop event-backend event-loop))))

(defun run-cli (argv &key (output *standard-output*) (error-output *error-output*)
                       (input *standard-input*) providers user-config-dir
                       (getenv #'uiop:getenv) data-dir)
  "Run one invocation of ARGV and return its exit code (0, 1, 2 or 130); never
quits. OUTPUT gets the answer or JSON, ERROR-OUTPUT the diagnostics, INPUT the
prompt when ARGV has none. PROVIDERS (alist name → factory) come before the
built-in ones. USER-CONFIG-DIR defaults to USER-CONFIG-DIRECTORY. GETENV is the
process environment lookup under the settings env. DATA-DIR (H3c) defaults to
USER-DATA-DIRECTORY: sessions live under it."
  (let ((start (get-internal-real-time)))
    (handler-case
        (let ((inv (parse-arguments argv)))
          (cond ((invocation-help-p inv)
                 (%usage-text output)
                 0)
                ((invocation-version-p inv)
                 (format output "cl-stack-code ~a~%" +version+)
                 0)
                ((not (invocation-print-p inv))
                 (%run-interactive inv :output output :input input :providers providers
                                       :user-config-dir user-config-dir :getenv getenv
                                       :data-dir data-dir))
                (t
                 (%run-headless inv :output output :input input :providers providers
                                    :user-config-dir user-config-dir :getenv getenv
                                    :start start :data-dir data-dir))))
      (error (c)
        (format error-output "cl-stack-code: ~a~%" c)
        (force-output error-output)
        (condition-exit-code c)))))

(defun main ()
  "Binary entry point: quit with RUN-CLI's exit code."
  (uiop:quit (run-cli (uiop:command-line-arguments))))
