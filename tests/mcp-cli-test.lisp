(in-package #:cl-stack-code/tests)

;;; H3e-2a end to end in -p: the fake stdio server (a child SBCL) and the
;;; loopback HTTP server, the scripted model, stream-json output.

(defun %pj (project config steps &rest argv)
  "-p stream-json run → (values exit out err backend)."
  (code project config (append (list "-p" "go" "--output-format" "stream-json") argv)
        :steps steps))

(defun %user-fake (config base &rest more)
  "User settings with the fake stdio server as \"fake\" (plus MORE name/object pairs)."
  (let ((servers (args "fake" (fake-stdio-server base))))
    (loop for (k v) on more by #'cddr do (setf (gethash k servers) v))
    (write-user-settings config "mcpServers" servers)))

(defun %result-content (out name)
  (jget (tool-result-of out name) "content"))

(deftest mcp-cli-init-and-tools
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out err backend) (%pj project config '("done"))
      (ok (eql 0 exit) err)
      (let* ((servers (mcp-init-servers out))
             (fake (server-object servers "fake"))
             (tools (coerce (jget (first (events out "system")) "tools") 'list)))
        (ok (= 1 (length servers)))
        (ok (equal "connected" (jget fake "status")))
        (ok (equal "user" (jget fake "scope")))
        (ok (equal "stdio" (jget fake "transport")))
        (ok (eq :null (jget fake "error")))
        (ok (same-set (mcp-names "fake") (coerce (jget fake "tools") 'list)))
        (ok (same-set (mcp-names "fake") (last tools (length +fake-stdio-tools+)))
            "the MCP tools come last")
        (ok (subsetp (mcp-names "fake") (request-tool-names (first (scripted-requests backend)))
                     :test #'equal)
            "the model is offered them")))))

(deftest mcp-cli-no-servers-no-key
  (with-project (project config) '()
    (multiple-value-bind (exit out) (%pj project config '("done"))
      (ok (eql 0 exit))
      (ok (null (nth-value 1 (gethash "mcp_servers" (first (events out "system")))))))))

(deftest mcp-cli-read-only-tool-of-a-user-server-runs
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out err)
        (%pj project config (list (list :tool "mcp__fake__echo" (json-args "msg" "hi")) "done"))
      (ok (eql 0 exit) err)
      (ok (equal "done" (jget (first (events out "tool_result")) "status")) "ran without asking")
      (ok (equal "hi" (%result-content out "mcp__fake__echo")))
      (ok (null (denial-of out "mcp__fake__echo"))))))

(deftest mcp-cli-default-is-ask
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out)
        (%pj project config (list (list :tool "mcp__fake__write_note" (json-args "text" "x")) "done"))
      (ok (eql 0 exit))
      (ok (equal "denied" (jget (tool-result-of out "mcp__fake__write_note") "status")))
      (ok (equal "headless" (jget (denial-of out "mcp__fake__write_note") "reason"))))))

(deftest-parametrize mcp-cli-rules
    ((flag rule status)
     ("--allowed-tools" "mcp__fake__write_note" "done")
     ("--allowed-tools" "mcp__fake__*" "done"))
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out)
        (%pj project config (list (list :tool "mcp__fake__write_note" (json-args "text" "x")) "done")
             flag rule)
      (ok (eql 0 exit))
      (ok (equal status (jget (tool-result-of out "mcp__fake__write_note") "status"))))))

(deftest mcp-cli-deny-hides
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out) (%pj project config '("done") "--disallowed-tools" "mcp__fake__*")
      (ok (eql 0 exit))
      (ok (notany (lambda (n) (uiop:string-prefix-p "mcp__fake__" n))
                  (coerce (jget (first (events out "system")) "tools") 'list))))))

(deftest mcp-cli-error-result
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out)
        (%pj project config (list (list :tool "mcp__fake__fail" "{}") "done")
             "--allowed-tools" "mcp__fake__fail")
      (ok (eql 0 exit) "a tool error does not fail the run")
      (let ((r (tool-result-of out "mcp__fake__fail")))
        (ok (equal "error" (jget r "status")))
        (ok (eq t (jget r "is_error")))
        (ok (has "disk full" (jget r "content")))))))

(deftest mcp-cli-image-result
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out)
        (%pj project config (list (list :tool "mcp__fake__picture" "{}") "done")
             "--allowed-tools" "mcp__fake__picture")
      (ok (eql 0 exit))
      (let ((r (tool-result-of out "mcp__fake__picture")))
        (ok (equal (format nil "a picture~%[image image/png]") (jget r "content")))
        (ok (equal "image/png" (jget r "images" 0 "media_type")))
        (ok (equal "iVBORw0KGgo=" (jget r "images" 0 "data")))))))

(deftest mcp-cli-env-expansion-reaches-the-child
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers"
                         (args "fake" (fake-stdio-server base :env (list "FAKE_TOKEN" "${MY_TOKEN}"))))
    (multiple-value-bind (exit out)
        (code project config (list "-p" "go" "--output-format" "stream-json"
                                   "--allowed-tools" "mcp__fake__env")
              :steps (list (list :tool "mcp__fake__env" "{}") "done")
              :getenv (env-lookup "MY_TOKEN" "s3cret"))
      (ok (eql 0 exit))
      (ok (equal "s3cret" (%result-content out "mcp__fake__env"))))))

(deftest mcp-cli-unset-variable-is-a-usage-error
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers"
                         (args "fake" (fake-stdio-server base :env (list "FAKE_TOKEN" "${NOPE}"))))
    (multiple-value-bind (exit out err) (%pj project config '("done"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has "${NOPE} is not set (MCP server fake)" err)))))

(deftest mcp-cli-crashing-server
  (with-project (project config :base base) '()
    (%user-fake config base "crashy" (fake-stdio-server base :mode "crash"))
    (multiple-value-bind (exit out err) (%pj project config '("done"))
      (ok (eql 0 exit) "a failed server does not fail the run")
      (let ((crashy (server-object (mcp-init-servers out) "crashy")))
        (ok (equal "failed" (jget crashy "status")))
        (ok (stringp (jget crashy "error")))
        (ok (zerop (length (jget crashy "tools")))))
      (ok (equal "connected" (jget (server-object (mcp-init-servers out) "fake") "status"))
          "the other server is there")
      (ok (has "cl-stack-code: MCP server crashy failed:" err)))))

(deftest mcp-cli-hanging-server-times-out
  (with-project (project config :base base) '()
    (let ((hang (fake-stdio-server base :mode "hang")))
      (setf (gethash "startupTimeout" hang) 1500)
      (write-user-settings config "mcpServers" (args "slow" hang)))
    (let ((start (get-internal-real-time)))
      (multiple-value-bind (exit out err) (%pj project config '("done"))
        (ok (eql 0 exit))
        (let ((slow (server-object (mcp-init-servers out) "slow")))
          (ok (equal "failed" (jget slow "status")))
          (ok (has "timed out" (jget slow "error"))))
        (ok (has "cl-stack-code: MCP server slow failed:" err))
        (ok (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 30)
            "bounded by the startup timeout")))))

(deftest mcp-cli-project-server-unapproved
  (with-project (project config :base base) '()
    (write-mcp-json project "proj" (fake-stdio-server base))
    (multiple-value-bind (exit out err) (%pj project config '("done"))
      (ok (eql 0 exit))
      (let ((proj (server-object (mcp-init-servers out) "proj")))
        (ok (equal "unapproved" (jget proj "status")))
        (ok (equal "project" (jget proj "scope")))
        (ok (zerop (length (jget proj "tools")))))
      (ok (notany (lambda (n) (uiop:string-prefix-p "mcp__proj__" n))
                  (coerce (jget (first (events out "system")) "tools") 'list)))
      (ok (has (format nil "cl-stack-code: MCP server proj (~a) is not approved; skipped"
                       (native (merge-pathnames ".mcp.json" project)))
               err)))))

(deftest-parametrize mcp-cli-project-approval
    ((user-keys status)
     ('("enableAllProjectMcpServers" t) "connected")
     ('("enabledMcpjsonServers" :qualified) "connected")
     ('("enabledMcpjsonServers" ("proj")) "connected")
     ('("enableAllProjectMcpServers" t "disabledMcpjsonServers" ("proj")) "rejected"))
  (with-project (project config :base base) '()
    (write-mcp-json project "proj" (fake-stdio-server base))
    (apply #'write-user-settings config
           (loop for (k v) on user-keys by #'cddr
                 append (list k (cond ((eq v :qualified)
                                       (vector (format nil "proj@~a" (native project))))
                                      ((listp v) (coerce v 'vector))
                                      (t v)))))
    (multiple-value-bind (exit out) (%pj project config '("done"))
      (ok (eql 0 exit))
      (ok (equal status (jget (server-object (mcp-init-servers out) "proj") "status"))))))

(deftest mcp-cli-project-cannot-approve-itself
  (with-project (project config :base base) '()
    (write-mcp-json project "proj" (fake-stdio-server base))
    (write-file project ".cl-stack-code/settings.json"
                (json-args "enableAllProjectMcpServers" t "enabledMcpjsonServers" (vector "proj")))
    (multiple-value-bind (exit out) (%pj project config '("done"))
      (ok (eql 0 exit))
      (ok (equal "unapproved" (jget (server-object (mcp-init-servers out) "proj") "status"))))))

(deftest mcp-cli-project-read-only-still-asks
  (with-project (project config :base base) '()
    (write-mcp-json project "proj" (fake-stdio-server base))
    (approve-all config)
    (multiple-value-bind (exit out)
        (%pj project config (list (list :tool "mcp__proj__echo" (json-args "msg" "hi")) "done"))
      (ok (eql 0 exit))
      (ok (equal "denied" (jget (tool-result-of out "mcp__proj__echo") "status"))
          "a project server's readOnlyHint does not allow by itself")
      (ok (equal "headless" (jget (denial-of out "mcp__proj__echo") "reason"))))))

(deftest mcp-cli-disabled-server
  (with-project (project config :base base) '()
    (let ((off (fake-stdio-server base)))
      (setf (gethash "disabled" off) t)
      (%user-fake config base "off" off))
    (multiple-value-bind (exit out err) (%pj project config '("done"))
      (ok (eql 0 exit))
      (ok (equal "disabled" (jget (server-object (mcp-init-servers out) "off") "status")))
      (ok (not (has "MCP server off" err)) "no notice"))))

(deftest mcp-cli-sse-unsupported
  (with-project (project config) '()
    (write-user-settings config "mcpServers" (args "old" (args "type" "sse" "url" "http://mcp.test/sse")))
    (multiple-value-bind (exit out err) (%pj project config '("done"))
      (ok (eql 0 exit))
      (let ((old (server-object (mcp-init-servers out) "old")))
        (ok (equal "unsupported" (jget old "status")))
        (ok (equal "sse" (jget old "transport"))))
      (ok (has "cl-stack-code: MCP server old: transport sse is not supported yet" err)))))

(deftest mcp-cli-strict-config
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out)
        (%pj project config '("done") "--strict-mcp-config"
             "--mcp-config" (mcp-servers-json "flagged" (fake-stdio-server base)))
      (ok (eql 0 exit))
      (let ((servers (mcp-init-servers out)))
        (ok (equal '("flagged") (map 'list (lambda (s) (jget s "name")) servers)))
        (ok (equal "flag" (jget (server-object servers "flagged") "scope")))
        (ok (equal "connected" (jget (server-object servers "flagged") "status")))))))

(deftest mcp-cli-bad-mcp-json
  (with-project (project config) '((".mcp.json" . "{\"mcpServers\":{\"x\":{\"args\":[1]}}}"))
    (multiple-value-bind (exit out err) (%pj project config '("done"))
      (ok (eql 2 exit))
      (ok (equal "" out))
      (ok (has ".mcp.json" err))
      (ok (has "mcpServers.x" err)))))

(deftest mcp-cli-plan-mode
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out err)
        (%pj project config (list (list :tools (list "mcp__fake__write_note" (json-args "text" "x"))
                                         (list "mcp__fake__echo" (json-args "msg" "hi")))
                                  "done")
             "--permission-mode" "plan" "--plan-area" "copy")
      (ok (eql 0 exit) err)
      (let ((write (tool-result-of out "mcp__fake__write_note"))
            (echo (tool-result-of out "mcp__fake__echo")))
        (ok (equal "denied" (jget write "status")))
        (ok (has +mcp-plan-mode-feedback+ (jget write "content")))
        (ok (equal "done" (jget echo "status")) "read-only and trusted: runs")))))

(deftest mcp-cli-plan-mode-allow-rule
  (with-project (project config :base base) '()
    (%user-fake config base)
    (multiple-value-bind (exit out)
        (%pj project config (list (list :tool "mcp__fake__write_note" (json-args "text" "x")) "done")
             "--permission-mode" "plan" "--plan-area" "copy"
             "--allowed-tools" "mcp__fake__write_note")
      (ok (eql 0 exit))
      (ok (equal "done" (jget (tool-result-of out "mcp__fake__write_note") "status"))))))

(deftest mcp-cli-close-reaps-the-child
  (with-project (project config :base base) '()
    (let ((pid-file (subdir base "fake.pid")))
      (write-user-settings config "mcpServers" (args "fake" (fake-stdio-server base :pid-file pid-file)))
      (multiple-value-bind (exit out) (%pj project config '("done"))
        (ok (eql 0 exit))
        (ok (equal "connected" (jget (server-object (mcp-init-servers out) "fake") "status")))
        (let ((pid (read-pid pid-file)))
          (ok (and pid (plusp pid)))
          (ok (wait-until (lambda () (not (process-alive-p pid))) :timeout 10)
              "the child is gone after the run"))))))

;;; Streamable HTTP over the loopback backend

(deftest mcp-cli-http-server
  (with-project (project config) '()
    (write-user-settings config "mcpServers"
                         (args "web" (http-server-object "Authorization" "Bearer ${WEB_TOKEN}")))
    (with-loopback (backend)
      (multiple-value-bind (exit out err)
          (code project config (list "-p" "go" "--output-format" "stream-json")
                :steps (list (list :tool "mcp__web__echo" (json-args "msg" "over http")) "done")
                :getenv (env-lookup "WEB_TOKEN" "tok-1"))
        (ok (eql 0 exit) err)
        (let ((web (server-object (mcp-init-servers out) "web")))
          (ok (equal "connected" (jget web "status")))
          (ok (equal "http" (jget web "transport")))
          (ok (same-set '("mcp__web__echo" "mcp__web__fail") (coerce (jget web "tools") 'list))))
        (ok (equal "over http" (%result-content out "mcp__web__echo")))
        (ok (equal "Bearer tok-1" (loopback-header backend "authorization")))
        (ok (every (lambda (r) (equal "/mcp" (second r))) (loopback-requests backend)))))))

(deftest mcp-cli-http-error-result
  (with-project (project config) '()
    (write-user-settings config "mcpServers" (args "web" (http-server-object)))
    (with-loopback (backend)
      (multiple-value-bind (exit out)
          (code project config (list "-p" "go" "--output-format" "stream-json"
                                     "--allowed-tools" "mcp__web__fail")
                :steps (list (list :tool "mcp__web__fail" "{}") "done"))
        (ok (eql 0 exit))
        (ok (equal "error" (jget (tool-result-of out "mcp__web__fail") "status")))
        (ok (has "nope" (%result-content out "mcp__web__fail")))))))
