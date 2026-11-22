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

(defun %h3e2-pending (what)
  "H3e-2a contract stub. The implementation removes it and every call."
  (error 'code-error :message (format nil "not implemented yet (H3e-2a contract): ~a" what)))

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

;;; Stubbed (the header's rules).

(defun %parse-mcp-keys (file object)
  (declare (ignore file object))
  (%h3e2-pending "parse the MCP settings keys"))

(defun parse-mcp-servers (object &key file scope)
  "OBJECT: the decoded \"mcpServers\" value → list of MCP-SERVER-CONFIG (SCOPE,
FILE set), in the object's order; SETTINGS-ERROR as the header says."
  (declare (ignore object file scope))
  (%h3e2-pending "parse-mcp-servers"))

(defun mcp-json-path (cwd)
  "<project root of CWD, else CWD>/.mcp.json."
  (declare (ignore cwd))
  (%h3e2-pending "mcp-json-path"))

(defun read-mcp-json (pathname &key (scope :project))
  "→ the servers of the .mcp.json-shaped file PATHNAME, or NIL when it does
not exist. SETTINGS-ERROR (bad JSON, not an object, bad server) with restarts
CONTINUE (→ NIL) and USE-VALUE, as READ-SETTINGS-FILE."
  (declare (ignore pathname scope))
  (%h3e2-pending "read-mcp-json"))

(defun expand-mcp-variables (config env)
  "→ a copy of CONFIG with ${VAR} / ${VAR:-default} expanded through ENV (a
function name → value or NIL)."
  (declare (ignore config env))
  (%h3e2-pending "expand-mcp-variables"))

(defun effective-mcp-servers (cwd settings &key user-config-dir sdk-servers env)
  "→ the session's MCP-SERVER-CONFIGs, expanded, in first-seen order (see the
header). SETTINGS: the merged settings (LOAD-SETTINGS). SDK-SERVERS: configs or
a decoded mcpServers object (scope :sdk). ENV: the effective lookup. A missing
--mcp-config file → CODE-USAGE-ERROR \"--mcp-config: no such file X\"."
  (declare (ignore cwd settings user-config-dir sdk-servers env))
  (%h3e2-pending "effective-mcp-servers"))

(defun mcp-server-approval (config settings &key project-dir)
  "→ :APPROVED, :REJECTED or :UNAPPROVED (trusted servers → :APPROVED)."
  (declare (ignore config settings project-dir))
  (%h3e2-pending "mcp-server-approval"))

(defun save-mcp-approval (name project-dir decision &key user-config-dir)
  "DECISION :YES → NAME@<project-dir> added to enabledMcpjsonServers of the
user settings file (and removed from disabledMcpjsonServers); :NO → the other
way round; :LATER → nothing. Other keys of the file are kept. → the file."
  (declare (ignore name project-dir decision user-config-dir))
  (%h3e2-pending "save-mcp-approval"))

(defun mcp-timeouts (config settings env)
  "→ (values startup-seconds tool-seconds) for CONFIG (see the header)."
  (declare (ignore config settings env))
  (%h3e2-pending "mcp-timeouts"))
