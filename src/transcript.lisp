(in-package #:cl-stack-code)

;;; H3b: transcript entries and how they look. Everything here is pure.
;;;
;;; An ENTRY is one block of the transcript:
;;;   :user       TEXT is what the user typed (mentions not expanded)
;;;   :assistant  TEXT is the streamed markdown of one assistant message
;;;   :tool       ID NAME INPUT (the arguments: JSON string, object or NIL)
;;;               STATUS (an agent-invocation status) RESULT (string or NIL)
;;;               ERROR-P
;;;   :notice     TEXT, e.g. "interrupted", /help output
;;;   :error      TEXT, a message
;;;
;;; TOOL-CALL-SUMMARY NAME INPUT → one line. INPUT is decoded when it is a
;;; JSON object string. With A the decoded object:
;;;   read write edit multi_edit   "NAME <file_path>"
;;;   glob grep                    "NAME <pattern>"
;;;   ls                           "ls <path>", path default "."
;;;   bash                         "bash <command>": only the first line of
;;;                                the command, then " …" when it has more
;;;   job_output job_input job_kill "NAME <job_id>"
;;;   any other tool               "NAME <A encoded as compact JSON>"
;;; A missing or empty argument gives just "NAME" (ls: "ls ."). Input that
;;; is not an object:
;;; "NAME <input as given>", or "NAME" for NIL / "".
;;;
;;; TOOL-RESULT-DIFF RESULT → the unified diff in an agent-tools edit /
;;; multi_edit result: from its first line starting with "--- a/" up to (not
;;; including) the last line starting with "hash: ", every line ending in
;;; LF; NIL when there is no such line pair.
;;;
;;; TOOL-CALL-PREVIEW ROOT NAME INPUT → the diff the call would make, as the
;;; same text agent-tools puts in its edit result, or NIL. REL is file_path
;;; relative to ROOT ("/" separators). OLD / NEW are the file's text before
;;; and after:
;;;   edit        old_string → new_string in the file's text, every match with
;;;               replace_all, else exactly one match (0 or >1 → NIL)
;;;   multi_edit  the edits in order, each under the same rule (any → NIL)
;;;   write       NEW is content; an existing file's OLD is its text
;;; → "--- a/REL" LF "+++ b/REL" LF (DIFF:RENDER-DIFF (DIFF:COMPUTE-DIFF
;;; (DIFF:FIND-DIFF-ENGINE :TEXT) OLD NEW :CONTEXT 3) :UNIFIED NIL); a write
;;; to a new file starts "--- /dev/null" LF and diffs "" → content. Other
;;; tools, bad arguments, a path outside ROOT or a file that is not UTF-8 →
;;; NIL. Never signals.
;;;
;;; APPROVAL-MESSAGE ROOT INVOCATION → the approval dialog's message: the
;;; summary; then, when TOOL-CALL-PREVIEW gives a diff, LF and its first 12
;;; lines, followed by LF "… +N more lines" when it has N more. Lines are
;;; joined by LF, with no final LF.
;;;
;;; TRANSCRIPT-LINES ENTRIES WIDTH &key STREAMING → lines of runs
;;; (tui-protocol/widgets) for a viewport WIDTH cells wide. Entries are
;;; separated by one empty line (no leading or trailing empty line). Per kind:
;;;   :user       W:WRAP-RUNS of the text at WIDTH − 2; first row "> " + row,
;;;               the others "  " + row
;;;   :assistant  (MD:RENDER-MARKDOWN text WIDTH); when STREAMING is true and
;;;               the entry is the last one, the lines of a markdown stream of
;;;               WIDTH fed the text (MD:MARKDOWN-STREAM-LINES, not finished)
;;;   :tool       "● " + summary, cut with W:TRUNCATE-RUNS at WIDTH; then
;;;               - status :done with a TOOL-RESULT-DIFF: each line of
;;;                 (MD:RENDER-DIFF-LINES diff (- WIDTH 2)) after "  "
;;;               - status :done, :error or :denied otherwise: "  ⎿ " + the
;;;                 result's first line (cut at WIDTH), or "  ⎿ (no output)"
;;;                 for an empty result; when the result has N > 0 more lines
;;;                 (final empty lines not counted), "    … +N lines"
;;;               - any other status: nothing more
;;;   :notice     the text wrapped at WIDTH
;;;   :error      "error: " + text, wrapped at WIDTH
;;; Styles are free; tests compare W:RUNS-STRING of each line.

(defstruct (entry (:constructor make-entry
                      (&key kind text id name input status result error-p)))
  "One transcript block (see the file header)."
  (kind :notice :type (member :user :assistant :tool :notice :error))
  (text "")
  (id nil)
  (name nil)
  (input nil)
  (status nil)
  (result nil)
  (error-p nil))

(defun tool-call-summary (name input)
  "→ one line saying what the tool call NAME with INPUT does."
  (declare (ignore name input))
  (%not-implemented 'tool-call-summary))

(defun tool-result-diff (result)
  "→ the unified diff text inside an edit / multi_edit RESULT, or NIL."
  (declare (ignore result))
  (%not-implemented 'tool-result-diff))

(defun tool-call-preview (root name input)
  "→ the unified diff the call would make under ROOT, or NIL."
  (declare (ignore root name input))
  (%not-implemented 'tool-call-preview))

(defun approval-message (root invocation)
  "→ the approval dialog message for INVOCATION (an AGENT-INVOCATION)."
  (declare (ignore root invocation))
  (%not-implemented 'approval-message))

(defun transcript-lines (entries width &key streaming)
  "→ lines of runs showing ENTRIES at WIDTH (see the file header)."
  (declare (ignore entries width streaming))
  (%not-implemented 'transcript-lines))
