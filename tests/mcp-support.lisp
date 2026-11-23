(in-package #:cl-stack-code/tests)

;;; H3e-2a helpers (test code, complete).
;;;
;;; The fake stdio MCP server is this SBCL (no init files) loading
;;; mcp-protocol and mcp-backend-stdio through ASDF with the PARENT's
;;; source directories and output translations, so it loads the fasls this
;;; image compiled (no compilation, no network, no registry of its own). Its
;;; script is written to a temp file. FAKE_MCP_MODE picks the behaviour:
;;;   serve (default)  the tools below, then EOF ends it
;;;   crash            "fake-mcp: crashing" on stderr, exit 3, before serving
;;;   hang             reads stdin forever, never answers (initialize times out)
;;; Tools: echo {msg} (readOnlyHint true) → msg; write_note {text} → "noted:
;;; TEXT"; fail → isError "disk full"; picture → a text item and a PNG image
;;; item; env → $FAKE_TOKEN or "unset"; log → a notifications/message "hello
;;; from fake", then "logged". On start it writes "fake-mcp: started" to
;;; stderr and, with FAKE_MCP_PID_FILE, its pid to that file.
;;;
;;; The fake streamable-HTTP server is in this image: an mcp-protocol server
;;; behind mcp-backend-streamable-http's MAKE-MCP-APP (the real Clack app),
;;; reached through LOOPBACK-HTTP-BACKEND, an http-protocol backend whose SEND
;;; turns the request into a Clack env and calls the app. No socket. Every
;;; request's headers are recorded.

(defparameter +fake-mcp-script+
  "(in-package :cl-user)
(defvar *fake-mode* (or (uiop:getenv \"FAKE_MCP_MODE\") \"serve\"))
(format *error-output* \"fake-mcp: started~%\") (finish-output *error-output*)
(let ((file (uiop:getenv \"FAKE_MCP_PID_FILE\")))
  (when (and file (plusp (length file)))
    (with-open-file (o file :direction :output :if-exists :supersede)
      (format o \"~d\" (or (ignore-errors (funcall (find-symbol \"UNIX-GETPID\" \"SB-UNIX\"))) 0)))))
(cond
  ((string= *fake-mode* \"crash\")
   (format *error-output* \"fake-mcp: crashing~%\") (finish-output *error-output*)
   (sb-ext:exit :code 3 :abort t))
  ((string= *fake-mode* \"hang\")
   (loop for line = (read-line *standard-input* nil) while line))
  (t
   (let ((server (make-instance 'mcp-protocol:mcp-server :name \"fake\" :version \"1.0.0\")))
     (flet ((obj (&rest kv) (apply #'mcp-protocol:json-object kv))
            (tool (&rest args) (mcp-protocol:register-tool server (apply #'mcp-protocol:make-mcp-tool args))))
       (tool \"echo\" :description \"Echo msg\" :input-schema (obj \"type\" \"object\")
                    :annotations (obj \"readOnlyHint\" t)
                    :handler (lambda (a) (or (mcp-protocol:param a \"msg\") \"\")))
       (tool \"write_note\" :description \"Write a note\" :input-schema (obj \"type\" \"object\")
                          :handler (lambda (a) (format nil \"noted: ~a\" (or (mcp-protocol:param a \"text\") \"\"))))
       (tool \"fail\" :description \"Always fails\" :input-schema (obj \"type\" \"object\")
                    :handler (lambda (a) (declare (ignore a))
                               (mcp-protocol:tool-result (list (mcp-protocol:make-text-content \"disk full\")) :is-error t)))
       (tool \"picture\" :description \"A picture\" :input-schema (obj \"type\" \"object\")
                       :handler (lambda (a) (declare (ignore a))
                                  (mcp-protocol:tool-result
                                   (list (mcp-protocol:make-text-content \"a picture\")
                                         (obj \"type\" \"image\" \"mimeType\" \"image/png\" \"data\" \"iVBORw0KGgo=\")))))
       (tool \"env\" :description \"FAKE_TOKEN\" :input-schema (obj \"type\" \"object\")
                   :handler (lambda (a) (declare (ignore a)) (or (uiop:getenv \"FAKE_TOKEN\") \"unset\")))
       (tool \"log\" :description \"Log a line\" :input-schema (obj \"type\" \"object\")
                   :handler (lambda (a) (declare (ignore a))
                              (mcp-protocol:mcp-log server \"info\" \"hello from fake\")
                              \"logged\")))
     (mcp-protocol:mcp-serve server :backend (mcp-backend-stdio:make-stdio-mcp-backend)))))
")

(defparameter +fake-stdio-tools+ '("echo" "write_note" "fail" "picture" "env" "log")
  "The fake stdio server's tools, in its tools/list order (registration order
is a hash table's in mcp-protocol 0.3; the tests compare as sets).")

(defun %loaded-system-dirs ()
  "Distinct source directories of every system loaded in this image."
  (remove-duplicates
   (loop for name in (asdf:already-loaded-systems)
         for dir = (and (not (member name '("asdf" "uiop" "asdf-package-system") :test #'string=))
                        (not (uiop:string-prefix-p "sb-" name))
                        (ignore-errors (asdf:system-source-directory name)))
         when dir collect (uiop:native-namestring dir))
   :test #'string=))

(defun %child-setup-forms ()
  "Forms (strings) that make a bare SBCL (ASDF loaded) find and load
mcp-backend-stdio from this image's sources and fasls: the loaded systems'
directories, their output translations, and the exact .asd of every loaded
system (%PIN-LOADED-SYSTEMS-FORM)."
  (let ((dirs (%loaded-system-dirs)))
    (list (let ((*print-readably* nil))
            (format nil "(asdf:initialize-source-registry '(:source-registry ~{(:directory ~s) ~}:ignore-inherited-configuration))"
                    dirs))
          (format nil "(asdf:initialize-output-translations '(:output-translations ~{(~s ~s) ~}:ignore-inherited-configuration))"
                  (loop for d in dirs
                        append (list d (uiop:native-namestring
                                        (asdf:apply-output-translations
                                         (uiop:parse-native-namestring d :ensure-directory t))))))
          (%pin-loaded-systems-form)
          "(let ((*standard-output* *error-output*)) (asdf:load-system \"mcp-backend-stdio\"))")))

(defun fake-mcp-setup (base)
  "Write the child's ASDF setup file under BASE (once) → its native namestring.
A file, not --eval forms: the registry runs to tens of kilobytes, past the
Windows command-line limit (32767 characters; \"The filename or extension is
too long\")."
  (let ((path (merge-pathnames "fake-mcp-asdf.lisp" (uiop:ensure-directory-pathname base))))
    (unless (probe-file path)
      (with-open-file (o path :direction :output :if-exists :supersede :external-format :utf-8)
        (dolist (form (%child-setup-forms)) (write-line form o))))
    (native path)))

(defun %child-load-forms (base)
  "--eval forms (strings) for the fake server child: ASDF, then the setup file."
  (list (%asdf-load-form)
        (format nil "(load (uiop:parse-native-namestring ~s) :external-format :utf-8)"
                (fake-mcp-setup base))))

(defun fake-mcp-script (base)
  "Write the fake server script under BASE (once) → its native namestring."
  (let ((path (merge-pathnames "fake-mcp-server.lisp" (uiop:ensure-directory-pathname base))))
    (unless (probe-file path)
      (with-open-file (o path :direction :output :if-exists :supersede :external-format :utf-8)
        (write-string +fake-mcp-script+ o)))
    (native path)))

(defun fake-stdio-server (base &key (mode "serve") env pid-file)
  "A .mcp.json server object (hash table) running the fake stdio server."
  (let ((argv (apply #'child-argv
                     (append (%child-load-forms base)
                             (list (format nil "(load (uiop:parse-native-namestring ~s) :external-format :utf-8)"
                                           (fake-mcp-script base))))))
        (env-object (make-hash-table :test 'equal)))
    (setf (gethash "FAKE_MCP_MODE" env-object) mode)
    (when pid-file (setf (gethash "FAKE_MCP_PID_FILE" env-object) (native pid-file)))
    (loop for (k v) on env by #'cddr do (setf (gethash k env-object) v))
    (args "command" (first argv) "args" (coerce (rest argv) 'vector) "env" env-object)))

(defun mcp-servers-json (&rest name-object)
  "{\"mcpServers\": {NAME: OBJECT, …}} as JSON text."
  (let ((servers (make-hash-table :test 'equal)))
    (loop for (name object) on name-object by #'cddr do (setf (gethash name servers) object))
    (json:encode (args "mcpServers" servers))))

(defun write-mcp-json (project &rest name-object)
  (write-file project ".mcp.json" (apply #'mcp-servers-json name-object)))

(defun write-user-settings (config &rest kv)
  "The user settings.json from alternating keys and values (JSON objects as hash tables)."
  (write-file config "settings.json" (json:encode (apply #'args kv))))

(defun approve-all (config &rest more)
  "User settings that approve every project MCP server."
  (apply #'write-user-settings config "enableAllProjectMcpServers" t more))

(defun mcp-init-servers (out)
  "The \"mcp_servers\" of the system init event in stream-json OUT."
  (jget (first (events out "system")) "mcp_servers"))

(defun server-object (servers name)
  (find name (coerce servers 'list) :key (lambda (s) (jget s "name")) :test #'equal))

(defun mcp-names (server &optional (tools +fake-stdio-tools+))
  (mapcar (lambda (tool) (format nil "mcp__~a__~a" server tool)) tools))

(defun same-set (a b)
  (and (subsetp a b :test #'equal) (subsetp b a :test #'equal)))

(defun process-alive-p (pid)
  (if (uiop:os-windows-p)
      (search (princ-to-string pid)
              (uiop:run-program (list "tasklist" "/FI" (format nil "PID eq ~d" pid))
                                :output :string :ignore-error-status t))
      (zerop (nth-value 2 (uiop:run-program (list "kill" "-0" (princ-to-string pid))
                                            :ignore-error-status t)))))

(defun read-pid (file)
  (and (probe-file file)
       (ignore-errors (parse-integer (uiop:read-file-string file)))))

;;; The loopback HTTP backend and the in-process HTTP MCP server.

(defclass loopback-http-backend (http-protocol:http-backend)
  ((app :initarg :app :reader loopback-app)
   (requests :initform '() :accessor loopback-requests
             :documentation "(method path headers-alist body), newest first."))
  (:default-initargs :name "loopback"))

(defun %header-alist (headers)
  (cond ((hash-table-p headers)
         (loop for k being the hash-keys of headers using (hash-value v)
               collect (cons (string-downcase (string k)) v)))
        (t (loop for h in headers
                 collect (cons (string-downcase (string (car h))) (cdr h))))))

(defun %url-path (url)
  (let* ((s (princ-to-string url))
         (start (or (search "://" s) -3))
         (slash (position #\/ s :start (+ start 3))))
    (if slash (subseq s slash (or (position #\? s :start slash) (length s))) "/")))

(defmethod http-protocol:send ((backend loopback-http-backend) client request &key)
  (declare (ignore client))
  (let* ((headers (%header-alist (http-protocol:http-request-headers request)))
         (header-table (let ((h (make-hash-table :test 'equal)))
                         (loop for (k . v) in headers do (setf (gethash k h) v)) h))
         (content (http-protocol:http-request-content request))
         (body (if (stringp content)
                   content
                   (babel:octets-to-string (coerce content '(vector (unsigned-byte 8)))
                                           :encoding :utf-8)))
         (path (%url-path (http-protocol:http-request-url request))))
    (push (list (http-protocol:http-request-method request) path headers body)
          (loopback-requests backend))
    (destructuring-bind (status plist parts)
        (funcall (loopback-app backend)
                 (list :request-method (http-protocol:http-request-method request)
                       :path-info path :server-name "mcp.test" :server-port 80
                       :headers header-table :raw-body body))
      (let ((h (make-hash-table :test 'equal)))
        (loop for (k v) on plist by #'cddr do (setf (gethash (string-downcase (string k)) h) v))
        (make-instance 'http-protocol:http-response
                       :status status :headers h
                       :body (format nil "~{~a~}" parts))))))

(defun fake-http-mcp-server ()
  "An in-process MCP server: echo (readOnlyHint) and fail."
  (let ((server (make-instance 'mcp-protocol:mcp-server :name "fake-http" :version "1.0.0")))
    (flet ((obj (&rest kv) (apply #'mcp-protocol:json-object kv)))
      (mcp-protocol:register-tool
       server (mcp-protocol:make-mcp-tool "echo" :description "Echo msg" :input-schema (obj "type" "object")
                                                 :annotations (obj "readOnlyHint" t)
                                                 :handler (lambda (a) (or (mcp-protocol:param a "msg") ""))))
      (mcp-protocol:register-tool
       server (mcp-protocol:make-mcp-tool "fail" :description "Fails" :input-schema (obj "type" "object")
                                                 :handler (lambda (a) (declare (ignore a))
                                                            (mcp-protocol:tool-result
                                                             (list (mcp-protocol:make-text-content "nope"))
                                                             :is-error t)))))
    server))

(defun make-loopback-backend (&optional (server (fake-http-mcp-server)))
  (make-instance 'loopback-http-backend
                 :app (mcp-backend-streamable-http:make-mcp-app server :path "/mcp")))

(defun loopback-header (backend name)
  "The value of header NAME in the last request BACKEND saw."
  (cdr (assoc (string-downcase name) (third (first (loopback-requests backend))) :test #'string=)))

(defun http-server-object (&rest headers)
  (args "type" "http" "url" "http://mcp.test/mcp"
        "headers" (apply #'args headers)))

(defmacro with-loopback ((backend &optional server) &body body)
  "BODY with http-protocol:*http-backend* bound to a fresh loopback BACKEND."
  `(let* ((,backend (make-loopback-backend ,@(and server (list server))))
          (http-protocol:*http-backend* ,backend))
     ,@body))

(defun tool-result-of (out name)
  "The first tool_result event of tool NAME in stream-json OUT."
  (find name (events out "tool_result") :key (lambda (e) (jget e "name")) :test #'equal))

(defun denial-of (out name)
  (find name (coerce (jget (first (events out "result")) "permission_denials") 'list)
        :key (lambda (d) (jget d "name")) :test #'equal))
