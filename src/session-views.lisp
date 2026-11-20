(in-package #:cl-stack-code)

;;; H3c: pure views of a session: the transcript entries a resumed session
;;; shows, the /tree, the --list-sessions lines and /export.
;;;
;;; Entries (SESSION-ENTRIES), per revision of the line, root first:
;;;   (:user PROMPT)                the record's prompt as typed
;;;   then, for the record's TURNS in order:
;;;     the first :user turn        skipped (it is PROMPT, mentions expanded)
;;;     a later :user turn made of text parts only, whose text does not
;;;     start with "<instructions"
;;;                                 the record's next STEERING text as a :user
;;;                                 entry (skipped when none is left)
;;;     an :assistant turn          its text parts concatenated → an :assistant
;;;                                 entry when not empty; then one :tool entry
;;;                                 per tool-call part (id, name, input = the
;;;                                 arguments string, status :done)
;;;     tool-result parts (any turn)
;;;                                 fill the :tool entry with their id: result
;;;                                 = the content, error-p, status :error when
;;;                                 error-p
;;;     anything else               skipped
;;;   a record whose FINISH is :CANCELED ends with (:notice "interrupted")
;;;
;;; Tree (SESSION-TREE-LINES). Every revision once, depth first from each root
;;; (roots and children in the store's insertion order, REV:WALK-REVISIONS
;;; :TOPO). A revision's label is "<mark> <first 8 id characters> <message>",
;;; mark "●" when it is on the head's line and "○" otherwise; the head's label
;;; ends with "  (head)". A revision with one child continues at its own
;;; indentation; a revision with several children draws each child's branch
;;; with "├─ " (or "└─ " for the last), and that branch continues under the
;;; prefix "│  " (or "   "):
;;;
;;;   ● aaaaaaaa first question
;;;   ● bbbbbbbb second question
;;;   ├─ ○ cccccccc third question
;;;   │  ○ eeeeeeee fifth question
;;;   └─ ● dddddddd another third  (head)
;;;
;;; A line longer than WIDTH characters has its message cut so the line is
;;; exactly WIDTH, ending in "…" (the prefix, mark, id and "  (head)" are never
;;; cut). No revisions → ("no turns yet").
;;;
;;; Markdown export (EXPORT-SESSION :FORMAT :MARKDOWN), blocks joined by one
;;; empty line, the text ending in one LF:
;;;   "# Session <id>"
;;;   per revision of the line: "## Turn <N>" (N from 1), then per entry:
;;;     :user       "**User**" and the text (two blocks)
;;;     :assistant  "**Assistant**" and the text
;;;     :tool       "**Tool** `<name>` <input>", plus " (error)" when error-p;
;;;                 then, when it has a result, the result in a fence of
;;;                 backticks one longer than the longest run of backticks in
;;;                 it (at least 3): "```" LF result LF "```"
;;;     :notice     "_<text>_"
;;;
;;; JSON export (:FORMAT :JSON): one object and LF:
;;;   {"session_id", "project" (native namestring or null), "head" (id or
;;;    null), "turns": [{"revision", "parent" (null for a root), "prompt",
;;;    "model" (or null), "permission_mode" (the mode name), "finish"
;;;    ("stop" "max_steps" "canceled" "failed"), "usage" (as in stream-json),
;;;    "steering" [...], "messages": [{"role" ("user" "assistant" "tool"),
;;;    "parts": [part]}]}]}
;;;   part: {"type":"text","text"} · {"type":"tool_call","id","name",
;;;   "arguments"} · {"type":"tool_result","id","name","content","is_error"} ·
;;;   {"type":"thinking","text"} · any other part {"type": its PART-STATE
;;;   :type, lowercased, - as _}

(defun session-entries (store &optional (designator +head-ref+))
  "→ fresh ENTRY values for the transcript of DESIGNATOR's line (see the file
header)."
  (declare (ignore store designator))
  (%not-implemented 'session-entries))

(defun session-tree-lines (store &key (width 80))
  "→ the /tree lines of STORE (strings; see the file header)."
  (declare (ignore store width))
  (%not-implemented 'session-tree-lines))

(defun session-summary-lines (sessions-dir)
  "→ one --list-sessions line per session of LIST-SESSIONS, in its order:
\"<id>  <N> turn[s]  <prompt>\", N = the length of the head's line (\"1
turn\", \"2 turns\", \"0 turns\"), PROMPT the first line of the line's root
prompt cut to 60 characters (59 and \"…\"); with 0 turns the line ends after
\"0 turns\"."
  (declare (ignore sessions-dir))
  (%not-implemented 'session-summary-lines))

(defun export-session (store stream &key (format :markdown) (designator +head-ref+))
  "Write DESIGNATOR's line of STORE to STREAM as FORMAT (:MARKDOWN or :JSON;
see the file header). → the number of turns written."
  (declare (ignore store stream format designator))
  (%not-implemented 'export-session))
