(in-package #:cl-stack-code/tests)

;;; --output-format json and stream-json.

(defun usage-of (object)
  (let ((u (jget object "usage")))
    (list (jget u "input_tokens") (jget u "output_tokens")
          (jget u "cache_read_tokens") (jget u "cache_write_tokens"))))

(defun hex-id-p (s)
  (and (stringp s) (= 32 (length s))
       (every (lambda (c) (find c "0123456789abcdef")) s)))

(deftest json-success-result
  (with-project (project config) '(("a.txt" "alpha
"))
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--output-format" "json" "read it")
              :steps (list (list :tool "read" (json-args "file_path" "a.txt"))
                           "It says alpha."))
      (ok (eql 0 exit))
      (ok (equal "" err))
      (ok (= 1 (length (lines out))) "one line")
      (let ((r (first (json-lines out))))
        (ok (equal "result" (jget r "type")))
        (ok (equal "success" (jget r "subtype")))
        (ok (null (jget r "is_error")))
        (ok (equal "It says alpha." (jget r "result")))
        (ok (eq :null (jget r "error")))
        (ok (eql 2 (jget r "num_turns")))
        (ok (hex-id-p (jget r "session_id")))
        (ok (and (integerp (jget r "duration_ms")) (>= (jget r "duration_ms") 0)))
        (ok (equal '(20 10 4 2) (usage-of r)) "usage summed over both steps")
        (ok (equalp #() (jget r "permission_denials")))
        (ok (equal '("duration_ms" "error" "is_error" "num_turns" "permission_denials"
                     "result" "session_id" "subtype" "type" "usage")
                   (jkeys r)))))))

(deftest json-max-turns-result
  (with-project (project config) '()
    (multiple-value-bind (exit out err)
        (code project config '("-p" "--output-format" "json" "--max-turns" "1" "go")
              :steps (list (list :tool "ls" "{}") "never"))
      (ok (eql 1 exit))
      (ok (has "max turns (1)" err))
      (let ((r (first (json-lines out))))
        (ok (equal "error_max_turns" (jget r "subtype")))
        (ok (eq t (jget r "is_error")))
        (ok (eql 1 (jget r "num_turns")))
        (ok (has "max turns (1)" (jget r "error")))))))

(deftest json-failure-result
  (with-project (project config) '()
    (multiple-value-bind (exit out) (code project config '("-p" "--output-format" "json" "go")
                                          :steps '((:error "backend exploded")))
      (ok (eql 1 exit))
      (let ((r (first (json-lines out))))
        (ok (equal "error_during_execution" (jget r "subtype")))
        (ok (eq t (jget r "is_error")))
        (ok (equal "" (jget r "result")))
        (ok (has "backend exploded" (jget r "error")))))))

(defun stream-run (project config steps &rest argv)
  (code project config (append '("-p" "--output-format" "stream-json") argv '("go")) :steps steps))

(deftest stream-json-init-and-result
  (with-project (project config) '(("AGENTS.md" "rules
"))
    (multiple-value-bind (exit out err) (stream-run project config '("Done.") "--model" "mock:big")
      (ok (eql 0 exit))
      (ok (equal "" err))
      (let* ((all (json-lines out))
             (init (first all))
             (result (car (last all))))
        (ok (equal "system" (jget init "type")))
        (ok (equal "init" (jget init "subtype")))
        (ok (equal "0.2.0" (jget init "version")))
        (ok (equal (native project) (jget init "cwd")))
        (ok (equal (native project) (jget init "project_root")))
        (ok (equal "mock:big" (jget init "model")) "the designator as given")
        (ok (equal "default" (jget init "permission_mode")))
        (ok (equalp (coerce (append at:+file-tool-names+ at:+shell-tool-names+) 'vector)
                    (jget init "tools")))
        (ok (equalp (vector (native (truename (merge-pathnames "AGENTS.md" project))))
                    (jget init "instructions")))
        (ok (equal "result" (jget result "type")))
        (ok (equal "Done." (jget result "result")))
        (ok (hex-id-p (jget init "session_id")))
        (ok (every (lambda (e) (equal (jget init "session_id") (jget e "session_id"))) all)
            "one session id in every event")))))

(deftest stream-json-text-deltas
  (with-project (project config) '()
    (let* ((out (nth-value 1 (stream-run project config '("Hello brave new world"))))
           (deltas (events out "text_delta"))
           (assistant (events out "assistant")))
      (ok (= 4 (length deltas)) "word-sized deltas from the stream")
      (ok (equal "Hello brave new world"
                 (format nil "~{~a~}" (mapcar (lambda (d) (jget d "text")) deltas))))
      (ok (every (lambda (d) (eql 1 (jget d "step"))) deltas))
      (ok (= 1 (length assistant)))
      (ok (equal "Hello brave new world" (jget (first assistant) "text")))
      (ok (equal "stop" (jget (first assistant) "finish_reason")))
      (ok (equal '(10 5 2 1) (usage-of (first assistant))) "the step's own usage"))))

(deftest stream-json-tool-events
  (with-project (project config) '(("a.txt" "alpha
"))
    (let* ((out (nth-value 1 (stream-run project config
                                         (list (list :text "Reading. "
                                                     :tools (list (list "read" (json-args "file_path" "a.txt"))
                                                                  (list "glob" (json-args "pattern" "*.txt"))))
                                               "Both done."))))
           (all (json-lines out))
           (types (mapcar (lambda (e) (jget e "type")) all))
           (uses (events out "tool_use"))
           (results (events out "tool_result")))
      (ok (equal '("system" "text_delta" "assistant" "tool_use" "tool_use" "tool_result" "tool_result"
                   "text_delta" "text_delta" "assistant" "result")
                 types)
          "deltas, assistant, tool uses, tool results per step; init first, result last")
      (ok (equal '("call-1-1" "call-1-2") (mapcar (lambda (e) (jget e "id")) uses)))
      (ok (equal '("read" "glob") (mapcar (lambda (e) (jget e "name")) uses)))
      (ok (equal "a.txt" (jget (first uses) "input" "file_path")) "input decoded as an object")
      (ok (equal '("call-1-1" "call-1-2")
                 (sort (mapcar (lambda (e) (jget e "id")) results) #'string<))
          "tools may finish in any order")
      (ok (every (lambda (e) (equal "done" (jget e "status"))) results))
      (ok (every (lambda (e) (null (jget e "is_error"))) results))
      (ok (equal "a.txt" (jget (find "glob" results :key (lambda (e) (jget e "name")) :test #'equal)
                              "content")))
      (ok (has "alpha" (jget (find "read" results :key (lambda (e) (jget e "name")) :test #'equal)
                             "content")))
      (ok (every (lambda (e) (eql 1 (jget e "step"))) (append uses results)))
      (ok (equal "tool_use" (jget (first (events out "assistant")) "finish_reason")))
      (ok (equal "Reading. " (jget (first (events out "assistant")) "text")))
      (ok (equal '(20 10 4 2) (usage-of (car (last all))))))))

(deftest stream-json-raw-input
  (with-project (project config) '()
    (let* ((out (nth-value 1 (stream-run project config
                                         (list (list :tool "read" "not json") "ok"))))
           (use (first (events out "tool_use")))
           (result (first (events out "tool_result"))))
      (ok (equal "not json" (jget use "input")) "arguments that are not an object stay a string")
      (ok (equal "error" (jget result "status")))
      (ok (eq t (jget result "is_error"))))))

(deftest stream-json-only-json-on-output
  (with-project (project config) '()
    (let ((out (nth-value 1 (stream-run project config '((:error "boom"))))))
      (ok (every (lambda (l) (hash-table-p (json:decode l))) (lines out)))
      (let ((r (car (last (json-lines out)))))
        (ok (equal "error_during_execution" (jget r "subtype")))))))
