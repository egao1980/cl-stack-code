(in-package #:cl-stack-code/tests)

;;; H3e-2b: elicitation (src/mcp-requests.lisp, "ELICITATION"). fake2's
;;; ask_user sends elicitation/create while its tool call runs. -p declines;
;;; the SDK and --rpc answer through the approval channel.

(defparameter +ask-user-tool+ "mcp__f2__ask_user")

(defun %elicitation-steps (&key (tool "ask_user") (final "done"))
  (list (f2-call tool) final))

(defun %sdk-elicitation-client (project config base fn &key (steps (%elicitation-steps)) (tool +ask-user-tool+)
                                                            server-keys deny)
  (apply #'user-fake2 config base server-keys)
  (call-with-test-client project config fn
                         :steps steps
                         :settings (make-settings :allow (list (parse-permission-rule tool :allow))
                                                  :deny (mapcar (lambda (r) (parse-permission-rule r :deny))
                                                                deny))))

;;; -p

(deftest h3e2b-elicitation-headless-declines
  (with-project (project config :base base) '()
    (user-fake2 config base)
    (multiple-value-bind (exit out err) (pj2 project config (%elicitation-steps) "--allowed-tools" +ask-user-tool+)
      (ok (eql 0 exit) err)
      (ok (equal "elicited: decline " (f2-result out "ask_user")) "declined, no content")
      (let ((e (first (system-subtype-events out "mcp_elicitation"))))
        (ok e "an mcp_elicitation event")
        (ok (equal "declined" (jget e "outcome")))
        (ok (equal "headless" (jget e "reason")))
        (ok (equal "mcp-elicitation-1" (jget e "request_id")))
        (ok (equalp #() (jget e "fields")))))))

(deftest h3e2b-elicitation-switched-off
  (with-project (project config :base base) '()
    (user-fake2 config base :elicitation nil)
    (multiple-value-bind (exit out) (pj2 project config (%elicitation-steps) "--allowed-tools" +ask-user-tool+)
      (ok (eql 0 exit))
      (ok (has "elicitation error -32601" (f2-result out "ask_user")) "no handler, no capability")
      (ok (null (system-subtype-events out "mcp_elicitation"))))))

(deftest h3e2b-elicitation-deny-rule
  (with-project (project config :base base) '()
    (%sdk-elicitation-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "ask me")))
         (client-wait turn :timeout 60)
         (ok (equal "elicited: decline " (turn-tool-content turn +ask-user-tool+)) "declined without asking")
         (ok (null (find "mcp_elicitation" (events-of events "approval_request")
                         :key (lambda (e) (event-value e "kind")) :test #'equal)))
         (let ((e (first (sdk-system-events events "mcp_elicitation"))))
           (ok (equal "denied" (event-value e "outcome")))
           (ok (equal "rule" (event-value e "reason"))))))
     :deny '("mcp_elicitation(f2)"))))

(deftest h3e2b-elicitation-unsupported-schema
  (with-project (project config :base base) '()
    (user-fake2 config base)
    (multiple-value-bind (exit out)
        (pj2 project config (%elicitation-steps :tool "ask_user_bad") "--allowed-tools" "mcp__f2__ask_user_bad")
      (ok (eql 0 exit))
      (ok (has "elicitation error -32602 unsupported elicitation schema" (or (f2-result out "ask_user_bad") "")))
      (ok (null (system-subtype-events out "mcp_elicitation")) "not a request anyone answers"))))

;;; The SDK

(deftest h3e2b-elicitation-sdk-accept
  (with-project (project config :base base) '()
    (%sdk-elicitation-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "ask me"))
              (req (pending-mcp s "mcp_elicitation")))
         (ok req "the question waits for the caller")
         (when req
           (ok (equal "mcp-elicitation-1" (event-value req "id")))
           (ok (equal "mcp_elicitation" (event-value req "name")))
           (ok (equal "f2" (event-value req "server")))
           (ok (equal "Which colour?" (event-value req "input" "message")))
           (ok (equal "integer" (event-value req "input" "requested_schema" "properties" "count" "type")))
           (ok (equal '("mcp-elicitation-1")
                      (client-respond-approval s "mcp-elicitation-1" :accept
                                               :content (color-content "colour" "red" "count" 3)))))
         (client-wait turn :timeout 60)
         (ok (equal "elicited: accept colour=red count=3" (turn-tool-content turn +ask-user-tool+)))
         (let ((e (first (sdk-system-events events "mcp_elicitation"))))
           (ok (equal "accepted" (event-value e "outcome")))
           (ok (equal '("colour" "count") (coerce (event-value e "fields") 'list)))
           (ok (not (search "red" (json:encode e))) "no content value in the event"))
         (let ((resolved (find "mcp-elicitation-1" (events-of events "approval_resolved")
                               :key (lambda (e) (event-value e "id")) :test #'equal)))
           (ok (equal "accept" (event-value resolved "decision")))))))))

(deftest h3e2b-elicitation-sdk-invalid-content
  (with-project (project config :base base) '()
    (%sdk-elicitation-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "ask me")))
         (ok (pending-mcp s "mcp_elicitation"))
         (let ((c (handler-case (progn (client-respond-approval s "mcp-elicitation-1" :accept
                                                                :content (color-content "colour" "pink"))
                                       nil)
                    (mcp-elicitation-content-error (e) e))))
           (ok c "MCP-ELICITATION-CONTENT-ERROR")
           (ok (and c (typep c 'code-usage-error)))
           (ok (and c (mcp-elicitation-content-error-errors c))))
         (ok (pending-mcp s "mcp_elicitation" :timeout 1) "still waiting")
         (ok (signals (client-respond-approval s "mcp-elicitation-1" :once) 'code-usage-error)
             "once does not answer a question")
         (client-respond-approval s "mcp-elicitation-1" :decline)
         (client-wait turn :timeout 60)
         (ok (equal "elicited: decline " (turn-tool-content turn +ask-user-tool+))))))))

(deftest-parametrize h3e2b-elicitation-sdk-decline-cancel
    ((decision action outcome)
     (:decline "decline" "declined")
     (:reject "decline" "declined")
     (:cancel "cancel" "canceled"))
  (with-project (project config :base base) '()
    (%sdk-elicitation-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "ask me")))
         (when (pending-mcp s "mcp_elicitation")
           (client-respond-approval s "mcp-elicitation-1" decision))
         (client-wait turn :timeout 60)
         (ok (equal (format nil "elicited: ~a " action) (turn-tool-content turn +ask-user-tool+)))
         (ok (equal outcome (event-value (first (sdk-system-events events "mcp_elicitation")) "outcome"))))))))

(deftest h3e2b-elicitation-sdk-on-approval
  (with-project (project config :base base) '()
    (user-fake2 config base)
    (with-test-client (client backend events project config
                       :steps (%elicitation-steps)
                       :settings (make-settings :allow (list (parse-permission-rule +ask-user-tool+ :allow)))
                       :on-approval (lambda (session request)
                                      (declare (ignore session))
                                      (and (equal "mcp_elicitation" (event-value request "kind"))
                                           (list :accept (color-content "colour" "blue")))))
      (let* ((s (client-new-session client))
             (turn (client-turn s "ask me")))
        (client-wait turn :timeout 60)
        (ok (equal "elicited: accept colour=blue" (turn-tool-content turn +ask-user-tool+))
            "ON-APPROVAL's (:accept CONTENT) answers at once")))))

(deftest h3e2b-elicitation-mrtr
  (with-project (project config :base base) '()
    (%sdk-elicitation-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "ask me")))
         (when (pending-mcp s "mcp_elicitation")
           (client-respond-approval s "mcp-elicitation-1" :accept :content (color-content "colour" "green")))
         (client-wait turn :timeout 60)
         (ok (equal "elicited: accept colour=green" (turn-tool-content turn "mcp__f2__ask_user_mrtr"))
             "input_required reaches the same handler; the retry carries the answer")))
     :steps (%elicitation-steps :tool "ask_user_mrtr")
     :tool "mcp__f2__ask_user_mrtr")))

;;; --rpc

(deftest h3e2b-elicitation-rpc
  (with-project (project config :base base) '()
    (user-fake2 config base)
    (with-rpc (rpc backend project config :steps (%elicitation-steps)
                   :settings (make-settings :allow (list (parse-permission-rule +ask-user-tool+ :allow))))
      (let ((id (new-session rpc)))
        (call rpc "turn/start" "session_id" id "prompt" "ask me")
        (let ((req (wait-until (lambda ()
                                 (find "mcp_elicitation" (rpc-client-events rpc :type "approval_request"
                                                                                :session-id id)
                                       :key (lambda (e) (event-value e "kind")) :test #'equal))
                               :timeout 15)))
          (ok req)
          (when req
            (multiple-value-bind (code data)
                (fault rpc "approval/respond" "session_id" id "id" (event-value req "id")
                       "decision" "accept" "content" (args "colour" "pink"))
              (ok (eql -32602 code) "content that does not match the schema")
              (ok (and data (plusp (length (jget data "errors"))))))
            (call rpc "approval/respond" "session_id" id "id" (event-value req "id")
                  "decision" "accept" "content" (args "colour" "red" "note" "hi"))))
        (rpc-result rpc id :timeout 60)
        (let ((r (find +ask-user-tool+ (rpc-client-events rpc :type "tool_result" :session-id id)
                       :key (lambda (e) (event-value e "name")) :test #'equal)))
          (ok (equal "elicited: accept colour=red note=hi" (and r (event-value r "content")))))))))
