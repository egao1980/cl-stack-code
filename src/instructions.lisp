(in-package #:cl-stack-code)

;;; Project root, AGENTS.md discovery and system prompt assembly.

(defparameter +instruction-file-names+ '("AGENTS.md" "CLAUDE.md")
  "Instruction file names in priority order: the first found in a directory
counts.")

(defparameter +max-instruction-chars+ 32000
  "Characters kept from one instruction file.")

(defun find-project-root (directory)
  "→ the truename of the nearest directory from DIRECTORY upward that holds a
.git entry (directory or file), or NIL."
  (declare (ignore directory))
  (%not-implemented 'find-project-root))

(defun instruction-files (cwd &key user-config-dir)
  "→ truenames of the instruction files for working directory CWD, in prompt
order: the user-level file in USER-CONFIG-DIR, then one per directory from the
project root (else the filesystem root) down to CWD. Blank files are left out."
  (declare (ignore cwd user-config-dir))
  (%not-implemented 'instruction-files))

(defun assemble-system-prompt (cwd &key tools backend settings user-config-dir)
  "→ (values prompt files). Sections joined by one blank line: steer's
BUILD-SYSTEM-PROMPT for TOOLS (offered names) and BACKEND, the # Environment
section, each instruction file as <instructions path=\"…\">…</instructions>,
then SETTINGS-APPEND-SYSTEM-PROMPT. FILES is INSTRUCTION-FILES."
  (declare (ignore cwd tools backend settings user-config-dir))
  (%not-implemented 'assemble-system-prompt))
