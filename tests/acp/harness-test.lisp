(in-package #:cl-stack-code/acp/tests)

;;; Self-tests of the test harness (support.lisp), independent of the code
;;; under test: they pass on the contract stubs. A HARNESS-AGENT stands in
;;; for the agent so the RECORDING-CLIENT, the request builders and the
;;; loopback helpers are known to work before any ACP-2 test relies on them.

(defclass harness-agent (acp:acp-agent) ())

(defmethod acp:acp-initialize ((agent harness-agent) request)
  (declare (ignore request))
  (acp:make-acp 'acp:initialize-response :protocol-version 1 :auth-methods #()))

(defmethod acp:acp-new-session ((agent harness-agent) request)
  (declare (ignore request))
  (acp:make-acp 'acp:new-session-response :session-id "s1"))

(defmethod acp:acp-prompt ((agent harness-agent) request)
  (let* ((remote acp:*acp-remote*)
         (sid (acp:session-id request))
         (text (acp:text (aref (acp:prompt request) 0))))
    (flet ((say (s)
             (acp:acp-send-update remote sid
                                  (acp:make-acp 'acp:update-agent-message-chunk
                                                :content (text-block s)))))
      (say "echo ")
      (say text)
      (when (equal text "ask")
        (multiple-value-bind (kind id)
            (acp:acp-ask-permission remote sid
                                    (acp:make-acp 'acp:tool-call-update :tool-call-id "t1")
                                    +acp-permission-options+)
          (declare (ignore id))
          (say (format nil " ~(~a~)" kind))))
      (when (equal text "tools")
        (say (acp:content (acp:acp-read-text-file
                           remote (acp:make-acp 'acp:read-text-file-request
                                                :session-id sid :path "/x/a.txt"))))
        (acp:acp-write-text-file remote (acp:make-acp 'acp:write-text-file-request
                                                      :session-id sid :path "/x/b.txt"
                                                      :content "B"))
        (let ((id (acp:terminal-id (acp:acp-create-terminal
                                    remote (acp:make-acp 'acp:create-terminal-request
                                                         :session-id sid :command "echo")))))
          (say (acp:output (acp:acp-terminal-output
                            remote (acp:make-acp 'acp:terminal-output-request
                                                 :session-id sid :terminal-id id)))))))
    (acp:make-acp 'acp:prompt-response :stop-reason "end_turn")))

(defun harness-pair (&key (caps *zed-client-caps*) (permission 'acp:allow-once))
  (let ((client (make-instance 'recording-client :permission permission)))
    (multiple-value-bind (ra rc) (acp:make-acp-loopback (make-instance 'harness-agent) client)
      (declare (ignore rc))
      (setf (client-remote client) ra)
      (req (initialize ra :caps caps))
      (values ra client))))

(deftest acp-harness-requests-build
  (with-project (project config) '()
    (ok (typep (caps *zed-client-caps*) 'acp:client-capabilities))
    (ok (acp:client-supports-p (caps *zed-client-caps*) :terminal))
    (ok (not (acp:client-supports-p (caps *bare-client-caps*) :read-text-file)))
    (dolist (object (list (acp:make-acp 'acp:embedded-resource
                                        :resource (acp:make-acp 'acp:text-resource-contents
                                                                :uri "file:///n.txt" :text "N"))
                          (acp:make-acp 'acp:resource-link :name "b.txt" :uri "file:///b.txt")
                          (acp:make-acp 'acp:image-content :data "iVBORw0KGgo=" :mime-type "image/png")
                          (acp:make-acp 'acp:set-session-mode-request :session-id "s" :mode-id "plan")
                          (acp:make-acp 'acp:load-session-request :session-id "s" :cwd (native project)
                                                                  :mcp-servers #())
                          (acp:make-acp 'acp:list-sessions-request :cwd (native project))
                          (acp:make-acp 'acp:close-session-request :session-id "s")
                          (acp:make-acp 'acp:cancel-notification :session-id "s")))
      (ok (stringp (acp:encode-acp-object object)) (d (type-of object))))))

(deftest acp-harness-loopback
  (multiple-value-bind (ra client) (harness-pair :permission 'acp:allow-always)
    (let ((sid (req (acp:session-id (acp:acp-new-session
                                     ra (acp:make-acp 'acp:new-session-request
                                                      :cwd "/x" :mcp-servers #()))))))
      (ok (equal "end_turn" (req (stop-reason ra sid "ask"))))
      (ok (equal "echo ask allow-always" (message-text client)) (message-text client))
      (ok (= 1 (length (permission-requests client))))
      (ok (updates-before-response-p ra))
      (clear-client client)
      (setf (gethash "/x/a.txt" (client-buffers client)) "A")
      (req (prompt ra sid "tools"))
      (ok (equal (format nil "echo toolsA~a" *terminal-output*) (message-text client)))
      (ok (equal "B" (gethash "/x/b.txt" (client-buffers client))))
      (ok (equal '("fs/read_text_file" "fs/write_text_file" "terminal/create" "terminal/output")
                 (call-methods client))))))

(deftest acp-harness-permission-restarts
  (dolist (row '((acp:allow-once "allow-once") (acp:reject-once "reject-once")
                 (acp:reject-always "reject-always") (nil "cancelled")))
    (multiple-value-bind (ra client) (harness-pair :permission (first row))
      (req (prompt ra "s1" "ask"))
      (ok (equal (format nil "echo ask ~a" (second row)) (message-text client))
          (message-text client)))))

(deftest acp-harness-signalled-and-within
  (ok (typep (signalled (lambda () (error "boom"))) 'error))
  (ok (null (signalled (lambda () 1))))
  (ok (typep (handler-case (within 1 (lambda () (sleep 5))) (error (c) c)) 'call-timed-out)))
