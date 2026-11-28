(in-package #:cl-stack-code/tests)

;;; H5c-0: plan documents through the SDK and --rpc (src/plan-docs.lisp
;;; header, SDK AND RPC), and the H5a RPC aliases.

(defun doc-of (events subtype)
  (find subtype (events-of events "plan") :key (lambda (e) (event-value e "subtype")) :test #'equal))

(deftest client-plan-doc-propose-approve
  (with-project (project config) (list (list "hello.sh" ""))
    (with-test-client (client backend events project config
                       :steps (list* (propose-step) (execution-steps)))
      (let ((s (client-new-session client :permission-mode :plan)))
        (multiple-value-bind (result turn-events) (client-query s "add a greeting" :timeout 60)
          (ok (equal "success" (event-value result "subtype")))
          (ok (equal "proposed" (event-value result "plan" "status")))
          (ok (doc-of turn-events "proposed")))
        (let ((object (client-plan-document s)))
          (ok (equal +plan-md+ (event-value object "markdown")))
          (ok (eql 1 (event-value object "revision"))))
        (multiple-value-bind (object turn) (client-approve-plan-document s :mode :accept-edits)
          (ok (equal "approved" (event-value object "status")))
          (let ((result (client-wait turn :timeout 60)))
            (ok (equal "success" (event-value result "subtype")))
            (ok (equal "executed" (event-value result "plan" "status")))))
        (ok (equal (nl "echo hello") (read-file project "hello.sh")))
        (ok (doc-of events "step") "checklist events")
        (ok (doc-of events "executed"))
        (ok (typep (failure (client-approve-plan-document s)) 'plan-document-state-error)
            "an executed plan does not run twice")))))

(deftest client-plan-doc-revise-update-reject
  (with-project (project config) '()
    (with-test-client (client backend events project config
                       :steps (list (propose-step) (propose-step +plan-md-2+)))
      (let ((s (client-new-session client :permission-mode :plan)))
        (client-query s "add a greeting" :timeout 60)
        (client-wait (client-revise-plan-document s "in French") :timeout 60)
        (ok (eql 2 (event-value (client-plan-document s) "revision")))
        (let ((object (client-update-plan-document s +plan-md+)))
          (ok (eql 3 (event-value object "revision")) "a user revision"))
        (ok (typep (failure (client-update-plan-document s "no sections")) 'plan-format-error))
        (let ((path (client-save-plan-document s)))
          (ok (stringp path))
          (ok (equal +plan-md+ (uiop:read-file-string (uiop:parse-native-namestring path)))))
        (ok (equal "rejected" (event-value (client-reject-plan-document s) "status")))
        (ok (doc-of events "rejected"))))))

(deftest client-plan-doc-without-a-plan
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("hello"))
      (let ((s (client-new-session client)))
        (client-query s "hi" :timeout 60)
        (ok (null (client-plan-document s)))
        (ok (signals (client-approve-plan-document s) 'plan-document-not-found))
        (ok (signals (client-reject-plan-document s) 'plan-document-not-found))))))

(deftest client-plan-doc-ask-user-unavailable
  (with-project (project config) '()
    (with-test-client (client backend events project config
                       :steps (list (ask-step "French?") (propose-step)))
      (let ((s (client-new-session client :permission-mode :plan)))
        (client-query s "add a greeting" :timeout 60)
        (ok (equal +ask-user-unavailable+
                   (result-content (first (request-tool-results (second (scripted-requests backend)))))))))))

;;; --rpc.

(deftest rpc-plan-doc-flow
  (with-project (project config) (list (list "hello.sh" ""))
    (with-rpc (rpc backend project config :steps (list* (propose-step) (propose-step +plan-md-2+)
                                                        (execution-steps)))
      (let ((id (new-session rpc "permission_mode" "plan")))
        (call rpc "turn/start" "session_id" id "prompt" "add a greeting")
        (ok (equal "proposed" (event-value (rpc-result rpc id) "plan" "status")))
        (let ((got (call rpc "plan/get" "session_id" id)))
          (ok (equal +plan-md+ (event-value got "plan" "markdown"))))
        (ok (equal id (event-value (call rpc "plan/revise" "session_id" id "feedback" "in French")
                                   "session_id")))
        (ok (eql 2 (event-value (rpc-result rpc id :n 1) "plan" "revision")))
        (let ((approved (call rpc "plan/approve" "session_id" id "mode" "acceptEdits")))
          (ok (equal "approved" (event-value approved "plan" "status")))
          (ok (equal id (event-value approved "session_id"))))
        (ok (equal "executed" (event-value (rpc-result rpc id :n 2) "plan" "status")))
        (ok (equal (nl "echo hello") (read-file project "hello.sh")))
        (ok (rpc-client-events rpc :type "plan" :session-id id) "plan events are notifications")))))

;;; #65: approving a plan whose execution has started is refused
;;; (plan-document-state-error, -32031); approving with :execute nil and then
;;; again (ACP's session/set_mode, then session/prompt) still runs it once.

(defun stalled-execution-steps (seconds)
  "EXECUTION-STEPS whose first step waits SECONDS, so the turn is still running."
  (let ((steps (execution-steps)))
    (cons (list :stall seconds (first steps)) (rest steps))))

(defun executed-count (events)
  (count "executed" (events-of events "plan")
         :key (lambda (e) (event-value e "subtype")) :test #'equal))

(deftest client-plan-doc-approve-twice-runs-once
  (with-project (project config) (list (list "hello.sh" ""))
    (with-test-client (client backend events project config
                              :steps (list* (propose-step) (stalled-execution-steps 2)))
      (let ((s (client-new-session client :permission-mode :plan)))
        (client-query s "add a greeting" :timeout 60)
        (multiple-value-bind (object turn) (client-approve-plan-document s :mode :accept-edits :execute nil)
          (ok (equal "approved" (event-value object "status")))
          (ok (null turn) "approved, not run"))
        (multiple-value-bind (object turn) (client-approve-plan-document s)
          (ok (equal "approved" (event-value object "status")))
          (ok turn "the approved plan's execution turn starts")
          (let ((again (failure (client-approve-plan-document s))))
            (ok (typep again 'plan-document-state-error)
                (format nil "approving it again while it runs is refused, got ~a" (type-of again))))
          (ok (equal "executed" (event-value (client-wait turn :timeout 60) "plan" "status"))))
        (ok (typep (failure (client-approve-plan-document s)) 'plan-document-state-error))
        (ok (eql 1 (executed-count events)) "one execution")))))

(deftest rpc-plan-doc-approve-twice-runs-once
  (with-project (project config) (list (list "hello.sh" ""))
    (with-rpc (rpc backend project config :steps (list* (propose-step) (stalled-execution-steps 2)))
      (let ((id (new-session rpc "permission_mode" "plan")))
        (call rpc "turn/start" "session_id" id "prompt" "add a greeting")
        (rpc-result rpc id)
        (ok (equal "approved" (event-value (call rpc "plan/approve" "session_id" id "mode" "acceptEdits")
                                           "plan" "status")))
        (multiple-value-bind (code data) (fault rpc "plan/approve" "session_id" id "mode" "acceptEdits")
          (ok (eql -32031 code) (format nil "a second plan/approve is -32031, got ~a" code))
          (ok (equal "approved" (event-value data "status"))))
        (ok (equal "executed" (event-value (rpc-result rpc id :n 1) "plan" "status")))
        (multiple-value-bind (code data) (fault rpc "plan/approve" "session_id" id)
          (ok (eql -32031 code))
          (ok (equal "executed" (event-value data "status"))))
        (ok (eql 1 (count "executed" (rpc-client-events rpc :type "plan" :session-id id)
                          :key (lambda (e) (event-value e "subtype")) :test #'equal))
            "one execution")))))

(deftest rpc-plan-doc-update-save-reject
  (with-project (project config) '()
    (with-rpc (rpc backend project config :steps (list (propose-step)))
      (let ((id (new-session rpc "permission_mode" "plan")))
        (call rpc "turn/start" "session_id" id "prompt" "go")
        (rpc-result rpc id)
        (ok (eql 2 (event-value (call rpc "plan/update" "session_id" id "markdown" +plan-md-2+)
                                "plan" "revision")))
        (multiple-value-bind (code data) (fault rpc "plan/update" "session_id" id "markdown" "x")
          (ok (eql -32602 code))
          (ok (equalp #("Goal" "Steps") (event-value data "missing"))))
        (let ((path (event-value (call rpc "plan/save" "session_id" id) "path")))
          (ok (probe-file (uiop:parse-native-namestring path))))
        (ok (equal "rejected" (event-value (call rpc "plan/reject" "session_id" id) "plan" "status")))
        (multiple-value-bind (code data) (fault rpc "plan/approve" "session_id" id)
          (ok (eql -32031 code))
          (ok (equal "rejected" (event-value data "status"))))))))

(deftest rpc-plan-doc-not-found
  (with-project (project config) '()
    (with-rpc (rpc backend project config :steps '("hello"))
      (let ((id (new-session rpc)))
        (ok (eq :null (gethash "plan" (call rpc "plan/get" "session_id" id))))
        (multiple-value-bind (code data) (fault rpc "plan/approve" "session_id" id)
          (ok (eql -32030 code))
          (ok (equal "plan-document-not-found" (event-value data "condition"))))))))

(deftest rpc-plan-approve-on-a-preview-is-not-an-alias
  ;; #62 (0.17.0): plan/approve and plan/reject act only on plan documents; on
  ;; a session with only an open preview they answer -32030, and the preview
  ;; stays open for preview/apply and preview/reject.
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-rpc (rpc backend project config :steps (list (write-tool "a.txt" (nl "beta")) "Done."
                                                       (write-tool "a.txt" (nl "gamma")) "Done."))
      (let ((id (new-session rpc "permission_mode" "preview")))
        (call rpc "turn/start" "session_id" id "prompt" "beta")
        (rpc-result rpc id)
        (multiple-value-bind (code data) (fault rpc "plan/approve" "session_id" id)
          (ok (eql -32030 code) (format nil "plan/approve on a preview: ~a" code))
          (ok (equal "plan-document-not-found" (event-value data "condition"))))
        (ok (equal (nl "alpha") (read-file project "a.txt")) "nothing applied")
        (ok (equal "applied" (event-value (call rpc "preview/apply" "session_id" id) "subtype")))
        (ok (equal (nl "beta") (read-file project "a.txt")))
        (call rpc "turn/start" "session_id" id "prompt" "gamma")
        (rpc-result rpc id :n 1)
        (multiple-value-bind (code data) (fault rpc "plan/reject" "session_id" id)
          (ok (eql -32030 code) (format nil "plan/reject on a preview: ~a" code))
          (ok (equal "plan-document-not-found" (event-value data "condition"))))
        (ok (equal "discarded" (event-value (call rpc "preview/reject" "session_id" id) "subtype")))))))

(deftest rpc-plan-doc-error-codes
  (multiple-value-bind (code message data)
      (rpc-error-for (make-condition 'plan-document-not-found :designator "x"))
    (declare (ignore message))
    (ok (eql -32030 code))
    (ok (equal "plan-document-not-found" (event-value data "condition"))))
  (ok (eql -32031 (rpc-error-for (make-condition 'plan-document-state-error :status :rejected)))))
