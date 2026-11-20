(in-package #:cl-stack-code/tests)

;;; Settings files, their parse errors and restarts, and the merge rules.

(defparameter +full-settings+
  "{\"model\": \"openai:gpt-x\",
    \"maxTurns\": 7,
    \"permissionMode\": \"plan\",
    \"permissions\": {\"allow\": [\"read\", \"bash(git *)\"],
                      \"ask\": [\"edit(src/*)\"],
                      \"deny\": [{\"tool\": \"bash\", \"resource\": \"program:rm\",
                                \"feedback\": \"Use trash.\"}]},
    \"env\": {\"FOO\": \"bar\", \"GONE\": null},
    \"appendSystemPrompt\": \"Answer in French.\",
    \"someFutureKey\": {\"x\": 1}}")

(deftest settings-parse-every-key
  (let ((s (parse-settings +full-settings+)))
    (ok (equal "openai:gpt-x" (settings-model s)))
    (ok (eql 7 (settings-max-turns s)))
    (ok (eq :plan (settings-permission-mode s)))
    (ok (equal '(("read" "*" :allow) ("bash" "bash:git *" :allow))
               (rule-lists (settings-allow s))))
    (ok (equal '(("edit" "path:src/*" :ask)) (rule-lists (settings-ask s))))
    (ok (equal '(("bash" "program:rm" :deny)) (rule-lists (settings-deny s))))
    (ok (equal "Use trash." (a:permission-rule-feedback (first (settings-deny s)))))
    (ok (equal '(("FOO" . "bar") ("GONE")) (settings-env s)) "null → unset")
    (ok (equal "Answer in French." (settings-append-system-prompt s)))
    (ok (null (settings-files s)) "no FILE given")))

(deftest settings-empty-object
  (let ((s (parse-settings "{}")))
    (ok (settings-p s))
    (ok (null (settings-model s)))
    (ok (null (settings-allow s)))))

(deftest settings-file-missing-and-present
  (with-project (project config) '()
    (ok (null (read-settings-file (merge-pathnames "nope.json" config))))
    (let* ((path (write-file config "settings.json" "{\"model\": \"mock:a\"}"))
           (s (read-settings-file path)))
      (ok (equal "mock:a" (settings-model s)))
      (ok (equal (list (truename path)) (mapcar #'truename (settings-files s)))))))

(deftest settings-bad-json
  (with-project (project config) '()
    (let* ((path (write-file config "settings.json" "{\"model\": "))
           (c (failure (read-settings-file path))))
      (ok (typep c 'settings-error))
      (ok (and (typep c 'settings-error)
               (equal (truename path) (truename (settings-error-file c)))))
      (ok (and (typep c 'settings-error) (null (settings-error-key c))))
      (ok (has "settings.json" (princ-to-string c))))
    (testing "not an object"
      (let ((c (failure (parse-settings "[1, 2]"))))
        (ok (typep c 'settings-error))
        (ok (and (typep c 'settings-error) (null (settings-error-key c))))))))

(deftest-parametrize settings-wrong-types
    ((json key)
     :ids ("model" "maxTurns-string" "maxTurns-zero" "mode" "permissions" "allow"
           "allow-item" "deny-rule" "env" "env-value" "append")
     ("{\"model\": 3}" "model")
     ("{\"maxTurns\": \"5\"}" "maxTurns")
     ("{\"maxTurns\": 0}" "maxTurns")
     ("{\"permissionMode\": \"yolo\"}" "permissionMode")
     ("{\"permissions\": []}" "permissions")
     ("{\"permissions\": {\"allow\": \"read\"}}" "permissions.allow")
     ("{\"permissions\": {\"allow\": [\"read\", 4]}}" "permissions.allow[1]")
     ("{\"permissions\": {\"deny\": [\"bash(\"]}}" "permissions.deny[0]")
     ("{\"env\": [\"A=b\"]}" "env")
     ("{\"env\": {\"A\": 1}}" "env.A")
     ("{\"appendSystemPrompt\": false}" "appendSystemPrompt"))
  (let ((c (failure (parse-settings json))))
    (ok (typep c 'settings-error))
    (ok (equal key (and (typep c 'settings-error) (settings-error-key c))))))

(deftest settings-error-restarts
  (with-project (project config) '()
    (let ((path (write-file config "settings.json" "not json")))
      (testing "CONTINUE skips the file"
        (ok (null (handler-bind ((settings-error
                                   (lambda (c)
                                     (declare (ignore c))
                                     (invoke-restart (find-restart 'continue)))))
                    (read-settings-file path)))))
      (testing "USE-VALUE supplies settings"
        (let* ((mine (make-settings :model "mock:x"))
               (got (handler-bind ((settings-error
                                     (lambda (c)
                                       (declare (ignore c))
                                       (invoke-restart (find-restart 'use-value) mine))))
                      (read-settings-file path))))
          (ok (eq mine got)))))))

(deftest settings-merge-scalars
  (let ((m (merge-settings (make-settings :model "a" :max-turns 3 :permission-mode :plan
                                          :append-system-prompt "one")
                           nil
                           (make-settings :model "b")
                           (make-settings :max-turns 9))))
    (ok (equal "b" (settings-model m)))
    (ok (eql 9 (settings-max-turns m)))
    (ok (eq :plan (settings-permission-mode m)) "unset later layers keep it")
    (ok (equal "one" (settings-append-system-prompt m))))
  (ok (settings-p (merge-settings)) "no layers → empty settings"))

(deftest settings-merge-rule-lists
  (let* ((l1 (parse-settings "{\"permissions\": {\"allow\": [\"read\", \"bash(git *)\"], \"deny\": [\"write\"]}}"))
         (l2 (parse-settings "{\"permissions\": {\"allow\": [\"grep\", \"read\"], \"ask\": [\"bash(npm *)\"]}}"))
         (m (merge-settings l1 l2)))
    (ok (equal '(("read" "*" :allow) ("bash" "bash:git *" :allow) ("grep" "*" :allow))
               (rule-lists (settings-allow m)))
        "concatenated in layer order, the later duplicate dropped")
    (ok (equal '(("bash" "bash:npm *" :ask)) (rule-lists (settings-ask m))))
    (ok (equal '(("write" "*" :deny)) (rule-lists (settings-deny m))))))

(deftest settings-merge-env
  (let ((m (merge-settings (make-settings :env '(("A" . "1") ("B" . "2") ("C" . "3")))
                           (make-settings :env '(("B" . "two") ("C") ("D" . "4")))
                           (make-settings :env '(("C" . "back"))))))
    (ok (equal '(("A" . "1") ("B" . "two") ("C" . "back") ("D" . "4")) (settings-env m))))
  (let ((m (merge-settings (make-settings :env '(("A" . "1")))
                           (make-settings :env '(("A"))))))
    (ok (equal '(("A")) (settings-env m)) "a later null unsets")))

(deftest settings-merge-files
  (let ((m (merge-settings (make-settings :files (list #p"/a.json"))
                           (make-settings)
                           (make-settings :files (list #p"/b.json")))))
    (ok (equal (list #p"/a.json" #p"/b.json") (settings-files m)))))

(deftest settings-config-directory
  (ok (same-path (uiop:ensure-directory-pathname "/x/code-config")
             (user-config-directory :getenv (env-lookup "CL_STACK_CODE_CONFIG_DIR" "/x/code-config"
                                                        "XDG_CONFIG_HOME" "/y"))))
  (ok (same-path (uiop:ensure-directory-pathname "/y/cl-stack-code")
             (user-config-directory :getenv (env-lookup "XDG_CONFIG_HOME" "/y"))))
  (ok (same-path (uiop:ensure-directory-pathname "/y/cl-stack-code")
             (user-config-directory :getenv (env-lookup "CL_STACK_CODE_CONFIG_DIR" "relative/dir"
                                                        "XDG_CONFIG_HOME" "/y")))
      "a relative value is ignored")
  (ok (same-path (merge-pathnames ".config/cl-stack-code/" (user-homedir-pathname))
             (user-config-directory :getenv (env-lookup "XDG_CONFIG_HOME" "")))))

(deftest settings-paths-with-project-root
  (with-project (project config) '("src/deep/")
    (let ((cwd (truename (subdir project "src/deep/"))))
      (ok (same-paths (list (merge-pathnames "settings.json" config)
                       (merge-pathnames ".cl-stack-code/settings.json" project)
                       (merge-pathnames ".cl-stack-code/settings.local.json" project))
                 (settings-file-paths cwd :user-config-dir config))))))

(deftest settings-paths-without-project-root
  (with-project (project config :git nil) '("sub/")
    (let ((cwd (truename (subdir project "sub/"))))
      (ok (same-paths (list (merge-pathnames "settings.json" config)
                       (merge-pathnames ".cl-stack-code/settings.json" cwd)
                       (merge-pathnames ".cl-stack-code/settings.local.json" cwd))
                 (settings-file-paths cwd :user-config-dir config))))))

(deftest settings-load-layers
  (with-project (project config)
      '((".cl-stack-code/settings.json"
         "{\"model\": \"mock:project\", \"maxTurns\": 4, \"permissions\": {\"allow\": [\"grep\"]}, \"env\": {\"A\": \"p\", \"B\": \"p\"}}")
        (".cl-stack-code/settings.local.json"
         "{\"maxTurns\": 5, \"permissions\": {\"deny\": [\"bash\"]}, \"env\": {\"B\": \"l\"}}"))
    (write-file config "settings.json"
                "{\"model\": \"mock:user\", \"permissionMode\": \"acceptEdits\", \"permissions\": {\"allow\": [\"read\"]}, \"env\": {\"A\": \"u\", \"U\": \"u\"}}")
    (let ((s (load-settings project :user-config-dir config
                                    :cli (make-settings :max-turns 6))))
      (ok (equal "mock:project" (settings-model s)))
      (ok (eql 6 (settings-max-turns s)))
      (ok (eq :accept-edits (settings-permission-mode s)))
      (ok (equal '(("read" "*" :allow) ("grep" "*" :allow)) (rule-lists (settings-allow s))))
      (ok (equal '(("bash" "*" :deny)) (rule-lists (settings-deny s))))
      (ok (equal '(("A" . "p") ("U" . "u") ("B" . "l")) (settings-env s)))
      (ok (equal (list (truename (merge-pathnames "settings.json" config))
                       (truename (merge-pathnames ".cl-stack-code/settings.json" project))
                       (truename (merge-pathnames ".cl-stack-code/settings.local.json" project)))
                 (mapcar #'truename (settings-files s)))))))

(deftest settings-load-sees-restarts
  (with-project (project config) '((".cl-stack-code/settings.json" "{oops"))
    (write-file config "settings.json" "{\"model\": \"mock:user\"}")
    (let ((s (handler-bind ((settings-error
                              (lambda (c)
                                (declare (ignore c))
                                (invoke-restart (find-restart 'continue)))))
               (load-settings project :user-config-dir config))))
      (ok (equal "mock:user" (settings-model s)) "the bad project file is skipped"))))

(deftest settings-mode-names
  (ok (equal '(:default :accept-edits :bypass-permissions :plan)
             (mapcar #'parse-permission-mode +permission-mode-names+)))
  (ok (equal +permission-mode-names+
             (mapcar #'permission-mode-name '(:default :accept-edits :bypass-permissions :plan))))
  (ok (null (parse-permission-mode "acceptedits")) "exact case")
  (ok (equal "default" (permission-mode-name nil))))
