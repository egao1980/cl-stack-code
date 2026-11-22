(in-package #:cl-stack-code/acp/tests)

;;; ACP-2 end to end: cl-stack-code --acp in a child SBCL (RUN-CLI on its
;;; own stdin / stdout, the scripted mock LLM), driven over real pipes by
;;; acp-backend-stdio's SPAWN-ACP-AGENT and a RECORDING-CLIENT, as an
;;; editor launches it. The child's stderr goes to a file. Each child loads
;;; the systems first, so its first answer gets *CHILD-START-SECONDS*.

(defmacro sbcl-only (&body body)
  #-sbcl (declare (ignore body))
  #-sbcl '(skip "the --acp child is started with SBCL")
  #+sbcl `(progn ,@body))

(deftest acp-process-turns-and-local-tools
  (sbcl-only
    (with-project (project config) '()
      (with-acp-child (connection ra client)
          (project config (list "Hello there world."
                                (write-step "a.txt" (nl "one"))
                                "Wrote it."))
        (let ((res (initialize-child ra :caps *bare-client-caps*)))
          (ok (typep res 'acp:initialize-response) "the child answers (it may compile first)")
          (when res
            (let ((caps (slot res 'acp:agent-capabilities)))
              (dolist (feature '(:load-session :embedded-context :session-list :session-close))
                (ok (acp:agent-supports-p caps feature) (format nil "advertises ~(~a~)" feature))))
            (ok (zerop (length (or (slot res 'acp:auth-methods) #()))) "no auth methods")))
        (ok (stdio:acp-stdio-connection-process connection) "a child process")
        (let* ((new (req (new-session ra project
                                      :mcp-servers (vector (stdio-mcp-server "fs")
                                                           (http-mcp-server "web")))))
               (sid (acp:session-id new)))
          (ok (hex-id-p sid) "MCP servers from the editor do not fail the session")
          (ok (equal "default" (acp:current-mode-id (acp:modes new))))
          ;; a turn of streamed chunks
          (ok (equal "end_turn" (req (stop-reason ra sid "hi"))))
          (ok (equal '("Hello " "there " "world.") (message-chunks client)) "streamed")
          ;; a tool call that asks (allow once); no fs capability: the disk
          (clear-client client)
          (ok (equal "end_turn" (req (stop-reason ra sid "write a"))))
          (ok (= 1 (length (permission-requests client))))
          (ok (equal (nl "one") (read-file project "a.txt")) "the local write tool")
          (ok (null (member "fs/write_text_file" (call-methods client) :test #'string=)))
          (let ((diff (first (diffs (first (tool-calls client "call-2-1"))))))
            (ok diff "the write's tool_call carries a diff")
            (ok (and diff (equal (abs-path project "a.txt") (acp:path diff))))
            (ok (and diff (equal (nl "one") (acp:new-text diff)))))
          (ok (equal "completed" (final-status client "call-2-1")))
          (ok (equal "Wrote it." (message-text client)))
          ;; session/list
          (let ((info (find sid (coerce (acp:sessions (req (session-list ra))) 'list)
                            :key #'acp:session-id :test #'equal)))
            (ok info "listed")
            (ok (and info (has "hi" (slot info 'acp:title)))))
          ;; EOF: exit 0, the record on disk
          (ok (eql 0 (close-child connection)) "stdin closed: the child exits 0")
          (ok (equal '("hi" "write a") (mapcar #'record-prompt (session-dir-records project config sid)))
              "the child committed both turns"))))))

(deftest acp-process-permission-answers
  (sbcl-only
    (with-project (project config) (list (list "a.txt" (nl "alpha" "beta")))
      (with-acp-child (connection ra client)
          (project config (list (list :tool "edit" (edit-args "a.txt" "alpha" "ALPHA"))
                                (list :tool "edit" (edit-args "a.txt" "beta" "BETA"))
                                "Both."
                                (write-step "b.txt" "x")
                                "Not written."
                                (list :tools (list "write" (write-args "c.txt" "1"))
                                      (list "write" (write-args "d.txt" "2")))
                                "Neither."))
        (ok (initialize-child ra))
        (let ((sid (req (new-session-id ra project))))
          ;; allow-always: the rule covers the second edit
          (setf (client-permission client) 'acp:allow-always)
          (ok (equal "end_turn" (req (stop-reason ra sid "both"))))
          (ok (= 1 (length (permission-requests client))) "allow_always: asked once")
          (ok (equal (nl "ALPHA" "BETA") (read-file project "a.txt")))
          (ok (equal '("edit(a.txt)") (local-rules project)) "the rule is saved")
          ;; reject-once
          (clear-client client)
          (setf (client-permission client) 'acp:reject-once)
          (ok (equal "end_turn" (req (stop-reason ra sid "write b"))))
          (ok (null (read-file project "b.txt")))
          (ok (equal "failed" (final-status client "call-4-1")))
          ;; reject-always: one question for both waiting calls
          (clear-client client)
          (setf (client-permission client) 'acp:reject-always)
          (ok (equal "end_turn" (req (stop-reason ra sid "write c and d"))))
          (ok (= 1 (length (permission-requests client))))
          (ok (null (read-file project "c.txt")))
          (ok (null (read-file project "d.txt")))
          (ok (eql 0 (close-child connection))))))))

(deftest acp-process-cancel-and-modes
  (sbcl-only
    (with-project (project config) '()
      (with-acp-child (connection ra client)
          ;; the interrupted run never asks again: the next turn takes step 2
          (project config (list (bash-step (pick "sleep 30" "ping -n 30 127.0.0.1 > nul"))
                                (write-step "a.txt" "1")
                                "Wrote without asking."))
        (ok (initialize-child ra))
        (let ((sid (req (new-session-id ra project))))
          (ok (typep (req (set-mode ra sid "bypassPermissions")) 'acp:set-session-mode-response))
          (let ((turn (in-background (lambda () (prompt ra sid "sleep")))))
            (ok (wait-until (lambda () (tool-calls client "call-1-1")) :timeout 60)
                "the shell call started")
            (let ((start (get-internal-real-time)))
              (cancel ra sid)
              (ok (await turn 20) "session/cancel ends the turn")
              (ok (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 20)
                  "well before the command would finish"))
            (let ((res (first (outcome-values turn))))
              (ok (and res (equal "cancelled" (acp:stop-reason res))) (d (outcome-condition turn)))))
          (ok (null (permission-requests client)) "bypassPermissions did not ask")
          ;; set_mode acceptEdits: a write without a question
          (clear-client client)
          (req (set-mode ra sid "acceptEdits"))
          (ok (equal "end_turn" (req (stop-reason ra sid "write a"))))
          (ok (null (permission-requests client)))
          (ok (equal "1" (read-file project "a.txt")))
          (ok (eql 0 (close-child connection))))))))

(deftest acp-process-load-a-finished-session
  (sbcl-only
    (with-project (project config) (list (list "a.txt" (nl "alpha")))
      (let ((sid nil))
        ;; the first child runs a turn and exits
        (with-acp-child (connection ra client)
            (project config (list (list :tool "read" (json-args "file_path" "a.txt"))
                                  "It says alpha."))
          (ok (initialize-child ra))
          (setf sid (req (new-session-id ra project)))
          (ok (equal "end_turn" (req (stop-reason ra sid "read it"))))
          (ok (eql 0 (close-child connection))))
        ;; a second child loads it from disk
        (with-acp-child (connection ra client) (project config (list "Still alpha."))
          (let ((res (initialize-child ra)))
            (ok (and res (acp:agent-supports-p (slot res 'acp:agent-capabilities) :load-session))))
          (let ((res (req (load-session ra project sid))))
            (ok (typep res 'acp:load-session-response)))
          (ok (equal "read it" (format nil "~{~a~}" (mapcar #'chunk-text
                                                            (client-updates client 'acp:update-user-message-chunk))))
              "the prompt replayed")
          (ok (tool-calls client "call-1-1") "the tool call replayed")
          (ok (equal "It says alpha." (message-text client)) "the answer replayed")
          (clear-client client)
          (ok (equal "end_turn" (req (stop-reason ra sid "and now?"))))
          (ok (equal "Still alpha." (message-text client)))
          (ok (eql 0 (close-child connection)))
          (ok (equal '("read it" "and now?")
                     (mapcar #'record-prompt (session-dir-records project config sid)))
              "the loaded session goes on in the same record"))))))

(deftest acp-process-client-fs-and-terminal
  (sbcl-only
    (with-project (project config) (list (list "a.txt" (nl "DISK")))
      (with-acp-child (connection ra client)
          (project config (list (list :tool "read" (json-args "file_path" "a.txt"))
                                (write-step "b.txt" (nl "NEW"))
                                (bash-step "echo hi-local")
                                "Done."))
        (set-buffer client project "a.txt" (nl "BUFFER"))
        (ok (initialize-child ra :caps *zed-client-caps*))
        (let ((sid (req (new-session-id ra project))))
          (ok (equal "end_turn" (req (stop-reason ra sid "read, write, run"))))
          (let ((methods (call-methods client)))
            (dolist (m '("fs/read_text_file" "fs/write_text_file" "terminal/create"
                         "terminal/output" "terminal/release"))
              (ok (member m methods :test #'string=) m)))
          (ok (equal (nl "NEW") (buffer client project "b.txt")) "written through the client")
          (ok (null (read-file project "b.txt")) "not on the disk")
          (ok (eql 0 (close-child connection))))))))

;;; stdout carries nothing but JSON-RPC: no banner, no log line, nothing
;;; before the first answer or after the last (what broke Zed before). The
;;; child is launched here with raw pipes, and every line it writes is read.

(defstruct (raw-child (:constructor %make-raw-child (process)))
  process (lock (bt:make-lock "raw child")) (lines '()) (eof nil))

(defun raw-lines (raw)
  (bt:with-lock-held ((raw-child-lock raw)) (reverse (raw-child-lines raw))))

(defun start-raw-child (project config steps)
  "Launch the --acp child with its stdin / stdout as pipes, and a thread
collecting every stdout line."
  (let* ((process (uiop:launch-program (acp-child-argv project config steps)
                                       :input :stream :output :stream
                                       :error-output (native (child-stderr config))
                                       :if-error-output-exists :supersede
                                       :external-format :utf-8))
         (raw (%make-raw-child process)))
    (bt:make-thread
     (lambda ()
       (let ((out (uiop:process-info-output process)))
         (loop for line = (ignore-errors (read-line out nil nil))
               while line
               do (bt:with-lock-held ((raw-child-lock raw))
                    (push line (raw-child-lines raw))))
         (setf (raw-child-eof raw) t)))
     :name "raw child stdout")
    raw))

(defun raw-send (raw object)
  "Write OBJECT as one line to the child; a child that exited already (a
broken pipe) is the missing answer's failure, not this one's."
  (let ((in (uiop:process-info-input (raw-child-process raw))))
    (ignore-errors
     (write-string (json:encode object) in)
     (terpri in)
     (finish-output in))))

(defun raw-response (raw id &key (timeout 60))
  "The decoded response with ID, waiting up to TIMEOUT seconds, or NIL."
  (wait-until (lambda ()
                (find-if (lambda (m) (and (hash-table-p m) (eql id (gethash "id" m))
                                          (null (gethash "method" m))))
                         (mapcar (lambda (l) (ignore-errors (json:decode l))) (raw-lines raw))))
              :timeout timeout))

(defun json-rpc-line-p (line)
  "LINE is one whole JSON-RPC 2.0 message."
  (let ((m (ignore-errors (json:decode line))))
    (and (hash-table-p m) (equal "2.0" (gethash "jsonrpc" m)))))

(deftest acp-process-stdout-is-only-json-rpc
  (sbcl-only
    (with-project (project config) '()
      (let ((raw (start-raw-child project config (list "Hello there world."))))
        (unwind-protect
             (progn
               (raw-send raw (args "jsonrpc" "2.0" "id" 1 "method" "initialize"
                                   "params" (args "protocolVersion" 1
                                                  "clientCapabilities" (args))))
               (ok (raw-response raw 1 :timeout *child-start-seconds*) "initialize answered")
               (raw-send raw (args "jsonrpc" "2.0" "id" 2 "method" "session/new"
                                   "params" (args "cwd" (native project) "mcpServers" #())))
               (let* ((new (raw-response raw 2))
                      (sid (jget new "result" "sessionId")))
                 (ok (stringp sid) "session/new answered")
                 (raw-send raw (args "jsonrpc" "2.0" "id" 3 "method" "session/prompt"
                                     "params" (args "sessionId" sid
                                                    "prompt" (vector (args "type" "text" "text" "hi")))))
                 (ok (equal "end_turn" (jget (raw-response raw 3) "result" "stopReason"))))
               ;; EOF on stdin: the child exits 0 and closes stdout
               (ignore-errors (close (uiop:process-info-input (raw-child-process raw))))
               (ok (wait-until (lambda () (raw-child-eof raw)) :timeout 30) "stdout closed")
               (ok (wait-until (lambda () (not (uiop:process-alive-p (raw-child-process raw))))
                               :timeout 30))
               (ok (eql 0 (uiop:wait-process (raw-child-process raw))) "exit 0 at EOF")
               (let ((lines (raw-lines raw)))
                 (ok (>= (length lines) 4) "three answers and the updates")
                 (ok (every #'json-rpc-line-p lines)
                     (format nil "every stdout line is JSON-RPC: ~s"
                             (remove-if #'json-rpc-line-p lines)))
                 (ok (find-if (lambda (l) (search "\"agent_message_chunk\"" l)) lines)
                     "the updates went to stdout too")))
          (when (uiop:process-alive-p (raw-child-process raw))
            (uiop:terminate-process (raw-child-process raw) :urgent t)))))))
