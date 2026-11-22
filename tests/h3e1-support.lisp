(in-package #:cl-stack-code/tests)

;;; H3e-1 helpers (test code, complete): skill and rule file texts, the
;;; lisp-workspace fixture, the expected blocks, small accessors.

(defun skill-md (name description &key (body "Body.") (folded t))
  "A SKILL.md text: NAME, DESCRIPTION (a folded `>-` scalar when FOLDED, over
two lines when it has a space), then BODY."
  (let ((space (position #\Space description)))
    (if (and folded space)
        (format nil "---~%name: ~a~%description: >-~%  ~a~%  ~a~%---~%~%~a~%"
                name (subseq description 0 space) (subseq description (1+ space)) body)
        (format nil "---~%name: ~a~%description: ~a~%---~%~%~a~%" name description body))))

(defun rule-md (patterns body)
  "A rule file: PATTERNS as a block list (none: no frontmatter), comments and
Cursor's keys as in lisp-workspace, then BODY."
  (if patterns
      (format nil "---~%description: A rule~%# Claude Code~%paths:~%~{  - \"~a\"~%~}# Cursor~%globs: \"~a\"~%alwaysApply: false~%---~%~%~a~%"
              patterns (first patterns) body)
      (format nil "~a~%" body)))

(defun import-block (path text)
  "The <import> item of the file PATH (an existing file) whose expansion is TEXT."
  (format nil "<import path=\"~a\">~%~a~%</import>" (native (truename path)) text))

(defun top-block (path text)
  (format nil "<instructions path=\"~a\">~%~a~%</instructions>" (native (truename path)) text))

(defun rule-injection (path patterns body)
  "The injected text of a path-scoped rule (STEER:COMPILE-INSTRUCTIONS)."
  (format nil "<instructions path=\"~a\" scope=\"~{~a~^, ~}\">~%~a~%</instructions>"
          (native (truename path)) patterns body))

(defun count-of (needle haystack)
  "Occurrences of NEEDLE in HAYSTACK."
  (loop with start = 0 and n = 0
        for i = (search needle haystack :start2 start)
        while i do (incf n) (setf start (1+ i))
        finally (return n)))

(defun first-system (backend)
  "The system prompt of BACKEND's first request."
  (request-system (first (scripted-requests backend))))

(defun init-of (out)
  (first (events out "system")))

(defun init-names (init key field)
  "FIELD of each object in the init event's KEY array."
  (map 'list (lambda (o) (jget o field)) (jget init key)))

(defun lisp-read-step (file)
  (list :tool "read" (json-args "file_path" file)))

(defun skill-step (name &optional path)
  (list :tool "skill" (if path (json-args "name" name "path" path) (json-args "name" name))))

(defparameter +fixture-agents+ "# Agent instructions

Act as a senior Common Lisp developer.")

(defparameter +fixture-claude-tail+ "## Claude Code

Skills load from .claude/skills/.")

(defparameter +fixture-rule-body+ "# cl-stack conditions

Define a typed foo-error tree.")

(defun lisp-workspace-fixture ()
  "MAKE-TREE entries mirroring a workspace with lisp-workspace in
.lisp-workspace/: the root CLAUDE.md imports .lisp-workspace/CLAUDE.md, which
imports AGENTS.md; one skill (rove), one path-scoped rule (lisp.md), the
plugin context file (never read on its own), and src/a.lisp."
  (list (list "CLAUDE.md" (format nil "@.lisp-workspace/CLAUDE.md~%~%<!-- Workspace root. -->~%"))
        (list ".lisp-workspace/CLAUDE.md" (format nil "@AGENTS.md~%~%~a~%" +fixture-claude-tail+))
        (list ".lisp-workspace/AGENTS.md" (format nil "~a~%" +fixture-agents+))
        (list ".lisp-workspace/skills/rove/SKILL.md"
              (skill-md "rove" "Rove quick ref (ok / signals / deftest-parametrize). For policy and runner choice use cl-unit-testing."
                        :body "# Rove

Use deftest and ok."))
        (list ".lisp-workspace/skills/rove/reference.md" (format nil "More about rove.~%"))
        (list ".lisp-workspace/rules/lisp.md" (rule-md '("**/*.lisp") +fixture-rule-body+))
        (list ".lisp-workspace/plugin/context.md" (format nil "PLUGIN CONTEXT ONLY~%"))
        (list "src/a.lisp" (format nil "(in-package :cl-user)~%"))))
