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
   ;; H5b
   (checkpoints :initarg :checkpoints :reader settings-checkpoints :initform nil
                :documentation "The \"checkpoints\" object as a plist of the
keys this layer sets: :ENABLED (T or NIL), :KEEP (an integer >= 1), :KIND
(:AUTO :JJ :GIT :COPY). An absent key is unset; a present :ENABLED NIL means
false. See CHECKPOINT-SETTINGS.")
   ;; H4b
   (lisp-image :initarg :lisp-image :reader settings-lisp-image :initform nil
               :documentation "The \"lispImage\" object as a plist of the keys this
layer sets: :IMAGE (a designator from PARSE-LISP-IMAGE-DESIGNATOR), :BACKEND
(\"swank\" or \"slynk\"), :OBSERVE (T or NIL), :ON-DEBUGGER (:TURN or :NOTICE).
See LISP-IMAGE-SETTINGS.")
   (model-params :initarg :model-params :reader settings-model-params :initform nil
                 :documentation "The \"modelParams\" object as an alist (wire-name
. value) in first-set order; a :NULL value means unset. See
MODEL-PARAMS-LLM-SETTINGS.")
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
                        append-system-prompt files checkpoints lisp-image
                        model-params)
  "A SETTINGS layer. NIL means unset for every scalar. CHECKPOINTS (H5b): a
plist of the checkpoints keys this layer sets. LISP-IMAGE (H4b): a plist of the
lispImage keys this layer sets. MODEL-PARAMS: an alist (wire-name . value) of
the modelParams keys this layer sets (:NULL = unset)."
  (make-instance 'settings :model model :max-turns max-turns
                           :permission-mode permission-mode
                           :allow allow :ask ask :deny deny :env env
                           :append-system-prompt append-system-prompt
                           :checkpoints (copy-list checkpoints)
                           :lisp-image (copy-list lisp-image)
                           :model-params (copy-alist model-params)
                           :files files))

;;; H5b: the checkpoints object.
;;;
;;;   "checkpoints": {"enabled": true, "keep": 50, "kind": "auto"}
;;;
;;; enabled  boolean (default true): record checkpoints. Rewinds of files
;;;          recorded earlier work either way.
;;; keep     integer >= 1 (default +DEFAULT-CHECKPOINT-KEEP+): checkpoints a
;;;          session keeps; older ones are garbage-collected.
;;; kind     "auto" (default), "jj", "git" or "copy": how the files part is
;;;          recorded (RESOLVE-CHECKPOINT-KIND).
;;; Layers merge per key (the last layer that sets a key wins). A bad value
;;; signals SETTINGS-ERROR with key path "checkpoints", "checkpoints.enabled",
;;; "checkpoints.keep" or "checkpoints.kind".

(defparameter +default-checkpoint-keep+ 50
  "H5b: checkpoints.keep when no layer sets it.")

(defparameter +checkpoint-kind-names+ '("auto" "jj" "git" "copy")
  "H5b: the checkpoints.kind values.")

(defun %parse-checkpoints (file value)
  (unless (hash-table-p value)
    (%settings-fail file "checkpoints" "must be an object with enabled, keep and kind"))
  (let ((out '()))
    (multiple-value-bind (enabled present) (%json-present value "enabled")
      (when present
        (unless (member enabled '(t nil))
          (%settings-fail file "checkpoints.enabled" "must be true or false"))
        (setf out (list* :enabled enabled out))))
    ;; JSON false decodes as NIL, which %JSON-PRESENT reports as present.
    (multiple-value-bind (keep present) (%json-present value "keep")
      (when present
        (unless (and (integerp keep) (>= keep 1))
          (%settings-fail file "checkpoints.keep" "must be an integer >= 1"))
        (setf out (list* :keep keep out))))
    (multiple-value-bind (kind present) (%json-present value "kind")
      (when present
        (unless (and (stringp kind) (member kind +checkpoint-kind-names+ :test #'string=))
          (%settings-fail file "checkpoints.kind" "must be one of ~{~a~^, ~}"
                          +checkpoint-kind-names+))
        (setf out (list* :kind (intern (string-upcase kind) :keyword) out))))
    out))

(defun %merge-checkpoints (plists)
  "Per key, the last plist that has it wins."
  (let ((out '()))
    (dolist (plist plists out)
      (loop for (key value) on plist by #'cddr
            do (setf (getf out key) value)))))

(defun checkpoint-settings (settings)
  "→ (values enabled keep kind) of SETTINGS's checkpoints object with the
defaults applied: enabled T, keep +DEFAULT-CHECKPOINT-KEEP+, kind :AUTO."
  (let ((plist (and settings (settings-checkpoints settings))))
    (values (getf plist :enabled t)
            (getf plist :keep +default-checkpoint-keep+)
            (getf plist :kind :auto))))

;;; H4b: the lispImage object (given code).
;;;
;;;   "lispImage": {"image": "spawn", "backend": "swank", "observe": false,
;;;                 "onDebugger": "turn"}
;;;
;;; image       "off" (default), "spawn", or "attach:PORT" / "attach:HOST:PORT"
;;;             (PARSE-LISP-IMAGE-DESIGNATOR): the live image the lisp tools
;;;             start with. --lisp-image sets it from the command line.
;;; backend     "swank" (default) or "slynk".
;;; observe     boolean (default false): the lisp tools in observe mode
;;;             (lisp-mcp/agent :mode :observe). Only with "attach:…".
;;;             --lisp-observe sets it.
;;; onDebugger  "turn" (default) or "notice": what an image event does in the
;;;             interactive mode when no turn runs (see src/lisp-image.lisp).
;;; Layers merge per key. A bad value signals SETTINGS-ERROR with key path
;;; "lispImage", "lispImage.image", "lispImage.backend", "lispImage.observe"
;;; or "lispImage.onDebugger".

(defparameter +lisp-image-backend-names+ '("swank" "slynk")
  "H4b: the lispImage.backend values.")

(defparameter +on-debugger-names+ '("turn" "notice")
  "H4b: the lispImage.onDebugger values.")

(defun parse-lisp-image-designator (string)
  "STRING → (:OFF), (:SPAWN) or (:ATTACH HOST PORT); NIL when it is none of
\"off\", \"spawn\", \"attach:PORT\", \"attach:HOST:PORT\". HOST defaults to
\"127.0.0.1\"; PORT is a decimal integer 1..65535; HOST is not empty and has no
colon."
  (when (stringp string)
    (cond ((string= string "off") (list :off))
          ((string= string "spawn") (list :spawn))
          ((uiop:string-prefix-p "attach:" string)
           (let* ((rest (subseq string (length "attach:")))
                  (colon (position #\: rest))
                  (host (if colon (subseq rest 0 colon) "127.0.0.1"))
                  (port-text (if colon (subseq rest (1+ colon)) rest))
                  (port (and (plusp (length port-text))
                             (every #'digit-char-p port-text)
                             (parse-integer port-text))))
             (and port (<= 1 port 65535)
                  (plusp (length host))
                  (not (find #\: host))
                  (list :attach host port))))
          (t nil))))

(defun %parse-lisp-image (file value)
  (unless (hash-table-p value)
    (%settings-fail file "lispImage" "must be an object with image, backend, observe and onDebugger"))
  (let ((out '()))
    (multiple-value-bind (image present) (%json-present value "image")
      (when present
        (let ((designator (parse-lisp-image-designator image)))
          (unless designator
            (%settings-fail file "lispImage.image"
                            "must be \"off\", \"spawn\" or \"attach:[HOST:]PORT\""))
          (setf out (list* :image designator out)))))
    (multiple-value-bind (backend present) (%json-present value "backend")
      (when present
        (unless (and (stringp backend)
                     (member backend +lisp-image-backend-names+ :test #'string=))
          (%settings-fail file "lispImage.backend" "must be one of ~{~a~^, ~}"
                          +lisp-image-backend-names+))
        (setf out (list* :backend backend out))))
    (multiple-value-bind (observe present) (%json-present value "observe")
      (when present
        (unless (member observe '(t nil))
          (%settings-fail file "lispImage.observe" "must be true or false"))
        (setf out (list* :observe observe out))))
    (multiple-value-bind (policy present) (%json-present value "onDebugger")
      (when present
        (unless (and (stringp policy) (member policy +on-debugger-names+ :test #'string=))
          (%settings-fail file "lispImage.onDebugger" "must be one of ~{~a~^, ~}"
                          +on-debugger-names+))
        (setf out (list* :on-debugger (intern (string-upcase policy) :keyword) out))))
    out))

(defun lisp-image-settings (settings)
  "→ (values image backend observe on-debugger) of SETTINGS's lispImage
object with the defaults applied: image (:OFF), backend \"swank\", observe
NIL, on-debugger :TURN."
  (let ((plist (and settings (settings-lisp-image settings))))
    (values (getf plist :image (list :off))
            (getf plist :backend "swank")
            (getf plist :observe nil)
            (getf plist :on-debugger :turn))))

(defun lisp-image-enabled-p (settings)
  "True when SETTINGS's lispImage.image is spawn or attach."
  (not (eq :off (first (lisp-image-settings settings)))))


;;; The modelParams object: sampling parameters for every model call.
;;;
;;;   "modelParams": {"temperature": 1.0, "top_p": 0.95, "top_k": 20,
;;;                   "min_p": 0.0, "presence_penalty": 0.0,
;;;                   "repeat_penalty": 1.0,
;;;                   "chat_template_kwargs": {"enable_thinking": true}}
;;;
;;; Keys are wire names. temperature and top_p (numbers) become the
;;; LLM-SETTINGS slots; every other key goes into LLM-SETTINGS-EXTRA, which
;;; the provider backend copies into the request body as written (values of
;;; any JSON type; objects go as objects). Layers merge per key, the later
;;; layer wins; a null value marks the key unset. --model-param KEY=VALUE is
;;; the flag layer (VALUE read as JSON, else taken as a string). A bad value
;;; signals SETTINGS-ERROR with key path "modelParams" or "modelParams.KEY".

(defparameter +model-param-number-keys+ '("temperature" "top_p")
  "modelParams keys that must be numbers (they are LLM-SETTINGS slots).")

(defun %check-model-param (file key value)
  (when (and (member key +model-param-number-keys+ :test #'string=)
             (not (eq value :null))
             (not (realp value)))
    (%settings-fail file (format nil "modelParams.~a" key) "must be a number or null"))
  (cons key value))

(defun %parse-model-params (file value)
  (unless (hash-table-p value)
    (%settings-fail file "modelParams" "must be an object of model parameters"))
  (let ((out '()))
    (maphash (lambda (key v) (push (%check-model-param file key v) out)) value)
    (sort out #'string< :key #'car)))

(defun model-params-llm-settings (settings)
  "→ an LLM-PROTOCOL:LLM-SETTINGS for SETTINGS's modelParams, or NIL when no
key is set: temperature → :TEMPERATURE, top_p → :TOP-P, every other key into
:EXTRA as a plist of wire-name strings in key order."
  (let ((temperature nil) (top-p nil) (extra '()))
    (dolist (entry (and settings (settings-model-params settings)))
      (destructuring-bind (key . value) entry
        (unless (eq value :null)
          (cond ((string= key "temperature") (setf temperature value))
                ((string= key "top_p") (setf top-p value))
                (t (setf extra (list* value key extra)))))))
    (when (or temperature top-p extra)
      (llm:make-llm-settings :temperature temperature :top-p top-p
                             :extra (reverse extra)))))


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
                    (and present (%parse-env file value))))
             (checkpoints (multiple-value-bind (value present) (%json-present object "checkpoints")
                            (and present (%parse-checkpoints file value))))
             (lisp-image (multiple-value-bind (value present) (%json-present object "lispImage")
                           (and present (%parse-lisp-image file value))))
             (model-params (multiple-value-bind (value present)
                               (%json-present object "modelParams")
                             (and present (%parse-model-params file value)))))
        (make-settings
         :model model
         :max-turns max-turns
         :permission-mode (and mode (parse-permission-mode mode))
         :append-system-prompt append-prompt
         :allow (and permissions (%parse-rule-array file permissions "allow" :allow))
         :ask (and permissions (%parse-rule-array file permissions "ask" :ask))
         :deny (and permissions (%parse-rule-array file permissions "deny" :deny))
         :env env
         :checkpoints checkpoints
         :lisp-image lisp-image
         :model-params model-params
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
       :checkpoints (%merge-checkpoints (mapcar #'settings-checkpoints layers))
       :lisp-image (%merge-checkpoints (mapcar #'settings-lisp-image layers))
       :model-params (%merge-env (mapcar #'settings-model-params layers))
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
