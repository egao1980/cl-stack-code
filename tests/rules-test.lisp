(in-package #:cl-stack-code/tests)

;;; H3e-1: rules (src/rules.lisp): roots, the format, globs, the lazy
;;; discovery and its once-per-session set, the turn records.

(defun rule-paths-of (rules)
  (mapcar #'steer:steer-directive-path rules))

;;; The format.

(deftest rules-parse-block-list
  (with-project (project config) (list (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp" "src/**/*.asd") "Lisp rule.")))
    (let ((rule (parse-rule-file (merge-pathnames ".claude/rules/lisp.md" project))))
      (ok (eq :rule (steer:steer-directive-kind rule)))
      (ok (equal '("**/*.lisp" "src/**/*.asd") (rule-patterns rule))
          "a YAML block list; comments and Cursor's globs / alwaysApply ignored")
      (ok (not (rule-always-p rule)))
      (ok (equal "Lisp rule." (steer:steer-directive-body rule))))))

(deftest rules-parse-comma-string
  (with-project (project config) '((".claude/rules/web.md" "---
paths: \"src/**/*.ts, , lib/*.js\"
---
Web.
"))
    (ok (equal '("src/**/*.ts" "lib/*.js")
               (rule-patterns (parse-rule-file (merge-pathnames ".claude/rules/web.md" project))))
        "split at commas, trimmed, empty pieces dropped")))

(deftest-parametrize rules-always-on
    ((text)
     :ids ("no-frontmatter" "no-paths" "empty-paths")
     ("Always.
")
     ("---
description: d
---
Always.
")
     ("---
paths: []
---
Always.
"))
  (with-project (project config) (list (list ".claude/rules/a.md" text))
    (let ((rule (parse-rule-file (merge-pathnames ".claude/rules/a.md" project))))
      (ok (rule-always-p rule))
      (ok (null (rule-patterns rule)))
      (ok (equal "Always." (steer:steer-directive-body rule)))
      (ok (equal (format nil "<rule path=\"~a\">~%Always.~%</rule>"
                         (native (truename (merge-pathnames ".claude/rules/a.md" project))))
                 (rule-block rule))))))

(deftest-parametrize rules-bad-frontmatter
    ((text reason)
     :ids ("bad-yaml" "paths-number" "paths-mixed")
     ("---
paths: [unclosed
---
x
" "bad frontmatter")
     ("---
paths: 3
---
x
" "paths must be a list of strings or a comma-separated string")
     ("---
paths:
  - a
  - 2
---
x
" "paths must be a list of strings or a comma-separated string"))
  (with-project (project config) (list (list ".claude/rules/bad.md" text))
    (let* ((path (merge-pathnames ".claude/rules/bad.md" project))
           (c (failure (parse-rule-file path))))
      (ok (typep c 'rule-format-error))
      (when (typep c 'rule-format-error)
        (ok (has reason (rule-format-error-reason c))))
      (multiple-value-bind (rules notes) (discover-rules project :user-config-dir config)
        (ok (null rules) "skipped")
        (ok (= 1 (length notes)))
        (ok (uiop:string-prefix-p (format nil "rule at ~a: " (native (truename path))) (first notes)))))))

;;; Discovery.

(deftest rules-roots-and-order
  (with-project (project config) (list (list ".cl-stack-code/rules/z.md" "Z.
")
                                       (list ".claude/rules/b.md" "B.
")
                                       (list ".claude/rules/a/deep.md" "Deep.
")
                                       (list ".claude/rules/notes.txt" "not a rule
")
                                       (list ".lisp-workspace/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp."))
                                       "src/")
    (write-file config "rules/mine.md" "Mine.
")
    (ok (same-paths (list (subdir project ".cl-stack-code/rules/") (subdir project ".claude/rules/")
                          (subdir project ".lisp-workspace/rules/") (subdir config "rules/"))
                    (rule-roots (subdir project "src/") :user-config-dir config)))
    (multiple-value-bind (rules notes) (discover-rules (subdir project "src/") :user-config-dir config)
      (ok (same-paths (mapcar (lambda (rel) (merge-pathnames rel project))
                              '(".cl-stack-code/rules/z.md" ".claude/rules/a/deep.md" ".claude/rules/b.md"
                                ".lisp-workspace/rules/lisp.md"))
                      (butlast (rule-paths-of rules)))
          "roots in order, recursive, by relative path; only *.md")
      (ok (same-path (merge-pathnames "rules/mine.md" config) (car (last (rule-paths-of rules)))))
      (ok (null notes)))))

#-(or windows win32)
(deftest rules-symlinked-twice-load-once
  (with-project (project config) (list (list ".lisp-workspace/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp.")))
    (ensure-directories-exist (subdir project ".claude/rules/"))
    (uiop:run-program (list "ln" "-s" "../../.lisp-workspace/rules/lisp.md"
                            (native (merge-pathnames ".claude/rules/lisp.md" project))))
    (multiple-value-bind (rules notes) (discover-rules project :user-config-dir config)
      (ok (= 1 (length rules)) "equal truenames count once")
      (ok (null notes)))))

;;; Globs.

(deftest-parametrize rules-glob-table
    ((patterns path expected)
     :ids ("root-file" "deep-file" "other-ext" "anchored-dir" "anchored-deep" "not-anchored"
           "star-one-level" "star-not-deep" "absolute-inside" "outside" "question" "bracket")
     ('("**/*.lisp") "x.lisp" t)
     ('("**/*.lisp") "src/a/b.lisp" t)
     ('("**/*.lisp") "src/a.lisp.txt" nil)
     ('("src/**/*.ts") "src/x.ts" t)
     ('("src/**/*.ts") "src/a/b/x.ts" t)
     ('("src/**/*.ts") "lib/src/x.ts" nil)
     ('("*.md") "README.md" t)
     ('("*.md") "docs/README.md" nil)
     ('("**/*.asd") :absolute t)
     ('("**/*.lisp") :outside nil)
     ('("src/?.c") "src/a.c" t)
     ('("src/[ab].c") "src/c.c" nil))
  (with-project (project config) (list (list ".claude/rules/r.md" (rule-md patterns "R.")))
    (let ((rule (parse-rule-file (merge-pathnames ".claude/rules/r.md" project)))
          (target (case path
                    (:absolute (native (merge-pathnames "sys/x.asd" project)))
                    (:outside (native (merge-pathnames "elsewhere/x.lisp" config)))
                    (t path))))
      (ok (eq expected (and (rule-matches-p rule target project) t))))))

(deftest rules-always-on-matches-nothing
  (with-project (project config) '((".claude/rules/a.md" "Always.
"))
    (ok (not (rule-matches-p (parse-rule-file (merge-pathnames ".claude/rules/a.md" project))
                             "x.lisp" project)))))

;;; Lazy discovery.

(defun lisp-rule-discovery (project config &rest keys)
  (let ((rules (discover-rules project :user-config-dir config)))
    (apply #'make-code-instruction-discovery project :rules rules :project-dir project keys)))

(deftest rules-discovery-loads-once
  (with-project (project config) (list (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp rule."))
                                       (list "src/a.lisp" "a") (list "src/b.lisp" "b") (list "notes.txt" "n"))
    (let* ((disc (lisp-rule-discovery project config))
           (rule-path (merge-pathnames ".claude/rules/lisp.md" project)))
      (ok (typep disc 'code-instruction-discovery))
      (ok (typep disc 'steer:instruction-discovery))
      (ok (null (steer:discover-instructions disc (list "notes.txt"))) "no match, nothing")
      (let ((found (steer:discover-instructions disc (list "src/a.lisp"))))
        (ok (= 1 (length found)))
        (ok (eq :rule (steer:steer-directive-kind (first found))))
        (ok (equal (native (truename rule-path)) (steer:steer-directive-name (first found))))
        (ok (equal (rule-injection rule-path '("**/*.lisp") "Lisp rule.")
                   (steer:compile-instructions found))))
      (ok (null (steer:discover-instructions disc (list "src/b.lisp"))) "once loaded, never again")
      (ok (equal (list (native (truename rule-path))) (discovery-loaded-rules disc))))))

(deftest rules-discovery-copies-share-the-set
  (with-project (project config) (list (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp rule."))
                                       (list "src/a.lisp" "a"))
    (let* ((disc (lisp-rule-discovery project config))
           (run-1 (steer:copy-instruction-discovery disc))
           (run-2 (steer:copy-instruction-discovery disc)))
      (ok (typep run-1 'code-instruction-discovery))
      (ok (= 1 (length (steer:discover-instructions run-1 (list "src/a.lisp")))))
      (ok (null (steer:discover-instructions run-2 (list "src/a.lisp")))
          "the next run of the session does not load it again")
      (ok (= 1 (length (discovery-loaded-rules disc)))))))

(deftest rules-discovery-seeded-and-forgotten
  (with-project (project config) (list (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp rule."))
                                       (list "src/a.lisp" "a"))
    (let* ((native-rule (native (truename (merge-pathnames ".claude/rules/lisp.md" project))))
           (disc (lisp-rule-discovery project config :loaded (list native-rule))))
      (ok (null (steer:discover-instructions disc (list "src/a.lisp"))) "a resumed session has it")
      (steer:forget-instructions disc)
      (ok (= 1 (length (steer:discover-instructions disc (list "src/a.lisp"))))
          "a compaction forgets it; it loads again on demand"))))

(deftest rules-discovery-keeps-nested-agents
  (with-project (project config) (list (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp rule."))
                                       (list "sub/AGENTS.md" "Sub rules.
")
                                       (list "sub/x.lisp" "x"))
    (let ((found (steer:discover-instructions (lisp-rule-discovery project config) (list "sub/x.lisp"))))
      (ok (= 2 (length found)))
      (ok (has "Sub rules." (steer:steer-directive-body (first found))) "nested AGENTS.md first, as before")
      (ok (eq :rule (steer:steer-directive-kind (second found)))))))

;;; Turn records.

(deftest rules-record-content
  (let* ((with (make-turn-record :prompt "p" :rules (list "/r/lisp.md")))
         (without (make-turn-record :prompt "p")))
    (ok (equal '("/r/lisp.md") (getf (record-content with) :rules)))
    (ok (not (member :rules (record-content without))) "older record shapes are unchanged")
    (ok (equal '("/r/lisp.md") (record-rules (content-record (record-content with)))))
    (ok (null (record-rules (content-record (record-content without)))))
    (ok (signals (content-record (append (record-content without) (list :rules '(3))))
                 'session-error))))

(deftest rules-session-loaded-rules
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (r1 (commit-turn s (simple-record "one" "1" :rules (list "/r/a.md")))))
      (commit-turn s (simple-record "two" "2"))
      (commit-turn s (simple-record "three" "3" :rules (list "/r/b.md" "/r/a.md")))
      (ok (equal '("/r/a.md" "/r/b.md") (session-loaded-rules s)) "line order, duplicates dropped")
      (ok (equal '("/r/a.md") (session-loaded-rules s (rev:revision-id r1)))
          "a rewind to turn 1 drops the later rules")
      (ok (null (session-loaded-rules (create-session dir)))))))
