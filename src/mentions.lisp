(in-package #:cl-stack-code)

;;; H3b: @path mentions.
;;;
;;; PROJECT-FILES: every file and directory under ROOT as a root-relative
;;; string with "/" separators, directories ending in "/", sorted STRING<.
;;; .gitignore / .ignore files apply (cl-stack-pathlib's :IGNORE :AUTO); a
;;; directory named ".git" and everything under it is left out; other dot
;;; files are kept. Directory symlinks are listed, not descended. At most
;;; LIMIT entries: the first LIMIT of the sorted list.
;;;
;;; MENTION-CANDIDATES: TOKEN is text-input's completion token. It must start
;;; with "@"; the query Q is the rest. An entry of FILES matches when Q occurs
;;; in it ignoring case (CHAR-EQUAL). Matches come in three groups, each in
;;; FILES order: (1) the entry starts with Q; (2) a segment after a "/"
;;; starts with Q; (3) the rest. Each candidate is "@" + the entry, at most
;;; LIMIT of them. An empty Q gives the first LIMIT entries. A token without
;;; "@" gives NIL.
;;;
;;; EXPAND-MENTIONS: a mention is "@" at the start of TEXT or after
;;; whitespace, followed by non-whitespace; trailing characters from
;;; . , ; : ! ? ) ] } " ' are not part of the path. The path is relative to
;;; ROOT. A mention naming a regular file under ROOT (no "..", no absolute
;;; path, no symlink leaving ROOT) whose content is UTF-8 is attached once, in
;;; order of first mention; anything else stays plain text. The prompt is
;;; TEXT, then for each attached file:
;;;
;;;   LF LF <file path="REL"> LF content LF </file>
;;;
;;; where REL is the mention's path as written (without the "@") and content
;;; has its trailing whitespace trimmed. Content over +MAX-MENTION-CHARS+
;;; characters is cut to that many and followed by LF
;;; "[truncated: REL is over 32000 characters]". → (values prompt rels).

(defparameter +max-mention-chars+ 32000
  "Characters of one @-mentioned file the prompt carries.")

(defun project-files (root &key (limit 10000))
  "→ root-relative entries under ROOT (see the file header), sorted."
  (declare (ignore root limit))
  (%not-implemented 'project-files))

(defun mention-candidates (files token &key (limit 20))
  "→ completion candidates (\"@path\" strings) of TOKEN over FILES."
  (declare (ignore files token limit))
  (%not-implemented 'mention-candidates))

(defun expand-mentions (text root)
  "→ (values prompt attached-rels): TEXT with the @-mentioned files of ROOT
appended (see the file header)."
  (declare (ignore text root))
  (%not-implemented 'expand-mentions))
