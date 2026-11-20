(in-package #:cl-stack-code/tests)

;;; Views of a session (src/session-views.lisp): transcript entries, /tree,
;;; markdown and JSON export.

(defun steering-record ()
  (make-turn-record
   :prompt "fix @a.txt"
   :turns (list (llm:user-turn "fix @a.txt <file path=\"a.txt\">alpha</file>")
                (llm:assistant-turn "" :tool-calls (list (call-part "c1" "edit" "{}")))
                (llm:tool-turn "c1" "no match" :name "edit" :error-p t)
                (llm:user-turn "also check b <file path=\"b.txt\">beta</file>")
                (llm:user-turn "<instructions path=\"/p/sub/AGENTS.md\">be terse</instructions>")
                (llm:assistant-turn "done"))
   :steering (list "also check b")
   :finish :canceled))

(deftest session-entries-from-records
  (with-sessions-dir (dir)
    (let ((s (create-session dir)))
      (commit-turn s (tool-record "read a.txt"))
      (commit-turn s (steering-record))
      (let ((entries (session-entries s)))
        (ok (every #'entry-p entries))
        (ok (equal '((:user "read a.txt") (:assistant "Let me look.") (:tool "read")
                     (:assistant "It says alpha.")
                     (:user "fix @a.txt") (:tool "edit") (:user "also check b")
                     (:assistant "done") (:notice "interrupted"))
                   (mapcar #'entry-summary entries)))
        (let ((read (third entries))
              (edit (sixth entries)))
          (ok (equal "c1" (entry-id read)))
          (ok (equal "{\"file_path\":\"a.txt\"}" (entry-input read)))
          (ok (equal "alpha" (entry-result read)))
          (ok (eq :done (entry-status read)))
          (ok (not (entry-error-p read)))
          (ok (eq :error (entry-status edit)))
          (ok (entry-error-p edit))
          (ok (equal "no match" (entry-result edit)))))
      (ok (equal '((:user "read a.txt") (:assistant "Let me look.") (:tool "read")
                   (:assistant "It says alpha."))
                 (mapcar #'entry-summary (session-entries s (first (session-line s)))))
          "entries of an earlier revision")
      (ok (null (session-entries (create-session dir))) "an empty session"))))

(defun tree-fixture (dir)
  "a → b → c → e, b → d; head d. → the store."
  (let ((s (create-session dir :id "0123456789abcdef0123456789abcdef")))
    (commit s "first question" "1" :id (rev-id #\a))
    (commit s "second question" "2" :id (rev-id #\b))
    (commit s "third question" "3" :id (rev-id #\c))
    (commit s "fifth question" "5" :id (rev-id #\e))
    (move-session-head s (rev-id #\b))
    (commit s "another third" "4" :id (rev-id #\d))
    s))

(deftest session-tree-lines-branches
  (with-sessions-dir (dir)
    (let ((s (tree-fixture dir)))
      (ok (equal '("● aaaaaaaa first question"
                   "● bbbbbbbb second question"
                   "├─ ○ cccccccc third question"
                   "│  ○ eeeeeeee fifth question"
                   "└─ ● dddddddd another third  (head)")
                 (session-tree-lines s)))
      (move-session-head s (rev-id #\e))
      (ok (equal '("● aaaaaaaa first question"
                   "● bbbbbbbb second question"
                   "├─ ● cccccccc third question"
                   "│  ● eeeeeeee fifth question  (head)"
                   "└─ ○ dddddddd another third")
                 (session-tree-lines s))
          "the marks follow the head"))))

(deftest session-tree-lines-roots-and-width
  (with-sessions-dir (dir)
    (let ((s (tree-fixture dir)))
      (ok (equal '("● aaaaaaaa first question"
                   "● bbbbbbbb second question"
                   "├─ ○ cccccccc third question"
                   "│  ○ eeeeeeee fifth question"
                   "└─ ● dddddddd another…  (head)")
                 (session-tree-lines s :width 30))
          "a long message is cut to the width")
      (rewind-session s 3)
      (commit s "a new start" "n" :id (rev-id #\f))
      (ok (equal '("○ aaaaaaaa first question"
                   "○ bbbbbbbb second question"
                   "├─ ○ cccccccc third question"
                   "│  ○ eeeeeeee fifth question"
                   "└─ ○ dddddddd another third"
                   "● ffffffff a new start  (head)")
                 (session-tree-lines s))
          "a second root after rewinding everything"))
    (ok (equal '("no turns yet") (session-tree-lines (create-session dir))))))

(defun export-fixture (dir)
  (let ((s (create-session dir :id "0123456789abcdef0123456789abcdef"
                               :project-dir #p"/tmp/proj/")))
    (commit-turn s (simple-record "hello" "Hi there") :id (rev-id #\1))
    (commit-turn s (make-turn-record
                    :prompt "show a.txt"
                    :turns (list (llm:user-turn "show a.txt")
                                 (llm:assistant-turn "Reading."
                                                     :tool-calls (list (call-part "c1" "read" "{\"file_path\":\"a.txt\"}")))
                                 (llm:tool-turn "c1" "x ``` y" :name "read")
                                 (llm:assistant-turn "Done."))
                    :model "mock:beta" :permission-mode :plan :finish :max-steps
                    :usage (list 1 2 3 4))
                 :id (rev-id #\2))
    s))

(deftest export-session-markdown
  (with-sessions-dir (dir)
    (let* ((s (export-fixture dir))
           (n nil)
           (text (with-output-to-string (o) (setf n (export-session s o)))))
      (ok (eql 2 n))
      (ok (equal (nl "# Session 0123456789abcdef0123456789abcdef"
                     ""
                     "## Turn 1"
                     ""
                     "**User**"
                     ""
                     "hello"
                     ""
                     "**Assistant**"
                     ""
                     "Hi there"
                     ""
                     "## Turn 2"
                     ""
                     "**User**"
                     ""
                     "show a.txt"
                     ""
                     "**Assistant**"
                     ""
                     "Reading."
                     ""
                     "**Tool** `read` {\"file_path\":\"a.txt\"}"
                     ""
                     "````"
                     "x ``` y"
                     "````"
                     ""
                     "**Assistant**"
                     ""
                     "Done.")
                 text))
      (ok (equal (nl "# Session fedcba9876543210fedcba9876543210")
                 (with-output-to-string (o)
                   (export-session (create-session dir :id "fedcba9876543210fedcba9876543210") o)))
          "an empty session"))))

(deftest export-session-markdown-errors-and-notices
  (with-sessions-dir (dir)
    (let* ((s (create-session dir :id "0123456789abcdef0123456789abcdef"))
           (text (progn (commit-turn s (steering-record))
                        (with-output-to-string (o) (export-session s o :format :markdown)))))
      (ok (has (nl "**Tool** `edit` {} (error)" "" "```" "no match" "```") text))
      (ok (has (nl "**User**" "" "also check b") text))
      (ok (uiop:string-suffix-p text (nl "_interrupted_"))))))

(deftest export-session-json
  (with-sessions-dir (dir)
    (let* ((s (export-fixture dir))
           (text (with-output-to-string (o) (export-session s o :format :json)))
           (j (json:decode text)))
      (ok (= 1 (length (lines text))) "one line")
      (ok (equal "0123456789abcdef0123456789abcdef" (jget j "session_id")))
      (ok (equal (uiop:native-namestring #p"/tmp/proj/") (jget j "project")))
      (ok (equal (rev-id #\2) (jget j "head")))
      (ok (= 2 (length (jget j "turns"))))
      (let ((t1 (jget j "turns" 0))
            (t2 (jget j "turns" 1)))
        (ok (equal (rev-id #\1) (jget t1 "revision")))
        (ok (eq :null (jget t1 "parent")))
        (ok (equal (rev-id #\1) (jget t2 "parent")))
        (ok (equal "hello" (jget t1 "prompt")))
        (ok (equal "mock" (jget t1 "model")))
        (ok (equal "default" (jget t1 "permission_mode")))
        (ok (equal "stop" (jget t1 "finish")))
        (ok (equal "plan" (jget t2 "permission_mode")))
        (ok (equal "max_steps" (jget t2 "finish")))
        (ok (equal '(1 2 3 4) (list (jget t2 "usage" "input_tokens") (jget t2 "usage" "output_tokens")
                                    (jget t2 "usage" "cache_read_tokens")
                                    (jget t2 "usage" "cache_write_tokens"))))
        (ok (equalp #() (jget t2 "steering")))
        (ok (equal '("user" "assistant" "tool" "assistant")
                   (map 'list (lambda (m) (jget m "role")) (jget t2 "messages"))))
        (ok (equal "show a.txt" (jget t2 "messages" 0 "parts" 0 "text")))
        (ok (equal "text" (jget t2 "messages" 0 "parts" 0 "type")))
        (let ((call (jget t2 "messages" 1 "parts" 1))
              (result (jget t2 "messages" 2 "parts" 0)))
          (ok (equal "tool_call" (jget call "type")))
          (ok (equal "c1" (jget call "id")))
          (ok (equal "read" (jget call "name")))
          (ok (equal "{\"file_path\":\"a.txt\"}" (jget call "arguments")))
          (ok (equal "tool_result" (jget result "type")))
          (ok (equal "x ``` y" (jget result "content")))
          (ok (eq nil (jget result "is_error")) "false"))))))
