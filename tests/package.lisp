(defpackage #:cl-stack-code/tests
  (:use #:cl #:rove #:cl-stack-code)
  (:local-nicknames (#:a #:ai-agent-protocol)
                    (#:llm #:llm-protocol)
                    (#:at #:agent-tools)
                    (#:steer #:steer-protocol)
                    (#:json #:json-protocol)
                    (#:bt #:bordeaux-threads)))

(in-package #:cl-stack-code/tests)
