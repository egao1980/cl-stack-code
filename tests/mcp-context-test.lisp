(in-package #:cl-stack-code/tests)

;;; H3e-2b: server instructions in the system prompt and deferred tool loading
;;; (src/mcp-context.lisp), with fake2: in -p, through the SDK, in the
;;; instruction set.

(defun %f2-block (&optional (text +fake2-instructions+))
  (format nil "<mcp-instructions server=\"f2\">~%~a~%</mcp-instructions>" text))

(defun %first-system (backend)
  (request-system-text (first (scripted-requests backend))))

(defun %f2-offered (request)
  "REQUEST's offered tool names of server f2, in order."
  (remove-if-not (lambda (n) (uiop:string-prefix-p "mcp__f2__" n)) (request-tool-names request)))

(defun %search-step (query)
  (list :tool "tool_search" (json-args "query" query)))

(defun %search-settings (config base &key (extra 12) server-keys mode threshold)
  "User settings: fake2 as f2 with EXTRA extra tools (SERVER-KEYS as FAKE2-SERVER's),
and \"mcpToolSearch\" MODE / \"mcpToolSearchThreshold\" THRESHOLD when given."
  (apply #'write-user-settings config
         "mcpServers" (args "f2" (apply #'fake2-server base :extra-tools extra server-keys))
         (append (and mode (list "mcpToolSearch" mode))
                 (and threshold (list "mcpToolSearchThreshold" threshold)))))

;;; Instructions

(deftest h3e2b-instructions-in-the-prompt
  (with-project (project config :base base) '()
    (user-fake2 config base :instructions +fake2-instructions+)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (let ((sys (%first-system backend)))
        (ok (and sys (uiop:string-suffix-p sys (%f2-block))) "the last section of the system prompt"))
      (ok (eq t (jget (server-object (mcp-init-servers out) "f2") "instructions"))))))

(deftest h3e2b-instructions-keep-the-prefix
  (with-project (project config :base base) '()
    (user-fake2 config base :instructions +fake2-instructions+ :include-instructions nil)
    (multiple-value-bind (exit1 out1 err1 without) (pj2 project config '("done"))
      (declare (ignore out1))
      (ok (eql 0 exit1) err1)
      (user-fake2 config base :instructions +fake2-instructions+)
      (multiple-value-bind (exit2 out2 err2 with) (pj2 project config '("done"))
        (declare (ignore out2))
        (ok (eql 0 exit2) err2)
        (ok (equal (format nil "~a~%~%~a" (%first-system without) (%f2-block)) (%first-system with))
            "the same prompt, then the block: the cached prefix is untouched")))))

(deftest h3e2b-instructions-opt-out
  (with-project (project config :base base) '()
    (user-fake2 config base :instructions +fake2-instructions+ :include-instructions nil)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (ok (not (search "<mcp-instructions" (or (%first-system backend) ""))))
      (ok (eq nil (jget (server-object (mcp-init-servers out) "f2") "instructions"))))))

;; Decided by the user, 2026-11-23: an approved project server that opts in
;; reaches the prompt; without the key, or unapproved, it does not.
(deftest h3e2b-instructions-approved-project-server-opted-in
  (with-project (project config :base base) '()
    (write-mcp-json project "f2" (fake2-server base :instructions +fake2-instructions+
                                                    :include-instructions t))
    (approve-all config)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (ok (equal "connected" (jget (server-object (mcp-init-servers out) "f2") "status")))
      (ok (uiop:string-suffix-p (or (%first-system backend) "") (%f2-block))
          "approved and opted in: its block ends the system prompt")
      (ok (eq t (jget (server-object (mcp-init-servers out) "f2") "instructions"))))))

(deftest h3e2b-instructions-approved-project-server-without-the-key
  (with-project (project config :base base) '()
    (write-mcp-json project "f2" (fake2-server base :instructions +fake2-instructions+))
    (approve-all config)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (ok (equal "connected" (jget (server-object (mcp-init-servers out) "f2") "status")) "it runs")
      (ok (not (search +fake2-instructions+ (or (%first-system backend) "")))
          "a project server needs \"includeInstructions\": true")
      (ok (eq nil (jget (server-object (mcp-init-servers out) "f2") "instructions"))))))

(deftest h3e2b-instructions-unapproved-project-server
  (with-project (project config :base base) '()
    (write-mcp-json project "f2" (fake2-server base :instructions +fake2-instructions+
                                                    :include-instructions t))
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (ok (equal "unapproved" (jget (server-object (mcp-init-servers out) "f2") "status")))
      (ok (not (search +fake2-instructions+ (or (%first-system backend) "")))
          "an unapproved server never writes the prompt")
      (ok (eq nil (jget (server-object (mcp-init-servers out) "f2") "instructions"))))))

(deftest h3e2b-instructions-capped
  (with-project (project config :base base) '()
    (let ((long (make-string 9000 :initial-element #\x)))
      (user-fake2 config base :instructions long)
      (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
        (declare (ignore out))
        (ok (eql 0 exit) err)
        (ok (uiop:string-suffix-p (or (%first-system backend) "")
                                  (%f2-block (format nil "~a~%[truncated]" (subseq long 0 8000)))))))))

(deftest h3e2b-instructions-in-the-snapshot
  (with-project (project config :base base) '()
    (user-fake2 config base :instructions +fake2-instructions+)
    (with-test-client (client backend events project config :steps '("done"))
      (let* ((s (client-new-session client))
             (store (%session-iset-store s))
             (id (%init-set s))
             (f2 (%snapshot-server (%mcp-snapshot store id) "f2")))
        (ok f2)
        (ok (%sha256-ref-p (getf f2 :instructions)) "a text hash")
        (when (%sha256-ref-p (getf f2 :instructions))
          (ok (equal +fake2-instructions+ (instruction-text store (getf f2 :instructions)))))
        (ok (equal (list (%f2-block)) (mcp-instruction-blocks store id)))
        (client-query s "hi" :timeout 60)
        (ok (uiop:string-suffix-p (or (%first-system backend) "") (%f2-block))
            "the SDK renders the prompt after the servers settled")))))

;;; Deferred tool loading

(deftest h3e2b-tool-search-auto
  (with-project (project config :base base) '()
    (%search-settings config base :threshold 5)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (let ((tools (request-tool-names (first (scripted-requests backend)))))
        (ok (equal "tool_search" (car (last tools))) "tool_search, last")
        (ok (null (%f2-offered (first (scripted-requests backend)))) "f2's 19 tools are deferred")
        (ok (equal tools (coerce (jget (init-of out) "tools") 'list)) "the init event lists what is offered"))
      (let ((ts (jget (init-of out) "mcp_tool_search")))
        (ok ts)
        (ok (equal "auto" (jget ts "mode")))
        (ok (eql 5 (jget ts "threshold")))
        (ok (eq t (jget ts "active")))
        (ok (eql (length (fake2-tools 12)) (jget ts "deferred"))))
      (let ((f2 (server-object (mcp-init-servers out) "f2")))
        (ok (eq t (jget f2 "deferred")))
        (ok (equalp #() (jget f2 "loaded")))))))

(deftest h3e2b-tool-search-loads
  (with-project (project config :base base) '()
    (%search-settings config base :threshold 5)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (list (%search-step "invoice") (f2-call "tool_03") "done")
             "--allowed-tools" "mcp__f2__tool_03")
      (ok (eql 0 exit) err)
      (let ((r (tool-result-of out "tool_search")))
        (ok (equal "done" (jget r "status")) "tool_search never asks")
        (ok (has "mcp__f2__tool_03" (or (jget r "content") "")))
        (ok (has "mcp__f2__tool_08" (or (jget r "content") "")))
        (ok (has "invoice" (or (jget r "content") "")) "with the descriptions"))
      (let ((second-request (second (scripted-requests backend))))
        (ok (member "mcp__f2__tool_03" (%f2-offered second-request) :test #'equal) "loaded for the next step")
        (ok (member "mcp__f2__tool_08" (%f2-offered second-request) :test #'equal))
        (ok (not (member "mcp__f2__tool_04" (%f2-offered second-request) :test #'equal)) "not the others")
        (ok (equal "tool_search" (car (last (request-tool-names second-request))))))
      (ok (equal "tool_03 ran" (f2-result out "tool_03")) "a loaded tool runs as any MCP tool"))))

(deftest h3e2b-tool-search-select
  (with-project (project config :base base) '()
    (%search-settings config base :threshold 5)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (list (%search-step "select:mcp__f2__tool_07,mcp__f2__echo") "done"))
      (declare (ignore out))
      (ok (eql 0 exit) err)
      (ok (same-set '("mcp__f2__echo" "mcp__f2__tool_07") (%f2-offered (second (scripted-requests backend))))
          "exactly those"))))

;; Decided by the user, 2026-11-23: a deferred tool called by name is loaded
;; and run (a skill or instructions may name it), through the permission path.
(deftest h3e2b-tool-search-call-loads
  (with-project (project config :base base) '()
    (%search-settings config base :threshold 5)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (list (f2-call "tool_03") "done") "--allowed-tools" "mcp__f2__tool_03")
      (ok (eql 0 exit) err)
      (ok (equal "tool_03 ran" (f2-result out "tool_03")) "called before any search: it runs")
      (ok (null (%f2-offered (first (scripted-requests backend)))) "it was deferred")
      (ok (equal '("mcp__f2__tool_03") (%f2-offered (second (scripted-requests backend))))
          "and is offered from the next step on")
      (ok (null (denial-of out "mcp__f2__tool_03"))))))

(deftest h3e2b-tool-search-denied-call-and-unknown-name
  (with-project (project config :base base) '()
    (%search-settings config base :threshold 5)
    (multiple-value-bind (exit out err backend)
        (pj2 project config (list (f2-call "tool_03") (f2-call "nope") "done"))
      (ok (eql 0 exit) err)
      (ok (equal "denied" (jget (tool-result-of out "mcp__f2__tool_03") "status"))
          "the normal permission path: the default ask, denied headless")
      (ok (null (%f2-offered (third (scripted-requests backend)))) "a denied call loads nothing")
      (let ((r (tool-result-of out "mcp__f2__nope")))
        (ok (eq t (jget r "is_error")) "a name no server offers stays an unknown tool")
        (ok (has "nope" (or (jget r "content") "")))))))

(deftest-parametrize h3e2b-tool-search-modes
    ((mode threshold extra active offered)
     ("auto" 40 12 nil 19)
     ("always" 40 0 t 0)
     ("never" 5 12 nil 19)
     ("auto" 18 12 t 0)
     ("auto" 19 12 nil 19))
  (with-project (project config :base base) '()
    (%search-settings config base :mode mode :threshold threshold :extra extra)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (let ((tools (request-tool-names (first (scripted-requests backend)))))
        (ok (eq active (and (member "tool_search" tools :test #'equal) t)))
        (ok (= offered (length (%f2-offered (first (scripted-requests backend))))))
        (ok (eq active (jget (init-of out) "mcp_tool_search" "active")))))))

(deftest h3e2b-tool-search-always-load
  (with-project (project config :base base) '()
    (write-user-settings config
                         "mcpServers" (args "f2" (fake2-server base :extra-tools 12 :always-load t)
                                            "g" (fake2-server base :extra-tools 12))
                         "mcpToolSearchThreshold" 5)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done"))
      (ok (eql 0 exit) err)
      (let ((first-request (first (scripted-requests backend))))
        (ok (= 19 (length (%f2-offered first-request))) "alwaysLoad keeps f2's tools")
        (ok (notany (lambda (n) (uiop:string-prefix-p "mcp__g__" n)) (request-tool-names first-request))
            "g's are deferred")
        (ok (member "tool_search" (request-tool-names first-request) :test #'equal)))
      (ok (eq nil (jget (server-object (mcp-init-servers out) "f2") "deferred")))
      (ok (eq t (jget (server-object (mcp-init-servers out) "g") "deferred"))))))

(deftest h3e2b-tool-search-deny-hides-it
  (with-project (project config :base base) '()
    (%search-settings config base :threshold 5)
    (multiple-value-bind (exit out err backend) (pj2 project config '("done") "--disallowed-tools" "tool_search")
      (declare (ignore out))
      (ok (eql 0 exit) err)
      (ok (not (member "tool_search" (request-tool-names (first (scripted-requests backend))) :test #'equal))))))

(deftest h3e2b-tool-search-in-the-instruction-set
  (with-project (project config :base base) '()
    (%search-settings config base :threshold 5)
    (with-test-client (client backend events project config
                       :steps (list "one" (%search-step "select:mcp__f2__tool_03") "two"
                                    (f2-call "tool_07") "three" "four")
                       :settings (make-settings :allow (list (parse-permission-rule "mcp__f2__tool_07" :allow))))
      (let* ((s (client-new-session client))
             (id (code-session-id s))
             (store (%session-iset-store s)))
        (client-query s "first" :timeout 60)
        (client-query s "second" :timeout 60)
        (client-query s "third" :timeout 60)
        (let* ((requests (scripted-requests backend))
               (records (session-dir-records project config id))
               (r1 (record-instructions (first records)))
               (r2 (record-instructions (second records)))
               (r3 (record-instructions (third records)))
               (f2-1 (%snapshot-server (%mcp-snapshot store r1) "f2"))
               (f2-2 (%snapshot-server (%mcp-snapshot store r2) "f2"))
               (f2-3 (%snapshot-server (%mcp-snapshot store r3) "f2")))
          (ok (null (%f2-offered (first requests))))
          (ok (equal '("mcp__f2__tool_03") (%f2-offered (third requests))) "loaded in turn 2")
          (ok (equal '("mcp__f2__tool_03") (%f2-offered (fourth requests))) "and still in turn 3")
          (ok (same-set '("mcp__f2__tool_03" "mcp__f2__tool_07") (%f2-offered (fifth requests)))
              "tool_07 loaded by its call in turn 3")
          (ok (eq t (getf f2-1 :deferred)))
          (ok (null (getf f2-1 :loaded)))
          (ok (not (equal r1 r2)) "the load committed a revision")
          (ok (equal '("tool_03") (getf f2-2 :loaded)) "the server's own name")
          (ok (same-set '("tool_03" "tool_07") (getf f2-3 :loaded)) "a call's load is recorded too")
          (client-rewind s 1 :mode :conversation)
          (client-query s "fourth" :timeout 60)
          (ok (null (%f2-offered (sixth (scripted-requests backend))))
              "after a rewind to turn 1, both are deferred again"))))))

(deftest h3e2b-mcp-list-objects
  (with-project (project config :base base) '()
    (write-user-settings config "mcpServers"
                         (args "f2" (fake2-server base :sampling t :instructions +fake2-instructions+)))
    (with-rpc (rpc backend project config :steps '("done"))
      (let* ((id (new-session rpc))
             (f2 (server-object (jget (call rpc "mcp/list" "session_id" id) "servers") "f2")))
        (ok (eq t (jget f2 "sampling")))
        (ok (eq t (jget f2 "elicitation")))
        (ok (eq t (jget f2 "instructions")))
        (ok (eq nil (jget f2 "deferred")))
        (ok (equalp #() (jget f2 "loaded")))))))
