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
                    (#:event #:event-protocol)
                    (#:diff #:diff-protocol)
                    (#:tui #:tui-protocol)
                    (#:w #:tui-protocol/widgets)
                    (#:md #:tui-markdown)
                    (#:tty #:tui-backend-tty))
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
   #:condition-exit-code

   ;; H3b: saved "always" rules
   #:format-permission-rule
   #:settings-rule-store
   #:make-settings-rule-store
   #:settings-rule-store-file

   ;; H3b: @ mentions
   #:project-files
   #:mention-candidates
   #:expand-mentions
   #:+max-mention-chars+

   ;; H3b: transcript
   #:entry
   #:make-entry
   #:entry-p
   #:entry-kind
   #:entry-text
   #:entry-id
   #:entry-name
   #:entry-input
   #:entry-status
   #:entry-result
   #:entry-error-p
   #:tool-call-summary
   #:tool-result-diff
   #:tool-call-preview
   #:approval-message
   #:transcript-lines
   #:status-line-text

   ;; H3b: the interactive core
   #:interactive-state
   #:make-interactive-state
   #:state-transcript
   #:state-busy-p
   #:state-queue
   #:state-approvals
   #:state-model
   #:state-permission-mode
   #:state-cwd
   #:state-usage
   #:state-rules
   #:state-quit-p
   #:interactive-update
   #:+help-text+
   #:+approval-choices+

   ;; H3b: the program
   #:code-program
   #:make-code-program
   #:close-code-program
   #:code-program-state
   #:code-program-input
   #:code-program-dialog))

(in-package #:cl-stack-code)

(defparameter +version+ "0.2.0"
  "The product version, as in the .asd.")

(defun %not-implemented (name)
  "Contract stub (H3b): the implementation removes this function and every call."
  (error "~a is not implemented yet (cl-stack-code H3b contract)" name))
