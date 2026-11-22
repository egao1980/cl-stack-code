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
;;;   :plan       (H5a) "● plan <id8>: N file[s] changed" (ID the plan id,
;;;               N = (length INPUT), INPUT the plan changes), then each line
;;;               of (MD:RENDER-DIFF-LINES text (- WIDTH 2)) after "  "
;;; Styles are free; tests compare W:RUNS-STRING of each line.

(defstruct (entry (:constructor make-entry
                      (&key kind text id name input status result error-p)))
  "One transcript block (see the file header)."
  (kind :notice :type (member :user :assistant :tool :notice :error :plan))
  (text "")
  (id nil)
  (name nil)
  (input nil)
  (status nil)
  (result nil)
  (error-p nil))

(defun %decode-object (input)
  "INPUT as a JSON object (hash table): itself, or a decoded JSON object
string; NIL otherwise."
  (cond ((hash-table-p input) input)
        ((stringp input)
         (let ((value (handler-case (json:decode input)
                        (error () nil))))
           (and (hash-table-p value) value)))
        (t nil)))

(defun %arg-string (object key)
  "KEY of OBJECT as a non-empty string, or NIL."
  (multiple-value-bind (value present) (gethash key object)
    (cond ((or (not present) (null value) (eq value :null)) nil)
          ((stringp value) (and (plusp (length value)) value))
          (t (princ-to-string value)))))

(defun %text-lines (text)
  "TEXT split at LF; a final LF starts no line."
  (let ((out '()) (start 0) (n (length text)))
    (loop for nl = (position #\Linefeed text :start start)
          while nl
          do (push (subseq text start nl) out)
             (setf start (1+ nl)))
    (when (< start n)
      (push (subseq text start) out))
    (nreverse out)))

(defparameter +summary-argument-keys+
  '((("read" "write" "edit" "multi_edit") . "file_path")
    (("glob" "grep") . "pattern")
    (("ls") . "path")
    (("bash") . "command")
    (("job_output" "job_input" "job_kill") . "job_id"))
  "The argument a tool call's summary shows, per tool name.")

(defun tool-call-summary (name input)
  "→ one line saying what the tool call NAME with INPUT does."
  (let ((object (%decode-object input))
        (key (cdr (find-if (lambda (entry) (member name (car entry) :test #'string=))
                           +summary-argument-keys+))))
    (cond ((null object)
           (let ((text (cond ((null input) "")
                             ((stringp input) input)
                             (t (princ-to-string input)))))
             (if (zerop (length text)) name (format nil "~a ~a" name text))))
          ((null key)
           (format nil "~a ~a" name (json:encode object)))
          (t
           (let ((value (%arg-string object key)))
             (cond ((and (null value) (string= name "ls")) "ls .")
                   ((null value) name)
                   ((string= name "bash")
                    (let ((nl (position #\Newline value)))
                      (if nl
                          (format nil "bash ~a …" (subseq value 0 nl))
                          (format nil "bash ~a" value))))
                   (t (format nil "~a ~a" name value))))))))

(defun tool-result-diff (result)
  "→ the unified diff text inside an edit / multi_edit RESULT, or NIL."
  (when (stringp result)
    (let* ((lines (%text-lines result))
           (start (position-if (lambda (l) (uiop:string-prefix-p "--- a/" l)) lines))
           (end (and start
                     (position-if (lambda (l) (uiop:string-prefix-p "hash: " l)) lines
                                  :start (1+ start) :from-end t))))
      (when end
        (format nil "~{~a~%~}" (subseq lines start end))))))

;;; Previews: the edit the call would make, computed as agent-tools does.

(defun %preview-rel (path)
  "PATH (file_path) as a root-relative string, or NIL when it is absolute or
climbs out with \"..\"."
  (let ((parts (remove "" (uiop:split-string path :separator "/\\") :test #'string=)))
    (unless (or (zerop (length path))
                (member (char path 0) '(#\/ #\\ #\~))
                (find #\: path)
                (member ".." parts :test #'string=)
                (null (remove "." parts :test #'string=)))
      (format nil "~{~a~^/~}" (remove "." parts :test #'string=)))))

(defun %preview-file (root rel)
  "→ (values truename exists-p) of REL under ROOT; truename NIL when it leaves
ROOT or is a directory."
  (let* ((root (uiop:ensure-directory-pathname (or (probe-file root) root)))
         (path (merge-pathnames (uiop:parse-unix-namestring rel) root))
         (true (probe-file path)))
    (cond ((null true) (values path nil))
          ((and (pathname-name true) (uiop:subpathp true root)) (values true t))
          (t (values nil t)))))

(defun %count-occurrences (needle text)
  (loop with k = (length needle)
        for at = (search needle text) then (search needle text :start2 (+ at k))
        while at
        count t))

(defun %replace-occurrences (needle new text all)
  (with-output-to-string (s)
    (let ((k (length needle)) (start 0))
      (loop for at = (search needle text :start2 start)
            while at
            do (write-string text s :start start :end at)
               (write-string new s)
               (setf start (+ at k))
            while all)
      (write-string text s :start start))))

(defun %apply-preview-edit (text edit)
  "TEXT after EDIT (a JSON object with old_string, new_string, replace_all), or
NIL when the edit tool would refuse it."
  (let ((old (gethash "old_string" edit))
        (new (gethash "new_string" edit))
        (all (eq t (gethash "replace_all" edit))))
    (when (and (stringp old) (stringp new) (plusp (length old)) (string/= old new))
      (let ((n (%count-occurrences old text)))
        (when (or (= n 1) (and all (plusp n)))
          (%replace-occurrences old new text all))))))

(defun %preview-disk-text (root rel)
  "→ (values text exists-p) of REL under ROOT on the disk; TEXT NIL when it is
not UTF-8 text, a directory, or leaves ROOT."
  (multiple-value-bind (file exists) (%preview-file root rel)
    (values (and file exists (%file-text file)) exists)))

(defun %preview-texts (root name args &key read-file)
  "→ (values rel old new new-file-p) for the call, or NIL. READ-FILE (rel) →
(values text exists-p) reads the file (default: the disk under ROOT)."
  (let* ((path (gethash "file_path" args))
         (rel (and (stringp path) (%preview-rel path))))
    (when rel
      (multiple-value-bind (old exists)
          (if read-file (funcall read-file rel) (%preview-disk-text root rel))
        (progn
          (cond ((string= name "write")
                 (let ((content (gethash "content" args)))
                   (cond ((not (stringp content)) nil)
                         ((not exists) (values rel "" content t))
                         (old (values rel old content nil)))))
                ((null old) nil)
                ((string= name "edit")
                 (let ((new (%apply-preview-edit old args)))
                   (and new (values rel old new nil))))
                ((string= name "multi_edit")
                 (let ((edits (gethash "edits" args)) (text old))
                   (when (and (vectorp edits) (not (stringp edits)) (plusp (length edits)))
                     (loop for edit across edits
                           do (setf text (and (hash-table-p edit)
                                              (%apply-preview-edit text edit)))
                           unless text do (return-from %preview-texts nil))
                     (values rel old text nil))))))))))

(defun tool-call-texts (root name input &key read-file)
  "ACP-2: → (values rel old new new-file-p) of a write / edit / multi_edit call
NAME with INPUT under ROOT: REL the root-relative path, OLD the file's whole
text before the call (\"\" for a new file, NEW-FILE-P true), NEW the whole
text the call would leave, with the edit tool's matching rules (TOOL-CALL-
PREVIEW's); NIL for another tool, bad arguments, a path outside ROOT, a file
that is not text, or an edit that would not apply. READ-FILE (lambda (rel)) →
(values text exists-p) reads the file instead of the disk (e.g. an editor's
buffer). Never signals."
  (handler-case
      (let ((args (%decode-object input)))
        (when (and args (member name '("edit" "multi_edit" "write") :test #'string=))
          (%preview-texts root name args :read-file read-file)))
    (error () nil)))

(defun tool-call-preview (root name input)
  "→ the unified diff the call would make under ROOT, or NIL."
  ;; The header's "never signals": a preview is a nicety, so any failure
  ;; (bad arguments, an unreadable file) means no preview.
  (handler-case
      (let ((args (%decode-object input)))
        (when (and args (member name '("edit" "multi_edit" "write") :test #'string=))
          (multiple-value-bind (rel old new new-file-p) (%preview-texts root name args)
            (when rel
              (format nil "~:[--- a/~a~;--- /dev/null~*~]~%+++ b/~a~%~a"
                      new-file-p rel rel
                      (diff:render-diff (diff:compute-diff (diff:find-diff-engine :text)
                                                           old new :context 3)
                                        :unified nil))))))
    (error () nil)))

(defparameter +approval-diff-lines+ 12
  "Diff lines the approval dialog shows.")

(defun approval-message (root invocation)
  "→ the approval dialog message for INVOCATION (an AGENT-INVOCATION)."
  (let* ((name (agent:agent-invocation-name invocation))
         (args (agent:agent-invocation-arguments invocation))
         (summary (tool-call-summary name args))
         (diff (tool-call-preview root name args)))
    (if (null diff)
        summary
        (let* ((lines (%text-lines diff))
               (shown (subseq lines 0 (min +approval-diff-lines+ (length lines))))
               (more (- (length lines) (length shown))))
          (format nil "~a~{~%~a~}~:[~;~%… +~d more lines~]"
                  summary shown (plusp more) more)))))

;;; Lines.

(defun %prefixed (prefix rows &optional (rest-prefix prefix))
  "ROWS (lines of runs) with PREFIX before the first and REST-PREFIX before
the others."
  (loop for row in rows
        for first = t then nil
        collect (cons (w:text-run (if first prefix rest-prefix)) row)))

(defun %result-lines (result)
  "RESULT's lines without final empty ones."
  (let ((lines (%text-lines (cond ((null result) "")
                                  ((stringp result) result)
                                  (t (princ-to-string result))))))
    (loop while (and lines (zerop (length (car (last lines)))))
          do (setf lines (butlast lines)))
    lines))

(defun %tool-entry-lines (entry width)
  (let* ((header (w:truncate-runs
                  (list (w:text-run (concatenate 'string "● "
                                                 (tool-call-summary (entry-name entry)
                                                                    (entry-input entry)))
                                    :bold t))
                  width))
         (status (entry-status entry))
         (diff (and (eq status :done) (tool-result-diff (entry-result entry)))))
    (cons header
          (cond (diff
                 (%prefixed "  " (md:render-diff-lines diff (max 1 (- width 2)))))
                ((member status '(:done :error :denied))
                 (let ((lines (%result-lines (entry-result entry))))
                   (if (null lines)
                       (list (w:truncate-runs (list (w:text-run "  ⎿ (no output)" :dim t))
                                              width))
                       (cons (w:truncate-runs
                              (list (w:text-run (concatenate 'string "  ⎿ " (first lines))
                                                :dim (not (entry-error-p entry))))
                              width)
                             (when (rest lines)
                               (list (list (w:text-run (format nil "    … +~d lines"
                                                               (length (rest lines)))
                                                       :dim t))))))))
                (t '())))))

(defun %entry-lines (entry width last-p streaming)
  (ecase (entry-kind entry)
    (:user (%prefixed "> " (w:wrap-runs (entry-text entry) (max 1 (- width 2))) "  "))
    (:assistant
     (if (and streaming last-p)
         (md:markdown-stream-lines
          (md:markdown-stream-append (md:make-markdown-stream :width width)
                                     (entry-text entry)))
         (md:render-markdown (entry-text entry) width)))
    (:tool (%tool-entry-lines entry width))
    (:notice (w:wrap-runs (entry-text entry) width))
    (:error (w:wrap-runs (list (w:text-run (concatenate 'string "error: " (entry-text entry))))
                         width))
    (:plan (%plan-entry-lines entry width))))

(defun %plan-entry-lines (entry width)
  "H5a: the lines of a :plan ENTRY (see the file header)."
  (let* ((id (or (entry-id entry) ""))
         (n (length (entry-input entry)))
         (header (w:truncate-runs
                  (list (w:text-run (format nil "● plan ~a: ~d file~:p changed"
                                            (subseq id 0 (min 8 (length id))) n)
                                    :bold t))
                  width))
         (text (or (entry-text entry) "")))
    (cons header
          (and (plusp (length text))
               (%prefixed "  " (md:render-diff-lines text (max 1 (- width 2))))))))

(defun transcript-lines (entries width &key streaming)
  "→ lines of runs showing ENTRIES at WIDTH (see the file header)."
  (let ((width (max 1 width)))
    (loop for (entry . more) on entries
          append (%entry-lines entry width (null more) streaming)
          when more collect '())))
