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

(defun %rule-string-candidate (tool resource)
  "The rule string FORMAT-PERMISSION-RULE tries first for TOOL and RESOURCE."
  (let* ((prefix (%tool-resource-prefix tool))
         (spec (and (plusp (length prefix))
                    (uiop:string-prefix-p prefix resource)
                    (subseq resource (length prefix)))))
    (cond ((string= resource "*") tool)
          ((and spec
                (plusp (length spec))
                (string/= spec "*")
                (notany (lambda (explicit) (uiop:string-prefix-p explicit spec))
                        +explicit-resource-prefixes+))
           (format nil "~a(~a)" tool spec))
          (t (format nil "~a(~a)" tool resource)))))

(defun format-permission-rule (rule)
  "→ the settings form of RULE (an AI-AGENT-PROTOCOL:PERMISSION-RULE): a rule
string, or a json-protocol object with \"tool\" and \"resource\"."
  (let* ((tool (agent:permission-rule-action rule))
         (resource (agent:permission-rule-resource rule))
         (effect (agent:permission-rule-effect rule))
         (text (%rule-string-candidate tool resource))
         (back (handler-case (parse-permission-rule text effect)
                 (permission-rule-error () nil))))
    (if (and back (equal (%rule-key back) (%rule-key rule)))
        text
        (let ((object (make-hash-table :test #'equal)))
          (setf (gethash "tool" object) tool
                (gethash "resource" object) resource)
          object))))

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

(defun %effect-key (effect)
  (ecase effect (:allow "allow") (:ask "ask") (:deny "deny")))

(defun %read-settings-object (file)
  "The JSON object in FILE (a fresh one when FILE does not exist). Not JSON or
not an object → SETTINGS-ERROR."
  (let ((path (probe-file file)))
    (if (null path)
        (make-hash-table :test #'equal)
        (let ((object (handler-case
                          (json:decode (uiop:read-file-string path :external-format :utf-8))
                        (error (e)
                          (%settings-fail file nil "not valid JSON (~a)" e)))))
          (unless (hash-table-p object)
            (%settings-fail file nil "settings must be a JSON object"))
          object))))

(defun %write-settings-object (file object)
  "Write OBJECT as JSON to FILE through a temporary file in its directory."
  (ensure-directories-exist file)
  (uiop:with-staging-pathname (tmp file)
    (with-open-file (out tmp :direction :output :if-exists :supersede
                             :external-format :utf-8)
      (json:encode object :stream out)
      (terpri out))))

(defun %save-rule-to-file (file rule)
  "Append RULE's settings form to FILE's permissions list for its effect unless
an equal rule is there. Signals SETTINGS-ERROR before writing anything."
  (let* ((object (%read-settings-object file))
         (key (%effect-key (agent:permission-rule-effect rule)))
         (permissions (multiple-value-bind (value present) (%json-present object "permissions")
                        (cond ((not present) (make-hash-table :test #'equal))
                              ((hash-table-p value) value)
                              (t (%settings-fail file "permissions"
                                                 "must be an object with allow, ask and deny arrays")))))
         (existing (%parse-rule-array file permissions key (agent:permission-rule-effect rule)))
         (items (multiple-value-bind (value present) (%json-present permissions key)
                  (if present (coerce value 'list) '()))))
    (unless (member (%rule-key rule) existing :key #'%rule-key :test #'equal)
      (setf (gethash key permissions)
            (coerce (append items (list (format-permission-rule rule))) 'vector)
            (gethash "permissions" object) permissions)
      (%write-settings-object file object))
    rule))

(defmethod agent:save-permission-rule ((store settings-rule-store) rule &key agent)
  (declare (ignore agent))
  (bt:with-lock-held ((%settings-rule-store-lock store))
    (%save-rule-to-file (settings-rule-store-file store) rule)
    (unless (member (%rule-key rule) (%settings-rule-store-rules store)
                    :key #'%rule-key :test #'equal)
      (push rule (%settings-rule-store-rules store))))
  rule)

(defmethod agent:list-permission-rules ((store settings-rule-store) &key agent)
  (declare (ignore agent))
  (bt:with-lock-held ((%settings-rule-store-lock store))
    (reverse (%settings-rule-store-rules store))))
