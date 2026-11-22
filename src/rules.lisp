(in-package #:cl-stack-code)

;;; H3e-1: rules (Claude Code's .claude/rules/): always-on rules in the system
;;; prompt, path-scoped rules loaded lazily, once per session.
;;; Brief: cl-stack/docs/capabilities/cl-stack-code.md, "H3e-1 — locked".
;;;
;;; Roots (RULE-ROOTS), in order, only existing directories (truenames);
;;; <project> is the project root, else CWD:
;;;   <project>/.cl-stack-code/rules/  <project>/.claude/rules/
;;;   <project>/.lisp-workspace/rules/ <user-config-dir>/rules/
;;; DISCOVER-RULES → (values rules notes): every *.md under each root,
;;; recursively, roots in order and by relative POSIX path (STRING<) inside a
;;; root; equal truenames count once (the first kept, no note). Rules have no
;;; names: all load, no precedence.
;;;
;;; PARSE-RULE-FILE reads a rule with STEER:LOAD-SKILL :KIND :RULE (steer-protocol
;;; 0.4.0, YAML through yaml-protocol) → a STEER-DIRECTIVE of kind :RULE, PATH the
;;; truename, BODY the text after the frontmatter (the whole file without one).
;;; Frontmatter is optional. Its "paths" is a list of strings or one string
;;; split at commas (each piece trimmed, empty ones dropped); RULE-PATTERNS →
;;; that list, or NIL. Every other key is ignored (Cursor's globs /
;;; alwaysApply included). SKILL-FORMAT-ERROR is never signalled here; a rule
;;; that cannot be used signals RULE-FORMAT-ERROR with "bad frontmatter (…)"
;;; or "paths must be a list of strings or a comma-separated string";
;;; DISCOVER-RULES makes it the note "rule at NATIVE: REASON" and skips it.
;;;
;;; RULE-ALWAYS-P: RULE-PATTERNS is NIL. RULE-BLOCK (system prompt, after the
;;; instruction blocks): "<rule path=\"NATIVE\">" LF BODY (trimmed) LF "</rule>".
;;;
;;; RULE-MATCHES-P rule path project-dir: PATH (a pathname or native string;
;;; relative ones are taken against PROJECT-DIR) relative to PROJECT-DIR, as a
;;; POSIX string REL; a path outside PROJECT-DIR → NIL. True when some pattern
;;; P has (CL-STACK-PATHLIB:MATCH-P (concatenate "/" REL) (concatenate "/" P)):
;;; pathlib's anchored glob, "**" = any number of directories, "*" never
;;; crosses "/". An always-on rule matches nothing (it is already in context).
;;;
;;; Lazy loading. MAKE-CODE-INSTRUCTION-DISCOVERY makes a
;;; CODE-INSTRUCTION-DISCOVERY (a STEER:INSTRUCTION-DISCOVERY rooted at CWD,
;;; names +INSTRUCTION-FILE-NAMES+, :INCLUDE-ROOT NIL, as %AGENT-SETTINGS' today)
;;; over RULES (DISCOVER-RULES'), PROJECT-DIR and LOADED (native paths already
;;; in context: the always-on rules and, for a continued session, the
;;; INSTRUCTION-SET-LOADED-RULES of its head's instruction set). The
;;; implementation puts it in %AGENT-SETTINGS' :INSTRUCTIONS-DISCOVERY.
;;; STEER:DISCOVER-INSTRUCTIONS on it, for a path or a list of paths: the nested
;;; AGENTS.md directives exactly as the parent class gives them, then, for each
;;; path-scoped rule that matches a path and is not loaded, in rule order, a
;;; directive of kind :RULE with
;;;   name   the rule's native path
;;;   body   its body (trimmed)
;;;   path   its truename
;;;   extra  (:rule t :scope-name "P1, P2" :hash …)
;;; so STEER:COMPILE-INSTRUCTIONS gives
;;;   <instructions path="NATIVE" scope="**/*.lisp">
;;;   BODY
;;;   </instructions>
;;; With :MARK (the default) the rules join the loaded set. The loaded set is
;;; SHARED by every STEER:COPY-INSTRUCTION-DISCOVERY of the discovery (one per
;;; agent run; specialized here), so a rule loads once per session.
;;; STEER:FORGET-INSTRUCTIONS (a compaction; :PATH one file, or all) removes
;;; the forgotten rules from the set, so they load again on demand.
;;; DISCOVERY-LOADED-RULES → the set, native strings in load order.
;;;
;;; The instruction set (src/instruction-sets.lisp). The loaded set is the
;;; :rules component's live state: MAKE-INSTRUCTION-SET :DISCOVERY links a
;;; discovery (and so its copies) to a set. A linked discovery commits the
;;; set (:RULE) after each STEER:DISCOVER-INSTRUCTIONS call that loaded one or
;;; more rules, before returning them, and (:FORGET) after a
;;; STEER:FORGET-INSTRUCTIONS that removed any; RESTORE-INSTRUCTION-SET sets
;;; the loaded set to the revision's (a rewind: rules loaded later load again
;;; on the next matching path). Turn records name the set's revision
;;; (RECORD-INSTRUCTIONS); there is no per-turn rules list.
;;;
;;; Events. Each :instructions agent event becomes, in -p stream-json, SDK and
;;; --rpc, {"type":"instructions","files":[{"path":NATIVE,"kind":"agents"|"rule"}]}
;;; (path: the file's native truename).

(defclass code-instruction-discovery (steer:instruction-discovery)
  ((rules :initarg :rules :reader discovery-rules :initform '()
          :documentation "Every rule found (always-on ones included), rule order.")
   (project-dir :initarg :project-dir :reader discovery-project-dir :initform nil)
   (loaded :initarg :loaded :reader %discovery-loaded
           :initform (list '())
           :documentation "A cons whose car is the loaded native paths, load
order; copies share the cons.")
   ;; Implementation (additive).
   (link :initarg :link :reader %discovery-link
         :initform (list nil)
         :documentation "A cons whose car is the INSTRUCTION-SET this discovery
commits (MAKE-INSTRUCTION-SET :DISCOVERY), or NIL; copies share the cons."))
  (:documentation "H3e-1: nested AGENTS.md (the parent class) plus path-scoped
rules, loaded once per session. See the header."))

(defun discovery-loaded-rules (discovery)
  "→ native paths of the rules in context in DISCOVERY's session, load order."
  (copy-list (car (%discovery-loaded discovery))))

;;; Roots and files.

(defun rule-roots (cwd &key user-config-dir)
  "→ the existing rule roots of CWD (truenames), in order. See the header."
  (let ((project (%project-directory cwd))
        (config (uiop:ensure-directory-pathname (or user-config-dir (user-config-directory)))))
    (remove nil (mapcar #'%existing-directory
                        (list (merge-pathnames ".cl-stack-code/rules/" project)
                              (merge-pathnames ".claude/rules/" project)
                              (merge-pathnames ".lisp-workspace/rules/" project)
                              (merge-pathnames "rules/" config))))))

(defun %rule-format-fail (path reason)
  (error 'rule-format-error :path path :reason reason))

(defun parse-rule-file (path)
  "→ the STEER-DIRECTIVE (kind :RULE) of the rule file PATH, or
RULE-FORMAT-ERROR. See the header."
  (let* ((path (or (ignore-errors (probe-file path)) (pathname path)))
         (rule (handler-case (steer:load-skill path :kind :rule)
                 (steer:steer-frontmatter-error (e)
                   (%rule-format-fail path (format nil "bad frontmatter (~a)" (%frontmatter-error-text e))))))
         (patterns (handler-case (steer:skill-paths rule)
                     (steer:steer-frontmatter-error ()
                       (%rule-format-fail path "paths must be a list of strings or a comma-separated string")))))
    (setf (steer:steer-directive-extra rule)
          (list* :patterns patterns (steer:steer-directive-extra rule)))
    rule))

(defun %root-markdown-files (root)
  "→ ((relative-posix . pathname) …) of every *.md under ROOT, by relative path."
  (let ((out '()))
    (uiop:collect-sub*directories
     root (constantly t) (constantly t)
     (lambda (dir)
       (dolist (file (uiop:directory-files dir "*.md"))
         (push (cons (uiop:unix-namestring (uiop:enough-pathname file root)) file) out))))
    (sort out #'string< :key #'car)))

(defun discover-rules (cwd &key user-config-dir)
  "→ (values rules notes) for CWD. See the header."
  (let ((rules '())
        (notes '())
        (seen (make-hash-table :test #'equal)))
    (dolist (root (rule-roots cwd :user-config-dir user-config-dir))
      (loop for (nil . file) in (%root-markdown-files root)
            for true = (%file-truename file)
            for native = (and true (uiop:native-namestring true))
            when (and true (not (gethash native seen)))
              do (setf (gethash native seen) t)
                 (handler-case (push (parse-rule-file true) rules)
                   (rule-format-error (e) (push (princ-to-string e) notes)))))
    (values (nreverse rules) (nreverse notes))))

(defun rule-patterns (rule)
  "→ RULE's paths patterns (strings), or NIL for an always-on rule."
  (copy-list (getf (steer:steer-directive-extra rule) :patterns)))

(defun rule-always-p (rule)
  "→ true when RULE has no paths patterns."
  (null (rule-patterns rule)))

(defun %rule-native (rule)
  (uiop:native-namestring (steer:steer-directive-path rule)))

(defun rule-matches-p (rule path project-dir)
  "→ true when the path-scoped RULE matches PATH under PROJECT-DIR. See the header."
  (let ((patterns (rule-patterns rule)))
    (when patterns
      (let* ((dir (uiop:truenamize (uiop:ensure-directory-pathname project-dir)))
             (given (etypecase path
                      (pathname path)
                      (string (uiop:parse-native-namestring path))))
             (file (uiop:truenamize (if (uiop:absolute-pathname-p given)
                                        given
                                        (uiop:merge-pathnames* given dir)))))
        (when (and (uiop:subpathp file dir) (not (uiop:directory-pathname-p file)))
          (let ((rel (concatenate 'string "/" (uiop:unix-namestring (uiop:enough-pathname file dir)))))
            (and (some (lambda (pattern) (p:match-p rel (concatenate 'string "/" pattern)))
                       patterns)
                 t)))))))

(defun rule-block (rule)
  "→ the system prompt block of the always-on RULE."
  (format nil "<rule path=\"~a\">~%~a~%</rule>" (%rule-native rule) (steer:steer-directive-body rule)))

;;; The discovery.

(defun make-code-instruction-discovery (cwd &key rules project-dir loaded)
  "→ a CODE-INSTRUCTION-DISCOVERY for CWD. See the header."
  (let ((root (%truename-directory cwd)))
    (make-instance 'code-instruction-discovery
                   :root root
                   :names (copy-list +instruction-file-names+)
                   :include-root nil
                   :rules (copy-list rules)
                   :project-dir (if project-dir (%truename-directory project-dir) (%project-directory root))
                   :loaded (list (copy-list loaded)))))

(defmethod steer:copy-instruction-discovery ((discovery code-instruction-discovery) &key keep-injected)
  (declare (ignore keep-injected))
  (let ((new (call-next-method)))
    ;; The parent rebuilt the configuration; the rules, the loaded set and
    ;; the link are the session's, shared by every copy.
    (setf (slot-value new 'rules) (discovery-rules discovery)
          (slot-value new 'project-dir) (discovery-project-dir discovery)
          (slot-value new 'loaded) (%discovery-loaded discovery)
          (slot-value new 'link) (%discovery-link discovery))
    new))

(defun %rule-directive (rule)
  "The injected directive of the path-scoped RULE."
  (let ((body (steer:steer-directive-body rule)))
    (steer:make-steer-directive
     :kind :rule
     :name (%rule-native rule)
     :body body
     :path (steer:steer-directive-path rule)
     :extra (list :rule t
                  :scope-name (format nil "~{~a~^, ~}" (rule-patterns rule))
                  :hash (p:octets-hash (p:utf8-encode body))))))

(defun %discovery-commit (discovery reason)
  (let ((set (car (%discovery-link discovery))))
    (when set
      (commit-instruction-set set reason))))

(defvar *%rule-pass* nil
  "True inside a CODE-INSTRUCTION-DISCOVERY's DISCOVER-INSTRUCTIONS: the
parent's per-path calls give AGENTS.md directives only.")

(defmethod steer:discover-instructions ((discovery code-instruction-discovery) path &key (mark t))
  (if *%rule-pass*
      (call-next-method)
      (let* ((agents (let ((*%rule-pass* t)) (call-next-method)))
             (root (steer:instruction-discovery-root discovery))
             (paths (mapcar (lambda (p)
                              (let ((given (if (pathnamep p) p (uiop:parse-native-namestring p))))
                                (if (uiop:absolute-pathname-p given)
                                    given
                                    (uiop:merge-pathnames* given root))))
                            (if (listp path) path (list path))))
             (cell (%discovery-loaded discovery))
             (rules (loop for rule in (discovery-rules discovery)
                          for native = (%rule-native rule)
                          when (and (not (rule-always-p rule))
                                    (not (member native (car cell) :test #'string=))
                                    (some (lambda (p)
                                            (rule-matches-p rule p (discovery-project-dir discovery)))
                                          paths))
                            collect (%rule-directive rule))))
        (when (and mark rules)
          (setf (car cell) (append (car cell) (mapcar #'steer:steer-directive-name rules)))
          (%discovery-commit discovery :rule))
        (append agents rules))))

(defmethod steer:mark-instructions-injected :after ((discovery code-instruction-discovery) directives &key)
  ;; A journal replay: its rules are in context again; the set has their revision.
  (let ((cell (%discovery-loaded discovery)))
    (dolist (d directives)
      (when (getf (steer:steer-directive-extra d) :rule)
        (let ((native (steer:steer-directive-name d)))
          (unless (member native (car cell) :test #'string=)
            (setf (car cell) (append (car cell) (list native)))))))))

(defmethod steer:forget-instructions :after ((discovery code-instruction-discovery) &key path)
  (let* ((cell (%discovery-loaded discovery))
         (before (car cell))
         (always (loop for rule in (discovery-rules discovery)
                       when (rule-always-p rule) collect (%rule-native rule)))
         (after (if path
                    (let ((native (uiop:native-namestring
                                   (uiop:truenamize
                                    (let ((p (if (pathnamep path) path (uiop:parse-native-namestring path))))
                                      (if (uiop:absolute-pathname-p p)
                                          p
                                          (uiop:merge-pathnames* p (steer:instruction-discovery-root discovery))))))))
                      (remove native before :test #'string=))
                    (remove-if-not (lambda (n) (member n always :test #'string=)) before))))
    (unless (equal before after)
      (setf (car cell) after)
      (%discovery-commit discovery :forget))))
