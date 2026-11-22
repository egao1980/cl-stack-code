(in-package #:cl-stack-code/acp/tests)

;;; ACP-2: the client's capabilities decide where the tools go
;;; (src/acp/agent.lisp, "Client capabilities"). The RECORDING-CLIENT's
;;; buffers differ from the disk, so the model's view shows which one a
;;; read used, and the disk shows whether a write went to the client.

(defun request-after-tool (backend)
  "The text of the model's request after the first tool call."
  (request-text (second (scripted-requests backend))))

(deftest acp-tools-fs-read-through-the-client
  (with-project (project config) (list (list "a.txt" (nl "DISK")))
    (with-loopback (ra client project config :caps *zed-client-caps*
                    :steps (list (list :tool "read" (json-args "file_path" "a.txt")) "Read."))
      (set-buffer client project "a.txt" (nl "BUFFER"))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "read a"))))
        (let ((call (cdr (first (client-calls client "fs/read_text_file")))))
          (ok call "fs/read_text_file")
          (ok (and call (equal (abs-path project "a.txt") (acp:path call))) "an absolute path")
          (ok (and call (equal sid (acp:session-id call)))))
        (ok (has "BUFFER" (request-after-tool backend)) "the editor's buffer reached the model")
        (ok (not (has "DISK" (request-after-tool backend))) "not the disk")))))

(deftest acp-tools-fs-write-through-the-client
  (with-project (project config) '()
    (with-loopback (ra client project config :caps *zed-client-caps*
                    :steps (list (write-step "b.txt" (nl "NEW")) "Wrote."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "write b"))))
        (ok (= 1 (length (permission-requests client))) "still asked first")
        (let ((call (cdr (first (client-calls client "fs/write_text_file")))))
          (ok call "fs/write_text_file")
          (ok (and call (equal (abs-path project "b.txt") (acp:path call))))
          (ok (and call (equal (nl "NEW") (acp:content call)))))
        (ok (equal (nl "NEW") (buffer client project "b.txt")))
        (ok (null (read-file project "b.txt")) "the agent did not write the disk")
        (ok (equal "completed" (final-status client "call-1-1")))))))

(deftest acp-tools-fs-edit-through-the-client
  (with-project (project config) (list (list "a.txt" (nl "alpha" "DISK")))
    (with-loopback (ra client project config :caps *zed-client-caps*
                    :steps (list (list :tool "edit" (edit-args "a.txt" "alpha" "omega")) "Edited."))
      (set-buffer client project "a.txt" (nl "alpha" "BUFFER"))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "edit a"))))
        (ok (member "fs/read_text_file" (call-methods client) :test #'string=))
        (ok (equal (nl "omega" "BUFFER") (buffer client project "a.txt"))
            "the edit applied to the buffer, written back through fs/write_text_file")
        (ok (equal (nl "alpha" "DISK") (read-file project "a.txt")) "the disk untouched")
        (let ((diff (first (diffs (first (tool-calls client "call-1-1"))))))
          (ok diff)
          (ok (and diff (equal (nl "alpha" "BUFFER") (slot diff 'acp:old-text)))
              "the diff's old text is the buffer's")
          (ok (and diff (equal (nl "omega" "BUFFER") (acp:new-text diff)))))))))

(deftest acp-tools-terminal-through-the-client
  (with-project (project config) '()
    (with-loopback (ra client project config :caps *zed-client-caps*
                    :steps (list (bash-step "echo hi-local") "Ran."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "run it"))))
        (ok (= 1 (length (permission-requests client))) "bash asks first")
        (let ((create (cdr (first (client-calls client "terminal/create")))))
          (ok create "terminal/create")
          (when create
            (ok (has "echo hi-local"
                     (format nil "~a ~{~a~^ ~}" (acp:command create)
                             (coerce (or (slot create 'acp:args) #()) 'list)))
                "the command line")
            (ok (equal sid (acp:session-id create)))
            (let ((cwd (slot create 'acp:cwd)))
              (ok (and cwd (same-path project (uiop:parse-native-namestring cwd :ensure-directory t)))
                  "in the tool root"))))
        (ok (member "terminal/output" (call-methods client) :test #'string=))
        (ok (member "terminal/release" (call-methods client) :test #'string=) "released")
        (ok (has "FROM-TERMINAL" (request-after-tool backend)) "the client's output is the result")
        (ok (not (has "hi-local" (request-after-tool backend))) "nothing ran locally")
        (ok (some (lambda (u)
                    (some (lambda (c) (and (typep c 'acp:terminal) (equal "term-1" (acp:terminal-id c))))
                          (coerce (or (slot u 'acp:content) #()) 'list)))
                  (append (tool-calls client "call-1-1") (tool-call-updates client "call-1-1")))
            "the tool call shows the client's terminal")))))

(deftest acp-tools-local-without-capabilities
  (with-project (project config) (list (list "a.txt" (nl "DISK")))
    (with-loopback (ra client project config :caps *bare-client-caps*
                    :steps (list (list :tools (list "read" (json-args "file_path" "a.txt"))
                                       (list "write" (write-args "b.txt" "LOCAL"))
                                       (list "bash" (json-args "command" "echo hi-local")))
                                 "All local."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "do it all"))))
        (ok (null (intersection '("fs/read_text_file" "fs/write_text_file" "terminal/create")
                                (call-methods client) :test #'string=))
            "nothing went to the client")
        (let ((text (request-after-tool backend)))
          (ok (has "DISK" text) "read the disk")
          (ok (has "hi-local" text) "ran locally"))
        (ok (equal "LOCAL" (read-file project "b.txt")) "wrote the disk")))))

(deftest acp-tools-fs-read-only-capability
  (with-project (project config) (list (list "a.txt" (nl "DISK")))
    (with-loopback (ra client project config :caps "{\"fs\":{\"readTextFile\":true}}"
                    :steps (list (list :tools (list "read" (json-args "file_path" "a.txt"))
                                       (list "write" (write-args "b.txt" "LOCAL")))
                                 "Mixed."))
      (set-buffer client project "a.txt" (nl "BUFFER"))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "read and write"))))
        (ok (has "BUFFER" (request-after-tool backend)) "reads through the client")
        (ok (not (member "fs/write_text_file" (call-methods client) :test #'string=))
            "writeTextFile not advertised: not called")
        (ok (equal "LOCAL" (read-file project "b.txt")) "the write went to the disk")))))
