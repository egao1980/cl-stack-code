(in-package #:cl-stack-code/acp)

;;; ACP-2: cl-stack-code --acp. GIVEN: the hook. STUBBED: SERVE-ACP.
;;;
;;; SERVE-ACP &rest client-args &key INPUT OUTPUT &allow-other-keys → 0.
;;;   MAKE-CODE-ACP-AGENT with CLIENT-ARGS (all but INPUT and OUTPUT), then
;;;   ACP-BACKEND-STDIO:SERVE-ACP-AGENT on INPUT / OUTPUT (NIL: the
;;;   process's stdin / stdout) until INPUT ends, then CLOSE-CODE-ACP-AGENT
;;;   (UNWIND-PROTECT). Only ACP JSON-RPC goes to OUTPUT: no banner, no log
;;;   line, no compiler or warning output (the SDK writes to no stream; the
;;;   core binds *STANDARD-OUTPUT* to the error output around the server;
;;;   acp-backend-stdio binds it in its handler threads). → 0 at EOF.
;;;   RUN-CLI's --acp (src/rpc.lisp %RUN-ACP) calls it through
;;;   CL-STACK-CODE:*ACP-SERVER*, set below when this system loads.

(defun serve-acp (&rest client-args &key input output &allow-other-keys)
  (let ((agent (apply #'make-code-acp-agent
                      (loop for (key value) on client-args by #'cddr
                            unless (member key '(:input :output))
                              append (list key value)))))
    (unwind-protect
         (stdio:serve-acp-agent agent :input input :output output)
      (close-code-acp-agent agent))
    0))

(setf code:*acp-server* 'serve-acp)
