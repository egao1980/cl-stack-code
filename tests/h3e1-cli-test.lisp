(in-package #:cl-stack-code/tests)

;;; H3e-1 end to end through run-cli (-p, stream-json, sessions): the system
;;; prompt, the init event, the skill tool, lazy rules, contextFiles, and the
;;; lisp-workspace fixture. Every LLM call goes to the scripted mock.

(defun h3e1-run (project config steps &rest argv)
  "A stream-json -p run → (values exit out backend err)."
  (multiple-value-bind (exit out err backend)
      (code project config (append '("-p" "--output-format" "stream-json") argv '("go")) :steps steps)
    (values exit out backend err)))

(defparameter +lisp-rule-body+ "Lisp rule: use conditions.")

(defun lisp-rule-project ()
  (list (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp") +lisp-rule-body+))
        (list "src/a.lisp" "(a)
")
        (list "src/b.lisp" "(b)
")
        (list "notes.txt" "notes
")))

;;; The init event.

(deftest h3e1-init-keys-on-a-bare-project
  (with-project (project config) '()
    (multiple-value-bind (exit out) (h3e1-run project config '("ok"))
      (ok (eql 0 exit))
      (let ((init (init-of out)))
        (dolist (key '("imports" "skills" "rules" "notes"))
          (ok (equalp #() (jget init key)) (format nil "~a is an empty array" key)))
        (ok (not (find "skill" (jget init "tools") :test #'equal)) "no skills, no skill tool")))))

(deftest h3e1-init-lists-everything
  (with-project (project config) (append (lisp-rule-project)
                                         (list (list "CLAUDE.md" "@docs/shared.md
@docs/gone.md
")
                                               (list "docs/shared.md" "Shared.
")
                                               (list ".claude/rules/always.md" "Always on.
")))
    (write-skill project ".claude/skills/" "rove" "Rove quick ref.")
    (write-skill config "skills/" "rove" "User rove.")
    (multiple-value-bind (exit out) (h3e1-run project config '("ok"))
      (ok (eql 0 exit))
      (let* ((init (init-of out))
             (claude (native (truename (merge-pathnames "CLAUDE.md" project)))))
        (ok (equalp (vector claude) (jget init "instructions")))
        (ok (equal (list (native (truename (merge-pathnames "docs/shared.md" project))))
                   (init-names init "imports" "path")))
        (ok (equal (list claude) (init-names init "imports" "from")))
        (ok (equal '("rove") (init-names init "skills" "name")))
        (ok (equal '("Rove quick ref.") (init-names init "skills" "description")))
        (ok (equal '("claude") (init-names init "skills" "source")))
        (ok (equal (list (native (truename (merge-pathnames ".claude/skills/rove/SKILL.md" project))))
                   (init-names init "skills" "path")))
        (let ((rules (coerce (jget init "rules") 'list)))
          (ok (= 2 (length rules)))
          (ok (equal (list (native (truename (merge-pathnames ".claude/rules/always.md" project)))
                           (native (truename (merge-pathnames ".claude/rules/lisp.md" project))))
                     (mapcar (lambda (r) (jget r "path")) rules))
              "rule order: by relative path")
          (ok (equal '(:null ("**/*.lisp")) (mapcar (lambda (r) (let ((p (jget r "paths")))
                                                                 (if (vectorp p) (coerce p 'list) p)))
                                                    rules)))
          (ok (equal '(t nil) (mapcar (lambda (r) (jget r "loaded")) rules))
              "the always-on rule is loaded at start, the path-scoped one is not"))
        (let ((notes (coerce (jget init "notes") 'list)))
          (ok (= 2 (length notes)) "one missing import, one shadowed skill")
          (ok (some (lambda (n) (has "import not found: @docs/gone.md" n)) notes))
          (ok (some (lambda (n) (has "skill rove at" n)) notes)))
        (ok (equal "skill" (aref (jget init "tools") (1- (length (jget init "tools")))))
            "the skill tool comes last")))))

;;; The system prompt.

(deftest h3e1-prompt-sections
  (with-project (project config) '(("AGENTS.md" "Project rules.
") (".claude/rules/always.md" "Always on.
"))
    (write-skill project ".claude/skills/" "rove" "Rove quick ref.")
    (let* ((backend (nth-value 2 (h3e1-run project config '("ok") "--append-system-prompt" "Answer in French.")))
           (prompt (first-system backend))
           (agents (search "Project rules." prompt))
           (rule (search (format nil "<rule path=\"~a\">~%Always on.~%</rule>"
                                 (native (truename (merge-pathnames ".claude/rules/always.md" project))))
                         prompt))
           (skills (search (format nil "# Skills~%~a~%- rove: Rove quick ref." +skill-listing-preamble+) prompt))
           (append (search "Answer in French." prompt)))
      (ok (and agents rule skills append))
      (ok (and agents rule skills append (< agents rule skills append))
          "instructions, always-on rules, skills, then appendSystemPrompt"))))

;;; The skill tool.

(deftest h3e1-skill-tool-in-headless-default-mode
  (with-project (project config) (lisp-workspace-fixture)
    (multiple-value-bind (exit out) (h3e1-run project config (list (skill-step "rove") "done"))
      (ok (eql 0 exit))
      (let ((result (result-named out "skill")))
        (ok result)
        (ok (has "<skill name=\"rove\" directory=" (jget result "content"))
            "allowed without an approval: -p would have refused an ask")
        (ok (has "Use deftest and ok." (jget result "content")))))))

(deftest h3e1-skill-tool-unknown-name
  (with-project (project config) (lisp-workspace-fixture)
    (let ((out (nth-value 1 (h3e1-run project config (list (skill-step "nope") "done")))))
      (ok (has "no skill named \"nope\"; skills: rove" (jget (result-named out "skill") "content"))))))

(deftest h3e1-skill-deny-rule
  (with-project (project config) (lisp-workspace-fixture)
    (let ((out (nth-value 1 (h3e1-run project config (list (skill-step "rove") "done")
                                      "--disallowed-tools" "skill(rove)"))))
      (ok (not (has "Use deftest and ok." (jget (result-named out "skill") "content")))
          "a deny rule names the skill"))
    (let ((init (init-of (nth-value 1 (h3e1-run project config '("ok") "--disallowed-tools" "skill")))))
      (ok (not (find "skill" (jget init "tools") :test #'equal)) "a deny-all rule hides the tool"))))

(deftest-parametrize h3e1-skill-allowed-in-every-mode
    ((mode) :ids ("default" "acceptEdits" "bypassPermissions" "plan")
     (:default) (:accept-edits) (:bypass-permissions) (:plan))
  (with-project (project config) (lisp-workspace-fixture)
    (let* ((source (make-skill-tools (discover-skills project :user-config-dir config)))
           (agent (a:make-ai-agent :name "t" :backend (make-scripted-backend '())
                                   :tools (list source)
                                   :permissions (settings-permission-rules
                                                 (make-settings :permission-mode mode)))))
      (ok (eq :allow (a:agent-permission agent source "skill" (json-args "name" "rove")))))))

(deftest h3e1-skill-rule-resource
  (with-project (project config) (lisp-workspace-fixture)
    (let* ((source (make-skill-tools (discover-skills project :user-config-dir config)))
           (agent (a:make-ai-agent :name "t" :backend (make-scripted-backend '())
                                   :tools (list source)
                                   :permissions (list (parse-permission-rule "skill(ro*)" :deny)))))
      (ok (eq :deny (a:agent-permission agent source "skill" (json-args "name" "rove")))))))

;;; Path-scoped rules.

(deftest h3e1-rule-loads-on-read
  (with-project (project config) (lisp-rule-project)
    (multiple-value-bind (exit out backend) (h3e1-run project config (list (lisp-read-step "src/a.lisp") "done"))
      (ok (eql 0 exit))
      (let ((requests (scripted-requests backend))
            (injected (rule-injection (merge-pathnames ".claude/rules/lisp.md" project)
                                      '("**/*.lisp") +lisp-rule-body+)))
        (ok (= 2 (length requests)))
        (ok (not (has +lisp-rule-body+ (request-text (first requests)))) "not at start")
        (ok (has injected (request-text (second requests))) "injected after the read")
        (let ((ev (first (events out "instructions"))))
          (ok ev "an instructions event")
          (when ev
            (ok (equal (list (native (truename (merge-pathnames ".claude/rules/lisp.md" project))))
                       (map 'list (lambda (f) (jget f "path")) (jget ev "files"))))
            (ok (equal '("rule") (map 'list (lambda (f) (jget f "kind")) (jget ev "files"))))))))))

(deftest-parametrize h3e1-rule-loads-on-write-and-edit
    ((step) :ids ("write" "edit")
     ('(:tool "write" "{\"file_path\":\"src/new.lisp\",\"content\":\"(new)\\n\"}"))
     ('(:tool "edit" "{\"file_path\":\"src/a.lisp\",\"old_string\":\"(a)\",\"new_string\":\"(aa)\"}")))
  (with-project (project config) (lisp-rule-project)
    (let ((backend (nth-value 2 (h3e1-run project config (list step "done") "--permission-mode" "acceptEdits"))))
      (ok (has +lisp-rule-body+ (request-text (second (scripted-requests backend))))))))

(deftest h3e1-rule-not-for-other-paths
  (with-project (project config) (lisp-rule-project)
    (multiple-value-bind (exit out backend) (h3e1-run project config (list (lisp-read-step "notes.txt") "done"))
      (ok (eql 0 exit))
      (ok (not (has +lisp-rule-body+ (request-text (second (scripted-requests backend))))))
      (ok (null (events out "instructions"))))))

(deftest h3e1-rule-once-per-run
  (with-project (project config) (lisp-rule-project)
    (let ((backend (nth-value 2 (h3e1-run project config (list (lisp-read-step "src/a.lisp")
                                                               (lisp-read-step "src/b.lisp")
                                                               "done")))))
      (ok (= 1 (count-of +lisp-rule-body+ (request-text (third (scripted-requests backend)))))))))

(deftest h3e1-rule-once-per-session-across-resume
  (with-project (project config) (lisp-rule-project)
    (let* ((out-1 (nth-value 1 (h3e1-run project config (list (lisp-read-step "src/a.lisp") "done"))))
           (id (jget (init-of out-1) "session_id"))
           (rule (native (truename (merge-pathnames ".claude/rules/lisp.md" project)))))
      (ok (equal (list (list rule)) (records-loaded-rules project config id))
          "the turn record's instruction set has the rule")
      (multiple-value-bind (exit out-2 backend-2)
          (h3e1-run project config (list (lisp-read-step "src/b.lisp") "done") "--continue")
        (ok (eql 0 exit))
        (let ((init (init-of out-2)))
          (ok (equal id (jget init "session_id")))
          (ok (equal '(t) (init-names init "rules" "loaded")) "seeded from the session")
          (ok (equal (record-instructions (first (session-dir-records project config id)))
                     (jget init "instruction_set"))
              "nothing changed on disk: the head's revision again"))
        (ok (= 1 (count-of +lisp-rule-body+ (request-text (car (last (scripted-requests backend-2))))))
            "the rule is in the history once, not injected again")
        (ok (null (events out-2 "instructions")))
        (ok (equal (list (list rule) (list rule)) (records-loaded-rules project config id)))
        (let ((ids (mapcar #'record-instructions (session-dir-records project config id))))
          (ok (equal (first ids) (second ids)) "both turns share one revision"))))))

;;; The instruction set's revisions.

(deftest h3e1-init-instruction-set
  (with-project (project config) (lisp-rule-project)
    (multiple-value-bind (exit out) (h3e1-run project config (list (lisp-read-step "notes.txt") "done"))
      (ok (eql 0 exit))
      (let* ((init (init-of out))
             (set-id (jget init "instruction_set"))
             (id (jget init "session_id"))
             (s (open-session (project-sessions project config) id)))
        (ok (and (stringp set-id) (= 64 (length set-id))) "the init event names the start revision")
        (ok (equal set-id (record-instructions (first (session-records s))))
            "a turn that loaded nothing ends on the same revision")
        (ok (equal set-id (session-instruction-set s "0")) "the start ref")
        (ok (probe-file (merge-pathnames (format nil "instructions/revisions/~a.sexp" set-id)
                                         (session-directory s))))))))

(deftest h3e1-instructions-event-names-the-revision
  (with-project (project config) (lisp-rule-project)
    (multiple-value-bind (exit out) (h3e1-run project config (list (lisp-read-step "src/a.lisp") "done"))
      (ok (eql 0 exit))
      (let* ((init (init-of out))
             (ev (first (events out "instructions")))
             (record (first (session-dir-records project config (jget init "session_id")))))
        (ok ev)
        (when ev
          (ok (equal (record-instructions record) (jget ev "instruction_set"))
              "the revision after the load, which the turn ends on")
          (ok (not (equal (jget init "instruction_set") (jget ev "instruction_set")))))))))

(deftest h3e1-rewind-drops-later-rules
  (with-project (project config) (lisp-rule-project)
    (let* ((out-1 (nth-value 1 (h3e1-run project config (list (lisp-read-step "notes.txt") "done"))))
           (id (jget (init-of out-1) "session_id")))
      (h3e1-run project config (list (lisp-read-step "src/a.lisp") "done") "--continue")
      (let ((records (session-dir-records project config id)))
        (ok (= 2 (length records)))
        (ok (not (equal (record-instructions (first records)) (record-instructions (second records))))
            "turn 2 loaded the rule: a new revision"))
      (ok (eql 0 (code project config (list "-p" "--resume" id "--rewind" "1" "--rewind-mode" "conversation"))))
      (multiple-value-bind (exit out-3 backend-3)
          (h3e1-run project config (list (lisp-read-step "src/b.lisp") "done") "--continue")
        (ok (eql 0 exit))
        (let ((init (init-of out-3))
              (turn-1 (first (session-dir-records project config id))))
          (ok (equal '(nil) (init-names init "rules" "loaded")) "turn 1's set: the rule is not loaded")
          (ok (equal (record-instructions turn-1) (jget init "instruction_set"))))
        (ok (= 1 (length (events out-3 "instructions"))) "it loads again on the next matching read")
        (ok (= 1 (count-of +lisp-rule-body+ (request-text (car (last (scripted-requests backend-3))))))
            "once: the rewound history no longer has it")
        (ok (equal (list nil (list (native (truename (merge-pathnames ".claude/rules/lisp.md" project)))))
                   (records-loaded-rules project config id)))))))

(deftest h3e1-fork-session-copies-the-instruction-set
  (with-project (project config) (lisp-rule-project)
    (let* ((out-1 (nth-value 1 (h3e1-run project config (list (lisp-read-step "src/a.lisp") "done"))))
           (id (jget (init-of out-1) "session_id"))
           (set-id (record-instructions (first (session-dir-records project config id)))))
      (multiple-value-bind (exit out-2 backend-2)
          (h3e1-run project config (list (lisp-read-step "src/b.lisp") "done") "--resume" id "--fork-session")
        (ok (eql 0 exit))
        (let* ((init (init-of out-2))
               (new (jget (first (events out-2 "result")) "session_id")))
          (ok (and new (not (equal id new))) "a new session")
          (ok (probe-file (merge-pathnames (format nil "~a/instructions/revisions/~a.sexp" new set-id)
                                           (project-sessions project config)))
              "the clone has the revision its copied record names")
          (ok (equal set-id (jget init "instruction_set")))
          (ok (equal '(t) (init-names init "rules" "loaded")))
          (ok (null (events out-2 "instructions")) "not loaded again in the fork")
          (ok (= 1 (count-of +lisp-rule-body+ (request-text (car (last (scripted-requests backend-2))))))))))))

(deftest h3e1-checkpoint-instructions-part
  (with-project (project config) (lisp-rule-project)
    (multiple-value-bind (exit out)
        (h3e1-run project config
                  (list '(:tool "write" "{\"file_path\":\"src/new.lisp\",\"content\":\"(new)\\n\"}") "done")
                  "--permission-mode" "acceptEdits")
      (ok (eql 0 exit))
      (let* ((init (init-of out))
             (s (open-session (project-sessions project config) (jget init "session_id")))
             (start (jget init "instruction_set"))
             (set-id (record-instructions (first (session-records s))))
             (cps (session-checkpoints s)))
        (ok (not (equal start set-id)) "the write loaded the rule")
        (ok (equal '(:before :turn) (mapcar #'checkpoint-reason cps)))
        (when (= 2 (length cps))
          (destructuring-bind (before turn) cps
            (ok (equal set-id (checkpoint-instructions-id turn)))
            (ok (equal start (checkpoint-instructions-id before)) "before turn 1: the start set")
            (let ((parts (rev:manifest-parts (rev:composite-manifest (checkpoint-store s) (checkpoint-id turn)))))
              (ok (equal '(:files :conversation :instructions) (mapcar #'rev:part-role parts)))
              (let ((part (third parts)))
                (when part
                (ok (equal set-id (rev:part-revision-id part)))
                (ok (equal '(:conversation) (rev:part-depends-on part)) "it goes with the conversation")
                (ok (eq (session-instruction-store s) (rev:part-store part))))))
            (let ((parts (rev:manifest-parts (rev:composite-manifest (checkpoint-store s) (checkpoint-id before)))))
              (ok (equal '(:files :instructions) (mapcar #'rev:part-role parts)))
              (when (second parts)
                (ok (null (rev:part-depends-on (second parts))))))
            (let ((plist (read-data (merge-pathnames (format nil "checkpoints/revisions/~a.sexp" (checkpoint-id turn))
                                                     (session-directory s)))))
              (ok (member (list :role :instructions :kind :instruction-set :revision set-id
                                :depends-on '(:conversation))
                          (getf (getf plist :content) :parts) :test #'equal)
                  "on disk"))))))))

;;; contextFiles.

(deftest h3e1-context-file-flag
  (with-project (project config) '(("AGENTS.md" "Project.
"))
    (write-file config "AGENTS.md" "User.
")
    (let* ((ctx (write-file config "lw/plugin/context.md" "Plugin context.
"))
           (missing (native (merge-pathnames "lw/none.md" config))))
      (multiple-value-bind (exit out backend)
          (h3e1-run project config '("ok") "--context-file" (native ctx) "--context-file" missing)
        (ok (eql 0 exit))
        (let* ((prompt (first-system backend))
               (user (search "User." prompt))
               (plugin (search (top-block ctx "Plugin context.") prompt))
               (proj (search "Project." prompt)))
          (ok (and user plugin proj (< user plugin proj))
              "after the user file, before the project chain"))
        (let ((init (init-of out)))
          (ok (equal (list (native (truename (merge-pathnames "AGENTS.md" config)))
                           (native (truename ctx))
                           (native (truename (merge-pathnames "AGENTS.md" project))))
                     (coerce (jget init "instructions") 'list)))
          (ok (find (format nil "context file not found: ~a" missing) (jget init "notes") :test #'equal)))))))

(deftest h3e1-context-files-user-settings-not-project
  (with-project (project config) '()
    (let ((mine (write-file config "mine.md" "Mine.
"))
          (theirs (write-file config "theirs.md" "Theirs.
")))
      (write-file config "settings.json" (json:encode (args "contextFiles" (vector (native mine)))))
      (write-file project ".cl-stack-code/settings.json"
                  (json:encode (args "contextFiles" (vector (native theirs)))))
      (let ((prompt (first-system (nth-value 2 (h3e1-run project config '("ok"))))))
        (ok (has "Mine." prompt))
        (ok (not (has "Theirs." prompt)) "a project cannot add context files")))))

(deftest h3e1-context-file-bad-flag
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("-p" "--context-file" "rel.md" "go") :steps '("ok"))
      (declare (ignore out))
      (ok (eql 2 exit))
      (ok (has "--context-file must be an absolute path or start with ~/" err)))))

(deftest h3e1-no-automatic-plugin-context
  (with-project (project config) (lisp-workspace-fixture)
    (ok (not (has "PLUGIN CONTEXT ONLY" (first-system (nth-value 2 (h3e1-run project config '("ok"))))))
        ".lisp-workspace/plugin/context.md comes only through contextFiles")))

;;; The lisp-workspace fixture.

(deftest h3e1-lisp-workspace-fixture
  (with-project (project config) (lisp-workspace-fixture)
    (multiple-value-bind (exit out backend)
        (h3e1-run project config (list (skill-step "rove") (lisp-read-step "src/a.lisp") "done"))
      (ok (eql 0 exit))
      (let* ((requests (scripted-requests backend))
             (prompt (first-system backend))
             (root-claude (merge-pathnames "CLAUDE.md" project))
             (lw-claude (merge-pathnames ".lisp-workspace/CLAUDE.md" project))
             (lw-agents (merge-pathnames ".lisp-workspace/AGENTS.md" project))
             (rule (merge-pathnames ".lisp-workspace/rules/lisp.md" project)))
        (ok (= 3 (length requests)))
        (ok (has (top-block root-claude
                            (format nil "~a~%@.lisp-workspace/CLAUDE.md~%~%<!-- Workspace root. -->"
                                    (import-block lw-claude
                                                  (format nil "~a~%@AGENTS.md~%~%~a"
                                                          (import-block lw-agents +fixture-agents+)
                                                          +fixture-claude-tail+))))
                 prompt)
            "CLAUDE.md → .lisp-workspace/CLAUDE.md → AGENTS.md, nested in place")
        (ok (has (format nil "# Skills~%~a~%- rove: Rove quick ref (ok / signals / deftest-parametrize). For policy and runner choice use cl-unit-testing."
                         +skill-listing-preamble+)
                 prompt))
        (ok (not (has +fixture-rule-body+ prompt)) "the path-scoped rule is not in the system prompt")
        (ok (not (has "PLUGIN CONTEXT ONLY" prompt)))
        (ok (has "Use deftest and ok." (jget (result-named out "skill") "content")))
        (ok (not (has +fixture-rule-body+ (request-text (second requests)))) "not after the skill call")
        (ok (has (rule-injection rule '("**/*.lisp") +fixture-rule-body+) (request-text (third requests)))
            "loaded after reading src/a.lisp")
        (let ((init (init-of out)))
          (ok (equal (list (native (truename root-claude))) (coerce (jget init "instructions") 'list)))
          (ok (equal (list (native (truename lw-claude)) (native (truename lw-agents)))
                     (init-names init "imports" "path")))
          (ok (equal '("lisp-workspace") (init-names init "skills" "source")))
          (ok (equal (list (native (truename rule))) (init-names init "rules" "path")))
          (ok (equalp #() (jget init "notes"))))))))
