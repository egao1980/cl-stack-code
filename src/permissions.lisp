(in-package #:cl-stack-code)

;;; Permission rules from settings and flags onto ai-agent-protocol.
;;; Agent rule list (last match wins): mode base rules, every allow, every ask,
;;; every deny — so deny beats ask beats allow across all layers.

(defparameter +headless-denial-feedback+
  "cl-stack-code is running headless (-p) and cannot ask for approval. Allow this call with --allowed-tools or a permissions.allow rule in settings, or run with --permission-mode acceptEdits or bypassPermissions."
  "Feedback the model gets when an ask is refused in headless mode.")

(defparameter +plan-mode-feedback+
  "You are in preview mode: your edits and shell commands run in a copy of the project (the working directory above), not in the project itself. Make the change there and run the tests there; nothing reaches the project until the user approves the projected change."
  "H5a: the system prompt section of a preview run (ASSEMBLE-SYSTEM-PROMPT with
an H5a plan). H5c-0: the same text as +PREVIEW-MODE-FEEDBACK+, its preferred
name; the Lisp name stays until the H5a API rename.")

(defparameter +explicit-resource-prefixes+
  '("path:" "bash:" "program:" "cd:" "read:" "write:" "job:")
  "A SPEC starting with one of these is kept as written.")

(defparameter +tool-resource-prefixes+
  '((("read" "write" "edit" "multi_edit" "glob" "grep" "ls") . "path:")
    (("bash") . "bash:")
    (("job_output" "job_input" "job_kill") . "job:"))
  "The prefix a plain SPEC gets, per tool name. Other tools and globs: none.")

(defun %tool-resource-prefix (tool)
  (or (cdr (find-if (lambda (entry) (member tool (car entry) :test #'string=))
                    +tool-resource-prefixes+))
      ""))

(defun %rule-fail (designator why)
  (error 'permission-rule-error
         :text designator
         :message (format nil "bad permission rule ~s: ~a" designator why)))

(defun %rule-whitespace-p (char)
  (member char '(#\Space #\Tab #\Newline #\Return #\Page)))

(defun %check-rule-tool (designator tool)
  (cond ((zerop (length tool))
         (%rule-fail designator "no tool name"))
        ((find-if (lambda (c) (or (%rule-whitespace-p c) (member c '(#\( #\)))))
                  tool)
         (%rule-fail designator "the tool name has whitespace or a parenthesis"))
        (t tool)))

(defun %spec-resource (tool spec)
  (if (or (string= spec "*")
          (some (lambda (prefix) (uiop:string-prefix-p prefix spec))
                +explicit-resource-prefixes+))
      spec
      (concatenate 'string (%tool-resource-prefix tool) spec)))

(defun %closing-paren (text open)
  "Index of the ) that closes the ( at OPEN, or NIL."
  (loop with depth = 0
        for i from open below (length text)
        do (case (char text i)
             (#\( (incf depth))
             (#\) (when (zerop (decf depth)) (return i))))
        finally (return nil)))

(defun %parse-rule-string (designator effect)
  (let* ((text (string-trim '(#\Space #\Tab #\Newline #\Return) designator))
         (open (position #\( text)))
    (if (null open)
        (agent:make-permission-rule (%check-rule-tool designator text) "*" effect)
        (let ((tool (%check-rule-tool designator (subseq text 0 open)))
              (close (%closing-paren text open)))
          (cond ((null close)
                 (%rule-fail designator "unbalanced parenthesis"))
                ((/= close (1- (length text)))
                 (%rule-fail designator "text after the closing parenthesis"))
                ((= close (1+ open))
                 (%rule-fail designator "empty ()")))
          (agent:make-permission-rule
           tool (%spec-resource tool (subseq text (1+ open) close)) effect)))))

(defun %parse-rule-object (designator effect)
  (flet ((field (key)
           (multiple-value-bind (value present) (gethash key designator)
             (if (or (not present) (eq value :null)) nil value))))
    (let ((tool (field "tool"))
          (resource (or (field "resource") "*"))
          (feedback (field "feedback")))
      (unless (stringp tool)
        (%rule-fail designator "\"tool\" must be a string"))
      ;; The object form takes the tool literally (it is the fallback of
      ;; FORMAT-PERMISSION-RULE for tools the string form cannot write).
      (when (zerop (length tool))
        (%rule-fail designator "no tool name"))
      (unless (stringp resource)
        (%rule-fail designator "\"resource\" must be a string"))
      (unless (or (null feedback) (stringp feedback))
        (%rule-fail designator "\"feedback\" must be a string"))
      (agent:make-permission-rule tool resource effect :feedback feedback))))

(defun parse-permission-rule (designator effect)
  "→ an AI-AGENT-PROTOCOL:PERMISSION-RULE with EFFECT (:allow :ask :deny).
DESIGNATOR is a string \"TOOL\" or \"TOOL(SPEC)\", or a JSON object (string-
keyed hash table) with \"tool\", \"resource\" and \"feedback\". See the brief
for the SPEC prefixes. A bad designator signals PERMISSION-RULE-ERROR."
  (check-type effect (member :allow :ask :deny))
  (typecase designator
    (string (%parse-rule-string designator effect))
    (hash-table (%parse-rule-object designator effect))
    (t (%rule-fail designator "a rule is a string or an object"))))

(defun split-rule-list (string)
  "Rule strings in STRING, split on commas and whitespace outside
parentheses; empty pieces dropped."
  (let ((pieces '())
        (start 0)
        (depth 0))
    (flet ((cut (end)
             (when (< start end)
               (push (subseq string start end) pieces))))
      (loop for i from 0 below (length string)
            for c = (char string i)
            do (cond ((char= c #\() (incf depth))
                     ((char= c #\)) (when (plusp depth) (decf depth)))
                     ((and (zerop depth)
                           (or (char= c #\,) (%rule-whitespace-p c)))
                      (cut i)
                      (setf start (1+ i)))))
      (cut (length string)))
    (nreverse pieces)))

(defparameter +edit-tool-names+ '("write" "edit" "multi_edit")
  "The file tools a mode's base rules decide.")

(defparameter +shell-tool-names+ '("bash" "job_input")
  "The shell tools plan mode's base rules allow (0.4.1).")

(defun %mode-base-rules (mode &key (plan-shell-allowed t))
  (flet ((rules (tools effect)
           (mapcar (lambda (tool) (agent:make-permission-rule tool "*" effect)) tools)))
    (case (or mode :default)
      (:default (rules +edit-tool-names+ :ask))
      (:accept-edits (rules +edit-tool-names+ :allow))
      ;; H5a: preview mode (H5a's plan mode) edits the area, so its edits are
      ;; allowed as in acceptEdits. 0.4.1 (the user's decision): the shell is
      ;; allowed too, rooted at the area; these are the lowest rules, so ask
      ;; and deny rules from settings or flags still win. R4d-4b: the shell
      ;; allows hold while the area's sandbox confines (PLAN-SHELL-ALLOWED);
      ;; without it bash asks again, as in 0.4.0. H5c-0: plan mode has the
      ;; same base rules; its policy (PLAN-MODE-TOOLS) confines the edits to
      ;; .plan-scratch/.
      ((:plan :preview) (append (rules +edit-tool-names+ :allow)
                                (and plan-shell-allowed (rules +shell-tool-names+ :allow))))
      (t '()))))

(defun settings-permission-rules (settings &key (plan-shell-allowed t))
  "The agent's :permissions for merged SETTINGS: base rules of its mode, then
SETTINGS-ALLOW, SETTINGS-ASK, SETTINGS-DENY. R4d-4b: PLAN-SHELL-ALLOWED NIL
drops plan mode's bash and job_input allows (no sandbox: they ask)."
  (append (%mode-base-rules (settings-permission-mode settings)
                            :plan-shell-allowed plan-shell-allowed)
          (settings-allow settings)
          (settings-ask settings)
          (settings-deny settings)))

(defun settings-permission-policy (settings)
  "The run's :permission-policy for SETTINGS. H5c-0: in plan mode
PLAN-MODE-PERMISSION-POLICY (edits only under .plan-scratch/, no update_plan);
NIL in every other mode (preview mode runs edits and the shell in its area,
src/plans.lisp)."
  (and settings
       (eq :plan (settings-permission-mode settings))
       (plan-mode-permission-policy)))

(defun hidden-tool-names (settings names)
  "The members of NAMES (in order) that a deny rule with resource \"*\" in
SETTINGS matches; they are not offered to the model."
  (let ((globs (loop for rule in (settings-deny settings)
                     when (string= "*" (agent:permission-rule-resource rule))
                       collect (agent:permission-rule-action rule))))
    (remove-if-not (lambda (name)
                     (some (lambda (glob) (agent:permission-glob-match-p glob name)) globs))
                   names)))
