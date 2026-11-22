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
                 :documentation "Native paths of the rules in context at start."))
  (:documentation "H3e-1: what a session's system prompt, tools and init event are
built from (LOAD-INSTRUCTION-CONTEXT)."))

(defun instruction-context-p (x)
  (typep x 'instruction-context))

(defun import-tokens (text)
  "→ the distinct import tokens of the markdown TEXT (paths after \"@\", \"\\ \"
unescaped), in order of first appearance. See the header."
  (declare (ignore text))
  (%h3e1-pending "import-tokens"))

(defun resolve-import (token from &key (home (user-homedir-pathname)))
  "→ the pathname TOKEN names, imported from the file FROM: \"~/…\" under HOME,
an absolute path as written, else relative to FROM's directory."
  (declare (ignore token from home))
  (%h3e1-pending "resolve-import"))

(defun instruction-block (path &key (home (user-homedir-pathname)) boundary user-scope seen)
  "→ (values block imports notes) for the top-level instruction file PATH (a
truename). See the header for the block, BOUNDARY, USER-SCOPE and SEEN (a
fresh table when NIL)."
  (declare (ignore path home boundary user-scope seen))
  (%h3e1-pending "instruction-block"))

(defun load-instruction-context (cwd &key settings user-config-dir
                                       (home (user-homedir-pathname)) session-rules)
  "→ the INSTRUCTION-CONTEXT of CWD for merged SETTINGS (MAKE-SETTINGS when NIL).
SESSION-RULES: native paths of rules a resumed session already loaded. See the
header."
  (declare (ignore cwd settings user-config-dir home session-rules))
  (%h3e1-pending "load-instruction-context"))
