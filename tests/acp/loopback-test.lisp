(in-package #:cl-stack-code/acp/tests)

;;; ACP-2 in process: a CODE-ACP-AGENT on the mock LLM and a RECORDING-CLIENT
;;; over acp-protocol's loopback (real JSON-RPC text, no threads of its own).
;;; The client advertises nothing here unless a test says otherwise, so the
;;; local tools run (fs / terminal: loopback-tools-test).

;;; initialize and session/new.

(deftest acp-loopback-initialize
  (with-project (project config) '()
    (with-loopback (ra client project config :initialize nil)
      (let* ((res (req (initialize ra :caps *zed-client-caps*)))
             (caps (slot res 'acp:agent-capabilities)))
        (ok (typep res 'acp:initialize-response))
        (ok (eql 1 (acp:protocol-version res)))
        (ok caps "agentCapabilities")
        (dolist (feature '(:load-session :embedded-context :session-list :session-close :mcp-http))
          (ok (acp:agent-supports-p caps feature) (format nil "advertises ~(~a~)" feature)))
        (dolist (feature '(:image :audio :session-delete :session-resume :logout :mcp-sse
                           :additional-directories :system-prompt))
          (ok (not (acp:agent-supports-p caps feature)) (format nil "does not advertise ~(~a~)" feature)))
        (ok (zerop (length (or (slot res 'acp:auth-methods) #()))) "no auth methods")
        (let ((info (slot res 'acp:agent-info)))
          (ok (and info (equal "cl-stack-code" (acp:name info))))
          (ok (and info (equal +version+ (acp:version info)))))
        (ok (search "\"authMethods\":[]" (cdr (second (wire-log ra))))
            "authMethods is on the wire, empty")
        (let ((mcp (jget (wire-result ra "initialize") "agentCapabilities" "mcpCapabilities")))
          (ok (and (hash-table-p mcp) (member (gethash "http" mcp) '(t :true))) "mcpCapabilities.http: true (#40)")
          (ok (present-false-p mcp "sse") "mcpCapabilities.sse: false (legacy SSE unsupported)"))))))

(deftest acp-loopback-new-session
  (with-project (project config) '()
    (with-loopback (ra client project config)
      (let ((res (req (new-session ra project))))
        (ok (typep res 'acp:new-session-response))
        (ok (hex-id-p (acp:session-id res)) "the SDK session id")
        (let ((modes (slot res 'acp:modes)))
          (ok modes "modes")
          (ok (and modes (equal "default" (acp:current-mode-id modes))))
          (ok (and modes (equal +acp-mode-ids+ (map 'list #'acp:id (acp:available-modes modes)))))
          (ok (and modes (every (lambda (m) (plusp (length (acp:name m))))
                                (acp:available-modes modes)))
              "each mode has a name"))
        (ok (not (equal (acp:session-id res) (acp:session-id (req (new-session ra project)))))
            "a new id each time")))))

(deftest acp-loopback-new-session-mode-from-settings
  (with-project (project config) '()
    (with-loopback (ra client project config :settings (make-settings :permission-mode :accept-edits))
      (ok (equal "acceptEdits" (acp:current-mode-id (acp:modes (req (new-session ra project)))))))))

(deftest acp-loopback-new-session-bad-cwd
  (with-project (project config) '()
    (with-loopback (ra client project config)
      (let ((c (signalled (lambda () (new-session ra (merge-pathnames "missing/" project))))))
        (ok (typep c 'acp:acp-invalid-params) (d c))
        (ok (has "is not a directory" (d c)))))))

;;; A turn.

(deftest acp-loopback-streamed-chunks
  (with-project (project config) '()
    (with-loopback (ra client project config :steps '("Hello there world."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "hi"))))
        (ok (equal '("Hello " "there " "world.") (message-chunks client))
            "one agent_message_chunk per streamed delta")
        (ok (every (lambda (n) (equal sid (acp:session-id n))) (client-notifications client))
            "every update names the session")
        (ok (updates-before-response-p ra) "every update precedes the prompt response")
        (ok (has "hi" (request-text (last-request backend))) "the prompt reached the model")))))

(deftest acp-loopback-thought-chunks
  (with-project (project config) '()
    (with-loopback (ra client project config :steps '((:think "Let me think." "Done.")))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "go"))))
        (ok (equal "Let me think." (thought-text client)) "agent_thought_chunks")
        (ok (equal "Done." (message-text client)))
        (let ((types (mapcar #'type-of (client-updates client))))
          (ok (< (position 'acp:update-agent-thought-chunk types)
                 (position 'acp:update-agent-message-chunk types))
              "the thought first"))))))

(deftest acp-loopback-tool-call-and-update
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-loopback (ra client project config
                    :steps (list (list :tool "read" (json-args "file_path" "a.txt")) "It says alpha."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "read it"))))
        (let ((call (first (tool-calls client "call-1-1"))))
          (ok call "a tool_call")
          (ok (and call (equal "read" (slot call 'acp:kind))))
          (ok (and call (equal "pending" (slot call 'acp:status))))
          (ok (and call (equal (tool-call-summary "read" (args "file_path" "a.txt")) (acp:title call))))
          (ok (and call (equal (list (abs-path project "a.txt"))
                               (map 'list #'acp:path (or (slot call 'acp:locations) #()))))))
        (ok (equal "completed" (final-status client "call-1-1")))
        (ok (some (lambda (u) (some (lambda (text) (has "alpha" text)) (text-contents u)))
                  (tool-call-updates client "call-1-1"))
            "the tool's output")
        (let ((types (mapcar #'type-of (client-updates client))))
          (ok (< (position 'acp:update-tool-call types)
                 (position 'acp:update-tool-call-update types)
                 (position 'acp:update-agent-message-chunk types))
              "tool_call, its update, then the answer"))
        (ok (null (permission-requests client)) "read needs no permission")
        (ok (equal "It says alpha." (message-text client)))))))

(deftest acp-loopback-edit-carries-a-diff
  (with-project (project config) (list (list "a.txt" (nl "alpha" "beta")))
    (with-loopback (ra client project config
                    :steps (list (list :tool "edit" (edit-args "a.txt" "alpha" "ALPHA")) "Done."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "shout"))))
        (flet ((check (where object)
                 (let ((diff (first (diffs object))))
                   (ok diff (format nil "~a carries a diff" where))
                   (when diff
                     (ok (equal (abs-path project "a.txt") (acp:path diff)) "absolute path")
                     (ok (equal (nl "alpha" "beta") (slot diff 'acp:old-text)) "the whole old text")
                     (ok (equal (nl "ALPHA" "beta") (acp:new-text diff)) "the whole new text")))))
          (check "the tool_call" (first (tool-calls client "call-1-1")))
          (let ((request (first (permission-requests client))))
            (ok request "the edit asked")
            (when request
              (check "the permission request's toolCall" (acp:tool-call request))
              (ok (equal "call-1-1" (acp:tool-call-id (acp:tool-call request))))
              (ok (equal sid (acp:session-id request))))))
        (ok (equal (nl "ALPHA" "beta") (read-file project "a.txt")) "allowed once: applied")))))

(deftest acp-loopback-write-of-a-new-file-diff
  (with-project (project config) '()
    (with-loopback (ra client project config
                    :steps (list (write-step "b.txt" (nl "new")) "Done."))
      (let ((sid (req (new-session-id ra project))))
        (req (prompt ra sid "write b"))
        (let ((diff (first (diffs (first (tool-calls client "call-1-1"))))))
          (ok diff)
          (ok (and diff (null (slot diff 'acp:old-text))) "no old text: a new file")
          (ok (and diff (equal (nl "new") (acp:new-text diff)))))))))

;;; Permission: the four answers.

(deftest acp-loopback-permission-options
  (with-project (project config) '()
    (with-loopback (ra client project config :steps (list (write-step "a.txt" "1") "Done."))
      (let ((sid (req (new-session-id ra project))))
        (req (prompt ra sid "write"))
        (let ((request (first (permission-requests client))))
          (ok request)
          (when request
            (ok (equal +acp-permission-options+
                       (map 'list (lambda (o) (list (acp:option-id o) (acp:name o) (acp:kind o)))
                            (acp:options request))))
            (let ((tc (acp:tool-call request)))
              (ok (equal "edit" (slot tc 'acp:kind)))
              (ok (equal "pending" (slot tc 'acp:status)))
              (ok (equal "a.txt" (jget (slot tc 'acp:raw-input) "file_path"))))))))))

(deftest acp-loopback-permission-allow-once
  (with-project (project config) '()
    (with-loopback (ra client project config :permission 'acp:allow-once
                    :steps (list (write-step "a.txt" "1") (write-step "a.txt" "2") "Done."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "write twice"))))
        (ok (= 2 (length (permission-requests client))) "once: the next call asks again")
        (ok (equal "2" (read-file project "a.txt")))
        (ok (equal "completed" (final-status client "call-1-1")))
        (ok (null (local-rules project)) "no rule saved")))))

(deftest acp-loopback-permission-allow-always
  (with-project (project config) (list (list "a.txt" (nl "alpha" "beta")))
    (with-loopback (ra client project config :permission 'acp:allow-always
                    :steps (list (list :tool "edit" (edit-args "a.txt" "alpha" "ALPHA"))
                                 (list :tool "edit" (edit-args "a.txt" "beta" "BETA"))
                                 "Both done."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "both"))))
        (ok (= 1 (length (permission-requests client))) "the second edit of a.txt did not ask")
        (ok (equal (nl "ALPHA" "BETA") (read-file project "a.txt")))
        (ok (equal '("edit(a.txt)") (local-rules project))
            "saved to settings.local.json, as the TUI does")))))

(deftest acp-loopback-permission-reject-once
  (with-project (project config) '()
    (with-loopback (ra client project config :permission 'acp:reject-once
                    :steps (list (write-step "b.txt" "x") "OK, I will not."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "write b"))))
        (ok (null (read-file project "b.txt")) "not written")
        (ok (equal "failed" (final-status client "call-1-1")))
        (ok (= 2 (length (scripted-requests backend))) "the model was told and answered")
        (ok (equal "OK, I will not." (message-text client)))
        (ok (null (local-rules project)))))))

(deftest acp-loopback-permission-reject-always
  (with-project (project config) '()
    (with-loopback (ra client project config :permission 'acp:reject-always
                    :steps (list (list :tools (list "write" (write-args "a.txt" "1"))
                                       (list "write" (write-args "b.txt" "2")))
                                 "Fine."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "end_turn" (req (stop-reason ra sid "write two"))))
        (ok (= 1 (length (permission-requests client))) "one question rejects every waiting call")
        (ok (null (read-file project "a.txt")))
        (ok (null (read-file project "b.txt")))
        (ok (equal "failed" (final-status client "call-1-1")))
        (ok (equal "failed" (final-status client "call-1-2")))))))

;;; Cancel.

(deftest acp-loopback-cancel-while-asking
  (with-project (project config) '()
    (with-loopback (ra client project config
                    :on-permission (lambda (client request)
                                     (cancel (client-remote client) (acp:session-id request)))
                    :steps (list (write-step "a.txt" "1") "After."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "cancelled" (req (stop-reason ra sid "write"))) "session/cancel mid-turn")
        (ok (null (read-file project "a.txt")) "the call did not run")
        (ok (= 1 (length (scripted-requests backend))) "the run did not resume")
        (setf (client-on-permission client) nil)
        (clear-client client)
        (ok (equal "end_turn" (req (stop-reason ra sid "again"))) "the session goes on")
        (ok (equal "After." (message-text client)))))))

(deftest acp-loopback-cancel-unknown-session
  (with-project (project config) '()
    (with-loopback (ra client project config)
      (ok (null (signalled (lambda () (cancel ra "ffffffffffffffffffffffffffffffff"))))
          "a notification: ignored"))))

;;; Modes.

(deftest acp-loopback-set-mode
  (with-project (project config) '()
    (with-loopback (ra client project config
                    :steps (list (write-step "a.txt" "1") "One." (write-step "b.txt" "2") "Two."))
      (let ((sid (req (new-session-id ra project))))
        (ok (typep (req (set-mode ra sid "acceptEdits")) 'acp:set-session-mode-response))
        (ok (equal '("acceptEdits")
                   (map 'list #'acp:current-mode-id (client-updates client 'acp:update-current-mode-update)))
            "a current_mode_update")
        (ok (equal "end_turn" (req (stop-reason ra sid "write a"))))
        (ok (null (permission-requests client)) "acceptEdits: no question")
        (ok (equal "1" (read-file project "a.txt")))
        (req (set-mode ra sid "default"))
        (ok (equal "end_turn" (req (stop-reason ra sid "write b"))))
        (ok (= 1 (length (permission-requests client))) "default: asks again")
        (ok (equal "2" (read-file project "b.txt")))))))

(deftest acp-loopback-set-mode-bypass
  (with-project (project config) '()
    (with-loopback (ra client project config
                    :steps (list (bash-step "echo hi-from-bash") "Ran it."))
      (let ((sid (req (new-session-id ra project))))
        (req (set-mode ra sid "bypassPermissions"))
        (ok (equal "end_turn" (req (stop-reason ra sid "run"))))
        (ok (null (permission-requests client)) "bypassPermissions: no question")
        (ok (has "hi-from-bash" (request-text (last-request backend))) "the local shell ran")))))

(deftest acp-loopback-set-mode-errors
  (with-project (project config) '()
    (with-loopback (ra client project config)
      (let ((sid (req (new-session-id ra project))))
        (ok (typep (signalled (lambda () (set-mode ra sid "yolo"))) 'acp:acp-invalid-params))
        (ok (typep (signalled (lambda () (set-mode ra "ffffffffffffffffffffffffffffffff" "plan")))
                   'acp:acp-resource-not-found))))))

(deftest acp-loopback-plan-mode
  ;; H5c-0: H5a's mode is "preview"; preview events are no longer ACP plan
  ;; updates (plan updates carry plan documents: plan-test).
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-loopback (ra client project config :plan-area :copy
                                             :steps (list (write-step "a.txt" (nl "beta")) "Previewed."))
      (let ((sid (req (new-session-id ra project))))
        (req (set-mode ra sid "preview"))
        (ok (equal "end_turn" (req (stop-reason ra sid "make it beta") :seconds 90)))
        (ok (equal (nl "alpha") (read-file project "a.txt")) "preview mode: the project is untouched")
        (ok (null (client-updates client 'acp:update-plan)) "no plan update from preview events")))))

;;; Stop reasons and errors.

(deftest acp-loopback-max-turns-and-failures
  (with-project (project config) '()
    (with-loopback (ra client project config :settings (make-settings :max-turns 1)
                    :steps (list (list :tool "ls" "{}") '(:error "backend exploded") "Fine."))
      (let ((sid (req (new-session-id ra project))))
        (ok (equal "max_turn_requests" (req (stop-reason ra sid "go"))))
        (let ((c (signalled (lambda () (prompt ra sid "again")))))
          (ok (typep c 'acp:acp-internal-error) (d c))
          (ok (has "backend exploded" (d c))))
        (ok (equal "end_turn" (req (stop-reason ra sid "once more"))) "the session goes on")))))

(deftest acp-loopback-unknown-session
  (with-project (project config) '()
    (with-loopback (ra client project config)
      (ok (typep (signalled (lambda () (prompt ra "ffffffffffffffffffffffffffffffff" "hi")))
                 'acp:acp-resource-not-found)))))

;;; Prompt content.

(deftest acp-loopback-embedded-context-and-links
  (with-project (project config) (list (list "b.txt" (nl "B-CONTENT")))
    (with-loopback (ra client project config :steps '("Seen."))
      (let ((sid (req (new-session-id ra project)))
            (notes (acp:make-acp 'acp:embedded-resource
                                 :resource (acp:make-acp 'acp:text-resource-contents
                                                         :uri "file:///elsewhere/notes.txt"
                                                         :text "NOTES-CONTENT")))
            (link (acp:make-acp 'acp:resource-link
                                :name "b.txt"
                                :uri (concatenate 'string "file://" (abs-path project "b.txt")))))
        (ok (equal "end_turn" (req (stop-reason ra sid "explain these" notes link))))
        (let ((text (request-text (last-request backend))))
          (ok (has "explain these" text))
          (ok (has "NOTES-CONTENT" text) "the embedded resource's text")
          (ok (has "B-CONTENT" text) "the linked file's content (a mention)"))))))

(deftest acp-loopback-image-refused
  (with-project (project config) '()
    (with-loopback (ra client project config :steps '("x"))
      (let ((sid (req (new-session-id ra project)))
            (image (acp:make-acp 'acp:image-content :data "iVBORw0KGgo=" :mime-type "image/png")))
        (ok (typep (signalled (lambda () (prompt ra sid "look" image))) 'acp:acp-invalid-params)
            "image is not advertised")
        (ok (null (scripted-requests backend)) "nothing ran")))))

;;; Sessions: list, close, load, the record.

(deftest acp-loopback-list-sessions
  (with-project (project config) '()
    (with-loopback (ra client project config :steps '("One."))
      (let ((sid (req (new-session-id ra project))))
        (req (prompt ra sid "first prompt"))
        (dolist (res (list (req (session-list ra)) (req (session-list ra project))))
          (ok (typep res 'acp:list-sessions-response))
          (let ((info (find sid (coerce (acp:sessions res) 'list)
                            :key #'acp:session-id :test #'equal)))
            (ok info "the session is listed")
            (when info
              (ok (same-path project (uiop:parse-native-namestring (acp:cwd info) :ensure-directory t)))
              (ok (has "first prompt" (slot info 'acp:title)))
              (let ((at (slot info 'acp:updated-at)))
                (ok (and (stringp at) (find #\T at) (char= #\Z (char at (1- (length at)))))
                    (format nil "RFC 3339 UTC: ~a" at)))))
          (ok (null (slot res 'acp:next-cursor)) "no pagination"))))))

(deftest acp-loopback-close-session
  (with-project (project config) '()
    (with-loopback (ra client project config :steps '("One."))
      (let ((sid (req (new-session-id ra project))))
        (ok (typep (req (close-session ra sid)) 'acp:close-session-response))
        (ok (typep (signalled (lambda () (prompt ra sid "hi"))) 'acp:acp-resource-not-found)
            "closed")
        (ok (typep (signalled (lambda () (close-session ra sid))) 'acp:acp-resource-not-found))))))

(deftest acp-loopback-record-on-disk
  (with-project (project config) '()
    (with-loopback (ra client project config :steps '("One." "Two."))
      (let ((sid (req (new-session-id ra project))))
        (req (prompt ra sid "first"))
        (req (prompt ra sid "second"))
        (ok (equal '("first" "second")
                   (mapcar #'record-prompt (session-dir-records project config sid)))
            "the SDK's session record, under the session id")))))

(deftest acp-loopback-load-replays-the-record
  (with-project (project config) (list (list "a.txt" (nl "alpha")))
    (with-loopback (ra client project config
                    :steps (list (list :tool "read" (json-args "file_path" "a.txt"))
                                 '(:think "Thinking it over." "It says alpha.")
                                 "Still alpha."))
      (let ((sid (req (new-session-id ra project))))
        (req (prompt ra sid "read it"))
        (req (close-session ra sid))
        (clear-client client)
        (let ((res (req (load-session ra project sid))))
          (ok (typep res 'acp:load-session-response))
          (ok (equal "default" (acp:current-mode-id (acp:modes res)))))
        (let ((types (mapcar #'type-of (client-updates client))))
          (ok (eq 'acp:update-user-message-chunk (first types)) "the prompt first")
          (ok (equal "read it" (format nil "~{~a~}" (mapcar #'chunk-text
                                                            (client-updates client 'acp:update-user-message-chunk)))))
          (ok (tool-calls client "call-1-1") "the tool call")
          (ok (equal "completed" (final-status client "call-1-1")))
          (ok (equal "Thinking it over." (thought-text client)))
          (ok (equal "It says alpha." (message-text client)))
          (ok (< (position 'acp:update-tool-call types)
                 (position 'acp:update-agent-message-chunk types))
              "in record order"))
        (ok (updates-before-response-p* ra "\"modes\"") "replayed before the response")
        (clear-client client)
        (ok (equal "end_turn" (req (stop-reason ra sid "and now?"))))
        (ok (has "It says alpha." (request-text (last-request backend))) "the history is kept")
        (ok (equal "Still alpha." (message-text client)))))))

(deftest acp-loopback-load-unknown-session
  ;; #44: only ids of the form the agent hands out open a new session.
  (with-project (project config) '()
    (with-loopback (ra client project config)
      ;; a prefix, other spellings of a session id: -32002, as before
      (dolist (id '("ffff" "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
                    "ffffffff-ffff-ffff-ffff-ffffffffffff"))
        (let ((c (signalled (lambda () (load-session ra project id)))))
          (ok (typep c 'acp:acp-resource-not-found) (format nil "~a: ~a" id c))
          (ok (and (typep c 'acp:acp-error) (equal id (jget (acp:acp-error-data c) "sessionId")))
              "data {\"sessionId\"}")))
      ;; not a session id at all: invalid params, as before
      (let ((c (signalled (lambda () (load-session ra project "nope")))))
        (ok (typep c 'acp:acp-invalid-params) (d c))))))

;;; #44: Zed restores its last thread with session/load after the agent
;;; restarts. A session that never had a turn has no record on disk (the
;;; SDK's store writes nothing before the first commit), so it used to be
;;; -32002 "No session" (Zed: "Failed to Launch").
(deftest acp-loopback-load-session-without-turns
  (with-project (project config) '()
    (let ((sid (with-loopback (ra client project config)
                 (let ((sid (req (new-session-id ra project))))
                   (ok (hex-id-p sid))
                   (ok (null (find sid (coerce (acp:sessions (req (session-list ra))) 'list)
                                   :key #'acp:session-id :test #'equal))
                       "not on disk: nothing was written")
                   sid))))
      ;; a new agent: the restarted process
      (with-loopback (ra client project config :steps '("Fresh start." "Again."))
        (let ((res (outcome-of (lambda () (load-session ra project sid)))))
          (ok (typep res 'acp:load-session-response) (d res))
          (ok (and (typep res 'acp:load-session-response)
                   (equal "default" (acp:current-mode-id (acp:modes res))))))
        (ok (null (client-updates client)) "nothing to replay")
        (ok (equal "end_turn" (req (stop-reason ra sid "hello again"))) "the session takes turns")
        (ok (equal "Fresh start." (message-text client)))
        (ok (equal '("hello again") (mapcar #'record-prompt (session-dir-records project config sid)))
            "its first turn is recorded under the id the editor knows")
        ;; closed in this agent before any further turn: loads again, with its turn
        (req (close-session ra sid))
        (clear-client client)
        (ok (typep (req (load-session ra project sid)) 'acp:load-session-response))
        (ok (equal "hello again" (format nil "~{~a~}" (mapcar #'chunk-text
                                                              (client-updates client 'acp:update-user-message-chunk))))
            "now the record is replayed")))))

(deftest acp-loopback-load-closed-session-without-turns
  ;; The same agent: session/new, session/close, session/load, no turn between.
  (with-project (project config) '()
    (with-loopback (ra client project config :steps '("Back."))
      (let ((sid (req (new-session-id ra project))))
        (req (close-session ra sid))
        (ok (typep (outcome-of (lambda () (load-session ra project sid)))
                   'acp:load-session-response))
        (ok (equal "end_turn" (req (stop-reason ra sid "hi"))))))))

;;; MCP servers from the editor: decoded, kept on the session and passed to
;;; the SDK (#40). The /usr/bin/true and example.invalid servers below fail to
;;; start, which does not fail the session.

(deftest acp-loopback-mcp-servers-kept
  (with-project (project config) '()
    (with-loopback (ra client project config :agent agent :steps '("Fine."))
      (let* ((servers (vector (stdio-mcp-server "files") (http-mcp-server "web")))
             (sid (req (acp:session-id (new-session ra project :mcp-servers servers)))))
        (ok (hex-id-p sid) "servers present: the session opens")
        (let ((kept (code-acp-agent-mcp-servers agent sid)))
          (ok (equal '("files" "web") (mcp-server-names kept)) "decoded, in order")
          (ok (typep (first kept) 'acp:mcp-server-stdio))
          (ok (and (first kept) (equal "/usr/bin/true" (acp:command (first kept)))))
          (ok (and (first kept) (equal '("--serve") (coerce (acp:args (first kept)) 'list))))
          (ok (and (first kept) (equal "TOKEN" (acp:name (aref (acp:env (first kept)) 0)))))
          (ok (typep (second kept) 'acp:mcp-server-http))
          (ok (and (second kept) (equal "https://mcp.example.invalid/mcp" (acp:url (second kept))))))
        (ok (equal "end_turn" (req (stop-reason ra sid "hi"))) "and turns run")
        (ok (null (code-acp-agent-mcp-servers agent "ffffffffffffffffffffffffffffffff"))
            "unknown session: NIL")))))

;;; #40: a stdio MCP server the editor gives in session/new connects; its
;;; tools are the session's mcp__<name>__* tools.
(deftest acp-loopback-mcp-servers-connect
  (with-project (project config :base base) '()
    (with-loopback (ra client project config :agent agent :steps '("Fine."))
      (let* ((fake (cl-stack-code/tests::fake-stdio-server base))
             (env (jget fake "env"))
             (server (acp:make-acp 'acp:mcp-server-stdio
                                   :name "ed" :command (jget fake "command")
                                   :args (coerce (jget fake "args") 'vector)
                                   :env (coerce (loop for k being the hash-keys of env
                                                        using (hash-value v)
                                                      collect (acp:make-acp 'acp:env-variable
                                                                            :name k :value v))
                                                'vector)))
             (sid (req (acp:session-id (new-session ra project :mcp-servers (vector server)))))
             (session (client-find-session (code-acp-agent-client agent) sid))
             (ed (find "ed" (client-mcp-servers session)
                       :key (lambda (s) (jget s "name")) :test #'equal)))
        (ok ed "the editor's server is the session's")
        (ok (equal "sdk" (jget ed "scope")))
        (ok (equal "connected" (jget ed "status")))
        (ok (cl-stack-code/tests::same-set
             (cl-stack-code/tests::mcp-names "ed")
             (remove-if-not (lambda (n) (uiop:string-prefix-p "mcp__" n))
                            (mapcar (lambda (tool) (jget tool "name")) (client-tools session))))
            "its tools are listed as mcp__ed__*")
        (ok (equal "end_turn" (req (stop-reason ra sid "hi"))) "and turns run")))))

(deftest acp-loopback-mcp-servers-none
  (with-project (project config) '()
    (with-loopback (ra client project config :agent agent)
      (let ((sid (req (new-session-id ra project))))
        (ok (null (code-acp-agent-mcp-servers agent sid)) "an empty mcpServers: none")))))

(deftest acp-loopback-mcp-servers-on-load
  (with-project (project config) '()
    (with-loopback (ra client project config :agent agent :steps '("One."))
      (let ((sid (req (acp:session-id (new-session ra project
                                                   :mcp-servers (vector (stdio-mcp-server "old")))))))
        (req (prompt ra sid "hi"))
        (req (close-session ra sid))
        (req (load-session ra project sid :mcp-servers (vector (http-mcp-server "new"))))
        (ok (equal '("new") (mcp-server-names (code-acp-agent-mcp-servers agent sid)))
            "session/load's servers replace the session's")))))
