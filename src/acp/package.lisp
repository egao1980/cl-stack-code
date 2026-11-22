(defpackage #:cl-stack-code/acp
  (:use #:cl)
  (:local-nicknames (#:code #:cl-stack-code)
                    (#:acp #:acp-protocol)
                    (#:stdio #:acp-backend-stdio)
                    (#:json #:json-protocol)
                    (#:bt #:bordeaux-threads)
                    (#:bt2 #:bordeaux-threads-2)
                    ;; the client-backed tool backends (bridge.lisp)
                    (#:agent #:ai-agent-protocol)
                    (#:tools #:agent-tools)
                    (#:fs #:cl-stack-pathlib)
                    (#:dt #:datetime-protocol))
  (:documentation "ACP-2: cl-stack-code as an Agent Client Protocol agent. A
CODE-ACP-AGENT implements acp-protocol's agent-side generic functions over the
cl-stack-code SDK (src/client.lisp); SERVE-ACP serves one on stdio
(acp-backend-stdio) and is the core's --acp server (CL-STACK-CODE:*ACP-SERVER*).")
  (:export
   ;; the agent
   #:code-acp-agent
   #:make-code-acp-agent
   #:code-acp-agent-client
   #:close-code-acp-agent
   #:code-acp-agent-mcp-servers
   ;; the server (--acp)
   #:serve-acp
   ;; the mapping tables
   #:+acp-mode-ids+
   #:mode-id-permission-mode
   #:permission-mode-mode-id
   #:+acp-permission-options+
   #:permission-kind-decision
   #:decision-permission-kind
   #:result-stop-reason
   #:tool-kind
   #:event-updates
   ;; the contract stub condition
   #:acp2-pending))

(in-package #:cl-stack-code/acp)

(define-condition acp2-pending (error)
  ((what :initarg :what :reader acp2-pending-what))
  (:report (lambda (c s)
             (format s "ACP-2 contract stub not implemented: ~S" (acp2-pending-what c))))
  (:documentation "Signalled by every contract stub of cl-stack-code/acp. The ACP-2
implementation replaces every call site; nothing signals it afterwards."))

(defun %acp2-pending (what)
  "Contract stub."
  (error 'acp2-pending :what what))
