(in-package #:cl-stack-code)

;;; H3e-1: Agent Skills (agentskills.io): discovery, the system prompt
;;; listing and the skill tool.
;;; Brief: cl-stack/docs/capabilities/cl-stack-code.md, "H3e-1 — locked".
;;;
;;; Roots (SKILL-ROOTS), in precedence order; <project> is the project root,
;;; else CWD; only existing directories are returned, as (truename . source):
;;;   1 <project>/.cl-stack-code/skills/   "project"
;;;   2 <project>/.claude/skills/          "claude"
;;;   3 <project>/.lisp-workspace/skills/  "lisp-workspace"
;;;   4 <user-config-dir>/skills/          "user"
;;;   5 each SETTINGS-SKILL-DIRS entry     "setting"  (missing → DISCOVER-SKILLS
;;;                                         adds "skill directory not found: NATIVE")
;;;
;;; A skill is <root>/<name>/SKILL.md (one level; symlinked directories are
;;; followed). PARSE-SKILL-FILE reads it with STEER:LOAD-SKILL (steer-protocol
;;; 0.4.0 decodes the frontmatter with yaml-protocol; cl-stack-code parses no
;;; YAML) → a STEER-DIRECTIVE of kind :SKILL whose name, description and body
;;; are the frontmatter's and the text after it. It signals SKILL-FORMAT-ERROR
;;; (reason, checked in this order):
;;;   no frontmatter
;;;   bad frontmatter (<the steer / yaml condition's text>)
;;;   name is missing
;;;   name "X" is not lowercase letters, digits and hyphens (at most 64)
;;;                                   ([a-z0-9]+(-[a-z0-9]+)*, length <= 64)
;;;   name "X" does not match its directory "Y"
;;;   description is missing          (absent, not a string, or blank)
;;; SKILL-DIRECTORY is the SKILL.md's directory; SKILL-SOURCE the root's source
;;; string (kept on the directive's EXTRA as :SOURCE).
;;;
;;; DISCOVER-SKILLS → (values skills notes). Roots in order; inside a root the
;;; skill directories by name (STRING<). A bad SKILL.md → note "skill at
;;; NATIVE: REASON" (the condition's report), skipped. A name already taken →
;;; note "skill NAME at NATIVE is shadowed by FIRST-NATIVE" (SKILL.md paths),
;;; skipped: the first wins. The same file reached twice (equal truenames, e.g.
;;; .claude/skills/x a symlink into .lisp-workspace/skills/) counts once, no
;;; note.
;;;
;;; SKILL-LISTING-SECTION skills → NIL for none, else
;;;   # Skills
;;;   +SKILL-LISTING-PREAMBLE+
;;;   - NAME: DESCRIPTION
;;;   …
;;; lines joined by LF, no final LF. DESCRIPTION: whitespace runs collapsed to
;;; one space, trimmed; longer than +MAX-SKILL-DESCRIPTION-CHARS+ → the first
;;; (1- that) characters and "…". Full lines are added while the sum of their
;;; lengths (each plus its LF) stays <= +SKILL-LISTING-BUDGET+; then "- NAME"
;;; lines while they fit; then, when skills are left, the line
;;; "(N more skills not listed; the skill tool names them all)".
;;;
;;; The skill tool (MAKE-SKILL-TOOLS, a SKILL-TOOLS agent tool source):
;;;   name         +SKILL-TOOL-NAME+ "skill"
;;;   description  "Load a skill: its instructions and its directory. With path,
;;;                read another file of the skill (relative to its directory)."
;;;   parameters   {"type":"object","properties":{"name":{"type":"string",
;;;                "description":"The skill's name"},"path":{"type":"string",
;;;                "description":"A file of the skill, relative to its directory"}},
;;;                "required":["name"]}
;;;   result       SKILL-TOOL-RESULT: for NAME
;;;                  <skill name="NAME" directory="NATIVE-DIR">
;;;                  BODY
;;;                  </skill>
;;;                for NAME and PATH (UTF-8 text of the file)
;;;                  <skill-file name="NAME" path="NATIVE">
;;;                  TEXT (right-trimmed)
;;;                  </skill-file>
;;;   errors       (tool errors, AI-AGENT-PROTOCOL:TOOL-INPUT-ERROR)
;;;                  no skill named "X"; skills: a, b, c      (all names, listing order)
;;;                  PATH is outside the skill directory NATIVE-DIR
;;;                  no file PATH in skill NAME
;;;   permission   TOOL-NEEDS-APPROVAL-P NIL; TOOL-PERMISSION-RESOURCES (NAME),
;;;                so rules skill(rove), skill(cl-*) and skill decide; no mode
;;;                base rule: allowed in every mode, plan included.
;;;   discovery    TOOL-INSTRUCTION-PATHS NIL: a skill's files never load
;;;                nested AGENTS.md or rules.
;;; MAKE-CODE-TOOLS (implementation) gains :SKILLS: with skills, and "skill" not
;;; hidden (HIDDEN-TOOL-NAMES), the SKILL-TOOLS source comes last:
;;; (file shell [lisp] units skill). CODE-SKILL-TOOLS finds it.

(defparameter +skill-tool-name+ "skill"
  "H3e-1: the skill tool's name and its permission rule action.")

(defparameter +skill-source-names+ '("project" "claude" "lisp-workspace" "user" "setting")
  "H3e-1: SKILL-SOURCE values, in precedence order.")

(defparameter +skill-listing-budget+ 8000
  "H3e-1: characters of skill lines (each with its LF) in the # Skills section.")

(defparameter +max-skill-description-chars+ 1024
  "H3e-1: the longest description listed (agentskills.io's limit).")

(defparameter +skill-listing-preamble+
  "Skills are instructions for particular tasks. When a task matches a skill's description, call the skill tool with its name before you start, and follow what it returns."
  "H3e-1: the line after # Skills.")

(defclass skill-tools ()
  ((skills :initarg :skills :reader skill-tools-skills :initform '()
           :documentation "The STEER-DIRECTIVEs it serves, listing order."))
  (:documentation "H3e-1: the agent tool source of the skill tool. Its
ai-agent-protocol methods (LIST-AGENT-TOOLS, INVOKE-TOOL / INVOKE-TOOL-ASYNC,
TOOL-NEEDS-APPROVAL-P, TOOL-PERMISSION-RESOURCES, TOOL-INSTRUCTION-PATHS) are
the implementation's; see the header."))

(defun skill-tools-p (x)
  (typep x 'skill-tools))

(defun code-skill-tools (sources)
  "H3e-1: the SKILL-TOOLS in SOURCES (MAKE-CODE-TOOLS' list), or NIL."
  (find-if #'skill-tools-p sources))

;;; Roots.

(defun %project-directory (cwd)
  "The project root of CWD, else CWD (a directory truename)."
  (let ((cwd (%truename-directory cwd)))
    (or (find-project-root cwd) cwd)))

(defun %existing-directory (dir)
  "DIR's truename when it is an existing directory, else NIL."
  (let ((d (uiop:directory-exists-p (uiop:ensure-directory-pathname dir))))
    (and d (truename d))))

(defun %skill-root-candidates (cwd settings user-config-dir)
  "((directory . source) …) of every configured root, existing or not."
  (let ((project (%project-directory cwd))
        (config (uiop:ensure-directory-pathname (or user-config-dir (user-config-directory)))))
    (append (list (cons (merge-pathnames ".cl-stack-code/skills/" project) "project")
                  (cons (merge-pathnames ".claude/skills/" project) "claude")
                  (cons (merge-pathnames ".lisp-workspace/skills/" project) "lisp-workspace")
                  (cons (merge-pathnames "skills/" config) "user"))
            (mapcar (lambda (dir) (cons (uiop:ensure-directory-pathname dir) "setting"))
                    (and settings (settings-skill-dirs settings))))))

(defun skill-roots (cwd &key settings user-config-dir)
  "→ ((directory-truename . source) …), the existing skill roots of CWD in
precedence order. See the header."
  (loop for (dir . source) in (%skill-root-candidates cwd settings user-config-dir)
        for true = (%existing-directory dir)
        when true collect (cons true source)))

;;; The format.

(defun %skill-name-p (name)
  "[a-z0-9]+(-[a-z0-9]+)*, at most 64 characters."
  (and (stringp name)
       (<= 1 (length name) 64)
       (every (lambda (c) (or (char<= #\a c #\z) (char<= #\0 c #\9) (char= c #\-))) name)
       (char/= #\- (char name 0))
       (char/= #\- (char name (1- (length name))))
       (not (search "--" name))))

(defun %skill-fail (path reason)
  (error 'skill-format-error :path path :reason reason))

(defun %frontmatter-error-text (condition)
  (or (steer:steer-error-message condition) (princ-to-string condition)))

(defun parse-skill-file (path)
  "→ the STEER-DIRECTIVE (kind :SKILL) of the SKILL.md PATH, or
SKILL-FORMAT-ERROR. See the header."
  (let* ((path (or (ignore-errors (probe-file path)) (pathname path)))
         (skill (handler-case (steer:load-skill path :kind :skill)
                  (steer:steer-frontmatter-error (e)
                    (%skill-fail path (format nil "bad frontmatter (~a)" (%frontmatter-error-text e)))))))
    (multiple-value-bind (fm frontmatter-p) (steer:skill-frontmatter skill)
      (unless frontmatter-p
        (%skill-fail path "no frontmatter"))
      (let ((name (getf fm :name))
            (description (getf fm :description))
            (dir (car (last (pathname-directory path)))))
        (unless (and (stringp name) (plusp (length name)))
          (%skill-fail path "name is missing"))
        (unless (%skill-name-p name)
          (%skill-fail path (format nil "name ~s is not lowercase letters, digits and hyphens (at most 64)"
                                    name)))
        (unless (equal name dir)
          (%skill-fail path (format nil "name ~s does not match its directory ~s" name dir)))
        (unless (and (stringp description) (not (%blank-p description)))
          (%skill-fail path "description is missing"))
        skill))))

;;; Discovery.

(defun %skill-directories (root)
  "The subdirectories of ROOT (symlinks kept as written), by name."
  (sort (copy-list (uiop:subdirectories root))
        #'string< :key (lambda (d) (car (last (pathname-directory d))))))

(defun discover-skills (cwd &key settings user-config-dir)
  "→ (values skills notes) for CWD. See the header."
  (let ((skills '())
        (notes '())
        (seen-files (make-hash-table :test #'equal)))
    (loop for (dir . source) in (%skill-root-candidates cwd settings user-config-dir)
          for root = (%existing-directory dir)
          do (cond
               ((null root)
                (when (string= source "setting")
                  (push (format nil "skill directory not found: ~a" (uiop:native-namestring dir))
                        notes)))
               (t
                (dolist (sub (%skill-directories root))
                  (let ((file (%file-truename (merge-pathnames "SKILL.md" sub))))
                    (when file
                      (let ((native (uiop:native-namestring file)))
                        (unless (gethash native seen-files)
                          (setf (gethash native seen-files) t)
                          (handler-case
                              (let* ((skill (parse-skill-file file))
                                     (name (steer:steer-directive-name skill))
                                     (first (find name skills :key #'steer:steer-directive-name
                                                              :test #'string=)))
                                (if first
                                    (push (format nil "skill ~a at ~a is shadowed by ~a"
                                                  name native
                                                  (uiop:native-namestring (steer:steer-directive-path first)))
                                          notes)
                                    (progn
                                      (setf (steer:steer-directive-extra skill)
                                            (list* :source source (steer:steer-directive-extra skill)))
                                      (push skill skills))))
                            (skill-format-error (e)
                              (push (princ-to-string e) notes)))))))))))
    (values (nreverse skills) (nreverse notes))))

(defun skill-directory (skill)
  "→ the directory pathname of SKILL's SKILL.md."
  (uiop:pathname-directory-pathname (steer:steer-directive-path skill)))

(defun skill-source (skill)
  "→ SKILL's source string (+SKILL-SOURCE-NAMES+)."
  (getf (steer:steer-directive-extra skill) :source))

;;; The listing.

(defun %collapse-whitespace (text)
  (with-output-to-string (o)
    (let ((space nil) (started nil))
      (loop for c across (or text "")
            do (if (%ws-char-p c)
                   (setf space t)
                   (progn (when (and space started) (write-char #\Space o))
                          (write-char c o)
                          (setf space nil started t)))))))

(defun %listing-description (text)
  (let ((d (%collapse-whitespace text)))
    (if (> (length d) +max-skill-description-chars+)
        (concatenate 'string (subseq d 0 (1- +max-skill-description-chars+)) "…")
        d)))

(defun skill-listing-section (skills)
  "→ the # Skills section for SKILLS, or NIL when there are none."
  (when skills
    (let ((lines '())
          (used 0)
          (rest skills))
      (loop while rest
            for line = (format nil "- ~a: ~a" (steer:steer-directive-name (first rest))
                               (%listing-description (steer:steer-directive-description (first rest))))
            while (<= (+ used (length line) 1) +skill-listing-budget+)
            do (push line lines)
               (incf used (1+ (length line)))
               (pop rest))
      (loop while rest
            for line = (format nil "- ~a" (steer:steer-directive-name (first rest)))
            while (<= (+ used (length line) 1) +skill-listing-budget+)
            do (push line lines)
               (incf used (1+ (length line)))
               (pop rest))
      (when rest
        (push (format nil "(~d more skills not listed; the skill tool names them all)" (length rest))
              lines))
      (format nil "# Skills~%~a~{~%~a~}" +skill-listing-preamble+ (nreverse lines)))))

;;; The tool.

(defparameter +skill-tool-description+
  "Load a skill: its instructions and its directory. With path, read another file of the skill (relative to its directory).")

(defparameter +skill-tool-parameters+
  "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"The skill's name\"},\"path\":{\"type\":\"string\",\"description\":\"A file of the skill, relative to its directory\"}},\"required\":[\"name\"]}")

(defun make-skill-tools (skills)
  "→ a SKILL-TOOLS source over SKILLS (listing order)."
  (make-instance 'skill-tools :skills (copy-list skills)))

(defun %tool-input-fail (control &rest args)
  (error 'agent:tool-input-error :message (apply #'format nil control args)))

(defun %lexically-inside-p (rel)
  "True when the relative POSIX path REL never climbs above its start."
  (let ((depth 0))
    (dolist (part (uiop:split-string rel :separator '(#\/)) t)
      (cond ((or (string= part "") (string= part ".")) nil)
            ((string= part "..") (decf depth) (when (minusp depth) (return nil)))
            (t (incf depth))))))

(defun skill-tool-result (skill &optional path)
  "→ the skill tool's result text for SKILL, or for its file PATH (a string
relative to SKILL-DIRECTORY). A PATH outside the directory or missing signals
AI-AGENT-PROTOCOL:TOOL-INPUT-ERROR with the header's text."
  (let* ((dir (skill-directory skill))
         (native-dir (uiop:native-namestring dir))
         (name (steer:steer-directive-name skill)))
    (if (null path)
        (let ((body (handler-case (steer:steer-directive-body (parse-skill-file (steer:steer-directive-path skill)))
                      (error () (steer:steer-directive-body skill)))))
          (format nil "<skill name=\"~a\" directory=\"~a\">~%~a~%</skill>" name native-dir (or body "")))
        (let* ((given (uiop:parse-native-namestring path))
               (target (if (uiop:absolute-pathname-p given)
                           given
                           (uiop:merge-pathnames* given dir)))
               (true (%file-truename target))
               (true-dir (or (ignore-errors (truename dir)) dir)))
          (when (or (and true (not (uiop:subpathp true true-dir)))
                    (and (not true)
                         (or (uiop:absolute-pathname-p given)
                             (not (%lexically-inside-p (substitute #\/ #\\ path))))))
            (%tool-input-fail "~a is outside the skill directory ~a" path native-dir))
          (unless (and true (%readable-text-p true))
            (%tool-input-fail "no file ~a in skill ~a" path name))
          (format nil "<skill-file name=\"~a\" path=\"~a\">~%~a~%</skill-file>"
                  name (uiop:native-namestring true) (%right-trim (%read-text true)))))))

(defun %skill-arguments (arguments)
  "ARGUMENTS (a JSON object string, a hash table or a plist) → (values name path)."
  (let ((table (typecase arguments
                 (string (handler-case (json:decode arguments)
                           (error () (%tool-input-fail "the arguments are not a JSON object"))))
                 (t arguments))))
    (flet ((field (key)
             (typecase table
               (hash-table (let ((v (gethash key table))) (and (stringp v) v)))
               (cons (let ((v (getf table (intern (string-upcase key) :keyword)))) (and (stringp v) v)))
               (t nil))))
      (values (field "name") (field "path")))))

(defun %find-skill (source name)
  (or (and name (find name (skill-tools-skills source) :key #'steer:steer-directive-name
                                                       :test #'string=))
      (%tool-input-fail "no skill named ~s; skills: ~{~a~^, ~}"
                        (or name "")
                        (mapcar #'steer:steer-directive-name (skill-tools-skills source)))))

(defmethod agent:list-agent-tools ((source skill-tools) &key context)
  (declare (ignore context))
  (list (llm:make-llm-tool :name +skill-tool-name+
                           :description +skill-tool-description+
                           :parameters (json:decode +skill-tool-parameters+))))

(defmethod agent:tool-executable-p ((source skill-tools) name &key context)
  (declare (ignore context))
  (string= name +skill-tool-name+))

(defun %call-skill-tool (source arguments)
  (multiple-value-bind (name path) (%skill-arguments arguments)
    (skill-tool-result (%find-skill source name) path)))

(defmethod agent:invoke-tool-async ((source skill-tools) name arguments
                                    &key context callback error-callback)
  (if (string= name +skill-tool-name+)
      (agent:invoke-tool-async
       (agent:make-function-tool
        :name name
        :handler (lambda (args) (%call-skill-tool source args)))
       name arguments
       :context context :callback callback :error-callback error-callback)
      (call-next-method)))

(defmethod agent:tool-needs-approval-p ((source skill-tools) name arguments &key context)
  (declare (ignore name arguments context))
  nil)

(defmethod agent:tool-permission-resources ((source skill-tools) name arguments &key context)
  (declare (ignore name context))
  (let ((skill-name (handler-case (nth-value 0 (%skill-arguments arguments))
                      (agent:tool-input-error () nil))))
    (list (or skill-name "*"))))

(defmethod agent:tool-instruction-paths ((source skill-tools) name arguments &key context)
  (declare (ignore name arguments context))
  nil)
