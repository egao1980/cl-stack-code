(in-package #:cl-stack-code/tests)

;;; H3e-2a: the SDK and --rpc. Stdio servers are supervised units; the init
;;; event lists the servers; CLIENT-NEW-SESSION :MCP-SERVERS (the ACP-2 entry);
;;; mcp/list and mcp/reconnect.

(defun %mcp-unit (session)
  (find "mcp-server" (client-units session) :key (lambda (u) (jget u "kind")) :test #'equal))

(defun %unit-log-texts (session unit-id)
  (map 'list (lambda (r) (jget r "text"))
       (jget (client-read-unit session :unit unit-id) "records")))

(deftest mcp-client-init-and-unit
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers" (args "fake" (fake-stdio-server base)))
    (with-test-client (client backend events project config :steps '("done"))
      (let* ((s (client-new-session client))
             (servers (event-value (code-session-init s) "mcp_servers"))
             (fake (server-object servers "fake"))
             (unit (%mcp-unit s)))
        (ok (equal "connected" (jget fake "status")))
        (ok (same-set (mcp-names "fake") (coerce (jget fake "tools") 'list)))
        (ok unit "the stdio server is a unit of the session's supervisor")
        (ok (equal (jget unit "id") (jget fake "unit")))
        (ok (equal "running" (jget unit "status")))
        (ok (equal "fake" (jget unit "labels" "server")))
        (ok (equal "mcp" (jget unit "owner")))
        (ok (wait-until (lambda () (member "fake-mcp: started" (%unit-log-texts s (jget unit "id"))
                                           :test #'equal))
                        :timeout 10)
            "the child's stderr is in the unit log")
        (ok (same-set (mcp-names "fake")
                      (remove-if-not (lambda (n) (uiop:string-prefix-p "mcp__" n))
                                     (coerce (event-value (code-session-init s) "tools") 'list))))))))

(deftest mcp-client-server-log-in-unit-log
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers" (args "fake" (fake-stdio-server base)))
    (with-test-client (client backend events project config
                              :steps (list (list :tool "mcp__fake__log" "{}") "done")
                              :settings (make-settings :allow (list (parse-permission-rule "mcp__fake__log" :allow))))
      (let* ((s (client-new-session client))
             (unit (%mcp-unit s)))
        (client-query s "log something" :timeout 60)
        (ok (wait-until (lambda () (member "[mcp info] hello from fake" (%unit-log-texts s (jget unit "id"))
                                           :test #'equal))
                        :timeout 10))))))

(deftest mcp-client-close-reaps-the-unit
  (with-project (project config :base base) '()
    (let ((pid-file (subdir base "fake.pid")))
      (write-user-settings config "mcpServers" (args "fake" (fake-stdio-server base :pid-file pid-file)))
      (with-test-client (client backend events project config :steps '("done"))
        (let* ((s (client-new-session client))
               (sup (code-session-supervisor s)))
          (ok (sup:find-units sup :kind :mcp-server))
          (let ((pid (wait-until (lambda () (read-pid pid-file)) :timeout 10)))
            (ok pid)
            (client-close-session s)
            (ok (wait-until (lambda () (not (process-alive-p pid))) :timeout 10))
            (ok (every (lambda (u) (member (sup:unit-state u) '(:exited :failed :killed)))
                       (sup:find-units sup :kind :mcp-server)))))))))

(deftest mcp-client-sdk-servers
  (with-project (project config :base base) '()
    (with-test-client (client backend events project config
                              :steps (list (list :tool "mcp__ed__echo" (json-args "msg" "from the editor"))
                                           "done"))
      (let* ((servers (jget (json:decode (mcp-servers-json "ed" (fake-stdio-server base))) "mcpServers"))
             (s (client-new-session client :mcp-servers servers))
             (ed (server-object (event-value (code-session-init s) "mcp_servers") "ed")))
        (ok (equal "sdk" (jget ed "scope")))
        (ok (equal "connected" (jget ed "status")))
        (client-query s "echo" :timeout 60)
        (ok (equal "from the editor"
                   (event-value (first (events-of events "tool_result")) "content"))
            "an SDK server is trusted: its read-only tool runs")))))

(deftest mcp-client-add-servers-mid-session
  (with-project (project config :base base) '()
    (with-test-client (client backend events project config :steps '("one" "two"))
      (let ((s (client-new-session client)))
        (client-query s "first" :timeout 60)
        (ok (null (client-mcp-servers s)))
        (client-add-mcp-servers s (jget (json:decode (mcp-servers-json "late" (fake-stdio-server base)))
                                        "mcpServers"))
        (ok (equal "connected" (jget (server-object (client-mcp-servers s) "late") "status")))
        (client-query s "second" :timeout 60)
        (ok (subsetp (mcp-names "late") (request-tool-names (second (scripted-requests backend)))
                     :test #'equal)
            "the next turn offers the new tools")))))

(deftest mcp-client-reconnect
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers"
                         (args "fake" (fake-stdio-server base)
                               "crashy" (fake-stdio-server base :mode "crash")))
    (with-test-client (client backend events project config :steps '("done"))
      (let* ((s (client-new-session client))
             (sup (code-session-supervisor s)))
        (ok (equal "failed" (jget (server-object (client-mcp-servers s) "crashy") "status")))
        (let ((units-before (length (sup:find-units sup :kind :mcp-server))))
          (let ((after (client-reconnect-mcp s "crashy")))
            (ok (equal "failed" (jget (server-object after "crashy") "status")))
            (ok (equal "connected" (jget (server-object after "fake") "status")) "fake untouched"))
          (ok (= (1+ units-before) (length (sup:find-units sup :kind :mcp-server)))
              "a reconnect starts a new unit"))
        (ok (signals (client-reconnect-mcp s "nope") 'mcp-server-not-found))))))

;;; --rpc

(deftest mcp-rpc-list-and-reconnect
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers" (args "fake" (fake-stdio-server base)))
    (with-rpc (rpc backend project config :steps '("done"))
      (let ((init (call rpc "initialize")))
        (ok (find "mcp/list" (jget init "methods") :test #'equal))
        (ok (find "mcp/reconnect" (jget init "methods") :test #'equal)))
      (let* ((id (new-session rpc))
             (list (call rpc "mcp/list" "session_id" id)))
        (ok (equal "connected" (jget (server-object (jget list "servers") "fake") "status")))
        (let ((again (call rpc "mcp/reconnect" "session_id" id "server" "fake")))
          (ok (equal "connected" (jget (server-object (jget again "servers") "fake") "status"))))
        (multiple-value-bind (code data) (fault rpc "mcp/reconnect" "session_id" id "server" "nope")
          (ok (eql -32020 code))
          (ok (equal "nope" (jget data "server"))))))))

(deftest mcp-rpc-session-new-mcp-servers
  (with-project (project config :base base) '()
    (with-rpc (rpc backend project config :steps '("done"))
      (let* ((servers (jget (json:decode (mcp-servers-json "ed" (fake-stdio-server base))) "mcpServers"))
             (result (call rpc "session/new" "mcp_servers" servers))
             (id (event-value result "session_id"))
             (list (call rpc "mcp/list" "session_id" id)))
        (ok (equal "sdk" (jget (server-object (jget list "servers") "ed") "scope")))
        (ok (equal "connected" (jget (server-object (jget list "servers") "ed") "status")))))))

(deftest mcp-rpc-error-code
  (ok (eql -32020 (cdr (assoc 'mcp-server-not-found +rpc-error-codes+)))))
