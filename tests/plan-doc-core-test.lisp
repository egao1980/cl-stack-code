(in-package #:cl-stack-code/tests)

;;; H5c-0: the interactive core's plan document events, replies and commands
;;; (src/plan-docs.lisp header, INTERACTIVE). Pure: no program, no files.

(defparameter +doc-id+ "abcdef0123456789abcdef0123456789")

(defun doc-steps (&rest statuses)
  (loop for status in statuses
        for i from 1
        collect (list :index i :text (format nil "step ~d" i) :status status)))

(defun doc-opened-state (&rest keys)
  (feed (apply #'fresh-state :permission-mode :plan keys)
        (list :plan-doc-opened :id +doc-id+ :path "/tmp/docs/plan.md" :area "/tmp/area/")))

(defun doc-proposed-state (&key (revision 1))
  (feed (doc-opened-state)
        (list :plan-proposed :id +doc-id+ :revision revision :title "Add a greeting"
                             :markdown "# Add a greeting" :steps (doc-steps :pending :pending))))

(deftest plan-doc-core-opened
  (let ((s (doc-opened-state)))
    (ok (equal +doc-id+ (getf (state-plan-document s) :id)))
    (ok (eq :drafting (getf (state-plan-document s) :status)))
    (ok (null (state-plan-document-prompt s)))
    (ok (eq :notice (entry-kind (last-entry s))))
    (ok (has "plan abcdef01" (entry-text (last-entry s))))
    (ok (has "/tmp/area/" (entry-text (last-entry s))) "where the exploration runs")))

(deftest plan-doc-core-proposed
  (let ((s (doc-proposed-state)))
    (ok (eq :plan-doc (state-plan-document-prompt s)) "idle: the plan dialog")
    (ok (eql 1 (getf (state-plan-document s) :revision)))
    (ok (eq :proposed (getf (state-plan-document s) :status)))
    (let ((e (last-entry s)))
      (ok (eq :plan-document (entry-kind e)))
      (ok (equal +doc-id+ (entry-id e)))
      (ok (has "# Add a greeting" (entry-text e))))))

(deftest plan-doc-core-proposed-while-busy
  (let ((s (feed (doc-opened-state) '(:submit "go"))))
    (feed s (list :plan-proposed :id +doc-id+ :revision 1 :title "T" :markdown "# T"
                                 :steps (doc-steps :pending)))
    (ok (null (state-plan-document-prompt s)) "no dialog while a turn runs")
    (ok (eq :plan-document (entry-kind (last-entry s))))))

(deftest-parametrize plan-doc-core-replies
    ((choice effects mode)
     :ids ("accept" "ask" "preview" "edit" "reject" "save")
     (:approve-accept '((:approve-plan-document :mode :accept-edits)) :accept-edits)
     (:approve-ask '((:approve-plan-document :mode :default)) :default)
     (:approve-preview '((:approve-plan-document :mode :preview)) :preview)
     (:edit '((:edit-plan-document)) :plan)
     (:reject '((:reject-plan-document)) :plan)
     (:save '((:save-plan-document)) :plan))
  (let ((s (doc-proposed-state)))
    (ok (equal effects (effects s (list :reply choice))))
    (ok (null (state-plan-document-prompt s)))
    (ok (eq mode (state-permission-mode s)) "approval switches to the execution mode")))

(deftest plan-doc-core-revise
  (let ((s (doc-proposed-state)))
    (ok (null (effects s '(:reply :revise))))
    (ok (null (state-plan-document-prompt s)))
    (ok (equal "plan abcdef01 r1: send your feedback to revise it, /approve to run it"
               (entry-text (last-entry s))))
    (ok (eq :plan (state-permission-mode s)))
    (ok (equal '((:run "in French")) (effects s '(:submit "in French")))
        "the next message is a plan turn")))

(deftest plan-doc-core-escape-revises
  (let ((s (doc-proposed-state)))
    (ok (null (effects s '(:interrupt))))
    (ok (null (state-plan-document-prompt s)))
    (ok (has "send your feedback to revise it" (entry-text (last-entry s))))
    (ok (state-plan-document s) "still waiting")))

(deftest-parametrize plan-doc-core-commands
    ((command effects)
     :ids ("plan" "approve" "approve-accept" "approve-ask" "approve-preview" "reject" "save")
     ("/plan" '((:show-plan-document)))
     ("/approve" '((:approve-plan-document :mode :accept-edits)))
     ("/approve accept" '((:approve-plan-document :mode :accept-edits)))
     ("/approve ask" '((:approve-plan-document :mode :default)))
     ("/approve preview" '((:approve-plan-document :mode :preview)))
     ("/reject" '((:reject-plan-document)))
     ("/save-plan" '((:save-plan-document))))
  (let ((s (doc-proposed-state)))
    (feed s '(:reply :revise))
    (ok (equal effects (effects s (list :submit command))) command)))

(deftest plan-doc-core-approve-usage
  (let ((s (doc-proposed-state)))
    (feed s '(:reply :revise))
    (ok (null (effects s '(:submit "/approve sometimes"))))
    (ok (eq :error (entry-kind (last-entry s))))
    (ok (has "/approve [accept|ask|preview]" (entry-text (last-entry s))))))

(deftest plan-doc-core-commands-without-a-plan
  (let ((s (fresh-state :permission-mode :plan)))
    (ok (null (effects s '(:submit "/plan"))))
    (ok (equal "no plan yet" (entry-text (last-entry s))))
    (ok (null (effects s '(:submit "/save-plan"))))
    (ok (equal "no plan yet" (entry-text (last-entry s))))))

(deftest plan-doc-core-waiting-plan
  (let ((s (doc-proposed-state)))
    (feed s '(:reply :revise))
    (ok (null (effects s '(:submit "/clear"))))
    (ok (equal "plan abcdef01 is waiting: /approve or /reject it first" (entry-text (last-entry s))))
    (ok (null (effects s '(:submit "/permissions acceptEdits"))) "switching modes is fine")
    (ok (eq :accept-edits (state-permission-mode s)))
    (ok (state-plan-document s) "the plan waits")))

(deftest plan-doc-core-checklist
  (let ((s (doc-proposed-state)))
    (feed s '(:reply :approve-accept)
          (list :plan-step :id +doc-id+ :steps (doc-steps :in-progress :pending))
          (list :plan-step :id +doc-id+ :steps (doc-steps :done :in-progress)))
    (let ((lists (remove-if-not (lambda (e) (eq :plan-steps (entry-kind e))) (state-transcript s))))
      (ok (= 1 (length lists)) "one checklist, replaced in place")
      (ok (has "☑ 1. step 1" (entry-text (first lists))))
      (ok (has "◐ 2. step 2" (entry-text (first lists)))))
    (ok (equal '(:done :in-progress) (mapcar (lambda (p) (getf p :status))
                                              (getf (state-plan-document s) :steps))))))

(deftest plan-doc-core-executed
  (let ((s (doc-proposed-state)))
    (feed s '(:reply :approve-accept)
          (list :plan-executed :id +doc-id+ :status :executed
                               :lines '("plan abcdef01 r1: 2 of 2 steps done" "files: 1 planned, 1 changed")
                               :diff "diff --git a/hello.sh b/hello.sh"))
    (ok (eq :plan-result (state-plan-document-prompt s)) "idle: the result dialog")
    (let ((e (last-entry s)))
      (ok (eq :plan-result (entry-kind e)))
      (ok (has "2 of 2 steps done" (entry-text e)))
      (ok (has "diff --git" (entry-text e))))))

(deftest-parametrize plan-doc-core-result-replies
    ((choice effects)
     :ids ("keep" "rewind-files" "save")
     (:keep nil)
     (:rewind-files '((:rewind 1 :parts (:files))))
     (:save '((:save-plan-document))))
  (let ((s (doc-proposed-state)))
    (feed s '(:reply :approve-accept)
          (list :plan-executed :id +doc-id+ :status :executed :lines '("x") :diff ""))
    (ok (equal effects (effects s (list :reply choice))))
    (ok (null (state-plan-document-prompt s)))))

(deftest-parametrize plan-doc-core-closed
    ((status text)
     :ids ("rejected" "executed" "interrupted")
     (:rejected "plan abcdef01 rejected")
     (:executed "plan abcdef01 done")
     (:interrupted "plan abcdef01 stopped before its end: /approve runs the remaining steps"))
  (let ((s (doc-proposed-state)))
    (feed s (list :plan-doc-closed :id +doc-id+ :status status))
    (ok (equal text (entry-text (last-entry s))))
    (ok (eq (eq status :interrupted) (and (state-plan-document s) t)))))

(deftest plan-doc-core-help
  (dolist (needle '("/plan" "/approve [accept|ask|preview]" "/reject" "/save-plan" "/preview"))
    (ok (has needle +help-text+) needle))
  (ok (has "plan" (find-if (lambda (line) (has "/permissions" line))
                           (uiop:split-string +help-text+ :separator '(#\Newline)))))
  (ok (has "preview" (find-if (lambda (line) (has "/permissions" line))
                              (uiop:split-string +help-text+ :separator '(#\Newline))))
      "/permissions names the new mode"))
