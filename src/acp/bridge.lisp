(in-package #:cl-stack-code/acp)

;;; ACP-2: the bridge between the SDK's threads and the ACP client, and the
;;; client-backed tool backends (agent.lisp, "Client capabilities").
;;;
;;; COURIER: one per ACP session. A FIFO of items for the thread that pumps
;;; it (the thread of the ACP GF that is running the session's prompt, or its
;;; session/load), which is the only thread that sends to the client for the
;;; session's turns (agent.lisp, "Threads"):
;;;   (:event EVENT DIFF)   an SDK event of the running turn, put by the turn's
;;;                         ON-EVENT on the loop thread (never blocks);
;;;   (:call THUNK BOX)     a delegated client request (fs/*, terminal/*) of a
;;;                         tool worker, which waits on BOX for THUNK's values
;;;                         (or its error, signalled again in the worker).
;;; Events and calls share one order, so the tool_call of a call is on the
;;; wire before that call's fs or terminal request. COURIER-CALL from the
;;; pumping thread itself runs THUNK at once. When the pump ends, every call
;;; still queued fails with CLIENT-BRIDGE-UNAVAILABLE, and so does a call
;;; made while no thread pumps: no worker is left waiting. Every wait is
;;; bounded by polls (0.2 s) that see the pump end.
;;;
;;; The tool backends (TOOL-SOURCES-HOOK → CL-STACK-CODE:CLIENT-NEW-SESSION's
;;; :TOOL-SOURCES), only for what the client advertises:
;;;   CLIENT-FILESYSTEM, a CL-STACK-PATHLIB:LOCAL-FILESYSTEM whose content I/O
;;;     goes to the client: with fs.readTextFile, FS-READ-BYTES and
;;;     FS-CONTENT-HASH read fs/read_text_file (the editor's buffer); with
;;;     fs.writeTextFile, FS-WRITE-ATOMIC and FS-WRITE-BYTES write
;;;     fs/write_text_file, the compare-and-swap checked against the content
;;;     the filesystem reads (pathlib's CONTENT-HASH-MISMATCH with OVERWRITE /
;;;     USE-CURRENT). Paths, stat, directories and walks stay local. The file
;;;     tools are agent-tools' own, made over it (MAKE-FILE-TOOLS :FILESYSTEM).
;;;     A client error → CL-STACK-PATHLIB:PATH-NOT-FOUND (resource not found)
;;;     or PATH-ERROR, so the tool reports it as for a disk error.
;;;   CLIENT-TERMINAL-SHELL, a subclass of AGENT-TOOLS:SHELL-TOOLS (the
;;;     session's own shell tools, CHANGE-CLASSed, so permission, resources,
;;;     jobs and closing are inherited): a foreground bash runs its command
;;;     line through terminal/create (the shell argv with the command as its
;;;     last argument, cwd the workdir), sends a tool_call_update with the
;;;     TERMINAL content, then terminal/wait_for_exit (timeout_ms: then
;;;     terminal/kill), terminal/output and terminal/release. The result is
;;;     the output cleaned and capped as the local bash does, then its status
;;;     line ("[exit code N]", "[killed by signal S]"). Background bash and
;;;     the job tools stay local.

(define-condition client-bridge-unavailable (acp:acp-internal-error)
  ()
  (:default-initargs :message "No prompt of this session is running to reach the client")
  (:documentation "A delegated client request with nobody to send it: no
thread pumps the session's courier, or the pump ended first."))

;;; The courier.

(defstruct (courier (:constructor make-courier ()))
  (lock (bt2:make-lock :name "acp courier"))
  (cv (bt2:make-condition-variable))
  (items '())                           ; FIFO
  (owner nil)                           ; the pumping thread, or NIL
  (session-id nil)                      ; the ACP session id (the SDK's)
  (terminals '()))                      ; live terminal ids (session/cancel kills them)

(defun courier-post (courier item)
  "Queue ITEM (any thread, never blocks). → T."
  (bt2:with-lock-held ((courier-lock courier))
    (setf (courier-items courier) (nconc (courier-items courier) (list item)))
    (bt2:condition-notify (courier-cv courier)))
  t)

(defun courier-take (courier timeout)
  "The next item, waiting up to TIMEOUT seconds; NIL when none came."
  (bt2:with-lock-held ((courier-lock courier))
    (unless (courier-items courier)
      (bt2:condition-wait (courier-cv courier) (courier-lock courier) :timeout timeout))
    (pop (courier-items courier))))

(defun %fill-box (courier box value)
  (bt2:with-lock-held ((courier-lock courier))
    (setf (car box) value)
    (bt2:condition-broadcast (courier-cv courier))))

(defun courier-run-call (courier item)
  "Run a (:call THUNK BOX) item on the pumping thread; its values or its
error go into BOX."
  (destructuring-bind (thunk box) (rest item)
    (%fill-box courier box
               (handler-case (cons :ok (multiple-value-list (funcall thunk)))
                 (error (e) (cons :error e))))))

(defun courier-call (courier thunk)
  "THUNK's values, computed on the pumping thread (at once when this is it).
Its error is signalled again here; no pump → CLIENT-BRIDGE-UNAVAILABLE."
  (when (eq (bt2:current-thread) (courier-owner courier))
    (return-from courier-call (funcall thunk)))
  (let ((box (list :pending)))
    (bt2:with-lock-held ((courier-lock courier))
      (unless (courier-owner courier)
        (error 'client-bridge-unavailable))
      (setf (courier-items courier)
            (nconc (courier-items courier) (list (list :call thunk box))))
      (bt2:condition-broadcast (courier-cv courier))
      (loop while (and (eq :pending (car box)) (courier-owner courier))
            do (bt2:condition-wait (courier-cv courier) (courier-lock courier) :timeout 0.2)))
    (let ((value (car box)))
      (when (eq value :pending)
        (error 'client-bridge-unavailable))
      (ecase (car value)
        (:ok (values-list (cdr value)))
        (:error (error (cdr value)))))))

(defun courier-claim (courier)
  "The calling thread pumps COURIER from now on. Another thread pumping →
ACP-INVALID-REQUEST (one prompt per session at a time)."
  (bt2:with-lock-held ((courier-lock courier))
    (when (and (courier-owner courier) (not (eq (courier-owner courier) (bt2:current-thread))))
      (error 'acp:acp-invalid-request :message "A prompt of this session is running"))
    (setf (courier-owner courier) (bt2:current-thread)
          (courier-items courier) '())))

(defun courier-release (courier)
  "Nobody pumps COURIER any more: the calls still queued fail."
  (let ((left (bt2:with-lock-held ((courier-lock courier))
                (setf (courier-owner courier) nil)
                (shiftf (courier-items courier) '()))))
    (dolist (item left)
      (when (eq :call (first item))
        (%fill-box courier (third item)
                   (cons :error (make-condition 'client-bridge-unavailable)))))
    (bt2:with-lock-held ((courier-lock courier))
      (bt2:condition-broadcast (courier-cv courier)))))

(defun courier-add-terminal (courier id)
  (bt2:with-lock-held ((courier-lock courier))
    (push id (courier-terminals courier))))

(defun courier-remove-terminal (courier id)
  (bt2:with-lock-held ((courier-lock courier))
    (setf (courier-terminals courier) (remove id (courier-terminals courier) :test #'equal))))

(defun courier-live-terminals (courier)
  (bt2:with-lock-held ((courier-lock courier))
    (copy-list (courier-terminals courier))))

;;; Client requests (on the pumping thread: *ACP-REMOTE* is the client).

(defun %native (fs pathname)
  (uiop:native-namestring (fs:fs-parse fs pathname)))

(defun client-read-text (courier path)
  "fs/read_text_file of the absolute native PATH → the text, or NIL when the
client has no such file."
  (courier-call courier
                (lambda ()
                  (handler-case
                      (acp:content
                       (acp:acp-read-text-file
                        acp:*acp-remote*
                        (acp:make-acp 'acp:read-text-file-request
                                      :session-id (courier-session-id courier) :path path)))
                    (acp:acp-resource-not-found () nil)))))

(defun client-write-text (courier path text)
  "fs/write_text_file of TEXT to the absolute native PATH."
  (courier-call courier
                (lambda ()
                  (acp:acp-write-text-file
                   acp:*acp-remote*
                   (acp:make-acp 'acp:write-text-file-request
                                 :session-id (courier-session-id courier)
                                 :path path :content text))
                  t)))

;;; The client-backed filesystem.

(defclass client-filesystem (fs:local-filesystem)
  ((courier :initarg :courier :reader %cfs-courier)
   (read-p :initarg :read-p :initform nil :reader %cfs-read-p
           :documentation "fs.readTextFile: contents are read from the client.")
   (write-p :initarg :write-p :initform nil :reader %cfs-write-p
            :documentation "fs.writeTextFile: contents are written to the client."))
  (:documentation "ACP-2: the local filesystem, its file contents read and / or
written through the ACP client (fs/*)."))

(defmacro %as-path-error ((fs pathname) &body body)
  "BODY with an ACP error of the client as the pathlib condition of PATHNAME."
  `(handler-case (progn ,@body)
     (acp:acp-error (e)
       (error 'fs:path-error :filesystem ,fs :path ,pathname
                             :message (format nil "the client refused: ~a" (acp:acp-error-message e))))))

(defun %client-octets (fs pathname)
  "The client's content of PATHNAME as UTF-8 octets; missing → PATH-NOT-FOUND."
  (let ((text (%as-path-error (fs pathname)
                (client-read-text (%cfs-courier fs) (%native fs pathname)))))
    (unless text
      (error 'fs:path-not-found :filesystem fs :path pathname
                                :message "the client has no such file"))
    (fs:utf8-encode text)))

(defmethod fs:fs-read-bytes ((fs client-filesystem) pathname)
  (if (%cfs-read-p fs)
      (%client-octets fs pathname)
      (call-next-method)))

(defmethod fs:fs-content-hash ((fs client-filesystem) pathname)
  (if (%cfs-read-p fs)
      (progn
        (when (fs:fs-directory-p fs pathname)
          (error 'fs:path-error :filesystem fs :path pathname :message "is a directory"))
        (fs:octets-hash (%client-octets fs pathname)))
      (call-next-method)))

(defun %current-hash (fs pathname)
  "The digest of PATHNAME's content as FS reads it, or NIL when missing."
  (handler-case (fs:fs-content-hash fs pathname)
    (fs:path-not-found () nil)))

(defun %client-write-octets (fs pathname bytes)
  (%as-path-error (fs pathname)
    (client-write-text (%cfs-courier fs) (%native fs pathname) (fs:utf8-decode bytes))))

(defmethod fs:fs-write-atomic ((fs client-filesystem) pathname bytes &key expected-hash mode)
  (declare (ignore mode))               ; the client owns the buffer
  (if (not (%cfs-write-p fs))
      (call-next-method)
      (let ((pn (fs:fs-parse fs pathname)))
        (when expected-hash
          (let ((actual (%current-hash fs pn)))
            (unless (if (eq expected-hash :absent)
                        (null actual)
                        (equal actual expected-hash))
              (restart-case
                  (error 'fs:content-hash-mismatch
                         :filesystem fs :path pn :expected expected-hash :actual actual
                         :message "compare-and-swap write refused")
                (fs:overwrite ()
                  :report (lambda (s) (format s "Write ~A anyway" pn))
                  nil)
                (fs:use-current ()
                  :report (lambda (s) (format s "Keep the current content of ~A, write nothing" pn))
                  (return-from fs:fs-write-atomic (values pn actual nil)))))))
        (%client-write-octets fs pn bytes)
        (values pn (fs:octets-hash bytes) t))))

(defmethod fs:fs-write-bytes ((fs client-filesystem) pathname bytes
                              &key append if-exists if-does-not-exist)
  (declare (ignore if-exists if-does-not-exist))
  (if (not (%cfs-write-p fs))
      (call-next-method)
      (let ((pn (fs:fs-parse fs pathname)))
        (%client-write-octets fs pn
                              (if append
                                  (concatenate '(vector (unsigned-byte 8))
                                               (handler-case (fs:fs-read-bytes fs pn)
                                                 (fs:path-not-found () #()))
                                               bytes)
                                  bytes))
        pn)))

;;; The client's terminal.

(defclass client-terminal-shell (tools:shell-tools)
  ((courier :initarg :courier :accessor %shell-courier)
   (workdir-tools :initform nil :accessor %shell-workdir-tools
                  :documentation "A FILE-TOOLS over the root with no tools, to
resolve workdir as the local bash does."))
  (:documentation "ACP-2: shell tools whose foreground bash runs in the ACP
client's terminal (terminal/*)."))

(defun %decoded-arguments (arguments)
  "ARGUMENTS as a JSON object (hash table), or NIL."
  (cond ((hash-table-p arguments) arguments)
        ((stringp arguments)
         (let ((v (handler-case (json:decode arguments)
                    (json:json-error () nil))))
           (and (hash-table-p v) v)))
        (t nil)))

(defun %client-bash-arguments (source name arguments)
  "The decoded arguments of a foreground bash call that goes to the client's
terminal, or NIL (the local tool then runs it, or reports its input error)."
  (let ((args (and (equal name "bash")
                   (member "bash" (tools:shell-tools-names source) :test #'equal)
                   (%decoded-arguments arguments))))
    (and args
         (let ((command (gethash "command" args)))
           (and (stringp command) (string/= "" (string-trim '(#\Space #\Tab #\Newline) command))))
         (not (eq t (gethash "run_in_background" args)))
         args)))

(defun %bash-directory (source args)
  "The native directory bash ARGS runs in: workdir under the root, else the
root. A workdir that does not resolve → AGENT-TOOLS' input error."
  (let ((workdir (gethash "workdir" args)))
    (uiop:native-namestring
     (uiop:ensure-directory-pathname
      (fs:path-pathname
       (if (stringp workdir)
           (tools:resolve-tool-path
            (or (%shell-workdir-tools source)
                (setf (%shell-workdir-tools source)
                      (tools:make-file-tools :root (tools:shell-tools-root source) :tools '())))
            workdir)
           (tools:shell-tools-root source)))))))

(defun %bash-timeout (source args)
  "Seconds: timeout_ms within the tools' cap, else their default."
  (let ((ms (gethash "timeout_ms" args)))
    (/ (if (and (integerp ms) (<= 1 ms (tools:shell-tools-max-timeout source)))
           ms
           (tools:shell-tools-default-timeout source))
       1000)))

(defun %terminal-text (source response timeout timed-out)
  "The bash result of a terminal's OUTPUT RESPONSE, as the local tool writes
it: the output cleaned and capped, then the status line."
  (let* ((output (string-right-trim
                  '(#\Newline)
                  (tools:truncate-shell-output (tools:clean-shell-output (or (acp:output response) ""))
                                               (tools:shell-tools-max-output source))))
         (status (and (slot-boundp response 'acp:exit-status)
                      (let ((s (acp:exit-status response))) (and (not (eq s :null)) s))))
         (code (and status (slot-boundp status 'acp:exit-code) (acp:exit-code status)))
         (signal (and status (slot-boundp status 'acp:exit-signal) (acp:exit-signal status)))
         ;; agent-tools' status line (its %EXIT-LINE is internal in 0.4.0).
         (line (cond (timed-out
                      (format nil "Command timed out after ~d ms and was killed"
                              (round (* 1000 timeout))))
                     ((and (stringp signal) (plusp (length signal)))
                      (format nil "[killed by signal ~a]" signal))
                     (t (format nil "[exit code ~a]" (if (integerp code) code "unknown"))))))
    (if (zerop (length output)) line (format nil "~a~%~a" output line))))

(defun %terminal-run (source command directory timeout call-id)
  "On the pumping thread: COMMAND in a new client terminal → the bash result."
  (let* ((courier (%shell-courier source))
         (remote acp:*acp-remote*)
         (sid (courier-session-id courier))
         (shell (tools:shell-tools-shell source))
         (id (acp:terminal-id
              (acp:acp-create-terminal
               remote (acp:make-acp 'acp:create-terminal-request
                                    :session-id sid
                                    :command (first shell)
                                    :args (coerce (append (rest shell) (list command)) 'vector)
                                    :cwd directory)))))
    (courier-add-terminal courier id)
    (flet ((terminal-request (class)
             (acp:make-acp class :session-id sid :terminal-id id)))
      (unwind-protect
           (let ((start (get-internal-real-time))
                 (timed-out nil))
             (when call-id
               (acp:acp-send-update remote sid
                                    (acp:make-acp 'acp:update-tool-call-update
                                                  :tool-call-id call-id
                                                  :content (vector (acp:make-acp 'acp:terminal
                                                                                 :terminal-id id)))))
             (handler-case
                 (acp:remote-call remote "terminal/wait_for_exit"
                                  (terminal-request 'acp:wait-for-terminal-exit-request)
                                  :timeout timeout)
               (acp:acp-error (e)
                 ;; The transport's deadline: kill it, as the local bash does.
                 (if (>= (/ (- (get-internal-real-time) start) internal-time-units-per-second)
                         timeout)
                     (progn
                       (setf timed-out t)
                       (handler-case (acp:acp-kill-terminal
                                      remote (terminal-request 'acp:kill-terminal-request))
                         (acp:acp-error () nil)))
                     (error e))))
             (%terminal-text source
                             (acp:acp-terminal-output remote (terminal-request 'acp:terminal-output-request))
                             timeout timed-out))
        (courier-remove-terminal courier id)
        (handler-case (acp:acp-release-terminal remote (terminal-request 'acp:release-terminal-request))
          (acp:acp-error () nil))))))

(defmethod agent:invoke-tool-async ((source client-terminal-shell) name arguments
                                    &key context callback error-callback)
  (let ((args (%client-bash-arguments source name arguments)))
    (if (null args)
        (call-next-method)
        (let ((call-id (let ((inv (and (listp context) (getf context :invocation))))
                         (and inv (agent:agent-invocation-id inv)))))
          ;; The protocol's sync function-tool path (a worker thread), as the
          ;; shell tools' own method: the worker hands the terminal to the
          ;; pumping thread and waits.
          (agent:invoke-tool-async
           (agent:make-function-tool
            :name name
            :handler (lambda (a)
                       (declare (ignore a))
                       (let ((directory (%bash-directory source args))
                             (timeout (%bash-timeout source args)))
                         (courier-call (%shell-courier source)
                                       (lambda ()
                                         (%terminal-run source (gethash "command" args)
                                                        directory timeout call-id))))))
           name arguments
           :context context :callback callback :error-callback error-callback)))))

(defun kill-client-terminals (courier)
  "session/cancel: terminal/kill every live terminal of COURIER's session, from
the calling thread (the cancel's). A refusal is not an error."
  (dolist (id (courier-live-terminals courier))
    (handler-case
        (acp:acp-kill-terminal acp:*acp-remote*
                               (acp:make-acp 'acp:kill-terminal-request
                                             :session-id (courier-session-id courier)
                                             :terminal-id id))
      (acp:acp-error () nil))))

;;; The hook.

(defun tool-sources-hook (courier caps)
  "CLIENT-NEW-SESSION's :TOOL-SOURCES for a client with capabilities CAPS, or
NIL when it advertises neither fs nor terminal (the local tools, unchanged)."
  (let ((read-p (acp:client-supports-p caps :read-text-file))
        (write-p (acp:client-supports-p caps :write-text-file))
        (terminal-p (acp:client-supports-p caps :terminal)))
    (when (or read-p write-p terminal-p)
      (lambda (sources)
        (destructuring-bind (files shell &rest more) sources
          (list* (if (or read-p write-p)
                     (let ((cfs (make-instance 'client-filesystem
                                               :courier courier :read-p read-p :write-p write-p)))
                       (tools:make-file-tools
                        :root (uiop:native-namestring (fs:path-pathname (tools:file-tools-root files)))
                        :filesystem cfs
                        :tools (tools:file-tools-names files)
                        :max-read-lines (tools:file-tools-max-read-lines files)
                        :max-output (tools:file-tools-max-output files)
                        :max-results (tools:file-tools-max-results files)))
                     files)
                 (if (and terminal-p (tools:shell-tools-p shell))
                     (change-class shell 'client-terminal-shell :courier courier)
                     shell)
                 more))))))
