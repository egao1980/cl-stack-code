(defpackage #:cl-stack-code/acp/tests
  (:use #:cl #:rove #:cl-stack-code #:cl-stack-code/acp)
  ;; rove exports PLAN too.
  (:shadowing-import-from #:cl-stack-code #:plan)
  ;; The core suite's helpers (test code): temporary projects, the scripted
  ;; mock LLM, JSON builders.
  (:import-from #:cl-stack-code/tests
                #:with-project #:native #:env-lookup #:data-dir-of #:read-file #:write-file
                #:has #:nl #:args #:json-args #:jget #:same-path #:failure #:pick
                #:make-scripted-backend #:scripted-provider #:scripted-requests
                #:request-text #:last-request
                #:write-args #:edit-args #:write-step #:bash-step
                #:session-dir-records #:wait-until
                #:%child-asdf-forms #:%child-dynamic-space-size)
  (:local-nicknames (#:acp #:acp-protocol)
                    (#:stdio #:acp-backend-stdio)
                    (#:json #:json-protocol)
                    (#:bt #:bordeaux-threads)))

(in-package #:cl-stack-code/acp/tests)
