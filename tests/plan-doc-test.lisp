(in-package #:cl-stack-code/tests)

;;; H5c-0: the plan document API, the markdown format, the tool policy and the
;;; tool source (src/plan-docs.lisp header). No LLM.

;;; Constants and given code.

(deftest plan-doc-constants
  (ok (equal '(:drafting :proposed :approved :executed :interrupted :rejected)
             +plan-document-statuses+))
  (ok (equal '(:pending :in-progress :done) +plan-step-statuses+))
  (ok (equal '(:default :spec) +plan-templates+))
  (ok (equal '(:default :accept-edits :bypass-permissions :preview) +plan-execution-modes+))
  (ok (equal ".plan-scratch" +plan-scratch-directory-name+))
  (ok (equal "docs/plans" +default-plan-save-directory+))
  (ok (equal '("propose_plan" "ask_user" "update_plan") +plan-tool-names+))
  (ok (equal '(:approve-accept :approve-ask :approve-preview :edit :revise :reject :save)
             (mapcar #'first +plan-document-choices+)))
  (ok (equal '(:keep :rewind-files :save) (mapcar #'first +plan-result-choices+)))
  (ok (equal '("acceptEdits" "default" "preview" "plan" "reject")
             (mapcar #'first +acp-plan-approval-options+)))
  (ok (has "propose_plan" +plan-mode-section+))
  (ok (has ".plan-scratch/" +plan-mode-section+))
  (ok (has "update_plan" +plan-execution-preamble+))
  (ok (has "\"preview\"" +plan-mode-migration-notice+))
  (dolist (heading '("## Goal" "## Findings" "## Steps" "## Files to change" "## Risks" "## Test plan"))
    (ok (has heading +default-plan-template+) heading))
  (dolist (heading '("## Requirements" "## Design" "## Tasks"))
    (ok (has heading +spec-plan-template+) heading)))

(deftest plan-doc-directory
  (with-project (project config) '()
    (let ((dir (project-plan-docs-dir project config)))
      (ok (uiop:subpathp dir (data-dir-of config)) "under the data directory")
      (ok (search "/plan-docs/" (namestring dir)))
      (ok (not (uiop:subpathp dir project)) "never inside the project")
      (ok (not (equal (namestring dir)
                      (namestring (plans-directory project :data-dir (data-dir-of config)))))
          "beside the preview areas, not among them"))))

(deftest plan-doc-policy-is-a-policy
  (ok (typep (stack-policy:find-policy 'plan-mode-tools) 'stack-policy:policy))
  (flet ((decide (action resource)
           (stack-policy:decision-effect
            (stack-policy:evaluate-policy 'plan-mode-tools
                                          (list :action action :resources (list resource)
                                                :context '((mode plan)))))))
    (ok (eq :forbid (decide "write" "path:src/a.lisp")))
    (ok (eq :forbid (decide "edit" "path:a.txt")))
    (ok (eq :forbid (decide "multi_edit" "path:a.txt")))
    (ok (eq :permit (decide "write" "path:.plan-scratch/try.sh")) "scratch is writable")
    (ok (eq :permit (decide "edit" "path:.plan-scratch/notes.md")))
    (ok (eq :forbid (decide "write" "path:.plan-scratchy/x")) "a prefix is not the directory")
    (ok (eq :forbid (decide "update_plan" "*")))
    (ok (not (eq :forbid (decide "read" "path:a.txt"))) "reads are not refused")
    (ok (not (eq :forbid (decide "bash" "bash:make test"))) "the shell is not this policy's")
    (ok (not (eq :forbid (decide "propose_plan" "*")))))
  (let ((d (stack-policy:evaluate-policy 'plan-mode-tools
                                         '(:action "write" :resources ("path:a.txt")
                                           :context ((mode plan))))))
    (ok (equal +plan-mode-edit-feedback+ (stack-policy:decision-feedback d)) "the refusal says why")))

(deftest plan-doc-permission-policy-adapter
  (let ((policy (plan-mode-permission-policy)))
    (ok (functionp policy))
    (multiple-value-bind (effect rule) (funcall policy "write" '("path:src/a.lisp") :allow)
      (ok (eq :deny effect))
      (ok (a:permission-rule-p rule))
      (ok (equal +plan-mode-edit-feedback+ (a:permission-rule-feedback rule))))
    (ok (null (funcall policy "write" '("path:.plan-scratch/x.sh") :allow)) "a permit tightens nothing")
    (ok (null (funcall policy "read" '("path:a.txt") :allow)) "undecided: no opinion")
    (ok (eq :deny (funcall policy "multi_edit" '("path:.plan-scratch/x" "path:a.txt") :allow))
        "one forbidden resource is enough")))

;;; Opening and reading back.

(deftest plan-doc-open
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config :session-id "0123456789abcdef0123456789abcdef")))
      (ok (plan-document-p doc))
      (ok (= 32 (length (plan-document-id doc))))
      (ok (every (lambda (c) (digit-char-p c 16)) (plan-document-id doc)))
      (ok (eq :drafting (plan-document-status doc)))
      (ok (eql 0 (plan-document-revision doc)))
      (ok (eq :default (plan-document-template doc)))
      (ok (null (plan-document-steps doc)))
      (ok (equal "0123456789abcdef0123456789abcdef" (plan-document-session-id doc)))
      (ok (doc-file doc "meta.sexp") "meta.sexp is written")
      (ok (null (doc-file doc "plan.md")) "no plan.md before a proposal")
      (ok (uiop:subpathp (plan-document-directory doc) (project-plan-docs-dir project config)))
      (let ((meta (with-standard-io-syntax
                    (let ((*read-eval* nil) (*package* (find-package :keyword)))
                      (read-from-string (doc-file doc "meta.sexp"))))))
        (ok (eql 1 (getf meta :format)))
        (ok (equal (plan-document-id doc) (getf meta :id)))
        (ok (eq :drafting (getf meta :status)))))))

(deftest plan-doc-reopen-and-list
  (with-project (project config) '()
    (let* ((a (fresh-plan-doc project config))
           (b (fresh-plan-doc project config :template :spec))
           (dir (project-plan-docs-dir project config)))
      (propose-plan-revision a +plan-md+)
      (let ((again (reopen-plan-document dir (plan-document-id a))))
        (ok (eq :proposed (plan-document-status again)))
        (ok (eql 1 (plan-document-revision again)))
        (ok (equal "Add a greeting" (plan-document-title again)))
        (ok (= 2 (length (plan-document-steps again)))))
      (ok (equal (list (plan-document-id a) (plan-document-id b))
                 (mapcar #'plan-document-id (list-plan-documents dir)))
          "oldest first")
      (ok (eq :spec (plan-document-template (reopen-plan-document dir (plan-document-id b)))))
      (ok (signals (reopen-plan-document dir "ffffffffffffffffffffffffffffffff")
                   'plan-document-not-found)))))

(deftest plan-doc-unreadable-meta
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (write-file (plan-document-directory doc) "meta.sexp" "#.(error \"no\")")
      (ok (signals (reopen-plan-document (project-plan-docs-dir project config) (plan-document-id doc))
                   'plan-document-not-found)
          "*read-eval* is off"))))

;;; The markdown format.

(deftest plan-doc-parse
  (multiple-value-bind (title steps files) (parse-plan-markdown +plan-md+)
    (ok (equal "Add a greeting" title))
    (ok (equal '("Write the greeting into hello.sh" "Add a test for it") steps)
        "item text, code spans as their text")
    (ok (equal '("hello.sh" "tests/hello-test.sh") files) "the first code span of each item")))

(deftest plan-doc-parse-details
  (multiple-value-bind (title steps files)
      (parse-plan-markdown "Intro.

## goal
x

### Steps
- one
  - nested, not a step
- two
  continued

- three

Text after.

1. a later list is not steps

## Files To Change
- src/a.lisp because
")
    (ok (null title) "no level-1 heading")
    (ok (equal '("one" "two continued" "three") steps) "headings match case-insensitively at any level")
    (ok (equal '("src/a.lisp") files) "no code span: up to the first whitespace")))

(deftest-parametrize plan-doc-parse-missing
    ((text template missing)
     :ids ("no-goal" "no-steps" "empty-steps" "nothing" "spec-no-design")
     ("# T
## Steps
1. x
" :default '("Goal"))
     ("## Goal
x
" :default '("Steps"))
     ("## Goal
x
## Steps
no list here
" :default '("Steps"))
     ("just text" :default '("Goal" "Steps"))
     ("## Requirements
- r
## Tasks
1. t
" :spec '("Design")))
  (let ((c (failure (parse-plan-markdown text :template template))))
    (ok (typep c 'plan-format-error))
    (ok (equal missing (plan-format-error-missing c)))
    (ok (has (first missing) (princ-to-string c)))))

(deftest plan-doc-parse-spec
  (multiple-value-bind (title steps files) (parse-plan-markdown +spec-md+ :template :spec)
    (ok (equal "Greeting" title))
    (ok (equal '("Write the script" "Test it") steps) "the Tasks list")
    (ok (equal '("hello.sh") files)))
  (ok (typep (failure (parse-plan-markdown +spec-md+)) 'plan-format-error)
      "a spec is not a :default plan (no Goal, no Steps)"))

(deftest plan-doc-template-text
  (ok (equal +default-plan-template+ (plan-template-text :default)))
  (ok (equal +spec-plan-template+ (plan-template-text :spec))))

;;; Revisions.

(deftest plan-doc-propose
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (ok (eql 1 (propose-plan-revision doc +plan-md+)))
      (ok (eq :proposed (plan-document-status doc)))
      (ok (equal +plan-md+ (doc-md doc)))
      (ok (equal +plan-md+ (doc-file doc "revisions/1.md")))
      (ok (equal '(:pending :pending) (step-statuses doc)))
      (ok (equal '(1 2) (mapcar #'plan-step-index (plan-document-steps doc))))
      (ok (equal '("hello.sh" "tests/hello-test.sh") (plan-document-files doc)))
      (ok (eql 2 (propose-plan-revision doc +plan-md-2+ :feedback "in French")))
      (ok (equal +plan-md-2+ (doc-md doc)))
      (ok (equal +plan-md+ (doc-file doc "revisions/1.md")) "revision 1 is kept")
      (ok (= 3 (length (plan-document-steps doc))))
      (let ((revisions (plan-document-revisions doc)))
        (ok (equal '(1 2) (mapcar #'plan-revision-index revisions)))
        (ok (equal '(:model :model) (mapcar #'plan-revision-author revisions)))
        (ok (equal '(nil "in French") (mapcar #'plan-revision-feedback revisions)))))))

(deftest plan-doc-propose-bad-writes-nothing
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (ok (signals (propose-plan-revision doc "## Goal
only
") 'plan-format-error))
      (ok (eql 1 (plan-document-revision doc)))
      (ok (equal +plan-md+ (doc-md doc)))
      (ok (null (doc-file doc "revisions/2.md"))))))

(deftest plan-doc-user-edits
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (ok (null (sync-plan-document-edits doc)) "unchanged: nothing recorded")
      (write-file (plan-document-directory doc) "plan.md" +plan-md-2+)
      (ok (eql 2 (sync-plan-document-edits doc)))
      (ok (eq :user (plan-revision-author (car (last (plan-document-revisions doc))))))
      (ok (equal +plan-md-2+ (doc-file doc "revisions/2.md")))
      (ok (= 3 (length (plan-document-steps doc))) "the steps follow the edit")
      (write-file (plan-document-directory doc) "plan.md" "broken")
      (ok (signals (sync-plan-document-edits doc) 'plan-format-error))
      (ok (eql 2 (plan-document-revision doc)) "a broken edit records nothing"))))

;;; Approval, steps, execution.

(deftest plan-doc-approve
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (ok (typep (failure (approve-plan-document doc)) 'plan-document-state-error)
          "nothing proposed yet")
      (propose-plan-revision doc +plan-md+)
      (ok (typep (failure (approve-plan-document doc :mode :plan)) 'code-usage-error)
          "a plan does not run in plan mode")
      (ok (eq doc (approve-plan-document doc)))
      (ok (eq :approved (plan-document-status doc)))
      (ok (eq :accept-edits (plan-document-execution-mode doc)) "the default")
      (ok (typep (failure (approve-plan-document doc)) 'plan-document-state-error) "once"))))

(deftest-parametrize plan-doc-approve-modes
    ((mode) :ids ("default" "accept-edits" "bypass" "preview")
     (:default) (:accept-edits) (:bypass-permissions) (:preview))
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (approve-plan-document doc :mode mode)
      (ok (eq mode (plan-document-execution-mode doc))))))

(deftest plan-doc-approve-takes-the-edit
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (write-file (plan-document-directory doc) "plan.md" +plan-md-2+)
      (approve-plan-document doc)
      (ok (eql 2 (plan-document-revision doc)) "the user's edit is the approved revision")
      (ok (has "bonjour" (plan-execution-prompt doc))))))

(deftest plan-doc-reject
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (ok (eq :rejected (reject-plan-document doc)))
      (ok (eq :rejected (plan-document-status doc)))
      (ok (typep (failure (approve-plan-document doc)) 'plan-document-state-error)))))

(deftest plan-doc-execution-prompt
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (approve-plan-document doc)
      (ok (equal (format nil "~a~%~%<plan id=\"~a\" revision=\"1\">~%~a~%</plan>"
                         +plan-execution-preamble+ (plan-document-id doc) +plan-md+)
                 (plan-execution-prompt doc)))
      (ok (has (format nil "</plan>~%~%Also keep the old greeting.")
               (plan-execution-prompt doc "Also keep the old greeting."))
          "extra instructions come last"))))

(deftest plan-doc-steps
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (approve-plan-document doc)
      (ok (equal '("☐ 1. Write the greeting into hello.sh" "☐ 2. Add a test for it")
                 (plan-steps-lines doc)))
      (set-plan-step doc 1 :in-progress)
      (ok (equal "◐ 1. Write the greeting into hello.sh" (first (plan-steps-lines doc))))
      (set-plan-step doc 1 :done)
      (ok (equal '(:done :pending) (step-statuses doc)))
      (ok (equal "☑ 1. Write the greeting into hello.sh" (first (plan-steps-lines doc))))
      (let ((c (failure (set-plan-step doc 3 :done))))
        (ok (typep c 'plan-document-error))
        (ok (has "no step 3" (princ-to-string c))))
      (ok (equal '(:done :pending)
                 (mapcar #'plan-step-status
                         (plan-document-steps (reopen-plan-document (project-plan-docs-dir project config)
                                                                    (plan-document-id doc)))))
          "the statuses are saved"))))

(deftest plan-doc-finish-and-interrupted
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (approve-plan-document doc)
      (set-plan-step doc 1 :done)
      (finish-plan-execution doc :interrupted t)
      (ok (eq :interrupted (plan-document-status doc)))
      (approve-plan-document doc)
      (ok (has "Steps already done: 1" (plan-execution-prompt doc)) "an interrupted plan resumes")
      (finish-plan-execution doc :changes '((:modified "hello.sh")))
      (ok (eq :executed (plan-document-status doc))))))

;;; Plan versus diff.

(deftest plan-doc-versus-diff
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (approve-plan-document doc)
      (set-plan-step doc 1 :done)
      (let ((changes '((:modified "hello.sh") (:added "notes.txt"))))
        (ok (equal '(("hello.sh" :modified t) ("notes.txt" :added nil) ("tests/hello-test.sh" nil t))
                   (plan-versus-diff doc changes)))
        (ok (equal (list (format nil "plan ~a r1: 1 of 2 steps done" (subseq (plan-document-id doc) 0 8))
                         "☑ 1. Write the greeting into hello.sh"
                         "☐ 2. Add a test for it"
                         "files: 2 planned, 2 changed"
                         "  M hello.sh  planned"
                         "  A notes.txt  not in the plan"
                         "    tests/hello-test.sh  planned, unchanged")
                   (plan-versus-diff-lines doc changes)))))))

;;; Save to workspace.

(deftest plan-doc-save
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (let* ((path (save-plan-to-workspace doc))
             (name (file-namestring path)))
        (ok (uiop:subpathp path (merge-pathnames "docs/plans/" project)))
        (ok (= (length "2026-11-22-add-a-greeting.md") (length name)))
        (ok (has "-add-a-greeting.md" name))
        (ok (digit-char-p (char name 0)) "starts with the date")
        (ok (equal +plan-md+ (uiop:read-file-string path)))
        (let ((second (save-plan-to-workspace doc)))
          (ok (has "-add-a-greeting-2.md" (file-namestring second)) "never overwrites")))
      (let ((other (save-plan-to-workspace doc :directory "plans")))
        (ok (uiop:subpathp other (merge-pathnames "plans/" project)))))))

(deftest plan-doc-save-slug-fallback
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc (format nil "# !!!~%~%## Goal~%x~%~%## Steps~%1. y~%"))
      (ok (has (format nil "-plan-~a.md" (subseq (plan-document-id doc) 0 8))
               (file-namestring (save-plan-to-workspace doc)))))))

;;; Objects and records.

(deftest plan-doc-object-and-record
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (propose-plan-revision doc +plan-md+)
      (let ((o (plan-document-object doc)))
        (ok (equal (plan-document-id doc) (jget o "id")))
        (ok (eql 1 (jget o "revision")))
        (ok (equal "proposed" (jget o "status")))
        (ok (equal "Add a greeting" (jget o "title")))
        (ok (equal (native (plan-document-path doc)) (jget o "path")))
        (ok (equal "default" (jget o "template")))
        (ok (eq :null (gethash "mode" o)))
        (ok (equal "Add a test for it" (jget o "steps" 1 "text")))
        (ok (eql 2 (jget o "steps" 1 "index")))
        (ok (equal "pending" (jget o "steps" 1 "status")))
        (ok (equalp #("hello.sh" "tests/hello-test.sh") (jget o "files"))))
      (let ((r (plan-document-record doc :feedback "why")))
        (ok (equal (plan-document-id doc) (getf r :id)))
        (ok (eql 1 (getf r :revision)))
        (ok (eq :proposed (getf r :status)))
        (ok (eq :model (getf r :author)))
        (ok (equal +plan-md+ (getf r :markdown)))
        (ok (equal "why" (getf r :feedback)))))))

(deftest plan-doc-record-round-trip
  (let* ((r (simple-record "go" "ok"
                              :plan-document '(:id "abcdef0123456789abcdef0123456789" :revision 2
                                               :status :proposed :author :model :markdown "# x"
                                               :feedback "more")))
         (back (content-record (record-content r))))
    (ok (equal (record-plan-document r) (record-plan-document back)))
    (ok (null (record-plan-document (content-record (record-content (simple-record "a" "b")))))
        "absent by default")))

(deftest plan-doc-old-records-read-as-preview
  ;; MIGRATION: a 0.4–0.14 plan-mode record (it carries an H5a :plan) reads back
  ;; in preview mode; a record of the new plan mode stays :plan.
  (let* ((old (simple-record "go" "ok" :permission-mode :plan
                                :plan '(:id "abcdef0123456789abcdef0123456789" :kind :copy
                                        :base "b" :root "/tmp/x/" :status :open)))
         (new (simple-record "go" "ok" :permission-mode :plan)))
    (ok (eq :preview (record-permission-mode (content-record (record-content old)))))
    (ok (equal "abcdef0123456789abcdef0123456789"
               (getf (record-plan (content-record (record-content old))) :id))
        "the area record is unchanged")
    (ok (eq :plan (record-permission-mode (content-record (record-content new)))))))

;;; The tool source.

(deftest plan-doc-tools
  (with-project (project config) '()
    (let ((doc (fresh-plan-doc project config)))
      (let ((planning (make-plan-tools doc :phase :plan)))
        (ok (plan-tools-p planning))
        (ok (equal '("propose_plan" "ask_user")
                   (mapcar #'llm:llm-tool-name (a:list-agent-tools planning))))
        (ok (not (a:tool-needs-approval-p planning "propose_plan" "{}")) "never asks"))
      (let ((executing (make-plan-tools doc :phase :execute)))
        (ok (equal '("update_plan") (mapcar #'llm:llm-tool-name (a:list-agent-tools executing))))
        (ok (not (a:tool-needs-approval-p executing "update_plan" "{}")))))))

;;; Settings.

(deftest plan-doc-settings
  (with-project (project config) '()
    (write-file project ".cl-stack-code/settings.json"
                "{\"planTemplate\": \"spec\", \"planSaveDirectory\": \"notes/plans\"}")
    (let ((s (load-settings project :user-config-dir config)))
      (ok (eq :spec (settings-plan-template s)))
      (ok (equal "notes/plans" (settings-plan-save-directory s))))
    (ok (null (settings-plan-template (load-settings (subdir project "nowhere/") :user-config-dir config)))
        "unset")))

(deftest-parametrize plan-doc-settings-errors
    ((json key)
     :ids ("template" "template-type" "dir-dotdot" "dir-absolute" "dir-type")
     ("{\"planTemplate\": \"kiro\"}" "planTemplate")
     ("{\"planTemplate\": 1}" "planTemplate")
     ("{\"planSaveDirectory\": \"../out\"}" "planSaveDirectory")
     ("{\"planSaveDirectory\": \"/abs\"}" "planSaveDirectory")
     ("{\"planSaveDirectory\": true}" "planSaveDirectory"))
  (with-project (project config) '()
    (write-file config "settings.json" json)
    (let ((c (failure (load-settings project :user-config-dir config))))
      (ok (typep c 'settings-error))
      (ok (has key (princ-to-string c))))))
