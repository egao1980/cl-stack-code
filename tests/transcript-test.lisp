(in-package #:cl-stack-code/tests)

;;; Transcript entries, tool summaries, diffs and previews
;;; (src/transcript.lisp header). Lines are compared as W:RUNS-STRING.

(deftest-parametrize tool-call-summaries
    ((name input summary)
     :ids ("read" "write" "edit" "multi-edit" "glob" "grep" "ls" "ls-default" "bash"
           "bash-multiline" "job" "other" "object-input" "not-json" "nil-input"
           "missing-arg")
     ("read" "{\"file_path\":\"src/a.lisp\",\"offset\":3}" "read src/a.lisp")
     ("write" "{\"file_path\":\"out.txt\",\"content\":\"x\"}" "write out.txt")
     ("edit" "{\"file_path\":\"a.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}" "edit a.txt")
     ("multi_edit" "{\"file_path\":\"a.txt\",\"edits\":[]}" "multi_edit a.txt")
     ("glob" "{\"pattern\":\"**/*.lisp\"}" "glob **/*.lisp")
     ("grep" "{\"pattern\":\"defun\",\"path\":\"src\"}" "grep defun")
     ("ls" "{\"path\":\"src\"}" "ls src")
     ("ls" "{}" "ls .")
     ("bash" "{\"command\":\"git status\"}" "bash git status")
     ("bash" "{\"command\":\"make\\nmake test\"}" "bash make …")
     ("job_output" "{\"job_id\":\"j1\",\"wait_ms\":10}" "job_output j1")
     ("search" "{\"q\":\"x\"}" "search {\"q\":\"x\"}")
     ("read" :object "read src/b.lisp")
     ("read" "not json" "read not json")
     ("read" nil "read")
     ("read" "{\"offset\":1}" "read"))
  (let ((input (if (eq input :object) (args "file_path" "src/b.lisp") input)))
    (ok (equal summary (tool-call-summary name input)))))

(defun edit-result (rel old new)
  "The text agent-tools' edit returns for REL going from OLD to NEW."
  (format nil "Edited ~a: 1 replacement~%--- a/~a~%+++ b/~a~%~ahash: deadbeef"
          rel rel rel
          (diff:render-diff (diff:compute-diff (diff:find-diff-engine :text) old new :context 3)
                            :unified nil)))

(defun file-diff (rel old new &key new-file)
  (format nil "~a~%+++ b/~a~%~a"
          (if new-file "--- /dev/null" (format nil "--- a/~a" rel))
          rel
          (diff:render-diff (diff:compute-diff (diff:find-diff-engine :text) old new :context 3)
                            :unified nil)))

(deftest tool-result-diffs
  (let ((result (edit-result "a.txt" (nl "one" "two") (nl "one" "2"))))
    (ok (equal (file-diff "a.txt" (nl "one" "two") (nl "one" "2"))
               (tool-result-diff result))))
  (ok (null (tool-result-diff "Wrote a.txt (3 bytes)")))
  (ok (null (tool-result-diff "")))
  (ok (null (tool-result-diff nil))))

(deftest tool-call-previews
  (with-project (project config) '(("a.txt" "alpha
beta
gamma
") ("dup.txt" "x
x
"))
    (testing "edit: the diff the edit tool reports"
      (ok (equal (file-diff "a.txt" (nl "alpha" "beta" "gamma") (nl "alpha" "BETA" "gamma"))
                 (tool-call-preview project "edit"
                                    (json-args "file_path" "a.txt" "old_string" "beta"
                                               "new_string" "BETA")))))
    (testing "the same text agent-tools returns after the edit"
      (let* ((input (json-args "file_path" "a.txt" "old_string" "gamma" "new_string" "G"))
             (preview (tool-call-preview project "edit" input))
             (tools (at:make-file-tools :root project))
             (result (at:call-file-tool tools "edit" input)))
        (ok (stringp preview))
        (ok (equal preview (tool-result-diff result)))))
    (testing "replace_all and multi_edit"
      (ok (equal (file-diff "dup.txt" (nl "x" "x") (nl "y" "y"))
                 (tool-call-preview project "edit"
                                    (json:encode (args "file_path" "dup.txt" "old_string" "x"
                                                       "new_string" "y" "replace_all" t)))))
      (ok (equal (file-diff "a.txt" (read-file project "a.txt")
                            (nl "ALPHA" "beta" "G"))
                 (tool-call-preview project "multi_edit"
                                    (json:encode
                                     (args "file_path" "a.txt"
                                           "edits" (vector (args "old_string" "alpha"
                                                                 "new_string" "ALPHA")
                                                           (args "old_string" "beta"
                                                                 "new_string" "betA")
                                                           (args "old_string" "betA"
                                                                 "new_string" "beta"))))))))
    (testing "write"
      (ok (equal (file-diff "new.txt" "" (nl "hello") :new-file t)
                 (tool-call-preview project "write"
                                    (json-args "file_path" "new.txt" "content" (nl "hello")))))
      (ok (equal (file-diff "dup.txt" (nl "x" "x") (nl "z"))
                 (tool-call-preview project "write"
                                    (json-args "file_path" "dup.txt" "content" (nl "z"))))))
    (testing "NIL, never an error"
      (ok (null (tool-call-preview project "edit"
                                   (json-args "file_path" "dup.txt" "old_string" "x"
                                              "new_string" "y")))
          "two matches without replace_all")
      (ok (null (tool-call-preview project "edit"
                                   (json-args "file_path" "a.txt" "old_string" "nope"
                                              "new_string" "y"))))
      (ok (null (tool-call-preview project "edit"
                                   (json-args "file_path" "missing.txt" "old_string" "a"
                                              "new_string" "b"))))
      (ok (null (tool-call-preview project "edit"
                                   (json-args "file_path" "../outside.txt" "old_string" "a"
                                              "new_string" "b"))))
      (ok (null (tool-call-preview project "edit" "not json")))
      (ok (null (tool-call-preview project "read" (json-args "file_path" "a.txt"))))
      (ok (null (tool-call-preview project "bash" (json-args "command" "ls")))))))

(deftest approval-messages
  (with-project (project config) '(("a.txt" "alpha
beta
"))
    (testing "summary and diff"
      (let ((inv (proposed "c1" "edit" (json-args "file_path" "a.txt" "old_string" "beta"
                                                  "new_string" "BETA"))))
        (ok (equal (format nil "edit a.txt~%~a"
                           (string-right-trim '(#\Newline)
                                              (file-diff "a.txt" (nl "alpha" "beta")
                                                         (nl "alpha" "BETA"))))
                   (approval-message project inv)))))
    (testing "a long diff is cut at 12 lines"
      (let* ((content (format nil "~{~a~%~}" (loop for i from 1 to 30 collect (format nil "l~d" i))))
             (inv (proposed "c2" "write" (json-args "file_path" "big.txt" "content" content)))
             (diff-lines (lines (file-diff "big.txt" "" content :new-file t)))
             (message (approval-message project inv)))
        (ok (equal (format nil "write big.txt~%~{~a~%~}… +~d more lines"
                           (subseq diff-lines 0 12) (- (length diff-lines) 12))
                   message))))
    (testing "no preview: just the summary"
      (ok (equal "bash git status"
                 (approval-message project (proposed "c3" "bash" (json-args "command" "git status"))))))))

(deftest transcript-user-and-text-entries
  (ok (null (transcript-lines '() 40)))
  (ok (equal '("> fix the bug")
             (line-strings (transcript-lines (list (make-entry :kind :user :text "fix the bug")) 40))))
  (ok (equal '("> aaa bbb" "  ccc")
             (line-strings (transcript-lines (list (make-entry :kind :user :text "aaa bbb ccc")) 9)))
      "wrapped at width − 2")
  (ok (equal '("> one" "  two")
             (line-strings (transcript-lines (list (make-entry :kind :user :text (format nil "one~%two")))
                                             40))))
  (ok (equal '("interrupted")
             (line-strings (transcript-lines (list (make-entry :kind :notice :text "interrupted")) 40))))
  (ok (equal '("error: backend" "exploded")
             (line-strings (transcript-lines (list (make-entry :kind :error :text "backend exploded"))
                                             14)))))

(deftest transcript-assistant-markdown
  (let ((text (format nil "# Plan~%~%- **one**~%- `two`~%")))
    (ok (equal (line-strings (md:render-markdown text 30))
               (line-strings (transcript-lines (list (make-entry :kind :assistant :text text)) 30))))
    (testing "streaming: the last entry is a live markdown stream"
      (let ((partial (format nil "Some text~%```lisp~%(+ 1 2)~%``")))
        (ok (equal (line-strings (md:markdown-stream-lines
                                  (md:markdown-stream-append (md:make-markdown-stream :width 30)
                                                             partial)))
                   (line-strings (transcript-lines (list (make-entry :kind :assistant :text partial))
                                                   30 :streaming t))))))
    (testing "an earlier assistant entry is final even while streaming"
      (ok (equal (append (line-strings (md:render-markdown text 30))
                         '("" "> next"))
                 (line-strings (transcript-lines (list (make-entry :kind :assistant :text text)
                                                       (make-entry :kind :user :text "next"))
                                                 30 :streaming t)))))))

(deftest transcript-tool-entries
  (flet ((tool (status result &optional (name "bash") (input (json-args "command" "ls")))
           (make-entry :kind :tool :id "c1" :name name :input input :status status :result result)))
    (ok (equal '("● bash ls") (line-strings (transcript-lines (list (tool :proposed nil)) 40))))
    (ok (equal '("● bash ls") (line-strings (transcript-lines (list (tool :running nil)) 40))))
    (ok (equal '("● bash ls" "  ⎿ a.txt")
               (line-strings (transcript-lines (list (tool :done (nl "a.txt"))) 40))))
    (ok (equal '("● bash ls" "  ⎿ a.txt" "    … +2 lines")
               (line-strings (transcript-lines (list (tool :done (nl "a.txt" "b.txt" "c.txt"))) 40))))
    (ok (equal '("● bash ls" "  ⎿ (no output)")
               (line-strings (transcript-lines (list (tool :done "")) 40))))
    (ok (equal '("● bash ls" "  ⎿ [exit code 1]")
               (line-strings (transcript-lines (list (tool :error "[exit code 1]")) 40))))
    (ok (equal '("● bash ls" "  ⎿ Tool bash was not run: denied" "    … +1 lines")
               (line-strings (transcript-lines (list (tool :denied (format nil "Tool bash was not run: denied~%Do not repeat it."))) 40))))
    (testing "the header is cut at the width"
      (ok (equal (list (w:runs-string (w:truncate-runs (list (w:text-run "● bash a very long command line")) 16)))
                 (line-strings (transcript-lines (list (tool :proposed nil "bash"
                                                             (json-args "command" "a very long command line")))
                                                 16)))))
    (testing "a finished edit shows its diff"
      (let* ((old (nl "alpha" "beta")) (new (nl "alpha" "BETA"))
             (result (edit-result "a.txt" old new))
             (entry (tool :done result "edit" (json-args "file_path" "a.txt"))))
        (ok (equal (cons "● edit a.txt"
                         (indent-lines "  " (md:render-diff-lines (file-diff "a.txt" old new) 38)))
                   (line-strings (transcript-lines (list entry) 40))))))
    (testing "entries are separated by one empty line"
      (ok (equal '("> hi" "" "● bash ls" "" "done")
                 (line-strings (transcript-lines (list (make-entry :kind :user :text "hi")
                                                       (tool :proposed nil)
                                                       (make-entry :kind :notice :text "done"))
                                                 40)))))))
