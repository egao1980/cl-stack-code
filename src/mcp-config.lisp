(in-package #:cl-stack-code)

;;; H3e-2a: MCP server configuration and trust (brief: cl-stack
;;; docs/capabilities/cl-stack-code.md, "H3e-2 — locked"). The runtime (the
;;; connections, the tool source, units, /mcp, RPC) is src/mcp.lisp.
;;;
;;; Sources, Claude Code's format (code.claude.com/docs/en/mcp) so existing
;;; .mcp.json files work unchanged:
;;;   user settings      "mcpServers" in <user-config-dir>/settings.json  scope :user
;;;   .mcp.json          <project root, else cwd>/.mcp.json              scope :project
;;;   project settings   "mcpServers" in .cl-stack-code/settings.json     scope :project
;;;   local settings     "mcpServers" in .cl-stack-code/settings.local.json scope :local
;;;   --mcp-config X     a file in .mcp.json shape, or that JSON as text   scope :flag
;;;                      (a value whose first non-blank character is "{"), repeatable
;;;   SDK / ACP          :mcp-servers of CLIENT-NEW-SESSION / ADD-MCP-SERVERS,
;;;                      RPC session/new "mcp_servers", ACP session/new   scope :sdk
;;; A server object (the value of mcpServers.NAME):
;;;   {"type": "stdio", "command": "…", "args": ["…"], "env": {"K": "V"}}
;;;   {"type": "http" | "sse", "url": "…", "headers": {"K": "V"}}
;;;   optional on both: "disabled" (boolean), "timeout" (the tool-call timeout
;;;   in ms, as Claude Code's per-server key; a value below 1000 is ignored, as
;;;   there), "startupTimeout" (ms, ours), "cacheTools" (boolean, default true),
;;;   "toolErrorBehavior" ("retry" default, "failed", "error").
;;;   Unknown keys are ignored. "type" absent: "command" present → stdio
;;;   (command wins when "url" is there too); else "url" → "sse" when the URL's
;;;   path ends in "/sse", else "http" (pydantic-ai's inference; Claude Code
;;;   calls a url without a type an error, so every file it accepts parses the
;;;   same here). "ws" and "sdk" types: SETTINGS-ERROR (unknown type). "streamable-http" is an alias of
;;;   "http". Neither command nor url → SETTINGS-ERROR "mcpServers.NAME: needs
;;;   \"command\" or \"url\"". A wrong type → SETTINGS-ERROR with the key path
;;;   (mcpServers.NAME.args[1], mcpServers.NAME.env.K, mcpServers.NAME.type …)
;;;   and the file. "mcpServers" not an object → key "mcpServers"; a server
;;;   not an object → "mcpServers.NAME". A server name must be non-empty.
;;; Settings keys besides "mcpServers" (any layer parses them):
;;;   "enableAllProjectMcpServers" boolean, "enabledMcpjsonServers" and
;;;   "disabledMcpjsonServers" arrays of strings, "mcpTimeout" (startup) and
;;;   "mcpToolTimeout" integers >= 1 (ms).
;;;
;;; ${VAR} expansion (EXPAND-MCP-VARIABLES), as Claude Code: in "command",
;;; every "args" element, "env" values, "url" and "headers" values. ${VAR} is
;;; the effective environment's value (settings env, then the process; the
;;; ENV function given); ${VAR:-default} is the default when VAR is unset; an
;;; empty value counts as set (as Claude Code), so ${VAR:-default} of an empty
;;; VAR is "". An unset ${VAR} without a default →
;;; SETTINGS-ERROR (Claude Code warns and keeps the text; the coordinator chose
;;; pydantic-ai's error: a server started with a literal "${TOKEN}" fails late
;;; and obscurely), file = the
;;; server's file, key = the field's key path, message "${VAR} is not set (MCP
;;; server NAME)". Text without "${" is unchanged; "${" with no "}" is kept
;;; literally. Expansion happens after the layers merge (EFFECTIVE-MCP-SERVERS),
;;; so a settings "env" can supply a token.
;;;
;;; Merge and precedence (decided: per server, the last source wins). In
;;; order: user, .mcp.json, project settings, local settings, each
;;; --mcp-config in order, SDK. A later source's server replaces the whole
;;; object of an earlier one with the same name (no per-key merge: half of a
;;; stdio object over an http one means nothing), and the winner's scope
;;; decides its trust. The result keeps the first-seen order of names.
;;; --strict-mcp-config: only --mcp-config and SDK servers; every other source
;;; is ignored (Claude Code's flag). Disabled servers stay in the list with
;;; status :disabled, so /mcp and the init event show them.
;;;
;;; Trust (MCP-SERVER-APPROVAL). :user, :flag and :sdk servers are trusted:
;;; the user (or the host that started us) wrote them. :project and :local
;;; servers come from files inside the repository (settings.local.json is
;;; untracked by convention, but nothing stops a repository from committing
;;; it), so they start only when approved:
;;;   a "disabledMcpjsonServers" entry matches → :rejected
;;;   else "enableAllProjectMcpServers" true, or an "enabledMcpjsonServers"
;;;   entry matches                            → :approved
;;;   else                                     → :unapproved
;;; Entries are "NAME" (every project) or "NAME@<project dir>" (the native
;;; namestring of the project root, or the cwd without one; compared after
;;; ensuring a trailing separator). The two approving keys count only from the
;;; user file and the flag layer: %MCP-LAYER drops them from the project and
;;; local layers, so a repository cannot approve its own servers (as
;;; "sandbox"; Claude Code also honours an untracked settings.local.json in a
;;; trusted folder, but cl-stack-code has no folder trust yet).
;;; "disabledMcpjsonServers" counts from every layer: it only takes away.
;;; Headless -p never asks: :unapproved servers are skipped with a notice
;;; (src/mcp.lisp). The TUI asks once per server (Yes / No / Not now);
;;; SAVE-MCP-APPROVAL records Yes and No as NAME@<project dir> in the user
;;; settings file (keeping its other keys), Not now records nothing.
;;;
;;; Timeouts (MCP-TIMEOUTS config settings env → (values startup tool), in
;;; seconds): the server's "startupTimeout" / "timeout" (>= 1000), else settings
;;; "mcpTimeout" / "mcpToolTimeout", else the environment's MCP_TIMEOUT /
;;; MCP_TOOL_TIMEOUT (Claude Code's variables, ms, a positive integer; other
;;; text is ignored), else +DEFAULT-MCP-TIMEOUT-MS+ / +DEFAULT-MCP-TOOL-TIMEOUT-MS+
;;; (10 minutes; Claude Code's default is about 28 hours, which lets one hung
;;; server stall a headless run for a day).
;;; Startup covers spawning or connecting, initialize and the first tool list.

;;; Given: constants, the config object, the layer hooks.

(defparameter +default-mcp-timeout-ms+ 30000
  "Startup timeout of one MCP server (ms).")

(defparameter +default-mcp-tool-timeout-ms+ 600000
  "Timeout of one MCP tool call (ms).")

(defparameter +mcp-json-file-name+ ".mcp.json")

(defparameter +mcp-transports+ '(:stdio :http :sse))

(defparameter +mcp-scopes+ '(:user :project :local :flag :sdk))

(defparameter +mcp-settings-keys+
  '("mcpServers" "enableAllProjectMcpServers" "enabledMcpjsonServers"
    "disabledMcpjsonServers" "mcpTimeout" "mcpToolTimeout")
  "Settings keys parsed by %PARSE-MCP-SETTINGS.")

(defclass mcp-server-config ()
  ((name :initarg :name :reader mcp-server-config-name)
   (scope :initarg :scope :initform nil :accessor mcp-server-config-scope
          :documentation "One of +MCP-SCOPES+, set by the source (NIL while unparsed).")
   (transport :initarg :transport :reader mcp-server-config-transport
              :documentation ":STDIO, :HTTP or :SSE.")
   (command :initarg :command :initform nil :reader mcp-server-config-command)
   (args :initarg :args :initform nil :reader mcp-server-config-args)
   (env :initarg :env :initform nil :reader mcp-server-config-env
        :documentation "Alist (name . value), in the file's order.")
   (url :initarg :url :initform nil :reader mcp-server-config-url)
   (headers :initarg :headers :initform nil :reader mcp-server-config-headers
            :documentation "Alist (name . value), in the file's order.")
   (disabled :initarg :disabled :initform nil :reader mcp-server-config-disabled-p)
   (timeout :initarg :timeout :initform nil :reader mcp-server-config-timeout
            :documentation "Tool-call timeout in ms (\"timeout\"), or NIL.")
   (startup-timeout :initarg :startup-timeout :initform nil
                    :reader mcp-server-config-startup-timeout
                    :documentation "Startup timeout in ms (\"startupTimeout\"), or NIL.")
   (cache-tools :initarg :cache-tools :initform t :reader mcp-server-config-cache-tools)
   (tool-error-behavior :initarg :tool-error-behavior :initform :retry
                        :reader mcp-server-config-tool-error-behavior)
   (file :initarg :file :initform nil :accessor mcp-server-config-file
         :documentation "The file it came from (a pathname), or NIL (flags as JSON text, SDK)."))
  (:documentation "One MCP server as configured (before or after ${VAR} expansion)."))

(defmethod print-object ((c mcp-server-config) stream)
  (print-unreadable-object (c stream :type t)
    (format stream "~a ~(~a~) ~(~a~)" (mcp-server-config-name c)
            (mcp-server-config-transport c) (mcp-server-config-scope c))))

(defun make-mcp-server-config (name &rest initargs &key scope transport command args env url
                                                       headers disabled timeout startup-timeout
                                                       (cache-tools t) (tool-error-behavior :retry)
                                                       file)
  (declare (ignore scope transport command args env url headers disabled timeout startup-timeout
                   cache-tools tool-error-behavior file))
  (apply #'make-instance 'mcp-server-config :name name initargs))

(defun %copy-mcp-config (config &rest changes)
  "A copy of CONFIG with CHANGES (initargs) applied."
  (let ((copy (allocate-instance (class-of config))))
    (dolist (slot '(name scope transport command args env url headers disabled timeout
                    startup-timeout cache-tools tool-error-behavior file))
      (setf (slot-value copy slot) (slot-value config slot)))
    (loop for (key value) on changes by #'cddr
          do (setf (slot-value copy (find-symbol (symbol-name key) '#:cl-stack-code)) value))
    copy))

(defun %parse-mcp-settings (file object)
  "The MCP plist of the settings OBJECT (a hash table), or NIL when it sets
none of +MCP-SETTINGS-KEYS+. Called by PARSE-SETTINGS."
  (when (some (lambda (key) (nth-value 1 (%json-present object key))) +mcp-settings-keys+)
    (%parse-mcp-keys file object)))

(defun %mcp-layer (layer scope)
  "LAYER (a SETTINGS or NIL) with its servers tagged SCOPE; for :PROJECT and
:LOCAL also without the approving keys (:ENABLE-ALL-PROJECT :ENABLED)."
  (let ((plist (and layer (settings-mcp layer))))
    (if (null plist)
        layer
        (let ((copy (merge-settings layer))
              (plist (copy-list plist)))
          (setf (getf plist :servers)
                (mapcar (lambda (entry)
                          (cons (car entry) (%copy-mcp-config (cdr entry) :scope scope)))
                        (getf plist :servers)))
          (when (member scope '(:project :local))
            (remf plist :enable-all-project)
            (remf plist :enabled))
          (setf (slot-value copy 'mcp) plist)
          copy))))

(defun %merge-mcp (plists)
  "Merge the layers' MCP plists, lowest first: :SERVERS per name (a later
layer's server replaces an earlier one, in first-seen order), :ENABLED,
:DISABLED and :CONFIG-FILES concatenated, the scalars last-set."
  (let ((out '()) (servers '()) (seen nil))
    (dolist (plist plists)
      (when plist
        (setf seen t)
        (dolist (entry (getf plist :servers))
          (let ((mine (assoc (car entry) servers :test #'string=)))
            (if mine (setf (cdr mine) (cdr entry)) (push (cons (car entry) (cdr entry)) servers))))
        (dolist (key '(:enabled :disabled :config-files))
          (when (getf plist key)
            (setf (getf out key) (append (getf out key) (getf plist key)))))
        (dolist (key '(:enable-all-project :timeout :tool-timeout :strict))
          (multiple-value-bind (k v tail) (get-properties plist (list key))
            (declare (ignore k))
            (when tail (setf (getf out key) v))))))
    (when seen
      (when servers (setf (getf out :servers) (nreverse servers)))
      out)))

(defun %mcp-flags (config-files strict)
  "The flag layer's MCP plist from --mcp-config values and --strict-mcp-config."
  (append (when config-files (list :config-files (copy-list config-files)))
          (when strict (list :strict t))))

(defun mcp-settings (settings)
  "→ (values servers enable-all-project enabled disabled timeout tool-timeout
config-files strict) of SETTINGS's MCP plist (servers: alist name . config)."
  (let ((p (and settings (settings-mcp settings))))
    (values (getf p :servers) (getf p :enable-all-project) (getf p :enabled)
            (getf p :disabled) (getf p :timeout) (getf p :tool-timeout)
            (getf p :config-files) (getf p :strict))))

(defun mcp-server-trusted-p (config)
  "True for :USER, :FLAG and :SDK servers."
  (and (member (mcp-server-config-scope config) '(:user :flag :sdk)) t))


;;; Parsing (the header's rules).

(defun %mcp-server-key (name &optional sub)
  (format nil "mcpServers.~a~@[.~a~]" name sub))

(defun %url-sse-p (url)
  "True when URL's path (without query and fragment) ends in \"/sse\"."
  (let* ((end (or (position-if (lambda (c) (member c '(#\? #\#))) url) (length url)))
         (n (- end 4)))
    (and (>= n 0) (string= "/sse" url :start2 n :end2 end))))

(defun %mcp-string-array (file key value)
  "VALUE (a JSON array of strings) as a list; else SETTINGS-ERROR KEY / KEY[i]."
  (unless (%json-array-p value)
    (%settings-fail file key "must be an array of strings"))
  (loop for item across value
        for i from 0
        do (unless (stringp item)
             (%settings-fail file (format nil "~a[~d]" key i) "must be a string"))
        collect item))

(defun %mcp-string-object (file key value)
  "VALUE (a JSON object of strings) as an alist in its order; else SETTINGS-ERROR."
  (unless (hash-table-p value)
    (%settings-fail file key "must be an object of strings"))
  (loop for name being the hash-keys of value using (hash-value v)
        do (unless (stringp v)
             (%settings-fail file (format nil "~a.~a" key name) "must be a string"))
        collect (cons name v)))

(defun %mcp-ms-p (value)
  (and (integerp value) (>= value 1)))

(defun %mcp-boolean-p (value)
  (member value '(t nil)))

(defun %parse-mcp-server (name object file scope)
  "One mcpServers entry → an MCP-SERVER-CONFIG (see the header)."
  (when (zerop (length name))
    (%settings-fail file "mcpServers." "a server name must not be empty"))
  (let ((key (%mcp-server-key name)))
    (unless (hash-table-p object)
      (%settings-fail file key "must be an object"))
    (flet ((field (sub test what)
             (multiple-value-bind (value present) (%json-present object sub)
               (when (and present (not (funcall test value)))
                 (%settings-fail file (%mcp-server-key name sub) "must be ~a" what))
               (values value present))))
      (let* ((type (field "type" #'stringp "a string"))
             (command (field "command" #'stringp "a string"))
             (url (field "url" #'stringp "a string"))
             (args (multiple-value-bind (value present) (%json-present object "args")
                     (and present (%mcp-string-array file (%mcp-server-key name "args") value))))
             (env (multiple-value-bind (value present) (%json-present object "env")
                    (and present (%mcp-string-object file (%mcp-server-key name "env") value))))
             (headers (multiple-value-bind (value present) (%json-present object "headers")
                        (and present
                             (%mcp-string-object file (%mcp-server-key name "headers") value))))
             (disabled (field "disabled" #'%mcp-boolean-p "true or false"))
             (timeout (field "timeout" #'%mcp-ms-p "an integer >= 1 (ms)"))
             (startup (field "startupTimeout" #'%mcp-ms-p "an integer >= 1 (ms)"))
             (cache-tools (multiple-value-bind (value present)
                              (field "cacheTools" #'%mcp-boolean-p "true or false")
                            (if present value t)))
             (behavior (let ((text (field "toolErrorBehavior" #'stringp "a string")))
                         (if text
                             (or (find text ai-agent-protocol/mcp:+tool-error-behaviors+
                                       :key #'symbol-name :test #'string-equal)
                                 (%settings-fail file (%mcp-server-key name "toolErrorBehavior")
                                                 "must be one of ~{~(~a~)~^, ~}"
                                                 ai-agent-protocol/mcp:+tool-error-behaviors+))
                             :retry)))
             (transport
               (cond ((null type)
                      (cond (command :stdio)
                            (url (if (%url-sse-p url) :sse :http))
                            (t (%settings-fail file key "needs \"command\" or \"url\""))))
                     ((string= type "stdio") :stdio)
                     ((member type '("http" "streamable-http") :test #'string=) :http)
                     ((string= type "sse") :sse)
                     (t (%settings-fail file (%mcp-server-key name "type")
                                        "unknown type ~s (stdio, http, streamable-http or sse)"
                                        type)))))
        (when (and (eq transport :stdio) (null command))
          (%settings-fail file (%mcp-server-key name "command") "a stdio server needs a command"))
        (when (and (member transport '(:http :sse)) (null url))
          (%settings-fail file (%mcp-server-key name "url") "an ~(~a~) server needs a url" transport))
        (make-mcp-server-config name :scope scope :transport transport
                                     :command (and (eq transport :stdio) command)
                                     :args (and (eq transport :stdio) args)
                                     :env (and (eq transport :stdio) env)
                                     :url (and (not (eq transport :stdio)) url)
                                     :headers (and (not (eq transport :stdio)) headers)
                                     :disabled (and disabled t)
                                     :timeout timeout :startup-timeout startup
                                     :cache-tools (and cache-tools t)
                                     :tool-error-behavior behavior
                                     :file file)))))

(defun %parse-mcp-keys (file object)
  "The MCP plist of the settings OBJECT: only the keys present are set (the
merge looks at presence)."
  (let ((out '()))
    (flet ((scalar (key test what)
             (multiple-value-bind (value present) (%json-present object key)
               (when (and present (not (funcall test value)))
                 (%settings-fail file key "must be ~a" what))
               (values value present))))
      (multiple-value-bind (value present) (%json-present object "mcpServers")
        (when present
          (setf (getf out :servers)
                (mapcar (lambda (c) (cons (mcp-server-config-name c) c))
                        (parse-mcp-servers value :file file)))))
      (multiple-value-bind (value present)
          (scalar "enableAllProjectMcpServers" #'%mcp-boolean-p "true or false")
        (when present (setf (getf out :enable-all-project) (and value t))))
      (loop for (key indicator) in '(("enabledMcpjsonServers" :enabled)
                                     ("disabledMcpjsonServers" :disabled))
            do (multiple-value-bind (value present) (%json-present object key)
                 (when present
                   (setf (getf out indicator) (%mcp-string-array file key value)))))
      (loop for (key indicator) in '(("mcpTimeout" :timeout) ("mcpToolTimeout" :tool-timeout))
            do (multiple-value-bind (value present) (scalar key #'%mcp-ms-p "an integer >= 1 (ms)")
                 (when present (setf (getf out indicator) value)))))
    out))

(defun parse-mcp-servers (object &key file scope)
  "OBJECT: the decoded \"mcpServers\" value → list of MCP-SERVER-CONFIG (SCOPE,
FILE set), in the object's order; SETTINGS-ERROR as the header says."
  (unless (hash-table-p object)
    (%settings-fail file "mcpServers" "must be an object of servers"))
  (loop for name being the hash-keys of object using (hash-value value)
        collect (%parse-mcp-server name value file scope)))

(defun mcp-json-path (cwd)
  "<project root of CWD, else CWD>/.mcp.json."
  (let ((dir (uiop:ensure-directory-pathname cwd)))
    (merge-pathnames +mcp-json-file-name+
                     (uiop:ensure-directory-pathname (or (find-project-root dir) dir)))))

(defun %parse-mcp-json-text (text file scope)
  "The servers of TEXT, a .mcp.json-shaped JSON object (FILE for messages)."
  (let ((object (handler-case (json:decode text)
                  (error (e) (%settings-fail file nil "not valid JSON (~a)" e)))))
    (unless (hash-table-p object)
      (%settings-fail file nil "must be a JSON object with \"mcpServers\""))
    (multiple-value-bind (value present) (%json-present object "mcpServers")
      (and present (parse-mcp-servers value :file file :scope scope)))))

(defun read-mcp-json (pathname &key (scope :project))
  "→ the servers of the .mcp.json-shaped file PATHNAME, or NIL when it does
not exist. SETTINGS-ERROR (bad JSON, not an object, bad server) with restarts
CONTINUE (→ NIL) and USE-VALUE, as READ-SETTINGS-FILE."
  (let ((path (probe-file pathname)))
    (when (and path (pathname-name path))
      (restart-case
          (%parse-mcp-json-text
           (handler-case (uiop:read-file-string path :external-format :utf-8)
             (error (e) (%settings-fail path nil "cannot read the file (~a)" e)))
           path scope)
        (continue ()
          :report "Skip this MCP server file."
          nil)
        (use-value (servers)
          :report "Use these servers instead."
          servers)))))

;;; ${VAR} expansion.

(defun %expand-mcp-text (text env name file key)
  "TEXT with ${VAR} and ${VAR:-default} expanded through ENV."
  (if (not (search "${" text))
      text
      (with-output-to-string (out)
        (let ((i 0))
          (loop
            (let* ((start (search "${" text :start2 i))
                   (end (and start (position #\} text :start (+ start 2)))))
              (unless end
                (write-string text out :start i)
                (return))
              (write-string text out :start i :end start)
              (let* ((body (subseq text (+ start 2) end))
                     (sep (search ":-" body))
                     (var (if sep (subseq body 0 sep) body))
                     (value (funcall env var)))
                (cond (value (write-string value out))
                      (sep (write-string body out :start (+ sep 2)))
                      (t (%settings-fail file key "${~a} is not set (MCP server ~a)" var name))))
              (setf i (1+ end))))))))

(defun expand-mcp-variables (config env)
  "→ a copy of CONFIG with ${VAR} / ${VAR:-default} expanded through ENV (a
function name → value or NIL)."
  (let* ((name (mcp-server-config-name config))
         (file (mcp-server-config-file config)))
    (flet ((one (text sub)
             (and text (%expand-mcp-text text env name file (%mcp-server-key name sub))))
           (alist (entries sub)
             (loop for (k . v) in entries
                   collect (cons k (%expand-mcp-text v env name file
                                                     (%mcp-server-key name (format nil "~a.~a" sub k)))))))
      (%copy-mcp-config config
                        :command (one (mcp-server-config-command config) "command")
                        :args (loop for arg in (mcp-server-config-args config)
                                    for i from 0
                                    collect (one arg (format nil "args[~d]" i)))
                        :env (alist (mcp-server-config-env config) "env")
                        :url (one (mcp-server-config-url config) "url")
                        :headers (alist (mcp-server-config-headers config) "headers")))))

;;; The layers.

(defun %mcp-env-lookup (settings env)
  "The effective lookup: SETTINGS's env first, then ENV (else the process)."
  (let ((entries (and settings (settings-env settings)))
        (base (or env #'uiop:getenv)))
    (lambda (name)
      (let ((entry (assoc name entries :test #'string=)))
        (if entry (cdr entry) (funcall base name))))))

(defun %sdk-mcp-servers (servers)
  "SERVERS (MCP-SERVER-CONFIGs or a decoded mcpServers object) as configs, scope
:SDK unless set."
  (cond ((null servers) '())
        ((hash-table-p servers) (parse-mcp-servers servers :scope :sdk))
        (t (mapcar (lambda (config)
                     (if (mcp-server-config-scope config)
                         config
                         (%copy-mcp-config config :scope :sdk)))
                   servers))))

(defun %sdk-mcp-configs (servers env)
  "SERVERS as %SDK-MCP-SERVERS, expanded through ENV."
  (mapcar (lambda (config) (expand-mcp-variables config env)) (%sdk-mcp-servers servers)))

(defun %mcp-flag-servers (cwd value)
  "One --mcp-config VALUE: JSON text (first non-blank character \"{\") or a file."
  (let ((trimmed (string-left-trim '(#\Space #\Tab #\Newline #\Return) value)))
    (if (and (plusp (length trimmed)) (char= #\{ (char trimmed 0)))
        (%parse-mcp-json-text value nil :flag)
        (let ((path (and (plusp (length value))
                         (probe-file (uiop:merge-pathnames* (uiop:parse-native-namestring value)
                                                            (uiop:ensure-directory-pathname cwd))))))
          (unless (and path (pathname-name path))
            (error 'code-usage-error :message (format nil "--mcp-config: no such file ~a" value)))
          (read-mcp-json path :scope :flag)))))

(defun %mcp-file-layers (cwd merged user-config-dir)
  "The servers of user settings, .mcp.json, project settings and local
settings, one list each in that order (as the files hold them), then the
merged settings' servers none of the files has."
  (destructuring-bind (user project local)
      (settings-file-paths cwd :user-config-dir user-config-dir)
    (flet ((servers (path scope)
             (let ((layer (%mcp-layer (handler-case (read-settings-file path)
                                        (settings-error () nil))
                                      scope)))
               (mapcar #'cdr (getf (and layer (settings-mcp layer)) :servers)))))
      (let ((layers (list (servers user :user)
                          (read-mcp-json (mcp-json-path cwd) :scope :project)
                          (servers project :project)
                          (servers local :local))))
        (append layers
                (list (loop for (name . config) in merged
                            unless (some (lambda (layer)
                                           (find name layer :key #'mcp-server-config-name
                                                            :test #'string=))
                                         layers)
                              collect config)))))))

(defun effective-mcp-servers (cwd settings &key user-config-dir sdk-servers env)
  "→ the session's MCP-SERVER-CONFIGs, expanded, in first-seen order (see the
header). SETTINGS: the merged settings (LOAD-SETTINGS). SDK-SERVERS: configs or
a decoded mcpServers object (scope :sdk). ENV: the effective lookup. A missing
--mcp-config file → CODE-USAGE-ERROR \"--mcp-config: no such file X\"."
  (multiple-value-bind (merged all enabled disabled timeout tool-timeout config-files strict)
      (mcp-settings settings)
    (declare (ignore all enabled disabled timeout tool-timeout))
    (let ((layers (append (unless strict (%mcp-file-layers cwd merged user-config-dir))
                          (mapcar (lambda (value) (%mcp-flag-servers cwd value)) config-files)
                          (list (%sdk-mcp-servers sdk-servers))))
          (winners '())
          (lookup (%mcp-env-lookup settings env)))
      (dolist (layer layers)
        (dolist (config layer)
          (let ((cell (assoc (mcp-server-config-name config) winners :test #'string=)))
            (if cell
                (setf (cdr cell) config)
                (push (cons (mcp-server-config-name config) config) winners)))))
      (mapcar (lambda (cell) (expand-mcp-variables (cdr cell) lookup))
              (nreverse winners)))))

;;; Trust: the approval keys as permission-rule data (the rules-and-logic rule).

(defun %dir-key (dir)
  "DIR (a pathname or native namestring) as a native namestring with a trailing separator."
  (uiop:native-namestring
   (uiop:ensure-directory-pathname (if (stringp dir) (uiop:parse-native-namestring dir) dir))))

(defun %approval-rule (entry effect)
  "An enabledMcpjsonServers / disabledMcpjsonServers ENTRY (\"NAME\" or
\"NAME@<dir>\") as a rule: action the server name, resource the project directory."
  (let ((at (position #\@ entry)))
    (agent:make-permission-rule (if at (subseq entry 0 at) entry)
                                (if at (%dir-key (subseq entry (1+ at))) "*")
                                effect)))

(defun %approval-rules (settings)
  "No match asks (:UNAPPROVED); enableAllProjectMcpServers and enabled entries
allow; disabled entries deny, last, so they win."
  (multiple-value-bind (servers all enabled disabled) (mcp-settings settings)
    (declare (ignore servers))
    (append (list (agent:make-permission-rule "*" "*" :ask))
            (and all (list (agent:make-permission-rule "*" "*" :allow)))
            (mapcar (lambda (entry) (%approval-rule entry :allow)) enabled)
            (mapcar (lambda (entry) (%approval-rule entry :deny)) disabled))))

(defun mcp-server-approval (config settings &key project-dir)
  "→ :APPROVED, :REJECTED or :UNAPPROVED (trusted servers → :APPROVED)."
  (if (mcp-server-trusted-p config)
      :approved
      (ecase (agent:permission-rules-effect (%approval-rules settings)
                                            (mcp-server-config-name config)
                                            (list (%dir-key (or project-dir (uiop:getcwd)))))
        (:allow :approved)
        (:ask :unapproved)
        (:deny :rejected))))

(defun save-mcp-approval (name project-dir decision &key user-config-dir)
  "DECISION :YES → NAME@<project-dir> added to enabledMcpjsonServers of the
user settings file (and removed from disabledMcpjsonServers); :NO → the other
way round; :LATER → nothing. Other keys of the file are kept. → the file."
  (check-type decision (member :yes :no :later))
  (let ((file (merge-pathnames "settings.json"
                               (uiop:ensure-directory-pathname
                                (or user-config-dir (user-config-directory))))))
    (unless (eq decision :later)
      (let* ((entry (format nil "~a@~a" name (%dir-key project-dir)))
             (object (if (probe-file file)
                         (handler-case (json:decode (uiop:read-file-string file :external-format :utf-8))
                           (error (e) (%settings-fail file nil "not valid JSON (~a)" e)))
                         (make-hash-table :test 'equal)))
             (add (if (eq decision :yes) "enabledMcpjsonServers" "disabledMcpjsonServers"))
             (drop (if (eq decision :yes) "disabledMcpjsonServers" "enabledMcpjsonServers")))
        (unless (hash-table-p object)
          (%settings-fail file nil "settings must be a JSON object"))
        (flet ((without (key)
                 (let ((value (gethash key object)))
                   (remove entry (if (%json-array-p value) (coerce value 'list) '())
                           :test #'equal))))
          (setf (gethash add object) (coerce (append (without add) (list entry)) 'vector))
          (when (nth-value 1 (gethash drop object))
            (setf (gethash drop object) (coerce (without drop) 'vector))))
        (ensure-directories-exist file)
        (p:write-text file (json:encode object) :atomic t)))
    file))

;;; Timeouts.

(defun %env-ms (env name)
  "ENV's NAME as a positive integer (ms), or NIL."
  (let ((text (and env (funcall env name))))
    (and (stringp text) (plusp (length text)) (every #'digit-char-p text)
         (let ((ms (parse-integer text)))
           (and (plusp ms) ms)))))

(defun mcp-timeouts (config settings env)
  "→ (values startup-seconds tool-seconds) for CONFIG (see the header)."
  (multiple-value-bind (servers all enabled disabled timeout tool-timeout) (mcp-settings settings)
    (declare (ignore servers all enabled disabled))
    (let ((startup (or (mcp-server-config-startup-timeout config)
                       timeout
                       (%env-ms env "MCP_TIMEOUT")
                       +default-mcp-timeout-ms+))
          (tool (or (let ((ms (mcp-server-config-timeout config)))
                      (and ms (>= ms 1000) ms))
                    tool-timeout
                    (%env-ms env "MCP_TOOL_TIMEOUT")
                    +default-mcp-tool-timeout-ms+)))
      (values (/ startup 1000) (/ tool 1000)))))
