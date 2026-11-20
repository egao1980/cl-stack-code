(in-package #:cl-stack-code)

;;; H3b: "always" approvals saved to settings.local.json.
;;;
;;; FORMAT-PERMISSION-RULE is the inverse of PARSE-PERMISSION-RULE:
;;;   resource "*"                                → "TOOL"
;;;   resource = the tool's prefix (path: bash: job:) + SPEC, where SPEC is
;;;   not empty, not "*" and does not itself start with an explicit prefix
;;;                                               → "TOOL(SPEC)"
;;;   any other resource                          → "TOOL(RESOURCE)"
;;; and that string is returned only when PARSE-PERMISSION-RULE maps it back
;;; to the same tool, resource and effect. Otherwise (whitespace or a
;;; parenthesis in the tool, an unbalanced parenthesis in the resource) the
;;; result is the object form: a json-protocol object (EQUAL hash table) with
;;; "tool" and "resource".
;;;
;;; A SETTINGS-RULE-STORE is the agent's PERMISSION-RULE-STORE in the
;;; interactive mode. SAVE-PERMISSION-RULE reads FILE (missing: an empty
;;; object), appends the formatted rule to permissions.allow (permissions.ask
;;; / permissions.deny for those effects) unless a rule there parses to the
;;; same tool, resource and effect, and writes the file back, creating its
;;; directory. Every other key and value is kept (the bytes need not be).
;;; A file that is not JSON or not an object, or a "permissions" / list of
;;; the wrong type, signals SETTINGS-ERROR (FILE, the key path) and writes
;;; nothing. LIST-PERMISSION-RULES returns every rule given to SAVE-PERMISSION-RULE
;;; on this object (a duplicate once), oldest first; rules already in the file reach the agent as
;;; settings rules instead.

(defun format-permission-rule (rule)
  "→ the settings form of RULE (an AI-AGENT-PROTOCOL:PERMISSION-RULE): a rule
string, or a json-protocol object with \"tool\" and \"resource\"."
  (declare (ignore rule))
  (%not-implemented 'format-permission-rule))

(defclass settings-rule-store (agent:permission-rule-store)
  ((file :initarg :file :reader settings-rule-store-file
         :documentation "The settings file the rules go to (a pathname).")
   (rules :initform '() :accessor %settings-rule-store-rules
          :documentation "Rules saved through this object, newest first.")
   (lock :initform (bt:make-lock "settings-rule-store") :reader %settings-rule-store-lock))
  (:documentation "PERMISSION-RULE-STORE writing \"always\" rules to a
settings file (the local settings.local.json in the interactive mode)."))

(defun make-settings-rule-store (file)
  "→ a SETTINGS-RULE-STORE saving to FILE (a pathname designator)."
  (make-instance 'settings-rule-store :file (pathname file)))

(defmethod agent:save-permission-rule ((store settings-rule-store) rule &key agent)
  (declare (ignore rule agent))
  (%not-implemented 'save-permission-rule))

(defmethod agent:list-permission-rules ((store settings-rule-store) &key agent)
  (declare (ignore agent))
  (%not-implemented 'list-permission-rules))
