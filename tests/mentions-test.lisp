(in-package #:cl-stack-code/tests)

;;; @ mentions (src/mentions.lisp header).

(deftest project-files-lists-entries
  (with-project (project config) '(("README.md" "r")
                                   ("src/alpha.lisp" "a")
                                   ("src/beta.lisp" "b")
                                   ("src/sub/gamma.lisp" "g")
                                   (".env" "x")
                                   ("build/out.o" "o")
                                   ("notes.log" "n")
                                   (".gitignore" "build/
*.log
")
                                   "empty/")
    (ok (equal '(".env" ".gitignore" "README.md" "empty/" "src/" "src/alpha.lisp"
                 "src/beta.lisp" "src/sub/" "src/sub/gamma.lisp")
               (project-files project))
        ".git and ignored entries are left out, directories end in /")
    (ok (equal '(".env" ".gitignore" "README.md") (project-files project :limit 3)))))

(deftest project-files-without-ignore-files
  (with-project (project config :git nil) '(("b.txt" "") ("a/c.txt" ""))
    (ok (equal '("a/" "a/c.txt" "b.txt") (project-files project)))))

(defparameter *files*
  '("README.md" "docs/" "docs/alpha-notes.md" "src/" "src/Alpha.lisp" "src/beta.lisp"
    "tests/" "tests/alpha-test.lisp" "zalpha.txt"))

(deftest mention-candidates-order
  (ok (equal '("@src/" "@src/Alpha.lisp" "@src/beta.lisp")
             (mention-candidates '("src/" "src/Alpha.lisp" "src/beta.lisp") "@src/"))
      "group 1 keeps FILES order")
  (ok (equal '("@docs/alpha-notes.md" "@src/Alpha.lisp" "@tests/alpha-test.lisp" "@zalpha.txt")
             (mention-candidates *files* "@alpha"))
      "a segment prefix (case-insensitive) before a plain substring")
  (ok (equal '("@zalpha.txt") (mention-candidates *files* "@zal")) "only one matches zal")
  (ok (equal '("@src/" "@src/Alpha.lisp" "@src/beta.lisp")
             (mention-candidates *files* "@SRC")))
  (ok (equal '("@docs/alpha-notes.md" "@tests/alpha-test.lisp")
             (mention-candidates *files* "@-")))
  (ok (null (mention-candidates *files* "@nothing")))
  (ok (null (mention-candidates *files* "alpha")) "no @, no candidates"))

(deftest mention-candidates-empty-query-and-limit
  (ok (equal (mapcar (lambda (f) (concatenate 'string "@" f)) (subseq *files* 0 4))
             (mention-candidates *files* "@" :limit 4)))
  (ok (= 20 (length (mention-candidates (loop for i below 50 collect (format nil "f~2,'0d.txt" i))
                                        "@f"))))
  (ok (equal '("@docs/alpha-notes.md") (mention-candidates *files* "@alpha" :limit 1))))

(deftest expand-mentions-attaches-files
  (with-project (project config) '(("src/a.lisp" "(defun a ()
  1)

") ("notes.txt" "n"))
    (multiple-value-bind (prompt rels) (expand-mentions "look at @src/a.lisp, then @notes.txt." project)
      (ok (equal (format nil "look at @src/a.lisp, then @notes.txt.~%~%<file path=\"src/a.lisp\">~%(defun a ()~%  1)~%</file>~%~%<file path=\"notes.txt\">~%n~%</file>")
                 prompt))
      (ok (equal '("src/a.lisp" "notes.txt") rels)))
    (testing "a file mentioned twice is attached once"
      (multiple-value-bind (prompt rels) (expand-mentions "@notes.txt and (@notes.txt)" project)
        (ok (equal (format nil "@notes.txt and (@notes.txt)~%~%<file path=\"notes.txt\">~%n~%</file>")
                   prompt))
        (ok (equal '("notes.txt") rels))))))

(deftest expand-mentions-leaves-other-text
  (with-project (project config) '(("src/a.lisp" "a") ("bin.dat" ""))
    (write-bytes project "bin.dat" #(255 254 0 1))
    (dolist (text (list "no mentions here"
                        "mail me at me@src/a.lisp"
                        "@missing.txt"
                        "@src/"
                        "@src"
                        "@../outside.txt"
                        "@bin.dat"
                        "@"))
      (multiple-value-bind (prompt rels) (expand-mentions text project)
        (ok (equal text prompt) text)
        (ok (null rels) text)))))

(deftest expand-mentions-truncates
  (let ((big (make-string 32010 :initial-element #\x)))
    (with-project (project config) (list (list "big.txt" big))
      (ok (equal (format nil "@big.txt~%~%<file path=\"big.txt\">~%~a~%[truncated: big.txt is over 32000 characters]~%</file>"
                         (subseq big 0 32000))
                 (expand-mentions "@big.txt" project)))
      (ok (= 32000 +max-mention-chars+)))))
