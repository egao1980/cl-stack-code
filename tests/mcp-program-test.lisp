(in-package #:cl-stack-code/tests)

;;; H3e-2a interactive: /mcp and the project-server approval dialog on
;;; tui-backend-terminal's headless driver (120 × 30).

(defun wait-mcp-line (tui needle &key (timeout *ui-timeout*))
  "Send /mcp about once a second until NEEDLE is on screen (servers connect in
the background, so one /mcp may still show them connecting). Bounded."
  (wait-until (lambda ()
                (or (on-screen tui needle)
                    (progn (send-line tui "/mcp") (sleep 1) (on-screen tui needle))))
              :timeout timeout))

(deftest mcp-program-slash-mcp
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers"
                         (args "fake" (fake-stdio-server base)
                               "crashy" (fake-stdio-server base :mode "crash")))
    (with-code-tui (tui program backend :cols 120 :rows 30) (project config)
      (ok (wait-mcp-line tui (format nil "fake (user, stdio): connected · ~d tools"
                                   (length +fake-stdio-tools+))))
      (ok (on-screen tui "mcp__fake__echo"))
      (ok (wait-mcp-line tui "crashy (user, stdio): failed:"))
      (send-line tui "/mcp reconnect crashy")
      (ok (wait-screen tui "reconnecting crashy")))))

(deftest mcp-program-no-servers
  (with-project (project config) '()
    (with-code-tui (tui program backend :cols 120 :rows 30) (project config)
      (send-line tui "/mcp")
      (ok (wait-screen tui "no MCP servers configured")))))

(deftest mcp-program-approval-yes
  (with-project (project config :base base) '()
    (write-mcp-json project "proj" (fake-stdio-server base))
    (with-code-tui (tui program backend :cols 120 :rows 30) (project config)
      (ok (wait-screen tui "MCP server proj from"))
      (ok (on-screen tui "wants to run:"))
      (dolist (choice +mcp-approval-choices+)
        (ok (on-screen tui (second choice)) (second choice)))
      (h:tui-press tui :enter)                  ; the first choice: Yes
      (ok (wait-gone tui "wants to run:"))
      (ok (wait-mcp-line tui "proj (project, stdio): connected"))
      (let ((user (json:decode (read-file config "settings.json"))))
        (ok (equal (list (format nil "proj@~a" (native project)))
                   (coerce (jget user "enabledMcpjsonServers") 'list))
            "saved in the user settings for this project")))))

(deftest mcp-program-approval-no
  (with-project (project config :base base) '()
    (write-mcp-json project "proj" (fake-stdio-server base))
    (with-code-tui (tui program backend :cols 120 :rows 30) (project config)
      (ok (wait-screen tui "MCP server proj from"))
      (h:tui-press tui :arrow-down)
      (h:tui-press tui :enter)                  ; No
      (ok (wait-gone tui "wants to run:"))
      (ok (wait-mcp-line tui "proj (project, stdio): rejected"))
      (let ((user (json:decode (read-file config "settings.json"))))
        (ok (equal (list (format nil "proj@~a" (native project)))
                   (coerce (jget user "disabledMcpjsonServers") 'list)))))))

(deftest mcp-program-approved-servers-do-not-ask
  (with-project (project config :base base) '()
    (write-mcp-json project "proj" (fake-stdio-server base))
    (approve-all config)
    (with-code-tui (tui program backend :cols 120 :rows 30) (project config)
      (ok (wait-mcp-line tui "proj (project, stdio): connected"))
      (ok (not (on-screen tui "wants to run:"))))))
