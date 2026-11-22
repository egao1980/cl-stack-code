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
;;; in context: the always-on rules and SESSION-LOADED-RULES). The
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
;;; Records. A turn's TURN-RECORD gets :RULES, the native paths of the
;;; path-scoped rules first loaded in that turn (the run's :instructions events'
;;; :rule directives), in order. -p, the TUI and the SDK seed a resumed or
;;; continued session's discovery with SESSION-LOADED-RULES of its head.
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
order; copies share the cons."))
  (:documentation "H3e-1: nested AGENTS.md (the parent class) plus path-scoped
rules, loaded once per session. See the header."))

(defun discovery-loaded-rules (discovery)
  "→ native paths of the rules in context in DISCOVERY's session, load order."
  (copy-list (car (%discovery-loaded discovery))))

(defun rule-roots (cwd &key user-config-dir)
  "→ the existing rule roots of CWD (truenames), in order. See the header."
  (declare (ignore cwd user-config-dir))
  (%h3e1-pending "rule-roots"))

(defun parse-rule-file (path)
  "→ the STEER-DIRECTIVE (kind :RULE) of the rule file PATH, or
RULE-FORMAT-ERROR. See the header."
  (declare (ignore path))
  (%h3e1-pending "parse-rule-file"))

(defun discover-rules (cwd &key user-config-dir)
  "→ (values rules notes) for CWD. See the header."
  (declare (ignore cwd user-config-dir))
  (%h3e1-pending "discover-rules"))

(defun rule-patterns (rule)
  "→ RULE's paths patterns (strings), or NIL for an always-on rule."
  (declare (ignore rule))
  (%h3e1-pending "rule-patterns"))

(defun rule-always-p (rule)
  "→ true when RULE has no paths patterns."
  (declare (ignore rule))
  (%h3e1-pending "rule-always-p"))

(defun rule-matches-p (rule path project-dir)
  "→ true when the path-scoped RULE matches PATH under PROJECT-DIR. See the header."
  (declare (ignore rule path project-dir))
  (%h3e1-pending "rule-matches-p"))

(defun rule-block (rule)
  "→ the system prompt block of the always-on RULE."
  (declare (ignore rule))
  (%h3e1-pending "rule-block"))

(defun make-code-instruction-discovery (cwd &key rules project-dir loaded)
  "→ a CODE-INSTRUCTION-DISCOVERY for CWD. See the header."
  (declare (ignore cwd rules project-dir loaded))
  (%h3e1-pending "make-code-instruction-discovery"))
