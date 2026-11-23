(in-package #:cl-stack-code/tests)

;;; H3e-2b: sampling (src/mcp-requests.lisp, "SAMPLING"). fake2's ask_model
;;; sends sampling/createMessage to the client while its tool call runs; the
;;; scripted model answers the sample as its next step. -p, then the SDK and
;;; --rpc.

(defparameter +ask-model-tool+ "mcp__f2__ask_model")

(defun %sampling-steps (&key (reply "Lisp in the morning") (final "done") (tool "ask_model"))
  (list (f2-call tool "prompt" "Write a haiku") reply final))

(defun %allow-sampling (&rest more)
  "argv allowing the ask_model tool and server f2's sampling."
  (append (list "--allowed-tools" +ask-model-tool+ "--allowed-tools" "mcp_sampling(f2)") more))

;;; -p

(deftest h3e2b-sampling-capabilities-default
  (with-project (project config :base base) '()
    (user-fake2 config base)
    (multiple-value-bind (exit out err) (pj2 project config (list (f2-call "caps") "done")
                                             "--allowed-tools" "mcp__f2__caps")
      (ok (eql 0 exit) err)
      (ok (equal "sampling=no elicitation=yes form=yes" (f2-result out "caps"))
          "no sampling without the opt-in; elicitation (form) by default"))))

(deftest h3e2b-sampling-capability-when-opted-in
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t :elicitation nil)
    (multiple-value-bind (exit out) (pj2 project config (list (f2-call "caps") "done")
                                         "--allowed-tools" "mcp__f2__caps")
      (ok (eql 0 exit))
      (ok (equal "sampling=yes elicitation=no form=no" (f2-result out "caps"))))))

(deftest h3e2b-sampling-not-opted-in
  (with-project (project config :base base) '()
    (user-fake2 config base)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (%sampling-steps :reply "done" :final "unused") "--allowed-tools" +ask-model-tool+)
      (ok (eql 0 exit) err)
      (ok (has "sampling error -32601" (f2-result out "ask_model")) "the client has no sampling handler")
      (ok (null (sampling-request-of backend)) "the model never saw the server's messages")
      (ok (null (system-subtype-events out "mcp_sampling"))))))

(deftest h3e2b-sampling-headless-denied
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (%sampling-steps :reply "done" :final "unused") "--allowed-tools" +ask-model-tool+)
      (ok (eql 0 exit) err)
      (ok (equal (format nil "sampling error -1 ~a" +mcp-sampling-headless-message+)
                 (f2-result out "ask_model"))
          "-1 and the headless message to the server")
      (ok (null (sampling-request-of backend)))
      (let ((e (first (system-subtype-events out "mcp_sampling"))))
        (ok e "an mcp_sampling event")
        (ok (equal "denied" (jget e "outcome")))
        (ok (equal "headless" (jget e "reason")))
        (ok (equal "f2" (jget e "server")))
        (ok (equal "mcp-sampling-1" (jget e "request_id"))))
      (let ((d (denial-of out "mcp_sampling")))
        (ok d "listed in permission_denials")
        (ok (equal "mcp-sampling-1" (jget d "id")))
        (ok (equal "f2" (jget d "input" "server")))
        (ok (equal "headless" (jget d "reason")))))))

(deftest h3e2b-sampling-allowed-by-rule
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (multiple-value-bind (exit out err backend)
        (apply #'pj2 project config (%sampling-steps) (%allow-sampling))
      (ok (eql 0 exit) err)
      (let ((sample (sampling-request-of backend))
            (first-request (first (scripted-requests backend))))
        (ok sample "the model got the server's request")
        (when sample
          (ok (equal '("Write a haiku") (request-user-texts sample)) "only the server's messages")
          (ok (null (request-tool-names sample)) "no tools in a sample")
          (ok (eql 4096 (llm:llm-settings-max-tokens (request-settings sample)))
              "maxTokens 10000 capped at the default 4096")
          (ok (equal (request-model first-request) (request-model sample))
              "the session's model, not the server's hint gpt-x")
          (ok (not (equal "gpt-x" (request-model sample))))))
      (ok (uiop:string-prefix-p "sampled: Lisp in the morning | model " (or (f2-result out "ask_model") ""))
          "the server got the answer")
      (ok (has "| stop endTurn" (or (f2-result out "ask_model") "")))
      (let ((e (first (system-subtype-events out "mcp_sampling"))))
        (ok (equal "allowed" (jget e "outcome")))
        (ok (eql 4096 (jget e "max_tokens")))
        (ok (eql 5 (jget e "usage" "output_tokens")) "the sample's usage")
        (ok (equal (jget e "request_id") "mcp-sampling-1")))
      (ok (equal "done" (jget (first (events out "result")) "result")))
      (ok (null (denial-of out "mcp_sampling"))))))

(deftest h3e2b-sampling-config-model-and-cap
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling (args "model" "mock:small" "maxTokens" 256))
    (multiple-value-bind (exit out err backend)
        (apply #'pj2 project config (%sampling-steps) (%allow-sampling))
      (ok (eql 0 exit) err)
      (let ((sample (sampling-request-of backend)))
        (ok sample)
        (when sample
          (ok (equal "small" (request-model sample)) "the configured designator's model")
          (ok (eql 256 (llm:llm-settings-max-tokens (request-settings sample))))))
      (let ((e (first (system-subtype-events out "mcp_sampling"))))
        (ok (equal "mock:small" (jget e "model")))
        (ok (eql 256 (jget e "max_tokens")))))))

(deftest h3e2b-sampling-deny-rule
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (multiple-value-bind (exit out)
        (pj2 project config (%sampling-steps :reply "done" :final "unused")
             "--allowed-tools" +ask-model-tool+ "--disallowed-tools" "mcp_sampling")
      (ok (eql 0 exit))
      (ok (equal (format nil "sampling error -1 ~a" +mcp-sampling-denied-message+) (f2-result out "ask_model")))
      (let ((e (first (system-subtype-events out "mcp_sampling"))))
        (ok (equal "denied" (jget e "outcome")))
        (ok (equal "rule" (jget e "reason")))))))

(deftest h3e2b-sampling-bypass-permissions
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (%sampling-steps) "--permission-mode" "bypassPermissions")
      (ok (eql 0 exit) err)
      (ok (sampling-request-of backend) "bypassPermissions allows the ask")
      (ok (has "sampled: Lisp in the morning" (or (f2-result out "ask_model") ""))))))

(deftest h3e2b-sampling-model-failure
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (multiple-value-bind (exit out err)
        (apply #'pj2 project config (list (f2-call "ask_model") '(:error "model exploded") "done")
               (%allow-sampling))
      (ok (eql 0 exit) err)
      (ok (has "sampling error -32603" (or (f2-result out "ask_model") "")))
      (ok (has "model exploded" (or (f2-result out "ask_model") "")))
      (let ((e (first (system-subtype-events out "mcp_sampling"))))
        (ok (equal "failed" (jget e "outcome")))
        (ok (has "model exploded" (or (jget e "error") "")))))))

(deftest h3e2b-sampling-mrtr
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (%sampling-steps :tool "ask_model_mrtr")
             "--allowed-tools" "mcp__f2__ask_model_mrtr" "--allowed-tools" "mcp_sampling(f2)")
      (ok (eql 0 exit) err)
      (ok (sampling-request-of backend) "input_required reaches the same handler")
      (ok (has "sampled: Lisp in the morning" (or (f2-result out "ask_model_mrtr") ""))
          "the retry carries the answer (mcp-protocol 0.5.0)"))))

;;; The SDK

(defun %sdk-sampling-client (project config base fn &key (steps (%sampling-steps)) settings)
  (user-fake2 config base :sampling t)
  (call-with-test-client project config fn
                         :steps steps
                         :settings (merge-settings
                                    (make-settings :allow (list (parse-permission-rule +ask-model-tool+ :allow)))
                                    settings)))

(deftest h3e2b-sampling-sdk-once
  (with-project (project config :base base) '()
    (%sdk-sampling-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "write a poem"))
              (req (pending-mcp s "mcp_sampling")))
         (ok req "the sample waits for the caller")
         (when req
           (ok (equal "approval_request" (event-type req)))
           (ok (equal "mcp-sampling-1" (event-value req "id")))
           (ok (equal "f2" (event-value req "server")))
           (ok (equal "call-1-1" (event-value req "tool_use_id")) "the MCP call that asked")
           (ok (equal "Write a haiku" (event-value req "input" "messages" 0 "text")))
           (ok (member req (events-of events "approval_request")) "delivered as an event too")
           (ok (equal '("mcp-sampling-1") (client-respond-approval s "mcp-sampling-1" :once))))
         (let ((result (client-wait turn :timeout 60)))
           (ok (equal "success" (event-value result "subtype"))))
         (ok (has "sampled: Lisp in the morning" (or (turn-tool-content turn +ask-model-tool+) "")))
         (ok (sampling-request-of backend))
         (let ((resolved (find "mcp-sampling-1" (events-of events "approval_resolved")
                               :key (lambda (e) (event-value e "id")) :test #'equal)))
           (ok (equal "once" (event-value resolved "decision"))))
         (ok (equal "approved" (event-value (first (sdk-system-events events "mcp_sampling")) "outcome")))
         (ok (null (read-file project ".cl-stack-code/settings.local.json")) "no rule saved"))))))

(deftest h3e2b-sampling-sdk-always
  (with-project (project config :base base) '()
    (%sdk-sampling-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "two poems")))
         (when (pending-mcp s "mcp_sampling")
           (client-respond-approval s "mcp-sampling-1" :always))
         (client-wait turn :timeout 60)
         (let ((local (read-file project ".cl-stack-code/settings.local.json")))
           (ok (and local (member "mcp_sampling(f2)" (coerce (jget (json:decode local) "permissions" "allow") 'list)
                                  :test #'equal))
               "saved as mcp_sampling(f2)"))
         (ok (equal "allowed" (event-value (second (sdk-system-events events "mcp_sampling")) "outcome"))
             "the second request did not ask")
         (ok (= 1 (count "mcp_sampling" (events-of events "approval_request")
                         :key (lambda (e) (event-value e "kind")) :test #'equal)))))
     :steps (list (f2-call "ask_model" "prompt" "one") "First." (f2-call "ask_model" "prompt" "two")
                  "Second." "done"))))

(deftest h3e2b-sampling-sdk-reject
  (with-project (project config :base base) '()
    (%sdk-sampling-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "write a poem")))
         (when (pending-mcp s "mcp_sampling")
           (client-respond-approval s "mcp-sampling-1" :reject :feedback "not now"))
         (client-wait turn :timeout 60)
         (let ((text (or (turn-tool-content turn +ask-model-tool+) "")))
           (ok (has "sampling error -1 User rejected sampling request" text))
           (ok (has "not now" text) "the feedback reaches the server"))
         (ok (null (sampling-request-of backend)))
         (ok (equal "rejected" (event-value (first (sdk-system-events events "mcp_sampling")) "outcome")))))
     :steps (%sampling-steps :reply "done" :final "unused"))))

(deftest h3e2b-sampling-sdk-decisions-and-ids
  (with-project (project config :base base) '()
    (%sdk-sampling-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "write a poem")))
         (ok (pending-mcp s "mcp_sampling"))
         (ok (signals (client-respond-approval s "mcp-sampling-1" :accept :content (args "x" 1))
                      'code-usage-error)
             "accept does not answer a sampling request")
         (ok (signals (client-respond-approval s "mcp-sampling-9" :once) 'approval-not-found))
         (ok (pending-mcp s "mcp_sampling" :timeout 1) "still waiting")
         (client-respond-approval s "mcp-sampling-1" :once)
         (client-wait turn :timeout 60))))))

(deftest h3e2b-sampling-sdk-interrupt
  (with-project (project config :base base) '()
    (%sdk-sampling-client
     project config base
     (lambda (client backend events)
       (declare (ignorable client backend events))
       (let* ((s (client-new-session client))
              (turn (client-turn s "write a poem")))
         (ok (pending-mcp s "mcp_sampling"))
         (ok (client-interrupt s))
         (let ((result (client-wait turn :timeout 60)))
           (ok result "the turn ends")
           (ok (equal "interrupted" (event-value result "error"))))
         (let ((resolved (find "mcp-sampling-1" (events-of events "approval_resolved")
                               :key (lambda (e) (event-value e "id")) :test #'equal)))
           (ok (equal "interrupt" (event-value resolved "decision"))))
         (ok (null (client-pending-approvals s)))))
     :steps (%sampling-steps :reply "unused" :final "unused"))))

;;; --rpc

(deftest h3e2b-sampling-rpc
  (with-project (project config :base base) '()
    (user-fake2 config base :sampling t)
    (with-rpc (rpc backend project config :steps (%sampling-steps)
                   :settings (make-settings :allow (list (parse-permission-rule +ask-model-tool+ :allow))))
      (let* ((id (new-session rpc)))
        (call rpc "turn/start" "session_id" id "prompt" "write a poem")
        (let ((req (wait-until (lambda ()
                                 (find "mcp_sampling" (rpc-client-events rpc :type "approval_request" :session-id id)
                                       :key (lambda (e) (event-value e "kind")) :test #'equal))
                               :timeout 15)))
          (ok req "approval_request kind mcp_sampling as a notification")
          (when req
            (ok (equal '("mcp-sampling-1")
                       (coerce (jget (call rpc "approval/respond" "session_id" id
                                           "id" (event-value req "id") "decision" "once")
                                     "resolved")
                               'list)))))
        (let ((result (rpc-result rpc id :timeout 60)))
          (ok (equal "success" (event-value result "subtype"))))
        (ok (sampling-request-of backend))))))
