(in-package #:cl-stack-code)

;;; Permission rules from settings and flags onto ai-agent-protocol.
;;; Agent rule list (last match wins): mode base rules, every allow, every ask,
;;; every deny — so deny beats ask beats allow across all layers.

(defparameter +headless-denial-feedback+
  "cl-stack-code is running headless (-p) and cannot ask for approval. Allow this call with --allowed-tools or a permissions.allow rule in settings, or run with --permission-mode acceptEdits or bypassPermissions."
  "Feedback the model gets when an ask is refused in headless mode.")

(defparameter +plan-mode-feedback+
  "Plan mode is read-only: describe the change instead of making it."
  "Feedback of plan mode's policy denies.")

(defun parse-permission-rule (designator effect)
  "→ an AI-AGENT-PROTOCOL:PERMISSION-RULE with EFFECT (:allow :ask :deny).
DESIGNATOR is a string \"TOOL\" or \"TOOL(SPEC)\", or a JSON object (string-
keyed hash table) with \"tool\", \"resource\" and \"feedback\". See the brief
for the SPEC prefixes. A bad designator signals PERMISSION-RULE-ERROR."
  (declare (ignore designator effect))
  (%not-implemented 'parse-permission-rule))

(defun split-rule-list (string)
  "Rule strings in STRING, split on commas and whitespace outside
parentheses; empty pieces dropped."
  (declare (ignore string))
  (%not-implemented 'split-rule-list))

(defun settings-permission-rules (settings)
  "The agent's :permissions for merged SETTINGS: base rules of its mode, then
SETTINGS-ALLOW, SETTINGS-ASK, SETTINGS-DENY."
  (declare (ignore settings))
  (%not-implemented 'settings-permission-rules))

(defun settings-permission-policy (settings)
  "Plan mode → deny rules for write, edit, multi_edit, bash and job_input with
+PLAN-MODE-FEEDBACK+ (the run's :permission-policy). Other modes → NIL."
  (declare (ignore settings))
  (%not-implemented 'settings-permission-policy))

(defun hidden-tool-names (settings names)
  "The members of NAMES (in order) that a deny rule with resource \"*\" in
SETTINGS matches; they are not offered to the model."
  (declare (ignore settings names))
  (%not-implemented 'hidden-tool-names))
