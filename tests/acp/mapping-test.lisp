(in-package #:cl-stack-code/acp/tests)

;;; ACP-2: the mapping tables (src/acp/mapping.lisp header), pure: SDK
;;; event objects in, acp-protocol objects out. The same tables are checked
;;; end to end over the loopback (loopback-test) and a child (process-test).

;;; The core gains the thinking event.

(deftest acp-core-thinking-event-type
  (ok (member "thinking_delta" +event-types+ :test #'string=)
      "the SDK delivers thinking deltas (ACP-2)")
  (ok (eql (1+ (position "text_delta" +event-types+ :test #'string=))
           (position "thinking_delta" +event-types+ :test #'string=))
      "right after text_delta")
  (ok (equal "unit" (car (last +event-types+))) "unit stays last (H8d)"))

;;; Modes.

(deftest acp-mode-ids
  (ok (equal '("default" "acceptEdits" "bypassPermissions" "plan") +acp-mode-ids+)))

(deftest-parametrize acp-mode-mapping
    ((id mode)
     :ids ("default" "acceptEdits" "bypassPermissions" "plan")
     ("default" :default)
     ("acceptEdits" :accept-edits)
     ("bypassPermissions" :bypass-permissions)
     ("plan" :plan))
  (ok (eq mode (mode-id-permission-mode id)))
  (ok (equal id (permission-mode-mode-id mode))))

(deftest acp-mode-mapping-edges
  (ok (null (mode-id-permission-mode "Default")) "exact case")
  (ok (null (mode-id-permission-mode "ask")))
  (ok (null (mode-id-permission-mode nil)))
  (ok (equal "default" (permission-mode-mode-id nil)) "NIL is the default mode")
  (ok (typep (failure (permission-mode-mode-id :yolo)) 'code-usage-error)))

;;; Permission.

(deftest acp-permission-options
  (ok (equal '(("allow_once" "Allow once" "allow_once")
               ("allow_always" "Always allow" "allow_always")
               ("reject_once" "Reject" "reject_once")
               ("reject_always" "Reject all" "reject_always"))
             +acp-permission-options+))
  (ok (equal acp:+acp-permission-option-kinds+ (mapcar #'third +acp-permission-options+))
      "one option per ACP kind, in the schema's order"))

(deftest-parametrize acp-permission-mapping
    ((kind kind-string decision)
     :ids ("allow-once" "allow-always" "reject-once" "reject-always")
     (:allow-once "allow_once" :once)
     (:allow-always "allow_always" :always)
     (:reject-once "reject_once" :reject)
     (:reject-always "reject_always" :reject-all))
  (ok (eq decision (permission-kind-decision kind)))
  (ok (eq decision (permission-kind-decision kind-string)) "the wire string too")
  (ok (eq kind (decision-permission-kind decision)) "and back"))

(deftest acp-permission-mapping-edges
  (ok (null (permission-kind-decision :cancelled)) "cancelled answers nothing")
  (ok (null (permission-kind-decision :something-else)))
  (ok (null (decision-permission-kind :interrupt)))
  (ok (every (lambda (d) (member d (mapcar #'cdr +approval-decision-names+)))
             (mapcar #'permission-kind-decision '(:allow-once :allow-always :reject-once :reject-always)))
      "every decision is one CLIENT-RESPOND-APPROVAL takes"))

;;; Stop reasons.

(defun result-event (subtype &optional (error :null))
  (args "type" "result" "subtype" subtype "is_error" (not (equal subtype "success"))
        "result" "" "error" error "num_turns" 1 "session_id" "s"))

(deftest-parametrize acp-stop-reasons
    ((result reason)
     :ids ("success" "max-turns" "interrupted" "failed")
     ((result-event "success") "end_turn")
     ((result-event "error_max_turns") "max_turn_requests")
     ((result-event "error_during_execution" "interrupted") "cancelled")
     ((result-event "error_during_execution" "boom") nil))
  (ok (equal reason (result-stop-reason result)))
  (ok (or (null reason) (member (result-stop-reason result) acp:+acp-stop-reasons+ :test #'string=))))

;;; Tool kinds.

(deftest-parametrize acp-tool-kinds
    ((name kind)
     :ids ("read" "ls" "write" "edit" "multi_edit" "grep" "glob" "bash" "job_output" "other")
     ("read" "read") ("ls" "read")
     ("write" "edit") ("edit" "edit") ("multi_edit" "edit")
     ("grep" "search") ("glob" "search")
     ("bash" "execute") ("job_output" "execute")
     ("lisp_eval" "other"))
  (ok (equal kind (tool-kind name)))
  (ok (member (tool-kind name) acp:+acp-tool-kinds+ :test #'string=)))

;;; Events → updates.

(defparameter *cwd* (uiop:ensure-directory-pathname (uiop:temporary-directory)))

(defun one-update (event)
  (let ((updates (event-updates event :cwd *cwd*)))
    (ok (= 1 (length updates)) (d updates))
    (first updates)))

(defun encodes-p (update)
  "UPDATE dumps to JSON (a valid model object)."
  (and (stringp (acp:encode-acp-object update)) t))

(deftest acp-event-text-delta
  (let ((u (one-update (args "type" "text_delta" "session_id" "s" "step" 1 "text" "Hello "))))
    (ok (typep u 'acp:update-agent-message-chunk))
    (ok (typep (acp:content u) 'acp:text-content))
    (ok (equal "Hello " (chunk-text u)))
    (ok (encodes-p u))))

(deftest acp-event-thinking-delta
  (let ((u (one-update (args "type" "thinking_delta" "session_id" "s" "step" 1 "text" "Let me "))))
    (ok (typep u 'acp:update-agent-thought-chunk))
    (ok (equal "Let me " (chunk-text u)))
    (ok (encodes-p u))))

(deftest acp-event-tool-use
  (let* ((input (args "file_path" "a.txt"))
         (u (one-update (args "type" "tool_use" "session_id" "s" "step" 1
                              "id" "call-1-1" "name" "read" "input" input))))
    (ok (typep u 'acp:update-tool-call))
    (ok (equal "call-1-1" (acp:tool-call-id u)))
    (ok (equal (tool-call-summary "read" input) (acp:title u)))
    (ok (equal "read" (slot u 'acp:kind)))
    (ok (equal "pending" (slot u 'acp:status)))
    (ok (equal "a.txt" (jget (slot u 'acp:raw-input) "file_path")) "rawInput is the input")
    (let ((locations (coerce (or (slot u 'acp:locations) #()) 'list)))
      (ok (= 1 (length locations)))
      (ok (equal (native (merge-pathnames "a.txt" *cwd*)) (acp:path (first locations)))
          "absolute, under CWD"))
    (ok (null (diffs u)) "no diff from the pure table")
    (ok (encodes-p u))))

(deftest acp-event-tool-use-without-a-path
  (let ((u (one-update (args "type" "tool_use" "session_id" "s" "step" 2
                             "id" "call-2-1" "name" "bash" "input" (args "command" "ls")))))
    (ok (equal "execute" (slot u 'acp:kind)))
    (ok (zerop (length (or (slot u 'acp:locations) #()))))))

(deftest acp-event-tool-use-path-key
  (let ((u (one-update (args "type" "tool_use" "session_id" "s" "step" 1
                             "id" "call-1-1" "name" "ls" "input" (args "path" "src")))))
    (ok (equal (list (native (merge-pathnames "src" *cwd*)))
               (map 'list #'acp:path (or (slot u 'acp:locations) #()))))))

(deftest-parametrize acp-event-tool-result
    ((status is-error expected)
     :ids ("done" "error" "denied")
     ("done" nil "completed")
     ("error" t "failed")
     ("denied" t "failed"))
  (let ((u (one-update (args "type" "tool_result" "session_id" "s" "step" 1 "id" "call-1-1"
                             "name" "read" "status" status "is_error" is-error
                             "content" "alpha"))))
    (ok (typep u 'acp:update-tool-call-update))
    (ok (equal "call-1-1" (acp:tool-call-id u)))
    (ok (equal expected (slot u 'acp:status)))
    (ok (equal '("alpha") (text-contents u)) "the result text as one content")
    (ok (encodes-p u))))

(defun plan-event (subtype &rest changes)
  (args "type" "plan" "subtype" subtype "session_id" "s" "plan_id" "abc"
        "changes" (map 'vector (lambda (c) (args "path" (second c) "kind" (first c))) changes)))

(deftest acp-event-plan-projected
  (let ((u (one-update (plan-event "projected" '("modified" "a.txt") '("added" "b.txt")))))
    (ok (typep u 'acp:update-plan))
    (let ((entries (coerce (acp:entries u) 'list)))
      (ok (equal '("modified a.txt" "added b.txt") (mapcar #'acp:content entries)))
      (ok (every (lambda (e) (equal "pending" (acp:status e))) entries))
      (ok (every (lambda (e) (equal "medium" (acp:priority e))) entries)))
    (ok (encodes-p u))))

(deftest acp-event-plan-applied-and-discarded
  (let ((u (one-update (plan-event "applied" '("modified" "a.txt")))))
    (ok (equal '("completed") (map 'list #'acp:status (acp:entries u)))))
  (let ((u (one-update (plan-event "discarded"))))
    (ok (typep u 'acp:update-plan))
    (ok (zerop (length (acp:entries u))) "an empty checklist")))

(deftest-parametrize acp-events-without-updates
    ((event)
     :ids ("system" "assistant" "approval_request" "approval_resolved" "result" "plan-opened"
           "steering" "session")
     ((args "type" "system" "subtype" "init" "session_id" "s"))
     ((args "type" "assistant" "session_id" "s" "step" 1 "text" "x" "finish_reason" "stop"))
     ((args "type" "approval_request" "session_id" "s" "step" 1 "id" "call-1-1"
            "name" "write" "input" (args "file_path" "a.txt") "summary" "write a.txt" "preview" :null))
     ((args "type" "approval_resolved" "session_id" "s" "id" "call-1-1" "decision" "once"))
     ((result-event "success"))
     ((plan-event "opened"))
     ((args "type" "steering" "subtype" "taken" "session_id" "s" "texts" #("x")))
     ((args "type" "session" "subtype" "forked" "from" "a" "session_id" "b")))
  (ok (null (event-updates event :cwd *cwd*))))
