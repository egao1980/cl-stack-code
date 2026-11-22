(in-package #:cl-stack-code/acp/tests)

;;; ACP-2 helpers (test code, complete).
;;;   * RECORDING-CLIENT: an ACP-PROTOCOL:ACP-CLIENT that records every
;;;     session/update and every call it gets, answers permission with a
;;;     restart from a slot, serves fs/* from an in-memory table of buffers
;;;     (absolute native path → text) and terminal/* with canned output.
;;;   * WITH-LOOPBACK: a CODE-ACP-AGENT on the scripted mock LLM, connected
;;;     to a RECORDING-CLIENT through acp-protocol's in-memory loopback.
;;;   * WITH-ACP-CHILD: cl-stack-code --acp in a child SBCL (RUN-CLI on its
;;;     own stdin / stdout, the mock LLM scripted from the parent), spawned
;;;     by acp-backend-stdio's SPAWN-ACP-AGENT with a RECORDING-CLIENT.
;;; Every wait has a deadline: a hang fails a test instead of the suite.

(defparameter *zed-client-caps*
  "{\"fs\":{\"readTextFile\":true,\"writeTextFile\":true},\"terminal\":true,\"session\":{\"compaction\":{},\"configOptions\":{\"boolean\":{}},\"notices\":{}},\"auth\":{\"terminal\":true},\"elicitation\":{\"form\":{},\"url\":{}},\"_meta\":{\"terminal_output\":true,\"terminal-auth\":true}}"
  "The clientCapabilities Zed 1.29.3 sends at initialize (cl-stack-demos
harness/acp/zed-wire-log.txt, message 001): fs and terminal on.")

(defparameter *bare-client-caps* "{}"
  "A client that advertises nothing: no fs, no terminal (Emacs agent-shell style).")

(defparameter *terminal-output* (format nil "FROM-TERMINAL~%")
  "What the RECORDING-CLIENT's terminals print.")

(defun d (x) (princ-to-string x))

;;; Background calls with a deadline.

(defstruct (outcome (:constructor %make-outcome ()))
  (values nil) (condition nil) (done nil))

(defun in-background (thunk &key (name "acp test call"))
  "Run THUNK on a new thread. → an OUTCOME."
  (let ((o (%make-outcome)))
    (bt:make-thread
     (lambda ()
       (unwind-protect
            (handler-case (setf (outcome-values o) (multiple-value-list (funcall thunk)))
              (serious-condition (c) (setf (outcome-condition o) c)))
         (setf (outcome-done o) t)))
     :name name)
    o))

(defun await (outcome seconds)
  "→ T when OUTCOME finished within SECONDS."
  (and (wait-until (lambda () (outcome-done outcome)) :timeout seconds) t))

(define-condition call-timed-out (error)
  ((seconds :initarg :seconds :reader call-timed-out-seconds))
  (:report (lambda (c s) (format s "no answer within ~a s" (call-timed-out-seconds c)))))

(defun within (seconds thunk)
  "THUNK's values, computed on another thread within SECONDS; the condition
it signalled is signalled again here; no answer → CALL-TIMED-OUT."
  (let ((o (in-background thunk)))
    (unless (await o seconds)
      (error 'call-timed-out :seconds seconds))
    (when (outcome-condition o)
      (error (outcome-condition o)))
    (values-list (outcome-values o))))

(defmacro req (form &key (seconds 60))
  "FORM (an ACP call) with a deadline."
  `(within ,seconds (lambda () ,form)))

(defun signalled (thunk)
  "The ERROR THUNK signals (through WITHIN), or NIL."
  (handler-case (progn (within 60 thunk) nil)
    (error (c) c)))

;;; The recording client.

(defclass recording-client (acp:acp-client)
  ((lock :initform (bt:make-lock "recording client") :reader %client-lock)
   (notifications :initform '() :documentation "SESSION-NOTIFICATIONs, newest first.")
   (calls :initform '() :documentation "(method . request), newest first.")
   (buffers :initform (make-hash-table :test 'equal) :reader client-buffers
            :documentation "fs/*: absolute native path → text.")
   (terminals :initform 0 :accessor %terminal-count)
   (permission :initarg :permission :initform 'acp:allow-once :accessor client-permission
               :documentation "The restart invoked for ACP-PERMISSION-REQUIRED, or NIL
to leave it unhandled (→ cancelled).")
   (on-permission :initarg :on-permission :initform nil :accessor client-on-permission
                  :documentation "(lambda (client request)) run first.")
   (remote :initform nil :accessor client-remote
           :documentation "The REMOTE-AGENT, once connected."))
  (:documentation "A scripted ACP client for the ACP-2 tests."))

(defun %record (client slot value)
  (bt:with-lock-held ((%client-lock client))
    (push value (slot-value client slot))))

(defun client-notifications (client)
  (bt:with-lock-held ((%client-lock client))
    (reverse (slot-value client 'notifications))))

(defun client-updates (client &optional type)
  "The UPDATE objects received, oldest first; only those of TYPE (a class
name) when given."
  (let ((all (mapcar #'acp:update (client-notifications client))))
    (if type (remove-if-not (lambda (u) (typep u type)) all) all)))

(defun client-calls (client &optional method)
  "(method . request) of every call to the client, oldest first; only
METHOD's when given."
  (let ((all (bt:with-lock-held ((%client-lock client))
               (reverse (slot-value client 'calls)))))
    (if method (remove method all :key #'car :test-not #'string=) all)))

(defun call-methods (client)
  (mapcar #'car (client-calls client)))

(defun chunk-text (update)
  (let ((c (acp:content update)))
    (if (typep c 'acp:text-content) (acp:text c) "")))

(defun message-chunks (client)
  "The text of every agent_message_chunk, oldest first."
  (mapcar #'chunk-text (client-updates client 'acp:update-agent-message-chunk)))

(defun message-text (client)
  (format nil "~{~a~}" (message-chunks client)))

(defun thought-text (client)
  (format nil "~{~a~}" (mapcar #'chunk-text (client-updates client 'acp:update-agent-thought-chunk))))

(defun clear-client (client)
  "Forget the updates and calls recorded so far."
  (bt:with-lock-held ((%client-lock client))
    (setf (slot-value client 'notifications) '()
          (slot-value client 'calls) '())))

(defun permission-requests (client)
  (mapcar #'cdr (client-calls client "session/request_permission")))

(defmethod acp:acp-session-update ((client recording-client) notification)
  (%record client 'notifications notification))

(defmethod acp:acp-request-permission :around ((client recording-client) request)
  (%record client 'calls (cons "session/request_permission" request))
  (when (client-on-permission client)
    (funcall (client-on-permission client) client request))
  (let ((restart (client-permission client)))
    (if restart
        (handler-bind ((acp:acp-permission-required
                         (lambda (c) (invoke-restart (find-restart restart c)))))
          (call-next-method))
        (call-next-method))))

(defmethod acp:acp-read-text-file ((client recording-client) request)
  (%record client 'calls (cons "fs/read_text_file" request))
  (let ((text (gethash (acp:path request) (client-buffers client))))
    (unless text
      (error 'acp:acp-resource-not-found :data (args "path" (acp:path request))))
    (acp:make-acp 'acp:read-text-file-response :content text)))

(defmethod acp:acp-write-text-file ((client recording-client) request)
  (%record client 'calls (cons "fs/write_text_file" request))
  (setf (gethash (acp:path request) (client-buffers client)) (acp:content request))
  (acp:make-acp 'acp:write-text-file-response))

(defmethod acp:acp-create-terminal ((client recording-client) request)
  (%record client 'calls (cons "terminal/create" request))
  (acp:make-acp 'acp:create-terminal-response
                :terminal-id (format nil "term-~d" (incf (%terminal-count client)))))

(defmethod acp:acp-terminal-output ((client recording-client) request)
  (%record client 'calls (cons "terminal/output" request))
  ;; MAKE-INSTANCE: MAKE-ACP would drop the false truncated (a required field)
  (make-instance 'acp:terminal-output-response
                :output *terminal-output* :truncated nil
                :exit-status (acp:make-acp 'acp:terminal-exit-status :exit-code 0)))

(defmethod acp:acp-wait-for-terminal-exit ((client recording-client) request)
  (%record client 'calls (cons "terminal/wait_for_exit" request))
  (acp:make-acp 'acp:wait-for-terminal-exit-response :exit-code 0))

(defmethod acp:acp-release-terminal ((client recording-client) request)
  (%record client 'calls (cons "terminal/release" request))
  (acp:make-acp 'acp:release-terminal-response))

(defmethod acp:acp-kill-terminal ((client recording-client) request)
  (%record client 'calls (cons "terminal/kill" request))
  (acp:make-acp 'acp:kill-terminal-response))

(defun set-buffer (client project rel text)
  "The client's buffer of REL under PROJECT (not the disk)."
  (setf (gethash (native (merge-pathnames rel project)) (client-buffers client)) text))

(defun buffer (client project rel)
  (gethash (native (merge-pathnames rel project)) (client-buffers client)))

;;; Requests.

(defun caps (json-text)
  (and json-text (acp:parse-acp-object 'acp:client-capabilities (json:decode json-text))))

(defun initialize (ra &key (caps *bare-client-caps*))
  (acp:acp-initialize
   ra (acp:make-acp 'acp:initialize-request
                    :protocol-version 1
                    :client-capabilities (caps caps)
                    :client-info (acp:make-acp 'acp:implementation
                                               :name "acp-2-tests" :version "0.0.1"))))

(defun new-session (ra project &key (mcp-servers #()))
  "session/new in PROJECT. → the NEW-SESSION-RESPONSE."
  (acp:acp-new-session ra (acp:make-acp 'acp:new-session-request
                                        :cwd (native project) :mcp-servers mcp-servers)))

(defun new-session-id (ra project)
  (acp:session-id (new-session ra project)))

(defun text-block (text)
  (acp:make-acp 'acp:text-content :text text))

(defun prompt (ra session-id &rest blocks)
  "session/prompt; a string block is a text block. → the PROMPT-RESPONSE."
  (acp:acp-prompt ra (acp:make-acp 'acp:prompt-request
                                   :session-id session-id
                                   :prompt (map 'vector (lambda (b)
                                                          (if (stringp b) (text-block b) b))
                                                blocks))))

(defun stop-reason (ra session-id &rest blocks)
  (acp:stop-reason (apply #'prompt ra session-id blocks)))

(defun cancel (ra session-id)
  (acp:acp-cancel ra (acp:make-acp 'acp:cancel-notification :session-id session-id)))

(defun set-mode (ra session-id mode-id)
  (acp:acp-set-session-mode ra (acp:make-acp 'acp:set-session-mode-request
                                             :session-id session-id :mode-id mode-id)))

(defun load-session (ra project session-id &key (mcp-servers #()))
  (acp:acp-load-session ra (acp:make-acp 'acp:load-session-request
                                         :session-id session-id :cwd (native project)
                                         :mcp-servers mcp-servers)))

(defun session-list (ra &optional project)
  (acp:acp-list-sessions ra (if project
                                (acp:make-acp 'acp:list-sessions-request :cwd (native project))
                                (acp:make-acp 'acp:list-sessions-request))))

(defun close-session (ra session-id)
  (acp:acp-close-session ra (acp:make-acp 'acp:close-session-request :session-id session-id)))

;;; Reading model objects.

(defun slot (object name)
  "OBJECT's slot NAME, or NIL when unbound or JSON null."
  (and object (slot-boundp object name)
       (let ((v (slot-value object name))) (if (eq v :null) nil v))))

(defun tool-calls (client &optional id)
  (remove-if-not (lambda (u) (or (null id) (equal id (acp:tool-call-id u))))
                 (client-updates client 'acp:update-tool-call)))

(defun tool-call-updates (client &optional id)
  (remove-if-not (lambda (u) (or (null id) (equal id (acp:tool-call-id u))))
                 (client-updates client 'acp:update-tool-call-update)))

(defun diffs (object)
  "The DIFF contents of a tool call (or update / permission toolCall)."
  (remove-if-not (lambda (c) (typep c 'acp:diff)) (coerce (or (slot object 'acp:content) #()) 'list)))

(defun text-contents (object)
  "The text of each CONTENT content of a tool call update, in order."
  (loop for c across (or (slot object 'acp:content) #())
        when (and (typep c 'acp:content) (typep (acp:content c) 'acp:text-content))
          collect (acp:text (acp:content c))))

(defun final-status (client id)
  "The status of tool call ID's last tool_call_update, or NIL."
  (let ((u (car (last (tool-call-updates client id)))))
    (and u (slot u 'acp:status))))

(defun abs-path (project rel)
  (native (merge-pathnames rel project)))

(defun hex-id-p (string)
  (and (stringp string) (= 32 (length string))
       (every (lambda (ch) (digit-char-p ch 16)) string)))

(defun local-rules (project)
  "permissions.allow of PROJECT's .cl-stack-code/settings.local.json, or NIL."
  (let ((text (read-file project ".cl-stack-code/settings.local.json")))
    (and text (coerce (jget (json:decode text) "permissions" "allow") 'list))))

;;; The loopback pair.

(defun call-with-loopback (project config fn &key steps settings (caps *bare-client-caps*)
                                                 (permission 'acp:allow-once) on-permission
                                                 (plan-area :auto) (initialize t))
  "FN gets (ra client agent backend): a CODE-ACP-AGENT on PROJECT with the
scripted mock LLM (STEPS) as provider \"mock\" and the default model
\"mock\" under SETTINGS, a RECORDING-CLIENT with PERMISSION, both ends of
MAKE-ACP-LOOPBACK, initialized with CAPS unless INITIALIZE is NIL."
  (let* ((backend (make-scripted-backend steps))
         (agent (make-code-acp-agent
                 :cwd project
                 :settings (merge-settings (make-settings :model "mock") settings)
                 :providers (list (cons "mock" (scripted-provider backend)))
                 :user-config-dir config
                 :data-dir (data-dir-of config)
                 :getenv (env-lookup)
                 :plan-area plan-area))
         (client (make-instance 'recording-client :permission permission
                                                  :on-permission on-permission)))
    (unwind-protect
         (multiple-value-bind (ra rc) (acp:make-acp-loopback agent client)
           (declare (ignore rc))
           (setf (client-remote client) ra)
           (when initialize
             (req (initialize ra :caps caps)))
           (funcall fn ra client agent backend))
      (ignore-errors (within 30 (lambda () (close-code-acp-agent agent)))))))

(defmacro with-loopback ((ra client project config &rest keys &key agent backend
                          &allow-other-keys)
                         &body body)
  (let ((a (or agent (gensym "AGENT")))
        (b (or backend (gensym "BACKEND")))
        (keys (loop for (k v) on keys by #'cddr
                    unless (member k '(:agent :backend)) append (list k v))))
    `(call-with-loopback ,project ,config
                         (lambda (,ra ,client ,a ,b)
                           (declare (ignorable ,ra ,client ,a ,b))
                           ,@body)
                         ,@keys)))

(defun wire-log (ra)
  "The loopback's JSON-RPC lines, oldest first: (direction . text)."
  (acp:acp-loopback-log ra))

(defun updates-before-response-p (ra)
  "Every session/update line of the log precedes the last prompt response."
  (updates-before-response-p* ra "\"stopReason\""))

(defun updates-before-response-p* (ra marker)
  "Every session/update line of the log precedes the last response to the
agent's client side whose text contains MARKER."
  (let* ((log (wire-log ra))
         (response (position-if (lambda (e) (and (eq :to-client (car e))
                                                 (search "\"result\"" (cdr e))
                                                 (search marker (cdr e))))
                                log :from-end t))
         (last-update (position-if (lambda (e) (search "\"session/update\"" (cdr e)))
                                   log :from-end t)))
    (and response last-update (< last-update response))))

;;; The child process: cl-stack-code --acp.

(defun acp-child-main (project config steps-text)
  "The child: RUN-CLI --acp on the process's stdin / stdout, the mock backend
scripted with the steps READ from STEPS-TEXT. Quits with RUN-CLI's code."
  (let* ((steps (let ((*read-eval* nil)) (read-from-string steps-text)))
         (backend (make-scripted-backend steps))
         (config (uiop:ensure-directory-pathname config)))
    (uiop:quit
     (run-cli (list "--acp" "--cwd" project "--model" "mock")
              :input *standard-input* :output *standard-output* :error-output *error-output*
              :providers (list (cons "mock" (scripted-provider backend)))
              :user-config-dir config
              :data-dir (data-dir-of config)
              :getenv (env-lookup)))))

(defun acp-child-argv (project config steps)
  #-sbcl (declare (ignore project config steps))
  #-sbcl (error "the --acp child is started with SBCL only")
  #+sbcl
  (append
   (list (uiop:native-namestring sb-ext:*runtime-pathname*)
         "--core" (uiop:native-namestring sb-ext:*core-pathname*) "--noinform"
         "--non-interactive" "--no-sysinit" "--no-userinit")
   (loop for form in (list (%asdf-load-form)
                           (format nil "(uiop:symbol-call :asdf :initialize-source-registry '~s)"
                                   (%registry-form))
                           ;; stdout is the protocol: compiler output must not reach it.
                           "(let ((*standard-output* (make-broadcast-stream))) (uiop:symbol-call :asdf :load-system \"cl-stack-code/acp/tests\"))"
                           (format nil "(uiop:symbol-call :cl-stack-code/acp/tests :acp-child-main ~s ~s ~s)"
                                   (native project) (native config)
                                   (let ((*print-readably* t)) (prin1-to-string steps))))
         append (list "--eval" form))))

(defparameter *child-start-seconds* 300
  "Deadline for a child's first answer: it loads the systems first.")

(defun child-stderr (config)
  "Where a child's stderr goes: a file beside CONFIG."
  (uiop:merge-pathnames* "acp-child-stderr.log" (uiop:pathname-parent-directory-pathname config)))

(defun call-with-acp-child (project config steps fn &key (client (make-instance 'recording-client)))
  "FN gets (connection ra client): a child cl-stack-code --acp spawned by
SPAWN-ACP-AGENT, not yet initialized. Afterwards the connection is closed
(bounded)."
  (multiple-value-bind (connection ra)
      (stdio:spawn-acp-agent (acp-child-argv project config steps)
                             :client client
                             :error-output (child-stderr config))
    (setf (client-remote client) ra)
    (unwind-protect (funcall fn connection ra client)
      (let ((code (ignore-errors
                   (within 40 (lambda () (stdio:close-acp-connection connection :timeout 10))))))
        (unless (eql code 0)
          (show-child-stderr config code))))))

(defun show-child-stderr (config code)
  "A failed child: the end of its stderr on *ERROR-OUTPUT*, for the log."
  (let* ((file (child-stderr config))
         (text (and (probe-file file) (ignore-errors (uiop:read-file-string file)))))
    (format *error-output* "~&;; --acp child exited with ~s; its stderr ends with:~%~a~%"
            code (if text (subseq text (max 0 (- (length text) 2000))) "(none)"))))

(defmacro with-acp-child ((connection ra client) (project config steps &rest keys) &body body)
  `(call-with-acp-child ,project ,config ,steps
                        (lambda (,connection ,ra ,client)
                          (declare (ignorable ,connection ,ra ,client))
                          ,@body)
                        ,@keys))

(defun initialize-child (ra &key (caps *bare-client-caps*))
  "INITIALIZE with the child's start-up deadline."
  (within *child-start-seconds* (lambda () (initialize ra :caps caps))))

(defun close-child (connection)
  "Close our side; → the child's exit code (it sees EOF on stdin)."
  (within 40 (lambda () (stdio:close-acp-connection connection :timeout 20))))

;;; MCP servers from the editor (session/new, session/load).

(defun stdio-mcp-server (name)
  (acp:make-acp 'acp:mcp-server-stdio
                :name name :command "/usr/bin/true" :args (vector "--serve")
                :env (vector (acp:make-acp 'acp:env-variable :name "TOKEN" :value "t"))))

(defun http-mcp-server (name)
  (make-instance 'acp:mcp-server-http
                 :wire-type "http" :name name :url "https://mcp.example.invalid/mcp"
                 :headers (vector (acp:make-acp 'acp:http-header :name "X-Key" :value "k"))))

(defun mcp-server-names (servers)
  (mapcar #'acp:name servers))

;;; The raw JSON of the loopback.

(defun wire-result (ra method)
  "The decoded \"result\" of the last answer to the client-side request METHOD."
  (let* ((log (wire-log ra))
         (request (position-if (lambda (e) (and (eq :to-agent (car e))
                                                (search (format nil "\"method\":\"~a\"" method) (cdr e))))
                               log :from-end t))
         (id (and request (gethash "id" (json:decode (cdr (nth request log))))))
         (answer (find-if (lambda (e)
                            (and (eq :to-client (car e))
                                 (let ((m (ignore-errors (json:decode (cdr e)))))
                                   (and (hash-table-p m) (null (gethash "method" m))
                                        (equal id (gethash "id" m))))))
                          log :start (or request 0))))
    (and answer (gethash "result" (json:decode (cdr answer))))))

(defun present-false-p (object key)
  "OBJECT (a decoded JSON object) has KEY, and its value is false."
  (and (hash-table-p object)
       (multiple-value-bind (v present) (gethash key object)
         (and present (member v '(nil :false)) t))))
