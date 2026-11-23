(in-package #:cl-stack-code/tests)

;;; PARSE-ARGUMENTS: the command line → an INVOCATION whose SETTINGS is the
;;; flag layer.

(defun inv (&rest argv)
  (parse-arguments argv))

(defun inv-settings (&rest argv)
  (invocation-settings (parse-arguments argv)))

(deftest version-constant
  (ok (equal "0.16.0" +version+))
  (ok (equal "0.16.0" (asdf:component-version (asdf:find-system "cl-stack-code")))))

(deftest args-print-and-prompt
  (let ((i (inv "-p" "fix" "the" "test")))
    (ok (invocation-print-p i))
    (ok (equal "fix the test" (invocation-prompt i)))
    (ok (eq :text (invocation-output-format i)))
    (ok (null (invocation-cwd i)))
    (ok (null (invocation-help-p i)))
    (ok (null (invocation-version-p i)))
    (ok (settings-p (invocation-settings i))))
  (testing "--print is -p"
    (let ((i (inv "--print" "hi")))
      (ok (invocation-print-p i))
      (ok (equal "hi" (invocation-prompt i)))))
  (testing "no -p"
    (ok (null (invocation-print-p (inv "hi")))))
  (testing "no free argument → read input"
    (ok (null (invocation-prompt (inv "-p"))))))

(deftest args-output-format
  (ok (eq :text (invocation-output-format (inv "-p" "--output-format" "text" "x"))))
  (ok (eq :json (invocation-output-format (inv "-p" "--output-format" "json" "x"))))
  (ok (eq :stream-json (invocation-output-format (inv "-p" "--output-format" "stream-json" "x"))))
  (let ((c (failure (inv "-p" "--output-format" "yaml" "x"))))
    (ok (typep c 'code-usage-error))
    (ok (has "stream-json" (princ-to-string c)) "the message names the valid formats")))

(deftest args-layer-scalars
  (let ((s (inv-settings "-p" "--model" "anthropic:claude-x" "--max-turns" "3"
                         "--permission-mode" "acceptEdits"
                         "--append-system-prompt" "Be terse." "x")))
    (ok (equal "anthropic:claude-x" (settings-model s)))
    (ok (eql 3 (settings-max-turns s)))
    (ok (eq :accept-edits (settings-permission-mode s)))
    (ok (equal "Be terse." (settings-append-system-prompt s)))
    (ok (null (settings-files s))))
  (testing "nothing given → every scalar unset"
    (let ((s (inv-settings "-p" "x")))
      (ok (null (settings-model s)))
      (ok (null (settings-max-turns s)))
      (ok (null (settings-permission-mode s)))
      (ok (null (settings-append-system-prompt s)))
      (ok (null (settings-allow s)))
      (ok (null (settings-deny s)))
      (ok (null (settings-env s))))))

(deftest args-cwd
  (ok (equal "/some/dir" (invocation-cwd (inv "-p" "--cwd" "/some/dir" "x")))))

(deftest-parametrize args-bad-max-turns
    ((value) :ids ("zero" "negative" "word" "fraction") ("0") ("-1") ("abc") ("1.5"))
  (ok (typep (failure (inv "-p" "--max-turns" value "x")) 'code-usage-error)))

(deftest args-permission-modes
  (ok (eq :default (settings-permission-mode (inv-settings "-p" "--permission-mode" "default" "x"))))
  (ok (eq :bypass-permissions
          (settings-permission-mode (inv-settings "-p" "--permission-mode" "bypassPermissions" "x"))))
  (ok (eq :plan (settings-permission-mode (inv-settings "-p" "--permission-mode" "plan" "x"))))
  (let ((c (failure (inv "-p" "--permission-mode" "yolo" "x"))))
    (ok (typep c 'code-usage-error))
    (ok (has "acceptEdits" (princ-to-string c)))))

(deftest args-tool-rules
  (let ((s (inv-settings "-p" "--allowed-tools" "read,grep"
                         "--allowed-tools" "bash(git log --oneline)"
                         "--disallowed-tools" "bash(program:rm) write" "x")))
    (ok (equal '(("read" "*" :allow) ("grep" "*" :allow)
                 ("bash" "bash:git log --oneline" :allow))
               (rule-lists (settings-allow s))))
    (ok (equal '(("bash" "program:rm" :deny) ("write" "*" :deny))
               (rule-lists (settings-deny s))))
    (ok (null (settings-ask s))))
  (testing "a bad rule"
    (let ((c (failure (inv "-p" "--allowed-tools" "bash(" "x"))))
      (ok (typep c 'permission-rule-error))
      (ok (typep c 'code-usage-error)))))

(deftest args-unknown-option
  (ok (typep (failure (inv "-p" "--frobnicate" "x")) 'code-usage-error)))

(deftest args-help-and-version
  (ok (invocation-help-p (inv "--help")))
  (ok (invocation-version-p (inv "--version")))
  (ok (null (invocation-print-p (inv "--version")))))

(deftest args-model-param
  (let ((params (settings-model-params
                 (inv-settings "-p" "--model-param" "top_k=20" "--model-param" "top_k=40"
                               "--model-param" "mode=fast" "--model-param" "seed=null" "x"))))
    (ok (equal '(("top_k" . 40) ("mode" . "fast") ("seed" . :null)) params)
        "JSON values, else strings; the later flag wins"))
  (ok (typep (failure (inv "-p" "--model-param" "top_k" "x")) 'code-usage-error) "no =")
  (ok (typep (failure (inv "-p" "--model-param" "=1" "x")) 'code-usage-error) "empty key")
  (ok (typep (failure (inv "-p" "--model-param" "temperature=hot" "x")) 'code-usage-error)))
