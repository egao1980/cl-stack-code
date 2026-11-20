(in-package #:cl-stack-code/tests)

;;; "Always" rules in settings.local.json (src/rule-store.lisp header).

(defun rule (action resource &optional (effect :allow))
  (a:make-permission-rule action resource effect))

(deftest-parametrize format-permission-rule-strings
    ((action resource text)
     :ids ("bare" "path" "bash" "program" "job" "star-spec" "explicit-in-other" "other-tool"
           "glob-action" "write-resource")
     ("read" "*" "read")
     ("edit" "path:src/a.lisp" "edit(src/a.lisp)")
     ("bash" "bash:git status *" "bash(git status *)")
     ("bash" "program:git" "bash(program:git)")
     ("job_output" "job:j1" "job_output(j1)")
     ("edit" "path:*" "edit(path:*)")
     ("edit" "path:program:x" "edit(path:program:x)")
     ("search" "q:x" "search(q:x)")
     ("job_*" "job:j1" "job_*(job:j1)")
     ("bash" "write:out/*" "bash(write:out/*)"))
  (let ((r (rule action resource)))
    (ok (equal text (format-permission-rule r)))
    (ok (equal (rule-list r) (rule-list (parse-permission-rule text :allow)))
        "parses back to the same rule")))

(deftest format-permission-rule-object-form
  (dolist (r (list (rule "my tool" "*") (rule "edit" "path:a(b") (rule "bash" "bash:echo )")))
    (let ((form (format-permission-rule r)))
      (ok (hash-table-p form) (rule-list r))
      (ok (equal (a:permission-rule-action r) (gethash "tool" form)))
      (ok (equal (a:permission-rule-resource r) (gethash "resource" form)))
      (ok (equal (rule-list r) (rule-list (parse-permission-rule form :allow)))))))

(deftest settings-rule-store-creates-the-file
  (with-project (project config) '()
    (let* ((file (local-settings config project))
           (store (make-settings-rule-store file)))
      (ok (typep store 'a:permission-rule-store))
      (ok (same-path file (settings-rule-store-file store)))
      (ok (null (a:list-permission-rules store)))
      (ok (not (probe-file file)))
      (let ((r (rule "edit" "path:src/a.lisp")))
        (ok (eq r (a:save-permission-rule store r))))
      (a:save-permission-rule store (rule "bash" "bash:git status *"))
      (ok (probe-file file) "the file and its directory are created")
      (ok (equal '("edit(src/a.lisp)" "bash(git status *)")
                 (coerce (jget (json:decode (read-file project ".cl-stack-code/settings.local.json"))
                               "permissions" "allow")
                         'list)))
      (ok (equal '(("edit" "path:src/a.lisp" :allow) ("bash" "bash:git status *" :allow))
                 (rule-lists (a:list-permission-rules store))))
      (testing "the next start reads them as settings rules"
        (ok (equal '(("edit" "path:src/a.lisp" :allow) ("bash" "bash:git status *" :allow))
                   (rule-lists (settings-allow (load-settings project :user-config-dir config)))))))))

(deftest settings-rule-store-keeps-the-rest
  (with-project (project config) '((".cl-stack-code/settings.local.json"
                                    "{\"model\": \"openai\", \"env\": {\"A\": \"1\"},
 \"permissions\": {\"allow\": [\"read\", \"edit(src/a.lisp)\"], \"deny\": [\"bash(rm *)\"]},
 \"custom\": [1, 2]}"))
    (let ((store (make-settings-rule-store (local-settings config project))))
      (a:save-permission-rule store (rule "edit" "path:src/a.lisp"))
      (a:save-permission-rule store (rule "grep" "*"))
      (a:save-permission-rule store (rule "bash" "bash:git *" :ask))
      (let ((o (json:decode (read-file project ".cl-stack-code/settings.local.json"))))
        (ok (equal "openai" (jget o "model")))
        (ok (equal "1" (jget o "env" "A")))
        (ok (equalp #(1 2) (jget o "custom")))
        (ok (equal '("read" "edit(src/a.lisp)" "grep") (coerce (jget o "permissions" "allow") 'list))
            "a rule already there is not added again")
        (ok (equal '("bash(git *)") (coerce (jget o "permissions" "ask") 'list)))
        (ok (equal '("bash(rm *)") (coerce (jget o "permissions" "deny") 'list))))
      (ok (equal '(("edit" "path:src/a.lisp" :allow) ("grep" "*" :allow) ("bash" "bash:git *" :ask))
                 (rule-lists (a:list-permission-rules store)))
          "every rule saved through the store is listed"))))

(deftest settings-rule-store-bad-file
  (dolist (content '("not json" "[1, 2]" "{\"permissions\": 3}" "{\"permissions\": {\"allow\": \"read\"}}"))
    (with-project (project config) (list (list ".cl-stack-code/settings.local.json" content))
      (let* ((store (make-settings-rule-store (local-settings config project)))
             (c (failure (a:save-permission-rule store (rule "read" "*")))))
        (ok (typep c 'settings-error) content)
        (ok (and c (same-path (local-settings config project) (settings-error-file c))) content)
        (ok (equal content (read-file project ".cl-stack-code/settings.local.json"))
            "nothing is written")))))
