(defpackage #:cl-stack-code
  (:use #:cl)
  (:nicknames #:stack-code)
  (:local-nicknames (#:agent #:ai-agent-protocol)
                    (#:llm #:llm-protocol)
                    (#:tools #:agent-tools)
                    (#:steer #:steer-protocol)
                    (#:cli #:cli-protocol)
                    (#:json #:json-protocol)
                    (#:p #:cl-stack-pathlib)
                    (#:event #:event-protocol))
  (:export
   ;; entry
   #:run-cli
   #:main
   #:+version+

   ;; arguments
   #:parse-arguments
   #:invocation
   #:invocation-print-p
   #:invocation-prompt
   #:invocation-output-format
   #:invocation-cwd
   #:invocation-help-p
   #:invocation-version-p
   #:invocation-settings

   ;; settings
   #:settings
   #:make-settings
   #:settings-p
   #:settings-model
   #:settings-max-turns
   #:settings-permission-mode
   #:settings-allow
   #:settings-ask
   #:settings-deny
   #:settings-env
   #:settings-append-system-prompt
   #:settings-files
   #:parse-settings
   #:read-settings-file
   #:merge-settings
   #:user-config-directory
   #:settings-file-paths
   #:load-settings
   #:permission-mode-name
   #:parse-permission-mode
   #:+permission-mode-names+
   #:+default-max-turns+

   ;; permissions
   #:parse-permission-rule
   #:split-rule-list
   #:settings-permission-rules
   #:settings-permission-policy
   #:hidden-tool-names
   #:+headless-denial-feedback+
   #:+plan-mode-feedback+

   ;; project and prompt
   #:find-project-root
   #:instruction-files
   #:assemble-system-prompt
   #:+instruction-file-names+
   #:+max-instruction-chars+

   ;; models and tools
   #:resolve-model
   #:default-providers
   #:+default-model+
   #:make-code-tools

   ;; conditions
   #:code-error
   #:code-error-message
   #:code-usage-error
   #:permission-rule-error
   #:permission-rule-error-text
   #:settings-error
   #:settings-error-file
   #:settings-error-key
   #:model-not-found
   #:model-not-found-designator
   #:run-failed
   #:run-failed-cause
   #:condition-exit-code))

(in-package #:cl-stack-code)

;;; H3a contract: the package, conditions, the SETTINGS and INVOCATION classes
;;; with their readers, CONDITION-EXIT-CODE and the constants are given. Every
;;; function body that does work calls %NOT-IMPLEMENTED. The implementation
;;; removes %NOT-IMPLEMENTED and every call to it.

(defun %not-implemented (what)
  (error "cl-stack-code: ~a is not implemented (H3a contract)" what))

(defparameter +version+ "0.1.0"
  "The product version, as in the .asd.")
