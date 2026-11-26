(defpackage #:cl-stack-code
  (:use #:cl)
  (:nicknames #:stack-code)
  (:local-nicknames (#:agent #:ai-agent-protocol)
                    (#:sc #:compute-protocol)
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
                    ;; H3e-1: import tokens come from the parsed markdown
                    (#:mdp #:markdown-protocol)
                    (#:tty #:tui-backend-tty)
                    (#:rev #:revision-protocol)
                    (#:git #:revision-backend-git)
                    (#:jj #:revision-backend-jj)
                    (#:dt #:datetime-protocol)
                    (#:lt #:lisp-mcp/agent)
                    ;; H8d
                    (#:sup #:supervisor-protocol)
                    (#:ss #:supervisor-protocol/search)
                    (#:pp #:process-protocol))
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
   #:settings-model-params
   #:model-params-llm-settings
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
   ;; ACP-2
   #:tool-call-texts
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
   #:checkpointer-no-project-p
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
   #:lisp-image-error-cause

   ;; H3d: the SDK (src/client.lisp)
   #:code-client
   #:make-client
   #:close-client
   #:with-client
   #:client-cwd
   #:client-closed-p
   #:client-sessions
   #:code-session
   #:code-session-id
   #:code-session-client
   #:code-session-cwd
   #:code-session-model
   #:code-session-permission-mode
   #:code-session-init
   #:code-session-store
   #:code-turn
   #:code-turn-session
   #:code-turn-prompt
   #:code-turn-events
   #:code-turn-result
   #:code-turn-done-p
   #:event-type
   #:event-value
   #:+event-types+
   #:+approval-decision-names+
   #:client-new-session
   #:client-resume-session
   #:client-fork-session
   #:client-close-session
   #:client-find-session
   #:client-list-sessions
   #:client-busy-p
   #:client-turn
   #:client-wait
   #:client-query
   #:client-steer
   #:client-interrupt
   #:client-pending-approvals
   #:client-respond-approval
   #:client-approve-plan
   #:client-reject-plan
   #:client-checkpoints
   #:client-rewind
   #:client-settings
   #:client-tools
   ;; ACP-2
   #:client-set-permission-mode
   #:client-export-session

   ;; H3d: conditions
   #:client-closed
   #:session-not-open
   #:session-not-open-id
   #:turn-busy
   #:turn-busy-session-id
   #:turn-not-running
   #:turn-not-running-session-id
   #:approval-not-found
   #:approval-not-found-id

   ;; H3d: JSON-RPC (src/rpc.lisp)
   #:invocation-rpc-p
   #:check-rpc-flags
   #:+rpc-protocol-version+
   #:+rpc-methods+
   #:+rpc-event-method+
   #:+rpc-error-codes+
   #:rpc-error-for
   #:make-rpc-handler
   #:serve-rpc
   #:rpc-client
   #:connect-rpc-client
   #:rpc-client-call
   #:rpc-client-events
   #:rpc-client-wait-event
   #:rpc-client-process
   #:close-rpc-client

   ;; ACP-2: --acp (src/rpc.lisp); the server is cl-stack-code/acp
   #:invocation-acp-p
   #:check-acp-flags
   #:*acp-server*
   #:*acp-system*

   ;; H8d: units (src/units.lisp, src/unit-panel.lisp)
   #:+unit-panel-key+
   #:+unit-log-scrollback+
   #:+unit-tick-interval+
   #:+unit-stats-interval+
   #:+unit-rpc-actions+
   #:+unit-action-choices+
   #:+unit-panel-columns+
   #:+unit-list-help+
   #:+unit-log-help+
   #:units-directory
   #:make-code-supervisor
   #:code-unit-tools
   #:unit-status-word
   #:unit-tree
   #:unit-last-line
   #:format-unit-uptime
   #:format-unit-rss
   #:format-unit-cpu
   #:unit-row-text
   #:unit-panel-lines
   #:unit-log-lines
   #:unit-log-title
   #:parse-ps-cpu-time
   #:sample-unit-resources
   #:unit-cpu-percent
   #:unit-object
   #:unit-objects
   #:unit-event-object
   #:unit-record-object
   #:unit-gap-object
   #:unit-control-arguments
   #:unit-action-permission
   #:unit-action-message
   #:unit-failure-notice
   #:state-units-running
   ;; H8d: the panel and the program
   #:unit-panel
   #:unit-panel-open-p
   #:unit-panel-mode
   #:unit-panel-selected
   #:unit-panel-unit
   #:unit-panel-query
   #:unit-panel-hits
   #:unit-panel-hit-index
   #:code-program-supervisor
   #:code-program-unit-tools
   #:code-program-panel
   ;; H8d: the SDK
   #:code-session-supervisor
   #:code-session-unit-tools
   #:client-units
   #:client-subscribe-units
   #:client-unsubscribe-units
   #:client-read-unit
   #:client-search-units
   #:client-control-unit
   ;; H8d: conditions
   #:unit-not-found
   #:unit-not-found-unit
   #:unit-control-denied
   #:unit-control-denied-unit
   #:unit-control-denied-action
   #:unit-control-denied-rule
   #:unit-control-needs-confirmation
   #:unit-control-needs-confirmation-unit
   #:unit-control-needs-confirmation-action
   #:unit-control-needs-confirmation-resource
   #:unit-control-failed
   #:unit-control-failed-unit
   #:unit-control-failed-action
   #:subscription-not-found
   #:subscription-not-found-id
   ;; H3e-1: @imports, skills, path-scoped rules (src/imports.lisp,
   ;; src/skills.lisp, src/rules.lisp)
   #:import-tokens
   #:resolve-import
   #:instruction-block
   #:+max-import-hops+
   #:load-instruction-context
   #:instruction-context
   #:instruction-context-p
   #:context-files
   #:context-imports
   #:context-skills
   #:context-rules
   #:context-notes
   #:context-project-dir
   #:context-loaded-rules
   #:skill-roots
   #:parse-skill-file
   #:discover-skills
   #:skill-directory
   #:skill-source
   #:skill-listing-section
   #:make-skill-tools
   #:skill-tools
   #:skill-tools-p
   #:skill-tools-skills
   #:code-skill-tools
   #:skill-tool-result
   #:+skill-tool-name+
   #:+skill-source-names+
   #:+skill-listing-budget+
   #:+max-skill-description-chars+
   #:+skill-listing-preamble+
   #:rule-roots
   #:parse-rule-file
   #:discover-rules
   #:rule-patterns
   #:rule-always-p
   #:rule-matches-p
   #:rule-block
   #:make-code-instruction-discovery
   #:code-instruction-discovery
   #:discovery-loaded-rules
   #:settings-skill-dirs
   #:settings-context-files
   #:record-instructions
   ;; H3e-1: the instruction set (src/instruction-sets.lisp)
   #:+instruction-set-format+
   #:+instruction-set-roles+
   #:+instruction-set-reasons+
   #:+instruction-start-ref+
   #:component-role
   #:component-snapshot
   #:component-restore
   #:instruction-set-components
   #:instruction-store
   #:instruction-store-p
   #:instruction-store-session
   #:instructions-directory
   #:session-instruction-store
   #:instruction-set
   #:instruction-set-p
   #:instruction-set-store
   #:instruction-set-current
   #:make-instruction-set
   #:add-instruction-component
   #:commit-instruction-set
   #:restore-instruction-set
   #:read-instruction-set
   #:instruction-set-id
   #:instruction-set-blocks
   #:instruction-set-loaded-rules
   #:intern-instruction-text
   #:instruction-text
   #:session-instruction-set
   #:checkpoint-instructions-id
   #:instruction-set-error
   #:skill-format-error
   #:skill-format-error-path
   #:skill-format-error-reason
   #:rule-format-error
   #:rule-format-error-path
   #:rule-format-error-reason
   ;; R4d-4b: plan mode's sandbox
   #:*plan-compute-backend*
   #:+no-sandbox-backend-reason+
   #:+plan-sandbox-statuses+
   #:+plan-sandbox-canary-timeout+
   #:default-plan-compute-backend
   #:plan-compute-backend
   #:plan-scratch-directory
   #:plan-confinement
   #:plan-sandbox
   #:plan-sandbox-p
   #:plan-sandbox-plan
   #:plan-sandbox-status
   #:plan-sandbox-backend
   #:plan-sandbox-confinement
   #:plan-sandbox-reason
   #:plan-sandbox-confined-p
   #:plan-sandbox-tool-keys
   #:open-plan-sandbox
   #:plan-sandbox-refused
   #:plan-sandbox-notice
   #:plan-sandbox-section
   #:plan-sandbox-object
   #:plan-sandbox-refusal-result
   #:plan-sandbox-unavailable
   #:plan-sandbox-unavailable-reason
   #:plan-sandbox-unavailable-backend
   #:settings-sandbox
   #:sandbox-settings
   #:+sandbox-network-names+))

(in-package #:cl-stack-code)

(defparameter +version+ "0.16.1"
  "The product version, as in the .asd.")
