(in-package #:cl-stack-code/tests)

;;; Rule syntax, mode base rules, precedence, plan policy, hidden tools.

(deftest-parametrize permission-rule-syntax
    ((text action resource)
     :ids ("bare" "bash-default-prefix" "bash-program" "bash-write" "edit-path"
           "read-path" "glob-tool" "job" "explicit-path" "star-spec" "glob-action"
           "other-tool" "multi-edit" "spaces-in-spec")
     ("read" "read" "*")
     ("bash(git *)" "bash" "bash:git *")
     ("bash(program:rm)" "bash" "program:rm")
     ("bash(write:secret/*)" "bash" "write:secret/*")
     ("edit(src/*)" "edit" "path:src/*")
     ("read(./notes.txt)" "read" "path:./notes.txt")
     ("glob(**)" "glob" "path:**")
     ("job_kill(job-1)" "job_kill" "job:job-1")
     ("write(path:out/*)" "write" "path:out/*")
     ("bash(*)" "bash" "*")
     ("*(path:secret/*)" "*" "path:secret/*")
     ("mcp_fetch(https://x/*)" "mcp_fetch" "https://x/*")
     ("multi_edit(a.lisp)" "multi_edit" "path:a.lisp")
     ("bash(git log --oneline)" "bash" "bash:git log --oneline"))
  (let ((rule (parse-permission-rule text :allow)))
    (ok (a:permission-rule-p rule))
    (ok (equal (list action resource :allow) (rule-list rule)))))

(deftest permission-rule-effects-and-object-form
  (ok (eq :deny (a:permission-rule-effect (parse-permission-rule "bash" :deny))))
  (ok (eq :ask (a:permission-rule-effect (parse-permission-rule "bash" :ask))))
  (let ((r (parse-permission-rule (args "tool" "edit" "resource" "secret/*"
                                        "feedback" "Leave secrets alone.")
                                  :deny)))
    (ok (equal '("edit" "secret/*" :deny) (rule-list r)) "resource taken literally")
    (ok (equal "Leave secrets alone." (a:permission-rule-feedback r))))
  (ok (equal '("grep" "*" :allow) (rule-list (parse-permission-rule (args "tool" "grep") :allow))))
  (ok (typep (failure (parse-permission-rule (args "resource" "x") :deny)) 'permission-rule-error)
      "an object without \"tool\""))

(deftest-parametrize permission-rule-errors
    ((designator) :ids ("empty" "open" "empty-spec" "no-tool" "trailing" "space-in-tool"
                        "blank" "number")
     ("") ("bash(") ("bash()") ("(git *)") ("bash(x)y") ("my tool") ("   ") (42))
  (let ((c (failure (parse-permission-rule designator :allow))))
    (ok (typep c 'permission-rule-error))
    (ok (typep c 'code-usage-error))))

(deftest permission-split-rule-list
  (ok (equal '("read" "grep") (split-rule-list "read,grep")))
  (ok (equal '("read" "grep" "ls") (split-rule-list " read  grep,, ls ")))
  (ok (equal '("bash(git log --format=%h,%s)" "edit(src/*)")
             (split-rule-list "bash(git log --format=%h,%s), edit(src/*)")))
  (ok (null (split-rule-list "  "))))

(defun allow (&rest texts) (mapcar (lambda (x) (parse-permission-rule x :allow)) texts))
(defun ask (&rest texts) (mapcar (lambda (x) (parse-permission-rule x :ask)) texts))
(defun deny (&rest texts) (mapcar (lambda (x) (parse-permission-rule x :deny)) texts))

(deftest permission-mode-base-rules
  (ok (equal '(("write" "*" :ask) ("edit" "*" :ask) ("multi_edit" "*" :ask))
             (rule-lists (settings-permission-rules (make-settings)))))
  (ok (equal '(("write" "*" :ask) ("edit" "*" :ask) ("multi_edit" "*" :ask))
             (rule-lists (settings-permission-rules (make-settings :permission-mode :default)))))
  (ok (equal '(("write" "*" :allow) ("edit" "*" :allow) ("multi_edit" "*" :allow))
             (rule-lists (settings-permission-rules (make-settings :permission-mode :accept-edits)))))
  (ok (null (settings-permission-rules (make-settings :permission-mode :bypass-permissions))))
  ;; H5a: plan mode edits the area, so its base rules are acceptEdits'.
  (ok (equal '(("write" "*" :allow) ("edit" "*" :allow) ("multi_edit" "*" :allow))
             (rule-lists (settings-permission-rules (make-settings :permission-mode :plan))))))

(deftest permission-rule-order
  (let ((s (merge-settings (make-settings :allow (allow "bash(git *)") :deny (deny "bash(program:rm)"))
                           (make-settings :allow (allow "read") :ask (ask "bash(git push *)")))))
    (ok (equal '(("write" "*" :ask) ("edit" "*" :ask) ("multi_edit" "*" :ask)
                 ("bash" "bash:git *" :allow) ("read" "*" :allow)
                 ("bash" "bash:git push *" :ask)
                 ("bash" "program:rm" :deny))
               (rule-lists (settings-permission-rules s))))))

(deftest permission-deny-beats-allow-across-layers
  (let* ((s (merge-settings (make-settings :deny (deny "edit(secret/*)"))
                            (make-settings :allow (allow "edit(secret/*)" "edit(src/*)"))))
         (rules (settings-permission-rules s)))
    (ok (eq :deny (a:permission-rules-effect rules "edit" '("path:secret/k.txt"))))
    (ok (eq :allow (a:permission-rules-effect rules "edit" '("path:src/a.lisp"))))
    (ok (eq :ask (a:permission-rules-effect rules "edit" '("path:other.txt"))) "the mode's base")))

(deftest permission-ask-beats-allow
  (let ((rules (settings-permission-rules
                (merge-settings (make-settings :ask (ask "bash(git push *)"))
                                (make-settings :allow (allow "bash(git *)"))))))
    (ok (eq :ask (a:permission-rules-effect rules "bash" '("bash:git push origin"))))
    (ok (eq :allow (a:permission-rules-effect rules "bash" '("bash:git status"))))))

(deftest permission-plan-policy
  ;; H5a: no mode has a policy; plan mode runs edits and the shell in its area.
  (ok (null (settings-permission-policy (make-settings))))
  (ok (null (settings-permission-policy (make-settings :permission-mode :accept-edits))))
  (ok (null (settings-permission-policy (make-settings :permission-mode :plan)))))

(deftest permission-hidden-tools
  (let ((names '("read" "write" "edit" "bash" "job_output" "job_input" "job_kill" "job_list")))
    (ok (null (hidden-tool-names (make-settings) names)))
    (ok (equal '("bash") (hidden-tool-names (make-settings :deny (deny "bash")) names)))
    (ok (null (hidden-tool-names (make-settings :deny (deny "bash(program:rm)")) names))
        "a scoped deny stays a rule")
    (ok (equal '("job_output" "job_input" "job_kill" "job_list")
               (hidden-tool-names (make-settings :deny (deny "job_*")) names)))
    (ok (equal '("write" "bash")
               (hidden-tool-names (make-settings :deny (deny "bash" "write" "bash(*)")) names))
        "in NAMES order")
    (ok (null (hidden-tool-names (make-settings :allow (allow "bash")) names)))))

(deftest permission-feedback-constants
  (ok (has "headless" +headless-denial-feedback+))
  (ok (has "--allowed-tools" +headless-denial-feedback+))
  (ok (has "bypassPermissions" +headless-denial-feedback+))
  (ok (has "plan mode" +plan-mode-feedback+))
  (ok (has "copy of the project" +plan-mode-feedback+)))
