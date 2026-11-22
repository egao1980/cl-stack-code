(in-package #:cl-stack-code/tests)

;;; H3e-1: @path imports (src/imports.lisp) and the instruction context.

(defun block-of (path &rest keys)
  "INSTRUCTION-BLOCK of PATH's truename → (values block imports notes)."
  (apply #'instruction-block (truename path) keys))

;;; Tokens.

(deftest-parametrize import-tokens-table
    ((text expected)
     :ids ("line" "two-in-a-sentence" "email" "code-span" "fenced-block"
           "quoted" "escaped-space" "duplicate" "lone-at" "link-destination"
           "list-item" "home" "absolute" "heading")
     ("@AGENTS.md" '("AGENTS.md"))
     ("See @docs/a.md and @docs/b.md." '("docs/a.md" "docs/b.md."))
     ("Mail a@b.com or x@y.md." ())
     ("Write `@README` to keep it, @x.md to import." '("x.md"))
     ("```
@inside.md
```
@outside.md" '("outside.md"))
     ("@\"quoted.md\" and @'single.md'" ())
     ("@Design\\ Docs/style.md" '("Design Docs/style.md"))
     ("@a.md
@a.md" '("a.md"))
     ("a lone @ sign" ())
     ("[see](@x.md)" ())
     ("- item @list.md" '("list.md"))
     ("@~/notes/me.md" '("~/notes/me.md"))
     ("@/etc/abs.md" '("/etc/abs.md"))
     ("# Title @head.md" '("head.md")))
  (ok (equal expected (import-tokens text))))

;;; Paths.

(deftest import-resolve
  (with-project (project config) '(("docs/CLAUDE.md" "x"))
    (let ((from (truename (merge-pathnames "docs/CLAUDE.md" project))))
      (ok (same-path (merge-pathnames "docs/AGENTS.md" project) (resolve-import "AGENTS.md" from))
          "relative to the including file's directory, not the cwd")
      (ok (same-path (merge-pathnames "shared/a.md" project) (resolve-import "../shared/a.md" from)))
      (ok (same-path (merge-pathnames "notes/me.md" config)
                     (resolve-import "~/notes/me.md" from :home config))
          "~/ is HOME")
      (let ((abs (native (merge-pathnames "abs.md" config))))
        (ok (same-path abs (resolve-import abs from)) "absolute as written")))))

;;; Blocks.

(deftest import-block-without-imports
  (with-project (project config) '(("AGENTS.md" "Plain rules.

"))
    (ok (equal (top-block (merge-pathnames "AGENTS.md" project) "Plain rules.")
               (block-of (merge-pathnames "AGENTS.md" project) :boundary project))
        "H3a's block, unchanged")))

(deftest import-relative
  (with-project (project config) '(("CLAUDE.md" "@AGENTS.md
Claude part.
") ("AGENTS.md" "Agents part.
"))
    (let ((claude (merge-pathnames "CLAUDE.md" project))
          (agents (merge-pathnames "AGENTS.md" project)))
      (multiple-value-bind (block imports notes) (block-of claude :boundary project)
        (ok (equal (top-block claude (format nil "~a~%@AGENTS.md~%Claude part."
                                             (import-block agents "Agents part.")))
                   block)
            "the import first, then the including file's own text")
        (ok (= 1 (length imports)))
        (ok (same-path agents (car (first imports))))
        (ok (same-path claude (cdr (first imports))))
        (ok (null notes))))))

(deftest import-nested
  (with-project (project config) '(("CLAUDE.md" "@sub/b.md
Top.
") ("sub/b.md" "@c.md
B.
") ("sub/c.md" "C.
"))
    (let ((top (merge-pathnames "CLAUDE.md" project))
          (b (merge-pathnames "sub/b.md" project))
          (c (merge-pathnames "sub/c.md" project)))
      (multiple-value-bind (block imports) (block-of top :boundary project)
        (ok (equal (top-block top
                              (format nil "~a~%@sub/b.md~%Top."
                                      (import-block b (format nil "~a~%@c.md~%B."
                                                              (import-block c "C.")))))
                   block)
            "c.md resolves against sub/, inside b.md's import")
        (ok (same-paths (list b c) (mapcar #'car imports)) "prompt order")
        (ok (same-paths (list top b) (mapcar #'cdr imports)))))))

(deftest import-home-from-user-scope
  (with-project (project config) '()
    (write-file config "AGENTS.md" "@~/notes/me.md
User.
")
    (write-file config "notes/me.md" "Mine.
")
    (let ((user (merge-pathnames "AGENTS.md" config)))
      (ok (equal (top-block user (format nil "~a~%@~~/notes/me.md~%User."
                                         (import-block (merge-pathnames "notes/me.md" config) "Mine.")))
                 (block-of user :home config :user-scope t))))))

(deftest import-external-from-project-scope
  (with-project (project config) '(("AGENTS.md" "@~/secret.md
Project.
"))
    (write-file config "secret.md" "Secret.
")
    (let ((agents (merge-pathnames "AGENTS.md" project))
          (secret (native (truename (merge-pathnames "secret.md" config)))))
      (multiple-value-bind (block imports notes) (block-of agents :home config :boundary project)
        (ok (equal (top-block agents (format nil "[import outside the project not expanded: @~~/secret.md (~a)]~%@~~/secret.md~%Project."
                                             secret))
                   block))
        (ok (not (has "Secret." block)) "the file is not read into the prompt")
        (ok (null imports))
        (ok (equal (list (format nil "~a: import outside the project not expanded: @~~/secret.md (~a)"
                                 (native (truename agents)) secret))
                   notes))))))

(deftest import-missing
  (with-project (project config) '(("AGENTS.md" "@gone.md
Text.
"))
    (let* ((agents (merge-pathnames "AGENTS.md" project))
           (gone (native (merge-pathnames "gone.md" project))))
      (multiple-value-bind (block imports notes) (block-of agents :boundary project)
        (ok (equal (top-block agents (format nil "[import not found: @gone.md (~a)]~%@gone.md~%Text." gone))
                   block)
            "a visible note, no error")
        (ok (null imports))
        (ok (equal (list (format nil "~a: import not found: @gone.md (~a)" (native (truename agents)) gone))
                   notes))))))

(deftest import-directory-is-not-found
  (with-project (project config) '(("AGENTS.md" "@docs
") "docs/")
    (ok (has "[import not found: @docs" (block-of (merge-pathnames "AGENTS.md" project) :boundary project)))))

(deftest import-cycle
  (with-project (project config) '(("a.md" "@b.md
A.
") ("b.md" "@a.md
B.
"))
    (let ((a (merge-pathnames "a.md" project))
          (b (merge-pathnames "b.md" project)))
      (multiple-value-bind (block imports notes) (block-of a :boundary project)
        (ok (equal (top-block a (format nil "~a~%@b.md~%A."
                                        (import-block b (format nil "[import cycle: @a.md (~a) is already being included]~%@a.md~%B."
                                                                (native (truename a))))))
                   block))
        (ok (= 1 (length imports)))
        (ok (= 1 (length notes)) "reported once")
        (ok (has "import cycle: @a.md" (first notes)))
        (ok (uiop:string-prefix-p (native (truename b)) (first notes)) "named by the file that closes the cycle")))))

(deftest import-self-cycle
  (with-project (project config) '(("a.md" "@a.md
A.
"))
    (let ((a (merge-pathnames "a.md" project)))
      (multiple-value-bind (block imports notes) (block-of a :boundary project)
        (ok (has "[import cycle: @a.md" block))
        (ok (null imports))
        (ok (= 1 (length notes)))))))

(deftest import-depth-limit
  (with-project (project config) '(("f0.md" "@f1.md
0
") ("f1.md" "@f2.md
1
") ("f2.md" "@f3.md
2
") ("f3.md" "@f4.md
3
") ("f4.md" "@f5.md
4
") ("f5.md" "5
"))
    (multiple-value-bind (block imports notes) (block-of (merge-pathnames "f0.md" project) :boundary project)
      (ok (= 4 (length imports)) "hops 1 to 4 are expanded")
      (ok (same-path (merge-pathnames "f4.md" project) (car (car (last imports)))))
      (ok (has (format nil "[import not expanded: @f5.md (~a) is more than 4 hops deep]"
                       (native (truename (merge-pathnames "f5.md" project))))
               block))
      (ok (not (has (format nil "~%5~%") block)) "f5.md's text is not in the prompt")
      (ok (= 1 (length notes)))
      (ok (= 4 +max-import-hops+)))))

(deftest import-already-included
  (with-project (project config) '(("a.md" "@b.md @c.md
A.
") ("b.md" "B.
") ("c.md" "@b.md
C.
"))
    (let ((b (native (truename (merge-pathnames "b.md" project)))))
      (multiple-value-bind (block imports notes) (block-of (merge-pathnames "a.md" project) :boundary project)
        (ok (= 1 (count-of (import-block (merge-pathnames "b.md" project) "B.") block))
            "b.md is expanded once")
        (ok (= 2 (length imports)) "b.md and c.md")
        (ok (has (format nil "[import already included: @b.md (~a)]" b) block))
        (ok (= 1 (length notes)))))))

(deftest import-seen-across-files
  (with-project (project config) '(("a.md" "@b.md
A.
") ("b.md" "B.
"))
    (let ((seen (make-hash-table :test #'equal)))
      (setf (gethash (native (truename (merge-pathnames "b.md" project))) seen) t)
      (multiple-value-bind (block imports) (block-of (merge-pathnames "a.md" project)
                                                     :boundary project :seen seen)
        (ok (has "[import already included: @b.md" block) "shown earlier in this prompt")
        (ok (null imports))
        (ok (gethash (native (truename (merge-pathnames "a.md" project))) seen)
            "the top-level file joins SEEN")))))

(deftest import-not-in-code
  (with-project (project config) '(("AGENTS.md" "Keep `@x.md` literal.

```
@x.md
```
") ("x.md" "X TEXT
"))
    (multiple-value-bind (block imports notes) (block-of (merge-pathnames "AGENTS.md" project) :boundary project)
      (ok (not (has "X TEXT" block)))
      (ok (null imports))
      (ok (null notes)))))

(deftest import-email-is-text
  (with-project (project config) '(("AGENTS.md" "Write to dev@example.md.
") ("example.md" "NOPE
"))
    (ok (not (has "NOPE" (block-of (merge-pathnames "AGENTS.md" project) :boundary project))))))

(deftest import-escaped-space
  (with-project (project config) '(("AGENTS.md" "@Design\\ Docs/style.md
") ("Design Docs/style.md" "Styled.
"))
    (multiple-value-bind (block imports) (block-of (merge-pathnames "AGENTS.md" project) :boundary project)
      (ok (has "Styled." block))
      (ok (= 1 (length imports))))))

(deftest import-truncation-per-file
  (with-project (project config)
      (list (list "big.md" (concatenate 'string (make-string 40000 :initial-element #\x) "
@late.md
"))
            (list "late.md" "LATE
")
            (list "top.md" "@huge.md
Top.
")
            (list "huge.md" (make-string 33000 :initial-element #\y)))
    (let ((big (block-of (merge-pathnames "big.md" project) :boundary project)))
      (ok (has (format nil "[truncated: ~a is over 32000 characters]"
                       (native (truename (merge-pathnames "big.md" project))))
               big))
      (ok (not (has "LATE" big)) "a token past the cut does not count"))
    (let ((top (block-of (merge-pathnames "top.md" project) :boundary project))
          (huge (native (truename (merge-pathnames "huge.md" project)))))
      (ok (has (format nil "~a~%[truncated: ~a is over 32000 characters]~%</import>"
                       (make-string 32000 :initial-element #\y) huge)
               top)
          "an imported file has its own limit")
      (ok (not (has (make-string 32001 :initial-element #\y) top)))
      (ok (has (format nil "</import>~%@huge.md~%Top.") top)
          "the including file's text is not cut by its import"))))

;;; The instruction context.

(deftest import-context-files-and-notes
  (with-project (project config) '(("CLAUDE.md" "@docs/shared.md
Project.
") ("docs/shared.md" "Shared.
"))
    (write-file config "AGENTS.md" "User.
")
    (let* ((extra (write-file config "extra/context.md" "Context.
"))
           (missing (merge-pathnames "extra/missing.md" config))
           (ctx (load-instruction-context
                 project
                 :settings (make-settings :context-files (list extra missing))
                 :user-config-dir config :home config)))
      (ok (instruction-context-p ctx))
      (ok (same-paths (list (merge-pathnames "AGENTS.md" config) extra
                            (merge-pathnames "CLAUDE.md" project))
                      (context-files ctx))
          "user file, context files, then the project chain")
      (ok (same-paths (list (merge-pathnames "docs/shared.md" project))
                      (mapcar #'car (context-imports ctx))))
      (ok (member (format nil "context file not found: ~a" (native missing))
                  (context-notes ctx) :test #'string=))
      (ok (same-path project (context-project-dir ctx)))
      (ok (null (context-skills ctx)))
      (ok (null (context-rules ctx))))))

(deftest import-context-file-imports-anything
  (with-project (project config) '()
    (write-file config "far/away.md" "Far.
")
    (let* ((context (write-file config "ctx/context.md" "@../far/away.md
Ctx.
"))
           (ctx (load-instruction-context project
                                          :settings (make-settings :context-files (list context))
                                          :user-config-dir config :home config)))
      (ok (same-paths (list (merge-pathnames "far/away.md" config))
                      (mapcar #'car (context-imports ctx)))
          "a context file is user scope")
      (ok (null (context-notes ctx))))))

(deftest import-system-prompt
  (with-project (project config) '(("CLAUDE.md" "@.lisp-workspace/AGENTS.md
Root.
") (".lisp-workspace/AGENTS.md" "Shared agents.
"))
    (let* ((backend (make-scripted-backend '()))
           (claude (merge-pathnames "CLAUDE.md" project)))
      (multiple-value-bind (prompt files context)
          (assemble-system-prompt project :tools '("read") :backend backend
                                          :settings (make-settings) :user-config-dir config)
        (ok (same-paths (list claude) files))
        (ok (instruction-context-p context) "the context comes back")
        (ok (has (top-block claude (format nil "~a~%@.lisp-workspace/AGENTS.md~%Root."
                                           (import-block (merge-pathnames ".lisp-workspace/AGENTS.md" project)
                                                         "Shared agents.")))
                 prompt))))))
