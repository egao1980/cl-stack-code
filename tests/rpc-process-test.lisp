(in-package #:cl-stack-code/tests)

;;; H3d: cl-stack-code --rpc in a child process, driven by CONNECT-RPC-CLIENT
;;; :COMMAND over its stdin / stdout pipes. The child is SBCL running
;;; RUN-CLI with --rpc on its own standard streams and the scripted mock
;;; backend (as the H3b pty smoke test starts its child).

(defun rpc-child-main (project config steps-text)
  "The child: RUN-CLI --rpc on the process's stdin / stdout, the mock backend
scripted with the steps READ from STEPS-TEXT. Quits with RUN-CLI's code."
  (let* ((steps (let ((*read-eval* nil)) (read-from-string steps-text)))
         (backend (make-scripted-backend steps))
         (config (uiop:ensure-directory-pathname config)))
    (uiop:quit
     (run-cli (list "--rpc" "--cwd" project "--model" "mock")
              :input *standard-input* :output *standard-output* :error-output *error-output*
              :providers (list (cons "mock" (scripted-provider backend)))
              :user-config-dir config
              :data-dir (data-dir-of config)
              :getenv (env-lookup)))))

(defun rpc-child-argv (project config steps)
  #-sbcl (declare (ignore project config steps))
  #-sbcl (error "the --rpc child is started with SBCL only")
  #+sbcl
  (append
   (list (uiop:native-namestring sb-ext:*runtime-pathname*)
         "--core" (uiop:native-namestring sb-ext:*core-pathname*) "--noinform"
         "--dynamic-space-size" (%child-dynamic-space-size)
         "--non-interactive" "--no-sysinit" "--no-userinit")
   (loop for form in (append (%child-asdf-forms)
                           (list ;; stdout is the protocol: compiler output must not reach it.
                                 "(let ((*standard-output* (make-broadcast-stream))) (uiop:symbol-call :asdf :load-system \"cl-stack-code/tests\"))"
                                 (format nil "(uiop:symbol-call :cl-stack-code/tests :rpc-child-main ~s ~s ~s)"
                                         (native project) (native config)
                                         (let ((*print-readably* t)) (prin1-to-string steps)))))
         append (list "--eval" form))))

(deftest rpc-subprocess-round-trip
  #-sbcl (skip "the --rpc child is started with SBCL")
  #+sbcl
  (with-project (project config) '(("a.txt" "alpha
"))
    (let ((rpc (connect-rpc-client
                :command (rpc-child-argv project config
                                         (list (list :tool "read" "{\"file_path\":\"a.txt\"}")
                                               "It says alpha.")))))
      (unwind-protect
           (progn
             (let ((init (rpc-client-call rpc "initialize" (args) :timeout 300)))
               (ok (equal "cl-stack-code" (event-value init "name")) "the child may compile first"))
             (ok (rpc-client-process rpc) "a child process")
             (let* ((id (event-value (rpc-client-call rpc "session/new" (args)) "session_id"))
                    (started (rpc-client-call rpc "turn/start" (args "session_id" id "prompt" "read it"))))
               (ok (equal id (event-value started "session_id")))
               (let ((result (rpc-result rpc id :timeout 60)))
                 (ok (equal "success" (event-value result "subtype")))
                 (ok (equal "It says alpha." (event-value result "result"))))
               (ok (find "tool_result" (rpc-client-events rpc :session-id id) :key #'event-type :test #'equal))
               (ok (eql 0 (close-rpc-client rpc)) "stdin closed: the child exits 0")
               (ok (equal '("read it")
                          (mapcar #'record-prompt (session-dir-records project config id)))
                   "the child committed the turn")))
        (close-rpc-client rpc)))))
