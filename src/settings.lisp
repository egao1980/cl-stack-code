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

(defun permission-mode-name (mode)
  "\"acceptEdits\" for :ACCEPT-EDITS, and so on; NIL means :DEFAULT."
  (declare (ignore mode))
  (%not-implemented 'permission-mode-name))

(defun parse-permission-mode (string)
  "The mode keyword for one of +PERMISSION-MODE-NAMES+ (exact case), or NIL."
  (declare (ignore string))
  (%not-implemented 'parse-permission-mode))

(defun parse-settings (json-string &key file)
  "→ SETTINGS from the JSON text of a settings file. FILE (a pathname) is for
messages and SETTINGS-FILES. Bad JSON, a non-object or a value of the wrong
type signals SETTINGS-ERROR naming FILE and the key path. Unknown keys are
ignored. Rules are parsed with PARSE-PERMISSION-RULE."
  (declare (ignore json-string file))
  (%not-implemented 'parse-settings))

(defun read-settings-file (pathname)
  "→ SETTINGS from PATHNAME, or NIL when it does not exist. SETTINGS-ERROR
offers CONTINUE (→ NIL) and USE-VALUE (→ the value)."
  (declare (ignore pathname))
  (%not-implemented 'read-settings-file))

(defun merge-settings (&rest layers)
  "→ one SETTINGS from LAYERS, lowest first; NIL layers are skipped."
  (declare (ignore layers))
  (%not-implemented 'merge-settings))

(defun user-config-directory (&key (getenv #'uiop:getenv))
  "→ directory pathname: $CL_STACK_CODE_CONFIG_DIR, else
$XDG_CONFIG_HOME/cl-stack-code/, else ~/.config/cl-stack-code/. Empty or
relative values are ignored."
  (declare (ignore getenv))
  (%not-implemented 'user-config-directory))

(defun settings-file-paths (cwd &key user-config-dir)
  "→ (user project local) settings pathnames for working directory CWD.
Project and local live in .cl-stack-code/ under the project root, or under CWD
when there is no project root."
  (declare (ignore cwd user-config-dir))
  (%not-implemented 'settings-file-paths))

(defun load-settings (cwd &key user-config-dir cli)
  "→ the merge of the user, project and local files for CWD, then CLI (the
flag layer). SETTINGS-ERROR restarts are visible to a handler around it."
  (declare (ignore cwd user-config-dir cli))
  (%not-implemented 'load-settings))
