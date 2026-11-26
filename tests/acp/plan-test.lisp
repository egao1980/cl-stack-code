(in-package #:cl-stack-code/acp/tests)

;;; H5c-0 over ACP (src/plan-docs.lisp header, "ACP"; .team-solve/task.md,
;;; "ACP" 1–7): plan documents as ACP plan updates, their approval as a
;;; session/request_permission with +ACP-PLAN-APPROVAL-OPTIONS+, and
;;; session/set_mode out of plan as approval. Loopback, scripted mock LLM.

(defun plan-updates (client)
  (client-updates client 'acp:update-plan))

(defun entry-contents (update)
  (map 'list #'acp:content (acp:entries update)))

(defun entry-statuses (update)
  (map 'list #'acp:status (acp:entries update)))

(defun entry-priorities (update)
  (map 'list #'acp:priority (acp:entries update)))

(defun mode-updates (client)
  "The currentModeId of every current_mode_update, oldest first."
  (mapcar #'acp:current-mode-id (client-updates client 'acp:update-current-mode-update)))

(defun option-triples (request)
  "REQUEST's options as (optionId kind name), the form of +ACP-PLAN-APPROVAL-OPTIONS+."
  (map 'list (lambda (o) (list (acp:option-id o) (acp:kind o) (acp:name o)))
       (acp:options request)))

(defun wire-position (ra &rest needles)
  "The index of the first wire-log line containing every NEEDLE, or NIL."
  (position-if (lambda (e) (every (lambda (n) (search n (cdr e))) needles))
               (wire-log ra)))

(defun in-order-p (&rest positions)
  "Every position is present and they strictly increase."
  (and (every #'integerp positions)
       (apply #'< positions)))

(defun subsequence-p (wanted list)
  "The elements of WANTED occur in LIST in this order (EQUAL), maybe with
others between them."
  (loop with rest = list
        for w in wanted
        for tail = (member w rest :test #'equal)
        unless tail return nil
        do (setf rest (cdr tail))
        finally (return t)))

(defparameter +plan-update-line+ "\"sessionUpdate\":\"plan\""
  "How a full plan update looks on the wire (not plan_update).")

(defun doc-step-texts (doc)
  (mapcar #'plan-step-text (plan-document-steps doc)))

;;; 1. Five session modes.

(deftest acp-plan-session-modes
  (with-project (project config) '()
    (with-loopback (ra client project config)
      (let ((modes (slot (req (new-session ra project)) 'acp:modes)))
        (ok modes "modes")
        (when modes
          (let ((available (coerce (acp:available-modes modes) 'list)))
            (ok (equal '("default" "acceptEdits" "bypassPermissions" "plan" "preview")
                       (mapcar #'acp:id available))
                "five ids, plan and preview apart")
            (ok (equal +permission-mode-names+ (mapcar #'acp:id available))
                "in +permission-mode-names+ order")
            (ok (equal "Plan" (acp:name (find "plan" available :key #'acp:id :test #'equal))))
            (ok (equal "Preview" (acp:name (find "preview" available :key #'acp:id :test #'equal))))))))))

;;; 2. propose_plan → a plan update, then the approval request.

(deftest acp-plan-proposed-asks-for-approval
  (with-project (project config) '()
    (with-loopback (ra client project config :plan-area :copy :permission "plan"
                    :steps (list (propose-step)))
      (let ((sid (req (new-session-id ra project))))
        (req (set-mode ra sid "plan"))
        (ok (equal "end_turn" (req (stop-reason ra sid "plan a greeting") :seconds 90)))
        (let ((doc (only-plan-doc project config))
              (update (first (plan-updates client)))
              (request (first (permission-requests client))))
          (ok (= 1 (length (scripted-requests backend))) "the run ended after propose_plan")
          (ok update "a plan update")
          (when (and doc update)
            (ok (= 2 (length (acp:entries update))))
            (ok (equal (doc-step-texts doc) (entry-contents update)) "entries = the steps")
            (ok (equal '("pending" "pending") (entry-statuses update)))
            (ok (equal '("medium" "medium") (entry-priorities update))))
          (ok (= 1 (length (permission-requests client))) "one approval request")
          (ok request)
          (when request
            (ok (equal +acp-plan-approval-options+ (option-triples request))
                "+acp-plan-approval-options+, in order")
            (let ((tc (acp:tool-call request)))
              (ok (equal "call-1-1" (acp:tool-call-id tc)) "the propose_plan call")
              (ok (equal "switch_mode" (slot tc 'acp:kind)))
              (when doc
                (ok (member (doc-md doc) (text-contents tc) :test #'equal)
                    "the markdown as content"))))
          (ok (in-order-p (wire-position ra +plan-update-line+)
                          (wire-position ra "\"method\":\"session/request_permission\""))
              "the plan update comes first"))))))

;;; 3. "acceptEdits": the execution in the same prompt.

(deftest acp-plan-approve-accept-edits
  (with-project (project config) '()
    (with-loopback (ra client project config :plan-area :copy :permission "acceptEdits"
                    :steps (list (propose-step)
                                 (update-step 1 "in_progress")
                                 (write-step "hello.sh" "echo hello")
                                 (update-step 1 "done")
                                 (update-step 2 "in_progress")
                                 (update-step 2 "done")
                                 "Done."))
      (let ((sid (req (new-session-id ra project))))
        (req (set-mode ra sid "plan"))
        (clear-client client)
        (ok (equal "end_turn" (req (stop-reason ra sid "plan a greeting") :seconds 90)))
        (ok (equal "echo hello" (read-file project "hello.sh")) "the edit landed in the project")
        (ok (= 1 (length (permission-requests client)))
            "only the approval asked (acceptEdits)")
        (ok (equal "acceptEdits" (car (last (mode-updates client))))
            "a current_mode_update to acceptEdits")
        (ok (in-order-p (wire-position ra "\"sessionUpdate\":\"current_mode_update\"" "acceptEdits")
                        (wire-position ra +plan-update-line+ "\"in_progress\""))
            "the mode update before the execution's steps")
        (let ((statuses (mapcar #'entry-statuses (plan-updates client))))
          (ok (equal '("pending" "pending") (first statuses)) "proposed")
          (ok (subsequence-p '(("in_progress" "pending")
                               ("completed" "pending")
                               ("completed" "in_progress")
                               ("completed" "completed"))
                             statuses)
              "the whole list again per update_plan")
          (ok (equal '("completed" "completed") (car (last statuses)))))
        (ok (has +plan-execution-preamble+ (request-texts (second (scripted-requests backend))))
            "the execution turn's prompt is the plan")
        (let ((doc (only-plan-doc project config)))
          (ok (and doc (eq :executed (plan-document-status doc))))
          (ok (and doc (eq :accept-edits (plan-document-execution-mode doc)))))))))

;;; 4. "plan": keep planning; the next prompt revises.

(deftest acp-plan-keep-planning
  (with-project (project config) '()
    (with-loopback (ra client project config :plan-area :copy :permission "plan"
                    :steps (list (propose-step) (propose-step +plan-md-2+)))
      (let ((sid (req (new-session-id ra project))))
        (req (set-mode ra sid "plan"))
        (ok (equal "end_turn" (req (stop-reason ra sid "plan a greeting") :seconds 90)))
        (ok (= 1 (length (scripted-requests backend))) "nothing ran after the answer")
        (let ((doc (only-plan-doc project config)))
          (ok (and doc (eq :proposed (plan-document-status doc))) "the document stays proposed")
          (ok (and doc (eql 1 (plan-document-revision doc)))))
        (clear-client client)
        (ok (equal "end_turn" (req (stop-reason ra sid "in French, and the README") :seconds 90)))
        (ok (has "in French, and the README" (request-text (last-request backend)))
            "the prompt is the feedback")
        (let ((update (car (last (plan-updates client)))))
          (ok update "a new plan update")
          (when update
            (ok (= 3 (length (acp:entries update))) "revision 2's steps")
            (ok (equal '("pending" "pending" "pending") (entry-statuses update)))))
        (ok (= 1 (length (permission-requests client))) "asked again")
        (let ((doc (only-plan-doc project config)))
          (ok (and doc (eql 2 (plan-document-revision doc))))
          (ok (and doc (eq :proposed (plan-document-status doc)))))))))

;;; 5. "reject".

(deftest acp-plan-reject
  (with-project (project config) '()
    (with-loopback (ra client project config :plan-area :copy :permission "reject"
                    :steps (list (propose-step)))
      (let ((sid (req (new-session-id ra project))))
        (req (set-mode ra sid "plan"))
        (ok (equal "end_turn" (req (stop-reason ra sid "plan a greeting") :seconds 90)))
        (let ((updates (plan-updates client)))
          (ok (>= (length updates) 2) "proposed, then rejected")
          (when updates
            (ok (= 2 (length (acp:entries (first updates)))) "proposed first")
            (ok (zerop (length (acp:entries (car (last updates))))) "then no entries")))
        (ok (null (read-file project "hello.sh")) "nothing ran")
        (ok (= 1 (length (scripted-requests backend))))
        (let ((doc (only-plan-doc project config)))
          (ok (and doc (eq :rejected (plan-document-status doc)))))))))

;;; 6. session/set_mode out of plan approves; the next prompt executes.

(deftest acp-plan-set-mode-approves
  (with-project (project config) '()
    (with-loopback (ra client project config :plan-area :copy :permission "plan"
                    :steps (list (propose-step)
                                 (update-step 1 "in_progress")
                                 (write-step "hello.sh" "echo hello")
                                 (update-step 1 "done")
                                 "Done."))
      (let ((sid (req (new-session-id ra project))))
        (req (set-mode ra sid "plan"))
        (ok (equal "end_turn" (req (stop-reason ra sid "plan a greeting") :seconds 90)))
        (ok (typep (req (set-mode ra sid "default")) 'acp:set-session-mode-response))
        (let ((doc (only-plan-doc project config)))
          (ok (and doc (eq :approved (plan-document-status doc))) "set_mode approved it")
          (ok (and doc (eq :default (plan-document-execution-mode doc))) "under that mode"))
        (ok (= 1 (length (scripted-requests backend))) "set_mode itself runs nothing")
        ;; the execution's write asks in default mode: allow it
        (setf (client-permission client) 'acp:allow-once)
        (clear-client client)
        (ok (equal "end_turn" (req (stop-reason ra sid "also log it") :seconds 90)))
        (let ((text (request-texts (second (scripted-requests backend)))))
          (ok (has +plan-execution-preamble+ text) "the next prompt executes the plan")
          (ok (has "also log it" text) "its text as extra instructions"))
        (ok (equal "echo hello" (read-file project "hello.sh")))
        (ok (= 1 (length (permission-requests client))) "default mode: the write asked")
        (ok (subsequence-p '(("in_progress" "pending") ("completed" "pending"))
                           (mapcar #'entry-statuses (plan-updates client))))
        (let ((doc (only-plan-doc project config)))
          (ok (and doc (eq :executed (plan-document-status doc)))))))))

;;; 7. Preview events give no plan update (the H5a events, renamed).

(defun preview-event (subtype &rest changes)
  (args "type" "preview" "subtype" subtype "session_id" "s" "preview_id" "abc"
        "changes" (map 'vector (lambda (c) (args "path" (second c) "kind" (first c))) changes)))

(deftest-parametrize acp-plan-preview-events-without-updates
    ((subtype)
     :ids ("opened" "reopened" "projected" "applied" "rebased" "drift" "discarded")
     ("opened") ("reopened") ("projected") ("applied") ("rebased") ("drift") ("discarded"))
  (ok (null (event-updates (preview-event subtype '("modified" "a.txt"))
                           :cwd (uiop:ensure-directory-pathname (uiop:temporary-directory))))))
