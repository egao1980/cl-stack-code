(in-package #:cl-stack-code/tests)

;;; ACP-2: the --acp flag in the core (src/arguments.lisp CHECK-ACP-FLAGS,
;;; src/rpc.lisp %RUN-ACP). The core never loads the ACP server here: the
;;; tests bind *ACP-SERVER* to a recorder, or *ACP-SYSTEM* to a system that
;;; does not exist. The server itself is cl-stack-code/acp's suite.

(deftest acp-flag-parse
  (let ((i (parse-arguments '("--acp" "--cwd" "x" "--model" "mock" "--plan-area" "copy"
                              "--permission-mode" "acceptEdits"))))
    (ok (invocation-acp-p i))
    (ok (not (invocation-rpc-p i)))
    (ok (eq t (check-acp-flags i)))
    (ok (not (invocation-acp-p (parse-arguments '("-p" "hi")))))
    (ok (eq t (check-acp-flags (parse-arguments '("--rpc")))) "no --acp: nothing to check")))

(deftest-parametrize acp-flag-errors
    ((argv message)
     :ids ("rpc" "print" "prompt" "output-format" "continue" "resume" "session-id"
           "list-sessions" "apply" "rewind" "list-checkpoints")
     ('("--acp" "--rpc") "--acp and --rpc cannot be used together")
     ('("--acp" "-p") "--acp and -p cannot be used together")
     ('("--acp" "hello") "--acp takes no prompt (send session/prompt)")
     ('("--acp" "--output-format" "json") "--acp writes ACP JSON-RPC; --output-format is for -p")
     ('("--acp" "--continue") "--acp opens sessions with session/new and session/load")
     ('("--acp" "--resume" "abcd") "--acp opens sessions with session/new and session/load")
     ('("--acp" "--session-id" "abcd") "--acp opens sessions with session/new and session/load")
     ('("--acp" "--list-sessions") "--acp opens sessions with session/new and session/load")
     ('("--acp" "--apply") "--acp takes none of --apply")
     ('("--acp" "--rewind" "1") "--acp takes none of --apply")
     ('("--acp" "--list-checkpoints") "--acp takes none of --apply"))
  (let ((c (failure (check-acp-flags (parse-arguments argv)))))
    (ok (typep c 'code-usage-error) (princ-to-string c))
    (ok (has message (princ-to-string c)) (princ-to-string c))))

(deftest acp-run-cli-flag-errors-exit-2
  (with-project (project config) '()
    (let ((*acp-server* (lambda (&rest args) (declare (ignore args)) 0)))
      (multiple-value-bind (exit out err) (code project config '("--acp" "--rpc"))
        (ok (eql 2 exit))
        (ok (equal "" out) "nothing on stdout")
        (ok (has "--acp and --rpc cannot be used together" err))))))

(deftest acp-run-cli-calls-the-server
  (with-project (project config) '()
    (let* ((got nil)
           (stdout-inside nil)
           (*acp-server* (lambda (&rest args &key output &allow-other-keys)
                           (setf got args
                                 stdout-inside (not (eq *standard-output* output)))
                           (write-string "{}" output)
                           7)))
      (multiple-value-bind (exit out err)
          (code project config '("--acp" "--plan-area" "copy" "--permission-mode" "acceptEdits")
                :input "")
        (ok (eql 7 exit) "the server's value is the exit code")
        (ok (equal "{}" out) "the server writes to RUN-CLI's OUTPUT")
        (ok (equal "" err) err)
        (ok stdout-inside "*STANDARD-OUTPUT* is not the protocol stream while serving")
        (ok (same-path project (getf got :cwd)) "the resolved --cwd")
        (ok (eq :copy (getf got :plan-area)))
        (ok (typep (getf got :settings) 'settings))
        (ok (equal "mock" (settings-model (getf got :settings))) "the flag layer")
        (ok (eq :accept-edits (settings-permission-mode (getf got :settings))))
        (ok (assoc "mock" (getf got :providers) :test #'equal))
        (ok (same-path config (getf got :user-config-dir)))
        (ok (same-path (data-dir-of config) (getf got :data-dir)))
        (ok (functionp (getf got :getenv)))
        (ok (streamp (getf got :input)))))))

(deftest acp-run-cli-bad-cwd-exit-2
  (with-project (project config) '()
    (let ((*acp-server* (lambda (&rest args) (declare (ignore args)) 0)))
      (multiple-value-bind (exit out err)
          (code project config (list "--acp" "--cwd" (native (merge-pathnames "missing/" project)))
                :cwd nil)
        (ok (eql 2 exit))
        (ok (equal "" out))
        (ok (has "is not a directory" err) err)))))

(deftest acp-run-cli-without-the-server-system
  (with-project (project config) '()
    (let ((*acp-server* nil)
          (*acp-system* "cl-stack-code-no-such-acp-system"))
      (multiple-value-bind (exit out err) (code project config '("--acp"))
        (ok (eql 2 exit))
        (ok (equal "" out) "nothing on stdout")
        (ok (has "--acp needs the cl-stack-code-no-such-acp-system system" err) err)))))

;;; #38: cl-stack-code installed from OCI had no acp-protocol /
;;; acp-backend-stdio (only cl-stack-code/acp depends on them), so --acp
;;; failed with ASDF's 'Component "acp-protocol" not found'.

(deftest acp-run-cli-missing-server-dependency
  ;; A stand-in for cl-stack-code/acp whose dependency is not installed.
  (with-project (project config :base base) '()
    (let* ((name "cl-stack-code-acp-missing-dependency-fixture")
           (asd (merge-pathnames (format nil "fixture/~a.asd" name) base)))
      (write-file base (format nil "fixture/~a.asd" name)
                  (format nil "(defsystem ~s :depends-on (\"cl-stack-code-no-such-dependency\"))~%"
                          name))
      (asdf:load-asd asd)
      (unwind-protect
           (let ((*acp-server* nil)
                 (*acp-system* name))
             (multiple-value-bind (exit out err) (code project config '("--acp"))
               (ok (eql 2 exit) "a usage error, exit 2")
               (ok (equal "" out) "nothing on stdout")
               (ok (has "--acp needs the cl-stack-code-acp-missing-dependency-fixture system" err) err)
               (ok (has "cl-stack-code-no-such-dependency" err) "names what is missing")
               (ok (has "ensure-system-dependencies" err) "and how to install it")))
        (asdf:clear-system name)))))

(defun %dep-name (dep)
  "The system name of an ASDF dependency spec (string, (:version …), (:feature …))."
  (cond ((stringp dep) dep)
        ((symbolp dep) (string-downcase (symbol-name dep)))
        ((eq :version (first dep)) (%dep-name (second dep)))
        ((eq :feature (first dep)) (%dep-name (third dep)))
        (t nil)))

(defun %dep-version (dep)
  (cond ((atom dep) nil)
        ((eq :version (first dep)) (third dep))
        ((eq :feature (first dep)) (%dep-version (third dep)))
        (t nil)))

(deftest acp-install-roots-in-the-core
  ;; cl-repo publishes a package's :depends-on (feature expressions ignored)
  ;; as its install closure; ASDF loads only what holds.
  (let ((core (asdf:system-depends-on (asdf:find-system "cl-stack-code")))
        (acp (asdf:system-depends-on (asdf:find-system "cl-stack-code/acp"))))
    (dolist (dep acp)
      (let ((name (%dep-name dep)))
        (unless (equal name "cl-stack-code")
          (let ((root (find name core :key #'%dep-name :test #'equal)))
            (ok root (format nil "~a (cl-stack-code/acp's) is in cl-stack-code's install closure" name))
            (when (and root (%dep-version dep))
              (ok (equal (%dep-version dep) (%dep-version root))
                  (format nil "~a: the same minimum version (~a)" name (%dep-version dep))))))))
    (dolist (name '("acp-protocol" "acp-backend-stdio"))
      (let ((root (find name core :key #'%dep-name :test #'equal)))
        (ok (and (consp root) (eq :feature (first root)) (not (uiop:featurep (second root))))
            (format nil "~a: an install root, never loaded with the core" name))))))
