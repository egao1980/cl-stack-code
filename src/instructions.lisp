(in-package #:cl-stack-code)

;;; Project root, AGENTS.md discovery and system prompt assembly.

(defparameter +instruction-file-names+ '("AGENTS.md" "CLAUDE.md")
  "Instruction file names in priority order: the first found in a directory
counts.")

(defparameter +max-instruction-chars+ 32000
  "Characters kept from one instruction file.")

(defun %truename-directory (directory)
  "DIRECTORY as a directory pathname, its truename when it exists."
  (let ((dir (uiop:ensure-directory-pathname directory)))
    (or (probe-file dir) dir)))

(defun %parent-directory (dir)
  "The parent of directory DIR, or NIL at the filesystem root."
  (let ((parent (uiop:pathname-parent-directory-pathname dir)))
    (and parent (not (equal parent dir)) parent)))

(defun %git-entry-p (dir)
  "T when DIR holds a .git entry, directory or file."
  (and (probe-file (make-pathname :name ".git" :type nil :version nil :defaults dir))
       t))

(defun find-project-root (directory)
  "→ the truename of the nearest directory from DIRECTORY upward that holds a
.git entry (directory or file), or NIL."
  (loop for dir = (%truename-directory directory) then (%parent-directory dir)
        while dir
        when (%git-entry-p dir) return dir))

(defun %blank-p (text)
  (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return #\Page))) text))

(defun %read-text (path)
  (uiop:read-file-string path :external-format :utf-8))

(defun %directory-instruction-file (dir)
  "The truename of DIR's instruction file: the first of +INSTRUCTION-FILE-NAMES+
that is a regular file, unless it is blank. → NIL when there is none."
  (dolist (name +instruction-file-names+ nil)
    (let ((path (probe-file (merge-pathnames name dir))))
      ;; A directory named AGENTS.md has a truename without a file name.
      (when (and path (pathname-name path))
        (return (and (not (%blank-p (%read-text path))) path))))))

(defun %directory-chain (cwd)
  "Directories from the project root (else the filesystem root) down to CWD."
  (let ((root (find-project-root cwd))
        (chain '()))
    (loop for dir = cwd then (%parent-directory dir)
          while dir
          do (push dir chain)
          until (and root (equal dir root)))
    chain))

(defun %context-file (path)
  "H3e-1: the truename of the context file PATH, or NIL when it is missing, a
directory or blank."
  (let ((p (probe-file path)))
    (and p (pathname-name p) (not (%blank-p (%read-text p))) p)))

(defun instruction-files (cwd &key user-config-dir context-files)
  "→ truenames of the instruction files for working directory CWD, in prompt
order: the user-level file in USER-CONFIG-DIR, then (H3e-1) the CONTEXT-FILES
(pathnames, in order; missing or blank ones left out), then one per directory
from the project root (else the filesystem root) down to CWD. Blank files are
left out; a file named twice appears once, at its first place."
  (let ((cwd (%truename-directory cwd))
        (user (uiop:ensure-directory-pathname
               (or user-config-dir (user-config-directory)))))
    (remove-duplicates
     (remove nil
             (append (list (%directory-instruction-file user))
                     (mapcar #'%context-file context-files)
                     (mapcar #'%directory-instruction-file (%directory-chain cwd))))
     :test #'equal :from-end t)))

(defun %right-trim (text)
  (string-right-trim '(#\Space #\Tab #\Newline #\Return #\Page) text))

(defun %instruction-block (path)
  (let* ((native (uiop:native-namestring path))
         (text (%right-trim (%read-text path)))
         (body (if (> (length text) +max-instruction-chars+)
                   (format nil "~a~%[truncated: ~a is over ~d characters]"
                           (subseq text 0 +max-instruction-chars+)
                           native +max-instruction-chars+)
                   text)))
    (format nil "<instructions path=\"~a\">~%~a~%</instructions>" native body)))

(defun %platform-name ()
  #+darwin "darwin"
  #+linux "linux"
  #+(or windows win32) "windows"
  #-(or darwin linux windows win32) "other")

(defun %environment-section (cwd root mode)
  (format nil "# Environment~%- Working directory: ~a~%- Project root: ~a~%- Platform: ~a~%- Permission mode: ~a"
          (uiop:native-namestring cwd)
          (if root (uiop:native-namestring root) "none")
          (%platform-name)
          (permission-mode-name mode)))

(defun %plan-environment-sections (cwd plan settings)
  "H5a: the sections that replace the # Environment section in a plan run:
  # Environment
  - Working directory: <native PLAN-TOOL-ROOT of CWD>
  - Project root: <native PLAN-ROOT, or \"none\" when CWD has no project root>
  - Platform: <as without a plan>
  - Permission mode: <mode name>
  - Plan: <id> (<copy|git>), a copy of <native PLAN-PROJECT-DIR>
then, as its own section, +PLAN-MODE-FEEDBACK+. → list of two strings."
  (let ((cwd (%truename-directory cwd)))
    (list (format nil "# Environment~%- Working directory: ~a~%- Project root: ~a~%- Platform: ~a~%- Permission mode: ~a~%- Plan: ~a (~(~a~)), a copy of ~a"
                  (uiop:native-namestring (plan-tool-root plan cwd))
                  (if (find-project-root cwd) (uiop:native-namestring (plan-root plan)) "none")
                  (%platform-name)
                  (permission-mode-name (settings-permission-mode settings))
                  (plan-id plan)
                  (plan-kind plan)
                  (uiop:native-namestring (plan-project-dir plan)))
          +plan-mode-feedback+)))

(defun assemble-system-prompt (cwd &key tools backend settings user-config-dir plan lisp-image
                                     sandbox context instruction-set)
  "→ (values prompt files). Sections joined by one blank line: steer's
BUILD-SYSTEM-PROMPT for TOOLS (offered names) and BACKEND, the # Environment
section, each instruction file as <instructions path=\"…\">…</instructions>,
then SETTINGS-APPEND-SYSTEM-PROMPT. FILES is INSTRUCTION-FILES. H5a: with a
PLAN, the # Environment section is %PLAN-ENVIRONMENT-SECTIONS (the area's
directories, the plan line, then +PLAN-MODE-FEEDBACK+); the instruction files
are still CWD's own. H4b: with LISP-IMAGE (the LISP-MCP/AGENT:LISP-TOOLS source),
%LISP-IMAGE-SECTIONS follow the environment sections. R4d-4b: with a SANDBOX
(a PLAN-SANDBOX, plan runs only), PLAN-SANDBOX-SECTION follows the plan
sections, before the image sections.

H3e-1 (the implementation wires it): CONTEXT is an INSTRUCTION-CONTEXT
(LOAD-INSTRUCTION-CONTEXT for CWD, SETTINGS and USER-CONFIG-DIR when NIL). The
instruction blocks are then INSTRUCTION-BLOCK of each CONTEXT-FILES entry (its
imports expanded), followed by RULE-BLOCK of each always-on rule, then
SKILL-LISTING-SECTION of CONTEXT-SKILLS (when there are skills), then
SETTINGS-APPEND-SYSTEM-PROMPT. → (values prompt files context): FILES is
CONTEXT-FILES. With INSTRUCTION-SET (an INSTRUCTION-SET with a current
revision), those blocks are INSTRUCTION-SET-BLOCKS of its current revision
instead (a rewound or resumed session renders the set it continues). Until
then CONTEXT is returned as given and unused, and INSTRUCTION-SET is ignored."
  (declare (ignore instruction-set))
  (let* ((settings (or settings (make-settings)))
         (cwd (%truename-directory cwd))
         (files (instruction-files cwd :user-config-dir user-config-dir))
         (append-prompt (settings-append-system-prompt settings))
         (sections (append
                    (list (steer:build-system-prompt :tools tools :model backend))
                    (if plan
                        (append (%plan-environment-sections cwd plan settings)
                                (and sandbox (list (plan-sandbox-section sandbox))))
                        (list (%environment-section cwd (find-project-root cwd)
                                                    (settings-permission-mode settings))))
                    (and lisp-image (%lisp-image-sections lisp-image settings))
                    (mapcar #'%instruction-block files)
                    (and append-prompt (plusp (length append-prompt))
                         (list append-prompt)))))
    (values (format nil "~{~a~^~%~%~}" sections) files context)))
