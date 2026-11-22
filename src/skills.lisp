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

(defun skill-roots (cwd &key settings user-config-dir)
  "→ ((directory-truename . source) …), the existing skill roots of CWD in
precedence order. See the header."
  (declare (ignore cwd settings user-config-dir))
  (%h3e1-pending "skill-roots"))

(defun parse-skill-file (path)
  "→ the STEER-DIRECTIVE (kind :SKILL) of the SKILL.md PATH, or
SKILL-FORMAT-ERROR. See the header."
  (declare (ignore path))
  (%h3e1-pending "parse-skill-file"))

(defun discover-skills (cwd &key settings user-config-dir)
  "→ (values skills notes) for CWD. See the header."
  (declare (ignore cwd settings user-config-dir))
  (%h3e1-pending "discover-skills"))

(defun skill-directory (skill)
  "→ the directory pathname of SKILL's SKILL.md."
  (declare (ignore skill))
  (%h3e1-pending "skill-directory"))

(defun skill-source (skill)
  "→ SKILL's source string (+SKILL-SOURCE-NAMES+)."
  (declare (ignore skill))
  (%h3e1-pending "skill-source"))

(defun skill-listing-section (skills)
  "→ the # Skills section for SKILLS, or NIL when there are none."
  (declare (ignore skills))
  (%h3e1-pending "skill-listing-section"))

(defun make-skill-tools (skills)
  "→ a SKILL-TOOLS source over SKILLS (listing order)."
  (declare (ignore skills))
  (%h3e1-pending "make-skill-tools"))

(defun skill-tool-result (skill &optional path)
  "→ the skill tool's result text for SKILL, or for its file PATH (a string
relative to SKILL-DIRECTORY). A PATH outside the directory or missing signals
AI-AGENT-PROTOCOL:TOOL-INPUT-ERROR with the header's text."
  (declare (ignore skill path))
  (%h3e1-pending "skill-tool-result"))
