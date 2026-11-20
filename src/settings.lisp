(in-package #:cl-stack-code)

;;; Settings: user, project and local JSON files, then the flag layer.
;;; Scalars: the last layer that sets one wins. Rule lists: concatenated in
;;; layer order, later duplicates dropped. env: merged per key, later wins, a
;;; NIL value (JSON null) marks the key unset.

(defparameter +permission-mode-names+
  '("default" "acceptEdits" "bypassPermissions" "plan")
  "The --permission-mode / permissionMode values, in this order.")

(defparameter +default-max-turns+ 50
  "maxTurns when no layer sets it.")

(defclass settings ()
  ((model :initarg :model :reader settings-model :initform nil
          :documentation "Provider ref string, or NIL (unset).")
   (max-turns :initarg :max-turns :reader settings-max-turns :initform nil
              :documentation "Integer >= 1, or NIL (unset).")
   (permission-mode :initarg :permission-mode :reader settings-permission-mode
                    :initform nil
                    :documentation ":DEFAULT :ACCEPT-EDITS :BYPASS-PERMISSIONS
:PLAN, or NIL (unset).")
   (allow :initarg :allow :reader settings-allow :initform nil
          :documentation "AI-AGENT-PROTOCOL:PERMISSION-RULEs, effect :ALLOW.")
   (ask :initarg :ask :reader settings-ask :initform nil
        :documentation "PERMISSION-RULEs, effect :ASK.")
   (deny :initarg :deny :reader settings-deny :initform nil
         :documentation "PERMISSION-RULEs, effect :DENY.")
   (env :initarg :env :reader settings-env :initform nil
        :documentation "Alist (name . value) in first-set order; a NIL value
means unset.")
   (append-system-prompt :initarg :append-system-prompt
                         :reader settings-append-system-prompt :initform nil)
   (files :initarg :files :reader settings-files :initform nil
          :documentation "Settings files this layer was read from, in order."))
  (:documentation "One settings layer, or the merge of several."))

(defmethod print-object ((s settings) stream)
  (print-unreadable-object (s stream :type t)
    (format stream "~@[model ~s~]~@[ files ~d~]" (settings-model s)
            (and (settings-files s) (length (settings-files s))))))

(defun settings-p (x)
  (typep x 'settings))

(defun make-settings (&key model max-turns permission-mode allow ask deny env
                        append-system-prompt files)
  "A SETTINGS layer. NIL means unset for every scalar."
  (make-instance 'settings :model model :max-turns max-turns
                           :permission-mode permission-mode
                           :allow allow :ask ask :deny deny :env env
                           :append-system-prompt append-system-prompt
                           :files files))


(defparameter +permission-mode-keywords+
  '(:default :accept-edits :bypass-permissions :plan)
  "Mode keywords in +PERMISSION-MODE-NAMES+ order.")

(defun permission-mode-name (mode)
  "\"acceptEdits\" for :ACCEPT-EDITS, and so on; NIL means :DEFAULT."
  (let ((pos (position (or mode :default) +permission-mode-keywords+)))
    (unless pos
      (error 'code-usage-error
             :message (format nil "unknown permission mode ~s" mode)))
    (nth pos +permission-mode-names+)))

(defun parse-permission-mode (string)
  "The mode keyword for one of +PERMISSION-MODE-NAMES+ (exact case), or NIL."
  (and (stringp string)
       (let ((pos (position string +permission-mode-names+ :test #'string=)))
         (and pos (nth pos +permission-mode-keywords+)))))

;;; Parsing one settings file.

(defun %settings-fail (file key control &rest args)
  (error 'settings-error :file file :key key
                         :message (apply #'format nil control args)))

(defun %json-present (object key)
  "→ (values value present-p) of KEY in the JSON OBJECT; JSON null counts as
absent."
  (multiple-value-bind (value present) (gethash key object)
    (if (or (not present) (eq value :null))
        (values nil nil)
        (values value t))))

(defun %json-array-p (value)
  (and (vectorp value) (not (stringp value))))

(defun %parse-rule-array (file permissions key effect)
  "Rules of PERMISSIONS[KEY] with EFFECT. A bad rule signals SETTINGS-ERROR
with key path permissions.KEY[i]."
  (multiple-value-bind (value present) (%json-present permissions key)
    (when present
      (unless (%json-array-p value)
        (%settings-fail file (format nil "permissions.~a" key)
                        "must be an array of rules"))
      (loop for item across value
            for i from 0
            collect (handler-case (parse-permission-rule item effect)
                      (permission-rule-error (e)
                        (%settings-fail file (format nil "permissions.~a[~d]" key i)
                                        "~a" e)))))))

(defun %parse-env (file value)
  (unless (hash-table-p value)
    (%settings-fail file "env" "must be an object of string or null values"))
  (loop for name being the hash-keys of value using (hash-value v)
        collect (cond ((eq v :null) (list name))
                      ((stringp v) (cons name v))
                      (t (%settings-fail file (format nil "env.~a" name)
                                         "must be a string or null")))))

(defun parse-settings (json-string &key file)
  "→ SETTINGS from the JSON text of a settings file. FILE (a pathname) is for
messages and SETTINGS-FILES. Bad JSON, a non-object or a value of the wrong
type signals SETTINGS-ERROR naming FILE and the key path. Unknown keys are
ignored. Rules are parsed with PARSE-PERMISSION-RULE."
  (let ((object (handler-case (json:decode json-string)
                  (error (e)
                    (%settings-fail file nil "not valid JSON (~a)" e)))))
    (unless (hash-table-p object)
      (%settings-fail file nil "settings must be a JSON object"))
    (flet ((scalar (key test what)
             (multiple-value-bind (value present) (%json-present object key)
               (when present
                 (unless (funcall test value)
                   (%settings-fail file key "must be ~a" what))
                 value))))
      (let* ((model (scalar "model" #'stringp "a string"))
             (max-turns (scalar "maxTurns" (lambda (v) (and (integerp v) (>= v 1)))
                                "an integer >= 1"))
             (mode (scalar "permissionMode" #'parse-permission-mode
                           (format nil "one of ~{~a~^, ~}" +permission-mode-names+)))
             (append-prompt (scalar "appendSystemPrompt" #'stringp "a string"))
             (permissions (scalar "permissions" #'hash-table-p
                                  "an object with allow, ask and deny arrays"))
             (env (multiple-value-bind (value present) (%json-present object "env")
                    (and present (%parse-env file value)))))
        (make-settings
         :model model
         :max-turns max-turns
         :permission-mode (and mode (parse-permission-mode mode))
         :append-system-prompt append-prompt
         :allow (and permissions (%parse-rule-array file permissions "allow" :allow))
         :ask (and permissions (%parse-rule-array file permissions "ask" :ask))
         :deny (and permissions (%parse-rule-array file permissions "deny" :deny))
         :env env
         :files (and file (list file)))))))

(defun read-settings-file (pathname)
  "→ SETTINGS from PATHNAME, or NIL when it does not exist. SETTINGS-ERROR
offers CONTINUE (→ NIL) and USE-VALUE (→ the value)."
  (let ((path (probe-file pathname)))
    (when (and path (pathname-name path))   ; a directory has no name
      (restart-case
          (parse-settings
           (handler-case (uiop:read-file-string path :external-format :utf-8)
             (error (e) (%settings-fail path nil "cannot read the file (~a)" e)))
           :file path)
        (continue ()
          :report "Skip this settings file."
          nil)
        (use-value (settings)
          :report "Use these settings instead."
          settings)))))

;;; Merging layers.

(defun %rule-key (rule)
  (list (agent:permission-rule-action rule)
        (agent:permission-rule-resource rule)
        (agent:permission-rule-effect rule)))

(defun %merge-rules (lists)
  "Rule LISTS concatenated in order; a later duplicate is dropped."
  (let ((seen '()) (out '()))
    (dolist (rules lists (nreverse out))
      (dolist (rule rules)
        (let ((key (%rule-key rule)))
          (unless (member key seen :test #'equal)
            (push key seen)
            (push rule out)))))))

(defun %merge-env (alists)
  "Per key: the first layer that names it fixes the position, the last one
gives the value (NIL = unset). Fresh conses; the layers are not modified."
  (let ((out '()))
    (dolist (alist alists (nreverse out))
      (dolist (entry alist)
        (let ((mine (assoc (car entry) out :test #'string=)))
          (if mine
              (setf (cdr mine) (cdr entry))
              (push (cons (car entry) (cdr entry)) out)))))))

(defun merge-settings (&rest layers)
  "→ one SETTINGS from LAYERS, lowest first; NIL layers are skipped."
  (let ((layers (remove nil layers)))
    (flet ((last-set (reader)
             (let ((value nil))
               (dolist (layer layers value)
                 (let ((v (funcall reader layer)))
                   (when v (setf value v)))))))
      (make-settings
       :model (last-set #'settings-model)
       :max-turns (last-set #'settings-max-turns)
       :permission-mode (last-set #'settings-permission-mode)
       :append-system-prompt (last-set #'settings-append-system-prompt)
       :allow (%merge-rules (mapcar #'settings-allow layers))
       :ask (%merge-rules (mapcar #'settings-ask layers))
       :deny (%merge-rules (mapcar #'settings-deny layers))
       :env (%merge-env (mapcar #'settings-env layers))
       :files (loop for layer in layers append (settings-files layer))))))

;;; Where the files are.

(defun %absolute-directory (string)
  "STRING as an absolute directory pathname, or NIL when it is empty or
relative."
  (and (stringp string)
       (plusp (length string))
       (let ((p (ignore-errors (uiop:parse-native-namestring string :ensure-directory t))))
         (and p (uiop:absolute-pathname-p p) p))))

(defun user-config-directory (&key (getenv #'uiop:getenv))
  "→ directory pathname: $CL_STACK_CODE_CONFIG_DIR, else
$XDG_CONFIG_HOME/cl-stack-code/, else ~/.config/cl-stack-code/. Empty or
relative values are ignored."
  (or (%absolute-directory (funcall getenv "CL_STACK_CODE_CONFIG_DIR"))
      (let ((xdg (%absolute-directory (funcall getenv "XDG_CONFIG_HOME"))))
        (and xdg (merge-pathnames "cl-stack-code/" xdg)))
      (merge-pathnames ".config/cl-stack-code/" (user-homedir-pathname))))

(defun %directory (pathname)
  "PATHNAME as a directory pathname (its truename when it exists)."
  (let ((dir (uiop:ensure-directory-pathname pathname)))
    (or (probe-file dir) dir)))

(defun settings-file-paths (cwd &key user-config-dir)
  "→ (user project local) settings pathnames for working directory CWD.
Project and local live in .cl-stack-code/ under the project root, or under CWD
when there is no project root."
  (let* ((cwd (%directory cwd))
         (user (uiop:ensure-directory-pathname
                (or user-config-dir (user-config-directory))))
         (project (or (find-project-root cwd) cwd)))
    (list (merge-pathnames "settings.json" user)
          (merge-pathnames ".cl-stack-code/settings.json" project)
          (merge-pathnames ".cl-stack-code/settings.local.json" project))))

(defun load-settings (cwd &key user-config-dir cli)
  "→ the merge of the user, project and local files for CWD, then CLI (the
flag layer). SETTINGS-ERROR restarts are visible to a handler around it."
  (apply #'merge-settings
         (append (mapcar #'read-settings-file
                         (settings-file-paths cwd :user-config-dir user-config-dir))
                 (list cli))))
