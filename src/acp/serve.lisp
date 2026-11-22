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
  (declare (ignore client-args input output))
  (%acp2-pending 'serve-acp))

(setf code:*acp-server* 'serve-acp)
