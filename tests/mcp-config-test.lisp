(in-package #:cl-stack-code/tests)

;;; H3e-2a: configuration, ${VAR} expansion, layers, trust, timeouts, names,
;;; views and the core's /mcp (src/mcp-config.lisp, src/mcp.lisp). No server
;;; runs here.

(defun %servers-of (json &key file (scope :project))
  (parse-mcp-servers (jget (json:decode json) "mcpServers") :file file :scope scope))

(defun %one (json)
  (first (%servers-of json)))

(deftest mcp-constants
  (ok (= 30000 +default-mcp-timeout-ms+))
  (ok (= 600000 +default-mcp-tool-timeout-ms+))
  (ok (equal ".mcp.json" +mcp-json-file-name+))
  (ok (equal "mcp__" +mcp-tool-prefix+))
  (ok (eq :mcp-server +mcp-unit-kind+))
  (ok (equal '(:yes :no :later) (mapcar #'first +mcp-approval-choices+)))
  (ok (has "/mcp" +help-text+)))

(deftest-parametrize mcp-parse-transport
    ((json transport)
     ("{\"mcpServers\":{\"x\":{\"command\":\"srv\"}}}" :stdio)
     ("{\"mcpServers\":{\"x\":{\"type\":\"stdio\",\"command\":\"srv\"}}}" :stdio)
     ("{\"mcpServers\":{\"x\":{\"type\":\"http\",\"url\":\"https://h/mcp\"}}}" :http)
     ("{\"mcpServers\":{\"x\":{\"type\":\"streamable-http\",\"url\":\"https://h/mcp\"}}}" :http)
     ("{\"mcpServers\":{\"x\":{\"type\":\"sse\",\"url\":\"https://h/events\"}}}" :sse)
     ("{\"mcpServers\":{\"x\":{\"url\":\"https://h/mcp\"}}}" :http)
     ("{\"mcpServers\":{\"x\":{\"url\":\"https://h/sse\"}}}" :sse)
     ("{\"mcpServers\":{\"x\":{\"url\":\"https://h/sse?k=1\"}}}" :sse)
     ("{\"mcpServers\":{\"x\":{\"command\":\"srv\",\"url\":\"https://h/mcp\"}}}" :stdio))
  (ok (eq transport (mcp-server-config-transport (%one json)))))

(deftest mcp-parse-stdio-fields
  (let ((c (%one "{\"mcpServers\":{\"lisp\":{\"command\":\"ros\",\"args\":[\"run\",\"-e\"],\"env\":{\"A\":\"1\",\"B\":\"2\"},\"disabled\":false,\"startupTimeout\":1500,\"timeout\":9000,\"cacheTools\":false,\"toolErrorBehavior\":\"failed\",\"futureKey\":{\"x\":1}}}}")))
    (ok (equal "lisp" (mcp-server-config-name c)))
    (ok (eq :project (mcp-server-config-scope c)))
    (ok (equal "ros" (mcp-server-config-command c)))
    (ok (equal '("run" "-e") (mcp-server-config-args c)))
    (ok (equal '(("A" . "1") ("B" . "2")) (mcp-server-config-env c)))
    (ok (not (mcp-server-config-disabled-p c)))
    (ok (= 1500 (mcp-server-config-startup-timeout c)))
    (ok (= 9000 (mcp-server-config-timeout c)))
    (ok (null (mcp-server-config-cache-tools c)))
    (ok (eq :failed (mcp-server-config-tool-error-behavior c)))))

(deftest mcp-parse-http-fields-and-defaults
  (let ((c (%one "{\"mcpServers\":{\"web\":{\"type\":\"http\",\"url\":\"https://h/mcp\",\"headers\":{\"Authorization\":\"Bearer t\"}}}}")))
    (ok (equal "https://h/mcp" (mcp-server-config-url c)))
    (ok (equal '(("Authorization" . "Bearer t")) (mcp-server-config-headers c)))
    (ok (null (mcp-server-config-command c)))
    (ok (null (mcp-server-config-timeout c)))
    (ok (null (mcp-server-config-startup-timeout c)))
    (ok (eq t (mcp-server-config-cache-tools c)))
    (ok (eq :retry (mcp-server-config-tool-error-behavior c)))))

(deftest mcp-parse-order-and-disabled
  (let ((cs (%servers-of "{\"mcpServers\":{\"b\":{\"command\":\"x\"},\"a\":{\"command\":\"y\",\"disabled\":true}}}")))
    (ok (equal '("b" "a") (mapcar #'mcp-server-config-name cs)))
    (ok (mcp-server-config-disabled-p (second cs)))))

(deftest-parametrize mcp-parse-errors
    ((json key)
     ("{\"mcpServers\":[1]}" "mcpServers")
     ("{\"mcpServers\":{\"x\":3}}" "mcpServers.x")
     ("{\"mcpServers\":{\"x\":{}}}" "mcpServers.x")
     ("{\"mcpServers\":{\"x\":{\"command\":5}}}" "mcpServers.x.command")
     ("{\"mcpServers\":{\"x\":{\"command\":\"s\",\"args\":\"a b\"}}}" "mcpServers.x.args")
     ("{\"mcpServers\":{\"x\":{\"command\":\"s\",\"args\":[\"a\",2]}}}" "mcpServers.x.args[1]")
     ("{\"mcpServers\":{\"x\":{\"command\":\"s\",\"env\":{\"K\":1}}}}" "mcpServers.x.env.K")
     ("{\"mcpServers\":{\"x\":{\"url\":\"u\",\"headers\":{\"H\":true}}}}" "mcpServers.x.headers.H")
     ("{\"mcpServers\":{\"x\":{\"type\":\"websocket\",\"url\":\"u\"}}}" "mcpServers.x.type")
     ("{\"mcpServers\":{\"x\":{\"type\":\"http\",\"command\":\"s\"}}}" "mcpServers.x.url")
     ("{\"mcpServers\":{\"x\":{\"command\":\"s\",\"timeout\":0}}}" "mcpServers.x.timeout")
     ("{\"mcpServers\":{\"x\":{\"command\":\"s\",\"startupTimeout\":\"9\"}}}" "mcpServers.x.startupTimeout")
     ("{\"mcpServers\":{\"x\":{\"command\":\"s\",\"disabled\":\"no\"}}}" "mcpServers.x.disabled")
     ("{\"mcpServers\":{\"x\":{\"command\":\"s\",\"toolErrorBehavior\":\"explode\"}}}" "mcpServers.x.toolErrorBehavior")
     ("{\"mcpServers\":{\"\":{\"command\":\"s\"}}}" "mcpServers.")
     ("{\"enabledMcpjsonServers\":\"x\"}" "enabledMcpjsonServers")
     ("{\"enabledMcpjsonServers\":[1]}" "enabledMcpjsonServers[0]")
     ("{\"enableAllProjectMcpServers\":1}" "enableAllProjectMcpServers")
     ("{\"mcpTimeout\":-1}" "mcpTimeout"))
  (handler-case (progn (parse-settings json :file #p"/tmp/settings.json")
                       (ok nil "must signal settings-error"))
    (settings-error (e)
      (ok (equal key (settings-error-key e)))
      (ok (equal #p"/tmp/settings.json" (settings-error-file e))))))

(deftest mcp-settings-keys
  (let ((s (parse-settings "{\"mcpServers\":{\"u\":{\"command\":\"c\"}},\"enableAllProjectMcpServers\":true,\"enabledMcpjsonServers\":[\"a\",\"b@/p\"],\"disabledMcpjsonServers\":[\"z\"],\"mcpTimeout\":1000,\"mcpToolTimeout\":2000}")))
    (multiple-value-bind (servers all enabled disabled timeout tool-timeout) (mcp-settings s)
      (ok (equal '("u") (mapcar #'car servers)))
      (ok (eq t all))
      (ok (equal '("a" "b@/p") enabled))
      (ok (equal '("z") disabled))
      (ok (= 1000 timeout))
      (ok (= 2000 tool-timeout))))
  (ok (null (settings-mcp (parse-settings "{\"model\":\"m\"}")))))

(deftest mcp-read-mcp-json
  (with-project (project config) '()
    (ok (null (read-mcp-json (merge-pathnames ".mcp.json" project))))
    (write-file project ".mcp.json" "{\"mcpServers\":{\"lisp\":{\"command\":\"lisp-mcp\"}}}")
    (ok (same-path (merge-pathnames ".mcp.json" project) (mcp-json-path project)))
    (let ((cs (read-mcp-json (mcp-json-path project))))
      (ok (equal '("lisp") (mapcar #'mcp-server-config-name cs)))
      (ok (eq :project (mcp-server-config-scope (first cs))))
      (ok (same-path (merge-pathnames ".mcp.json" project) (mcp-server-config-file (first cs)))))
    (write-file project ".mcp.json" "{\"mcpServers\":")
    (ok (signals (read-mcp-json (mcp-json-path project)) 'settings-error))
    (ok (null (handler-bind ((settings-error (lambda (e) (declare (ignore e)) (invoke-restart 'continue))))
                (read-mcp-json (mcp-json-path project)))))))

(deftest mcp-json-path-uses-the-project-root
  (with-project (project config) '(("sub/a.txt" . "x"))
    (ok (same-path (merge-pathnames ".mcp.json" project)
                   (mcp-json-path (subdir project "sub/"))))))

;;; ${VAR} expansion

(deftest-parametrize mcp-expand
    ((text expected)
     ("plain" "plain")
     ("${TOKEN}" "s3cret")
     ("Bearer ${TOKEN}" "Bearer s3cret")
     ("${TOKEN}-${TOKEN}" "s3cret-s3cret")
     ("${MISSING:-fallback}" "fallback")
     ("${EMPTY:-fallback}" "")
     ("${TOKEN:-fallback}" "s3cret")
     ("cost $5" "cost $5")
     ("${unterminated" "${unterminated"))
  (let* ((c (make-mcp-server-config "x" :scope :user :transport :stdio :command text
                                        :args (list text) :env (list (cons "K" text))))
         (e (expand-mcp-variables c (env-lookup "TOKEN" "s3cret" "EMPTY" ""))))
    (ok (equal expected (mcp-server-config-command e)))
    (ok (equal (list expected) (mcp-server-config-args e)))
    (ok (equal expected (cdr (first (mcp-server-config-env e)))))
    (ok (equal text (mcp-server-config-command c)) "the original is unchanged")))

(deftest mcp-expand-url-and-headers
  (let ((e (expand-mcp-variables
            (make-mcp-server-config "web" :scope :user :transport :http
                                          :url "https://${HOST}/mcp"
                                          :headers '(("Authorization" . "Bearer ${TOKEN}")))
            (env-lookup "HOST" "h.example" "TOKEN" "t"))))
    (ok (equal "https://h.example/mcp" (mcp-server-config-url e)))
    (ok (equal "Bearer t" (cdr (first (mcp-server-config-headers e)))))))

(deftest mcp-expand-unset-is-an-error
  (let ((c (make-mcp-server-config "srv" :scope :project :transport :stdio :command "x"
                                         :args '("ok" "${NOPE}") :file #p"/p/.mcp.json")))
    (handler-case (progn (expand-mcp-variables c (env-lookup)) (ok nil "must signal"))
      (settings-error (e)
        (ok (equal "mcpServers.srv.args[1]" (settings-error-key e)))
        (ok (equal #p"/p/.mcp.json" (settings-error-file e)))
        (ok (has "${NOPE} is not set (MCP server srv)" (princ-to-string e)))))))

;;; Layers and precedence

(defun %effective (project config &key cli sdk getenv)
  (let ((settings (load-settings project :user-config-dir config :cli cli)))
    (effective-mcp-servers project settings :user-config-dir config :sdk-servers sdk
                                            :env (or getenv (env-lookup)))))

(defun %names-scopes (configs)
  (mapcar (lambda (c) (list (mcp-server-config-name c) (mcp-server-config-scope c))) configs))

(deftest mcp-layers-last-source-wins
  (with-project (project config) '()
    (write-user-settings config "mcpServers" (args "a" (args "command" "user-a")
                                                   "b" (args "command" "user-b")))
    (write-mcp-json project "b" (args "command" "json-b") "c" (args "command" "json-c"))
    (write-file project ".cl-stack-code/settings.json"
                (json-args "mcpServers" (args "c" (args "command" "proj-c") "d" (args "command" "proj-d"))))
    (write-file project ".cl-stack-code/settings.local.json"
                (json-args "mcpServers" (args "d" (args "command" "local-d"))))
    (let ((cs (%effective project config)))
      (ok (equal '(("a" :user) ("b" :project) ("c" :project) ("d" :local)) (%names-scopes cs)))
      (ok (equal '("user-a" "json-b" "proj-c" "local-d") (mapcar #'mcp-server-config-command cs))))))

(deftest mcp-flags-and-sdk
  (with-project (project config) '()
    (write-user-settings config "mcpServers" (args "a" (args "command" "user-a")))
    (write-file project "extra.json" (mcp-servers-json "a" (args "command" "file-a")))
    (let* ((inv (parse-arguments (list "-p" "x"
                                       "--mcp-config" (native (merge-pathnames "extra.json" project))
                                       "--mcp-config" "{\"mcpServers\":{\"t\":{\"url\":\"https://h/mcp\"}}}")))
           (cs (%effective project config :cli (invocation-settings inv)
                                         :sdk (jget (json:decode (mcp-servers-json "s" (args "command" "sdk-s")))
                                                    "mcpServers"))))
      (ok (= 2 (length (invocation-mcp-config inv))))
      (ok (not (invocation-strict-mcp-config-p inv)))
      (ok (equal '(("a" :flag) ("t" :flag) ("s" :sdk)) (%names-scopes cs)))
      (ok (equal "file-a" (mcp-server-config-command (first cs)))))))

(deftest mcp-strict-config
  (with-project (project config) '()
    (write-user-settings config "mcpServers" (args "a" (args "command" "user-a")))
    (write-mcp-json project "b" (args "command" "json-b"))
    (let* ((inv (parse-arguments (list "-p" "x" "--strict-mcp-config"
                                       "--mcp-config" "{\"mcpServers\":{\"t\":{\"command\":\"tt\"}}}")))
           (cs (%effective project config :cli (invocation-settings inv))))
      (ok (invocation-strict-mcp-config-p inv))
      (ok (equal '(("t" :flag)) (%names-scopes cs))))))

(deftest mcp-missing-config-file
  (with-project (project config) '()
    (let ((inv (parse-arguments (list "-p" "x" "--mcp-config" (native (merge-pathnames "nope.json" project))))))
      (ok (signals (%effective project config :cli (invocation-settings inv)) 'code-usage-error)))))

(deftest mcp-settings-env-feeds-expansion
  (with-project (project config) '()
    (write-user-settings config "env" (args "TOKEN" "from-settings")
                                "mcpServers" (args "a" (args "command" "x" "args" (vector "${TOKEN}"))))
    (let ((cs (%effective project config)))
      (ok (equal '("from-settings") (mcp-server-config-args (first cs)))))))

(deftest mcp-no-servers
  (with-project (project config) '()
    (ok (null (%effective project config)))))

;;; Trust

(defun %approval (scope user-json &key project-json (project-dir #p"/work/p/"))
  (with-project (project config) '()
    (when user-json (write-file config "settings.json" user-json))
    (when project-json (write-file project ".cl-stack-code/settings.json" project-json))
    (let ((settings (load-settings project :user-config-dir config)))
      (mcp-server-approval (make-mcp-server-config "srv" :scope scope :transport :stdio :command "x")
                           settings :project-dir project-dir))))

(deftest-parametrize mcp-trust
    ((scope user-json project-json expected)
     (:user nil nil :approved)
     (:flag nil nil :approved)
     (:sdk nil nil :approved)
     (:project nil nil :unapproved)
     (:local nil nil :unapproved)
     (:project "{\"enableAllProjectMcpServers\":true}" nil :approved)
     (:local "{\"enableAllProjectMcpServers\":true}" nil :approved)
     (:project "{\"enabledMcpjsonServers\":[\"srv\"]}" nil :approved)
     (:project "{\"enabledMcpjsonServers\":[\"srv@/work/p/\"]}" nil :approved)
     (:project "{\"enabledMcpjsonServers\":[\"srv@/work/p\"]}" nil :approved)
     (:project "{\"enabledMcpjsonServers\":[\"srv@/other/\"]}" nil :unapproved)
     (:project "{\"enabledMcpjsonServers\":[\"other\"]}" nil :unapproved)
     (:project "{\"enableAllProjectMcpServers\":true,\"disabledMcpjsonServers\":[\"srv\"]}" nil :rejected)
     (:project "{\"enabledMcpjsonServers\":[\"srv\"],\"disabledMcpjsonServers\":[\"srv@/work/p/\"]}" nil :rejected)
     (:project nil "{\"enableAllProjectMcpServers\":true}" :unapproved)
     (:project nil "{\"enabledMcpjsonServers\":[\"srv\"]}" :unapproved)
     (:project "{\"enableAllProjectMcpServers\":true}" "{\"disabledMcpjsonServers\":[\"srv\"]}" :rejected)
     (:user "{\"disabledMcpjsonServers\":[\"srv\"]}" nil :approved))
  (ok (eq expected (%approval scope user-json :project-json project-json))))

(deftest mcp-trusted-p
  (dolist (scope '(:user :flag :sdk))
    (ok (mcp-server-trusted-p (make-mcp-server-config "s" :scope scope :transport :stdio :command "x"))))
  (dolist (scope '(:project :local))
    (ok (not (mcp-server-trusted-p (make-mcp-server-config "s" :scope scope :transport :stdio :command "x"))))))

(deftest mcp-save-approval
  (with-project (project config) '()
    (write-user-settings config "model" "keep-me")
    (let ((dir (native project)))
      (save-mcp-approval "srv" project :yes :user-config-dir config)
      (let ((s (json:decode (read-file config "settings.json"))))
        (ok (equal "keep-me" (jget s "model")))
        (ok (equal (list (format nil "srv@~a" dir)) (coerce (jget s "enabledMcpjsonServers") 'list))))
      (ok (eq :approved (mcp-server-approval
                         (make-mcp-server-config "srv" :scope :project :transport :stdio :command "x")
                         (load-settings project :user-config-dir config) :project-dir project)))
      (save-mcp-approval "srv" project :no :user-config-dir config)
      (let ((s (json:decode (read-file config "settings.json"))))
        (ok (zerop (length (jget s "enabledMcpjsonServers"))))
        (ok (equal (list (format nil "srv@~a" dir)) (coerce (jget s "disabledMcpjsonServers") 'list))))
      (let ((before (read-file config "settings.json")))
        (save-mcp-approval "srv" project :later :user-config-dir config)
        (ok (equal before (read-file config "settings.json")))))))

(deftest mcp-save-approval-creates-the-file
  (with-project (project config) '()
    (save-mcp-approval "srv" project :yes :user-config-dir config)
    (ok (probe-file (merge-pathnames "settings.json" config)))))

;;; Timeouts

(deftest-parametrize mcp-timeout-precedence
    ((server-ms settings-json env expected-startup expected-tool)
     (nil nil nil 30 600)
     ('(1500 9000) nil nil 1.5 9)
     ('(1500 500) nil nil 1.5 600)
     (nil "{\"mcpTimeout\":2000,\"mcpToolTimeout\":4000}" nil 2 4)
     (nil nil '("MCP_TIMEOUT" "5000" "MCP_TOOL_TIMEOUT" "7000") 5 7)
     (nil "{\"mcpTimeout\":2000}" '("MCP_TIMEOUT" "5000") 2 600)
     ('(1000 nil) nil '("MCP_TIMEOUT" "5000") 1 600)
     (nil nil '("MCP_TIMEOUT" "soon") 30 600))
  (let ((c (make-mcp-server-config "s" :scope :user :transport :stdio :command "x"
                                       :startup-timeout (first server-ms) :timeout (second server-ms)))
        (s (if settings-json (parse-settings settings-json) (make-settings))))
    (multiple-value-bind (startup tool) (mcp-timeouts c s (apply #'env-lookup env))
      (ok (= expected-startup startup))
      (ok (= expected-tool tool)))))

;;; Names, views, notices

(deftest-parametrize mcp-tool-names
    ((server tool expected)
     ("lisp" "repl-eval" "mcp__lisp__repl-eval")
     ("fake" "echo" "mcp__fake__echo")
     ("my.server" "do it" "mcp__my_server__do_it")
     ("café" "x/y" "mcp__caf___x_y"))
  (ok (equal expected (mcp-tool-name server tool))))

(defun %conn (name status &key (scope :user) (transport :stdio) error file)
  (let ((c (make-instance 'mcp-connection
                          :config (make-mcp-server-config name :scope scope :transport transport
                                                               :command "srv" :args '("--x" "y")
                                                               :url "https://h/mcp" :file file)
                          :status status)))
    (setf (mcp-connection-error c) error)
    c))

(deftest mcp-connection-objects
  (let ((o (mcp-connection-object (%conn "lisp" :failed :error "boom" :file #p"/p/.mcp.json" :scope :project))))
    (ok (equal '("error" "file" "name" "scope" "status" "tools" "transport" "unit") (jkeys o)))
    (ok (equal "lisp" (jget o "name")))
    (ok (equal "project" (jget o "scope")))
    (ok (equal "stdio" (jget o "transport")))
    (ok (equal "failed" (jget o "status")))
    (ok (equal "boom" (jget o "error")))
    (ok (zerop (length (jget o "tools"))))
    (ok (eq :null (jget o "unit"))))
  (dolist (status +mcp-statuses+)
    (ok (equal (string-downcase (string status))
               (jget (mcp-connection-object (%conn "s" status)) "status")))))

(deftest-parametrize mcp-notices
    ((status scope error needle)
     (:unapproved :project nil "cl-stack-code: MCP server srv (~a) is not approved; skipped")
     (:failed :user "spawn failed" "cl-stack-code: MCP server srv failed: spawn failed")
     (:unsupported :user "transport sse is not supported yet" "cl-stack-code: MCP server srv: transport sse is not supported yet")
     (:rejected :project nil "cl-stack-code: MCP server srv is disabled by disabledMcpjsonServers"))
  (ok (has (format nil needle (native #p"/p/.mcp.json")) (mcp-status-notice (%conn "srv" status :scope scope :error error :file #p"/p/.mcp.json")))))

(deftest mcp-no-notice-when-fine
  (ok (null (mcp-status-notice (%conn "srv" :connected))))
  (ok (null (mcp-status-notice (%conn "srv" :disabled)))))

(defun %status-object (name status &key (scope "user") (transport "stdio") tools error)
  (args "name" name "scope" scope "transport" transport "status" status
        "tools" (coerce tools 'vector) "error" (or error :null) "unit" :null "file" :null))

(deftest mcp-status-lines-text
  (ok (equal '("no MCP servers configured") (mcp-status-lines '())))
  (ok (equal (list "MCP servers:"
                   "  fake (user, stdio): connected · 2 tools"
                   "    mcp__fake__echo, mcp__fake__fail"
                   "  one (user, http): connected · 1 tool"
                   "    mcp__one__x"
                   "  proj (project, stdio): needs approval"
                   "  bad (user, stdio): failed: exit code 3"
                   "  old (user, sse): unsupported: transport sse is not supported yet"
                   "  off (local, stdio): disabled"
                   "  no (project, stdio): rejected")
             (mcp-status-lines
              (list (%status-object "fake" "connected" :tools '("mcp__fake__echo" "mcp__fake__fail"))
                    (%status-object "one" "connected" :transport "http" :tools '("mcp__one__x"))
                    (%status-object "proj" "unapproved" :scope "project")
                    (%status-object "bad" "failed" :error "exit code 3")
                    (%status-object "old" "unsupported" :transport "sse"
                                                         :error "transport sse is not supported yet")
                    (%status-object "off" "disabled" :scope "local")
                    (%status-object "no" "rejected" :scope "project"))))))

(deftest mcp-approval-messages
  (ok (equal (format nil "MCP server srv from ~a wants to run: srv --x y" (native #p"/p/.mcp.json"))
             (mcp-approval-message (%conn "srv" :unapproved :scope :project :file #p"/p/.mcp.json"))))
  (ok (equal (format nil "MCP server web from ~a wants to connect to https://h/mcp" (native #p"/p/.mcp.json"))
             (mcp-approval-message (%conn "web" :unapproved :scope :project :transport :http
                                                            :file #p"/p/.mcp.json")))))

;;; The core

(deftest mcp-core-command
  (let ((s (fresh-state)))
    (feed s '(:submit "/mcp"))
    (ok (equal "no MCP servers configured" (entry-text (last-entry s))))
    (feed s (list :mcp-status (list (%status-object "fake" "connected" :tools '("mcp__fake__echo")))))
    (ok (= 1 (length (state-mcp s))))
    (feed s '(:submit "/mcp"))
    (ok (has "fake (user, stdio): connected · 1 tool" (entry-text (last-entry s))))
    (ok (equal '((:mcp-reconnect "fake")) (effects s '(:submit "/mcp reconnect fake"))))
    (ok (equal "reconnecting fake" (entry-text (last-entry s))))
    (ok (equal '((:mcp-reconnect nil)) (effects s '(:submit "/mcp reconnect"))))
    (ok (equal "reconnecting MCP servers" (entry-text (last-entry s))))
    (ok (null (effects s '(:submit "/mcp frobnicate"))))
    (ok (eq :error (entry-kind (last-entry s))))
    (ok (equal "usage: /mcp [reconnect [NAME]]" (entry-text (last-entry s))))))

(deftest mcp-core-command-while-busy
  (let ((s (busy-state)))
    (ok (equal '((:mcp-reconnect nil)) (effects s '(:submit "/mcp reconnect"))))
    (ok (null (state-queue s)) "not queued")))

(deftest mcp-core-approval
  (let ((s (fresh-state)))
    (ok (null (effects s '(:mcp-approval "proj" "MCP server proj from f wants to run: x"))))
    (ok (null (effects s '(:mcp-approval "two" "MCP server two from f wants to run: y"))))
    (ok (equal '("proj" "two") (mapcar #'car (state-mcp-prompt s))))
    (ok (equal '((:mcp-approve "proj" :yes)) (effects s '(:mcp-reply :yes))))
    (ok (equal '(("two" . "MCP server two from f wants to run: y")) (state-mcp-prompt s)))
    (ok (equal '((:mcp-approve "two" :later)) (effects s '(:mcp-reply :later))))
    (ok (null (state-mcp-prompt s)))
    (ok (null (effects s '(:mcp-reply :no))) "nothing to answer")))
