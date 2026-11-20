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
                    (#:tty #:tui-backend-tty)
                    (#:rev #:revision-protocol)
                    (#:git #:revision-backend-git)
                    (#:jj #:revision-backend-jj)
                    (#:dt #:datetime-protocol)
                    (#:lt #:lisp-mcp/agent))
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
   #:code-program-dialog

   ;; H3c: the command line
   #:invocation-continue-p
   #:invocation-resume
   #:invocation-session-id
   #:invocation-fork-session-p
   #:invocation-list-sessions-p
   #:check-session-flags

   ;; H3c: where sessions live
   #:user-data-directory
   #:sessions-directory
   #:project-session-key
   #:normalize-session-id

   ;; H3c: turn records
   #:turn-record
   #:make-turn-record
   #:turn-record-p
   #:record-prompt
   #:record-turns
   #:record-replace-p
   #:record-finish
   #:record-model
   #:record-permission-mode
   #:record-usage
   #:record-steering
   #:record-version
   #:record-content
   #:content-record
   #:revision-record

   ;; H3c: the session store
   #:session-store
   #:session-store-p
   #:session-id
   #:session-directory
   #:session-project-dir
   #:session-cloned-from
   #:session-base
   #:+head-ref+
   #:+session-format+
   #:*session-lock-timeout*
   #:+stale-lock-seconds+
   #:create-session
   #:open-session
   #:sync-session
   #:list-sessions
   #:last-session
   #:session-head
   #:session-line
   #:session-records
   #:session-turns
   #:commit-turn
   #:resolve-turn
   #:move-session-head
   #:rewind-session
   #:fork-turn
   #:clone-session

   ;; H3c: views
   #:session-entries
   #:session-tree-lines
   #:session-summary-lines
   #:export-session

   ;; H3c: conditions and restarts
   #:session-error
   #:session-error-session
   #:session-not-found
   #:session-not-found-designator
   #:session-conflict
   #:session-conflict-expected
   #:session-conflict-actual
   #:session-locked
   #:session-locked-file
   #:session-lock-error
   #:session-lock-error-file
   #:session-lock-error-operation
   #:session-lock-error-cause
   #:break-lock
   #:session-turn-not-found
   #:session-turn-not-found-designator
   #:fork-session

   ;; H3c: the interactive core
   #:state-steering
   #:state-session-id

   ;; H5a: plans
   #:plan
   #:plan-p
   #:plan-id
   #:plan-kind
   #:plan-project-dir
   #:plan-root
   #:plan-base
   #:plan-status
   #:plan-session-id
   #:plan-directory
   #:plan-opened-at
   #:+plan-format+
   #:+plan-ref-prefix+
   #:+plan-kinds+
   #:plans-directory
   #:open-plan
   #:reopen-plan
   #:list-plans
   #:plan-tool-root
   #:plan-changes
   #:plan-diff
   #:plan-diff-text
   #:approve-plan
   #:reject-plan
   #:plan-record
   #:rebase-plan
   #:overwrite-plan
   #:abort-approval
   #:plan-error
   #:plan-error-plan
   #:plan-not-found
   #:plan-not-found-designator
   #:plan-drift
   #:plan-drift-paths
   #:record-plan

   ;; H5a: the command line
   #:invocation-apply-p
   #:invocation-reject-p
   #:invocation-on-drift
   #:invocation-plan-area
   #:check-plan-flags

   ;; H5a: the interactive core
   #:state-plan
   #:state-plan-prompt
   #:+plan-choices+
   #:+drift-choices+

   ;; H5b: checkpoints
   #:checkpoint
   #:checkpoint-p
   #:checkpoint-id
   #:checkpoint-ordinal
   #:checkpoint-reason
   #:checkpoint-turn
   #:checkpoint-turn-id
   #:checkpoint-files-kind
   #:checkpoint-files-id
   #:checkpoint-message
   #:checkpoint-recorded-at
   #:checkpoint-expired-p
   #:checkpoint-revision
   #:+checkpoint-format+
   #:+checkpoint-kinds+
   #:+checkpoint-reasons+
   #:+checkpoint-roles+
   #:+checkpoint-ref+
   #:+expired-ref+
   #:+checkpoint-ref-prefix+
   #:+default-checkpoint-keep+
   #:+rewind-parts+
   #:checkpoint-store
   #:checkpoint-store-p
   #:checkpoint-store-session
   #:checkpoints-directory
   #:resolve-checkpoint-kind
   #:checkpointer
   #:checkpointer-p
   #:make-checkpointer
   #:checkpointer-project-dir
   #:checkpointer-kind
   #:checkpointer-keep
   #:checkpointer-enabled-p
   #:checkpointer-data-dir
   #:close-checkpointer
   #:files-state
   #:files-state-p
   #:files-state-kind
   #:files-state-id
   #:read-files-state
   #:record-checkpoint
   #:begin-checkpoint-turn
   #:end-checkpoint-turn
   #:record-plan-checkpoints
   #:gc-checkpoints
   #:session-checkpoints
   #:tip-checkpoint
   #:find-checkpoint
   #:turn-checkpoint
   #:rewind-to
   #:rewind-description
   #:checkpoint-summary-lines
   #:plan-rewind

   ;; H5b: settings
   #:settings-checkpoints
   #:checkpoint-settings

   ;; H5b: conditions
   #:checkpoint-error
   #:checkpoint-error-session
   #:checkpoint-not-found
   #:checkpoint-not-found-designator
   #:checkpoint-expired
   #:checkpoint-expired-checkpoint

   ;; H5b: the command line
   #:invocation-rewind
   #:invocation-rewind-mode
   #:invocation-list-checkpoints-p
   #:check-rewind-flags

   ;; H5b: the interactive core
   #:state-rewind
   #:state-rewind-prompt
   #:+rewind-choices+

   ;; H4b: the Lisp image
   #:settings-lisp-image
   #:lisp-image-settings
   #:lisp-image-enabled-p
   #:parse-lisp-image-designator
   #:+lisp-image-backend-names+
   #:+on-debugger-names+
   #:+lisp-image-connection+
   #:check-lisp-image-settings
   #:make-code-lisp-tools
   #:start-lisp-image
   #:lisp-image-description
   #:lisp-image-state
   #:image-event-notice
   #:image-event-message
   #:image-banner-text
   #:state-image
   #:lisp-image-error
   #:lisp-image-error-image
   #:lisp-image-error-cause))

(in-package #:cl-stack-code)

(defparameter +version+ "0.6.0"
  "The product version, as in the .asd.")

(defun %not-implemented (name)
  "H4b contract stub."
  (error "~a is not implemented (H4b contract stub)" name))
