(in-package #:cl-stack-code/tests)

;;; H3e-2b interactive: the sampling and elicitation dialogs and the /mcp
;;; suffixes, on tui-backend-terminal's headless driver (120 × 30).

(defun %wait-request-with (tui backend needle &key (timeout *ui-timeout*))
  "True once a request BACKEND saw holds NEEDLE in its text."
  (wait-for* tui (lambda ()
                   (some (lambda (r) (search needle (request-text r))) (scripted-requests backend)))
             :timeout timeout))

(deftest h3e2b-program-sampling-dialog
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (with-code-tui (tui program backend :cols 120 :rows 30
                    :argv '("--allowed-tools" "mcp__f2__ask_model")
                    :steps (list (f2-call "ask_model" "prompt" "Write a haiku") "Lisp in the morning" "Done."))
        (project config)
      (ok (wait-mcp-line tui "f2 (user, stdio): connected"))
      (send-line tui "write a poem")
      (ok (wait-screen tui "MCP server f2 asks the model") "the dialog")
      (ok (on-screen tui "user: Write a haiku"))
      (dolist (choice +mcp-sampling-choices+)
        (ok (on-screen tui (second choice)) (second choice)))
      (h:tui-press tui :enter)                  ; Yes
      (ok (wait-gone tui "MCP server f2 asks the model"))
      (ok (%wait-request-with tui backend "sampled: Lisp in the morning") "the server got the sample")
      (ok (wait-screen tui "MCP server f2 sampled the model") "the notice")
      (ok (wait-screen tui "Done.")))))

(deftest h3e2b-program-sampling-dialog-no
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (with-code-tui (tui program backend :cols 120 :rows 30
                    :argv '("--allowed-tools" "mcp__f2__ask_model")
                    :steps (list (f2-call "ask_model") "Done."))
        (project config)
      (ok (wait-mcp-line tui "f2 (user, stdio): connected"))
      (send-line tui "write a poem")
      (ok (wait-screen tui "MCP server f2 asks the model"))
      (h:tui-press tui :escape)                 ; Esc rejects
      (ok (%wait-request-with tui backend "sampling error -1 User rejected sampling request"))
      (ok (wait-screen tui "MCP server f2's sampling request was rejected")))))

(deftest h3e2b-program-elicitation-form
  (with-project (project config :base base) '()
    (user-fake2 config base)
    (with-code-tui (tui program backend :cols 120 :rows 30
                    :argv '("--allowed-tools" "mcp__f2__ask_user")
                    :steps (list (f2-call "ask_user") "Done."))
        (project config)
      (ok (wait-mcp-line tui "f2 (user, stdio): connected"))
      (send-line tui "ask me")
      (ok (wait-screen tui "MCP server f2 asks:"))
      (ok (on-screen tui "Which colour?"))
      (dolist (choice +mcp-elicitation-choices+)
        (ok (on-screen tui (second choice)) (second choice)))
      (h:tui-press tui :enter)                  ; Answer
      (ok (wait-screen tui "Colour") "the enum field as a select dialog")
      (ok (on-screen tui "green"))
      (h:tui-press tui :arrow-down)
      (h:tui-press tui :enter)                  ; green
      (ok (wait-screen tui "How many (integer, optional)"))
      (send-line tui "11")
      (ok (wait-screen tui "at most 10") "a bad value keeps the field asking")
      (send-line tui "3")
      (ok (wait-screen tui "note (string, optional)"))
      (ok (on-screen tui "Anything else") "the description")
      (h:tui-press tui :enter)                  ; empty: left out
      (ok (%wait-request-with tui backend "elicited: accept colour=green count=3"))
      (ok (wait-screen tui "MCP server f2 got your answer (colour, count)")))))

(deftest h3e2b-program-mcp-suffixes
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t :instructions +fake2-instructions+)
    (with-code-tui (tui program backend :cols 120 :rows 30) (project config)
      (ok (wait-mcp-line tui (format nil "f2 (user, stdio): connected · ~d tools · sampling · instructions"
                                   (length +fake2-base-tools+)))))))
