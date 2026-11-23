(in-package #:cl-stack-code)

;;; H3e-1: @path imports in instruction files, and the instruction context
;;; (instruction files with their imports, skills, rules, notes) a session's
;;; system prompt, tools and init event are built from.
;;; Brief: cl-stack/docs/capabilities/cl-stack-code.md, "H3e-1 — locked".
;;;
;;; Tokens (IMPORT-TOKENS). An import is "@" at the start of a line or after
;;; whitespace, followed by a path that runs to the next unescaped whitespace;
;;; "\ " is a space in the path. Not imports: a lone "@", a path starting with
;;; a double or single quote, an "@" after a non-whitespace character
;;; (a@b.c). Only the text inlines of MDP:PARSE-MARKDOWN are scanned: code
;;; spans, fenced code blocks and link destinations never import. Distinct
;;; tokens, in order of first appearance. (Claude Code: "Import parsing skips
;;; Markdown code spans and fenced code blocks"; "the path ends at the first
;;; space"; "a path wrapped in quotes isn't imported at all".)
;;;
;;; Paths (RESOLVE-IMPORT). "~/…" is HOME (default USER-HOMEDIR-PATHNAME); an
;;; absolute path is taken as written; anything else is relative to the
;;; directory of the including file FROM.
;;;
;;; Blocks (INSTRUCTION-BLOCK). A file's own text is right-trimmed and cut at
;;; +MAX-INSTRUCTION-CHARS+ (H3a's "[truncated: NATIVE is over N characters]"
;;; line) BEFORE its imports are scanned: the limit is per file, imported files
;;; included, and tokens past the cut do not count. The block is
;;;
;;;   <instructions path="NATIVE">
;;;   ITEM
;;;   …
;;;   OWN TEXT (tokens left as written)
;;;   </instructions>
;;;
;;; one ITEM per token, in token order, each followed by LF:
;;;
;;;   <import path="NATIVE">       the imported file, expanded the same way
;;;   ITEM … OWN TEXT              (its own imports inside, before its text)
;;;   </import>
;;;
;;; or, when the token is not expanded, one note line:
;;;
;;;   [import not found: @TOKEN (NATIVE)]          missing, unreadable, a directory
;;;   [import cycle: @TOKEN (NATIVE) is already being included]
;;;                                                 NATIVE is on the current chain
;;;   [import already included: @TOKEN (NATIVE)]   shown earlier in this prompt
;;;                                                 (SEEN), not on the chain
;;;   [import not expanded: @TOKEN (NATIVE) is more than 4 hops deep]
;;;                                                 the import would be hop 5+
;;;   [import outside the project not expanded: @TOKEN (NATIVE)]
;;;                                                 project scope, NATIVE outside
;;;                                                 BOUNDARY
;;;
;;; A file with no tokens gives H3a's block exactly. NATIVE is the truename's
;;; native namestring for existing files, else the resolved path's. The
;;; top-level file is hop 0; +MAX-IMPORT-HOPS+ (4) is the deepest import
;;; expanded. Every note is also returned in NOTES as
;;; "INCLUDING-NATIVE: <text inside the brackets>". IMPORTS are (path . from)
;;; truename pairs of the expanded imports, in prompt order. SEEN (an EQUAL
;;; hash table of native namestrings, shared by all the files of one prompt)
;;; gets every file shown, the top-level one included.
;;;
;;; Scope. USER-SCOPE true (the user AGENTS.md, contextFiles): any path may be
;;; imported. Otherwise (the project chain) only paths under BOUNDARY (the
;;; project root, else the top-level file's directory) are expanded, at every
;;; hop; the rest get the "outside the project" note. H3e's project trust will
;;; add an approval.
;;;
;;; Context (LOAD-INSTRUCTION-CONTEXT). Reads, for CWD and merged SETTINGS:
;;; CONTEXT-FILES = INSTRUCTION-FILES with :CONTEXT-FILES (SETTINGS-CONTEXT-
;;; FILES); a missing or blank context file adds the note "context file not
;;; found: NATIVE". The blocks' IMPORTS and NOTES, in prompt order. SKILLS and
;;; their notes (DISCOVER-SKILLS), RULES and their notes (DISCOVER-RULES).
;;; LOADED-RULES = the always-on rules' native paths, then SESSION-RULES (native
;;; strings from INSTRUCTION-SET-LOADED-RULES of the head's instruction set,
;;; for a resumed session) that are still found. The context is what the
;;; built-in components of the instruction set are made from
;;; (MAKE-INSTRUCTION-SET, src/instruction-sets.lisp). Notes in this order: instruction files, skills, rules.

(defparameter +max-import-hops+ 4
  "H3e-1: the deepest import expanded (the instruction file is hop 0), as
Claude Code's \"maximum depth of four hops\".")

(defclass instruction-context ()
  ((files :initarg :files :reader context-files :initform '()
          :documentation "Top-level instruction files (truenames), prompt order.")
   (imports :initarg :imports :reader context-imports :initform '()
            :documentation "Expanded imports: (path . from) truenames, prompt order.")
   (skills :initarg :skills :reader context-skills :initform '()
           :documentation "Skills (STEER-DIRECTIVEs, kind :SKILL), listing order.")
   (rules :initarg :rules :reader context-rules :initform '()
          :documentation "Every rule found (STEER-DIRECTIVEs, kind :RULE), rule order.")
   (notes :initarg :notes :reader context-notes :initform '()
          :documentation "Diagnostic strings, in order.")
   (project-dir :initarg :project-dir :reader context-project-dir :initform nil
                :documentation "The project root, else the cwd (a directory truename).")
   (loaded-rules :initarg :loaded-rules :reader context-loaded-rules :initform '()
                 :documentation "Native paths of the rules in context at start.")
   ;; Implementation (additive): what the instruction set's built-in
   ;; components and ASSEMBLE-SYSTEM-PROMPT read, made in one pass.
   (file-entries :initarg :file-entries :reader %context-file-entries :initform '()
                 :documentation "One plist per CONTEXT-FILES file, prompt order:
(:path TRUENAME :source :user|:context|:project :sha256 H :block TEXT :imports ((path . from) …)).")
   (configured :initarg :configured :reader %context-configured :initform '()
               :documentation "((NATIVE . FOUND) …) of SETTINGS-CONTEXT-FILES, in order."))
  (:documentation "H3e-1: what a session's system prompt, tools and init event are
built from (LOAD-INSTRUCTION-CONTEXT)."))

(defun instruction-context-p (x)
  (typep x 'instruction-context))

;;; Tokens.

(defparameter +%inline-sentinel+ (code-char #xFFFC)
  "Stands for a non-text inline (a code span) in the scanned text: not
whitespace, so an @ right after one is no import, and a path ends at one.")

(defun %ws-char-p (c)
  (member c '(#\Space #\Tab #\Newline #\Return #\Page)))

(defun %inline-text (inlines out)
  "Write the text of INLINES to the stream OUT: strings as they are, breaks as
LF, a code span as the sentinel; emphasis and link texts recursively (a link's
destination is never written)."
  (dolist (node inlines)
    (cond ((stringp node) (write-string node out))
          ((not (consp node)) nil)
          (t (case (first node)
               ((:soft-break :hard-break) (write-char #\Newline out))
               (:code (write-char +%inline-sentinel+ out))
               (:link (write-char +%inline-sentinel+ out)
                (%inline-text (third node) out)
                (write-char +%inline-sentinel+ out))
               ((:emph :strong :strike) (%inline-text (second node) out))
               (t nil))))))

(defun %block-texts (blocks)
  "The scanned texts of the markdown BLOCKS, one string per text-bearing block,
document order. Code blocks give none."
  (let ((texts '()))
    (labels ((inl (inlines)
               (push (with-output-to-string (o) (%inline-text inlines o)) texts))
             (walk (blocks)
               (dolist (b blocks)
                 (when (consp b)
                   (case (first b)
                     (:paragraph (inl (second b)))
                     (:heading (inl (third b)))
                     (:block-quote (walk (second b)))
                     (:bullet-list (dolist (item (third b)) (walk item)))
                     (:ordered-list (dolist (item (fifth b)) (walk item)))
                     (:table (dolist (cell (third b)) (inl cell))
                      (dolist (row (fourth b))
                        (dolist (cell row) (inl cell))))
                     (t nil))))))
      (walk blocks))
    (nreverse texts)))

(defun %scan-tokens (text)
  "Import tokens of one scanned TEXT, in order (duplicates kept)."
  (let ((tokens '())
        (n (length text))
        (i 0))
    (loop while (< i n)
          do (let ((c (char text i)))
               (if (and (char= c #\@)
                        (or (zerop i) (%ws-char-p (char text (1- i)))))
                   (let ((out (make-string-output-stream))
                         (j (1+ i)))
                     (loop while (< j n)
                           do (let ((d (char text j)))
                                (cond ((and (char= d #\\) (< (1+ j) n)
                                            (char= (char text (1+ j)) #\Space))
                                       (write-char #\Space out)
                                       (incf j 2))
                                      ((or (%ws-char-p d) (char= d +%inline-sentinel+))
                                       (return))
                                      (t (write-char d out) (incf j)))))
                     (let ((path (get-output-stream-string out)))
                       (when (and (plusp (length path))
                                  (not (member (char path 0) '(#\" #\'))))
                         (push path tokens)))
                     (setf i j))
                   (incf i))))
    (nreverse tokens)))

(defun import-tokens (text)
  "→ the distinct import tokens of the markdown TEXT (paths after \"@\", \"\\ \"
unescaped), in order of first appearance. See the header."
  (check-type text string)
  (let ((out '()))
    (dolist (block-text (%block-texts (mdp:parse-markdown text)))
      (dolist (token (%scan-tokens block-text))
        (unless (member token out :test #'string=)
          (push token out))))
    (nreverse out)))

;;; Paths.

(defun resolve-import (token from &key (home (user-homedir-pathname)))
  "→ the pathname TOKEN names, imported from the file FROM: \"~/…\" under HOME,
an absolute path as written, else relative to FROM's directory."
  (check-type token string)
  (%lexical-pathname
   (cond ((uiop:string-prefix-p "~/" token)
          (uiop:merge-pathnames* (uiop:parse-native-namestring (subseq token 2))
                                 (uiop:ensure-directory-pathname home)))
         (t (let ((p (uiop:parse-native-namestring token)))
              (if (uiop:absolute-pathname-p p)
                  p
                  (uiop:merge-pathnames* p (uiop:pathname-directory-pathname from))))))))

(defun %lexical-pathname (path)
  "PATH with its \"..\" (:UP / :BACK) directory components folded away."
  (let ((dir (pathname-directory path)))
    (if (and (consp dir) (eq :absolute (first dir)))
        (let ((out '()))
          (dolist (part (rest dir))
            (if (member part '(:up :back))
                (pop out)
                (push part out)))
          (make-pathname :directory (cons :absolute (nreverse out)) :defaults path))
        path)))

;;; Blocks.

(defun %file-truename (path)
  "PATH's truename when it is an existing regular file, else NIL."
  (let ((p (ignore-errors (probe-file path))))
    (and p (pathname-name p) (not (uiop:directory-pathname-p p)) p)))

(defun %own-text (path)
  "→ (values body kept): PATH's text right-trimmed and cut at
+MAX-INSTRUCTION-CHARS+ (BODY with H3a's truncation line, KEPT the text the
imports are scanned in)."
  (let* ((native (uiop:native-namestring path))
         (text (%right-trim (%read-text path))))
    (if (> (length text) +max-instruction-chars+)
        (let ((kept (subseq text 0 +max-instruction-chars+)))
          (values (format nil "~a~%[truncated: ~a is over ~d characters]"
                          kept native +max-instruction-chars+)
                  kept))
        (values text text))))

(defun %readable-text-p (path)
  (handler-case (progn (%read-text path) t)
    (error () nil)))

(defun instruction-block (path &key (home (user-homedir-pathname)) boundary user-scope seen)
  "→ (values block imports notes) for the top-level instruction file PATH (a
truename). See the header for the block, BOUNDARY, USER-SCOPE and SEEN (a
fresh table when NIL)."
  (let* ((seen (or seen (make-hash-table :test #'equal)))
         (top-native (uiop:native-namestring path))
         (boundary (and (not user-scope)
                        (%truename-directory (or boundary (uiop:pathname-directory-pathname path)))))
         (imports '())
         (notes '()))
    (setf (gethash top-native seen) t)
    (labels ((note (including text)
               (push (format nil "~a: ~a" including text) notes)
               (format nil "[~a]" text))
             (expand (file native hop chain)
               ;; The contents of FILE's block: one item per token, then its own text.
               (multiple-value-bind (body kept) (%own-text file)
                 (with-output-to-string (o)
                   (dolist (token (import-tokens kept))
                     (let* ((resolved (resolve-import token file :home home))
                            (true (and (%file-truename resolved)
                                       (%readable-text-p resolved)
                                       (%file-truename resolved)))
                            (target (if true
                                        (uiop:native-namestring true)
                                        (uiop:native-namestring resolved))))
                       (write-string
                        (cond ((null true)
                               (note native (format nil "import not found: @~a (~a)" token target)))
                              ((member target chain :test #'string=)
                               (note native (format nil "import cycle: @~a (~a) is already being included"
                                                    token target)))
                              ((gethash target seen)
                               (note native (format nil "import already included: @~a (~a)" token target)))
                              ((> (1+ hop) +max-import-hops+)
                               (note native (format nil "import not expanded: @~a (~a) is more than ~d hops deep"
                                                    token target +max-import-hops+)))
                              ((and boundary (not (uiop:subpathp true boundary)))
                               (note native (format nil "import outside the project not expanded: @~a (~a)"
                                                    token target)))
                              (t
                               (setf (gethash target seen) t)
                               (push (cons true file) imports)
                               (format nil "<import path=\"~a\">~%~a~%</import>"
                                       target (expand true target (1+ hop) (cons target chain)))))
                        o)
                       (terpri o)))
                   (write-string body o)))))
      (let ((content (expand path top-native 0 (list top-native))))
        (values (format nil "<instructions path=\"~a\">~%~a~%</instructions>" top-native content)
                (nreverse imports)
                (nreverse notes))))))

;;; The context.

(defun %file-sha256 (path)
  (p:octets-hash (p:read-bytes (uiop:native-namestring path))))

(defun load-instruction-context (cwd &key settings user-config-dir
                                       (home (user-homedir-pathname)) session-rules)
  "→ the INSTRUCTION-CONTEXT of CWD for merged SETTINGS (MAKE-SETTINGS when NIL).
SESSION-RULES: native paths of rules a resumed session already loaded. See the
header."
  (let* ((settings (or settings (make-settings)))
         (cwd (%truename-directory cwd))
         (config (uiop:ensure-directory-pathname (or user-config-dir (user-config-directory))))
         (root (find-project-root cwd))
         (project-dir (or root cwd))
         (configured (settings-context-files settings))
         (context-truenames (mapcar #'%context-file configured))
         (user-file (%directory-instruction-file config))
         (files (instruction-files cwd :user-config-dir config :context-files configured))
         (seen (make-hash-table :test #'equal))
         (notes '())
         (imports '())
         (entries '()))
    (loop for given in configured
          for true in context-truenames
          unless true
            do (push (format nil "context file not found: ~a" (uiop:native-namestring given)) notes))
    (dolist (file files)
      (let* ((source (cond ((and user-file (equal file user-file)) :user)
                           ((member file context-truenames :test #'equal) :context)
                           (t :project)))
             (user-scope (member source '(:user :context))))
        (multiple-value-bind (block file-imports file-notes)
            (instruction-block file :home home
                                    :boundary (and (not user-scope)
                                                   (or root (uiop:pathname-directory-pathname file)))
                                    :user-scope user-scope
                                    :seen seen)
          (setf imports (append imports file-imports)
                notes (append (reverse file-notes) notes))
          (push (list :path file :source source :sha256 (%file-sha256 file)
                      :block block :imports file-imports)
                entries))))
    (multiple-value-bind (skills skill-notes)
        (discover-skills cwd :settings settings :user-config-dir config)
      (multiple-value-bind (rules rule-notes) (discover-rules cwd :user-config-dir config)
        (let* ((natives (mapcar (lambda (r) (uiop:native-namestring (steer:steer-directive-path r)))
                                rules))
               (always (loop for r in rules
                             for native in natives
                             when (rule-always-p r) collect native))
               (loaded (append always
                               (remove-if (lambda (n)
                                            (or (member n always :test #'string=)
                                                (not (member n natives :test #'string=))))
                                          (remove-duplicates session-rules :test #'string=
                                                                           :from-end t)))))
          (make-instance 'instruction-context
                         :files files
                         :imports imports
                         :skills skills
                         :rules rules
                         :notes (append (nreverse notes) skill-notes rule-notes)
                         :project-dir project-dir
                         :loaded-rules loaded
                         :file-entries (nreverse entries)
                         :configured (loop for given in configured
                                           for true in context-truenames
                                           collect (cons (uiop:native-namestring (or true given))
                                                         (and true t)))))))))
