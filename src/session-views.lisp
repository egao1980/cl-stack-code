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
;;; H5b: SESSION-TREE-LINES :MARKED IDS (revision ids): a marked revision's
;;; label gets " ◆" right after its message (before "  (head)"), and the
;;; marker is never cut either: "● bbbbbbbb second question ◆  (head)"; a cut
;;; message ends in "…" before it ("● bbbbbbbb sec… ◆  (head)", WIDTH long).
;;; The interactive /tree marks the turns that have a retained checkpoint (the
;;; conversation revisions of SESSION-CHECKPOINTS).
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

(defun %parts-text (parts)
  "The text parts of PARTS concatenated."
  (with-output-to-string (s)
    (dolist (part parts)
      (when (llm:llm-text-part-p part)
        (write-string (or (llm:llm-text-part-text part) "") s)))))

(defun %result-string (content)
  (cond ((null content) "")
        ((stringp content) content)
        (t (princ-to-string content))))

(defun %record-entries (record)
  "→ fresh ENTRY values for one turn RECORD (see the file header)."
  (let ((entries '())
        (steering (copy-list (record-steering record)))
        (tools (make-hash-table :test 'equal))
        (first-user t))
    ;; H3f: an idle /compact record has no user turn, only its marker.
    (unless (and (null (record-turns record)) (record-compactions record)
                 (string= "" (record-prompt record)))
      (push (make-entry :kind :user :text (record-prompt record)) entries))
    (dolist (turn (record-turns record))
      (let ((parts (llm:llm-turn-parts turn)))
        (case (llm:llm-turn-role turn)
          (:user
           (cond (first-user (setf first-user nil))
                 ;; H3f: continuation turns are hidden.
                 ((agent:continuation-turn-p turn))
                 ((and parts
                       (every #'llm:llm-text-part-p parts)
                       (not (uiop:string-prefix-p
                             "<instructions"
                             (string-left-trim '(#\Space #\Tab #\Newline #\Return)
                                               (%parts-text parts)))))
                  (let ((text (pop steering)))
                    (when text
                      (push (make-entry :kind :user :text text) entries))))))
          (:assistant
           (let ((text (%parts-text parts)))
             (when (plusp (length text))
               (push (make-entry :kind :assistant :text text) entries)))
           (dolist (part parts)
             (when (llm:llm-tool-call-part-p part)
               (let ((entry (make-entry :kind :tool
                                        :id (llm:llm-tool-call-part-id part)
                                        :name (llm:llm-tool-call-part-name part)
                                        :input (llm:llm-tool-call-part-arguments part)
                                        :status :done)))
                 (setf (gethash (entry-id entry) tools) entry)
                 (push entry entries))))))
        (dolist (part parts)
          (when (llm:llm-tool-result-part-p part)
            (let ((entry (gethash (llm:llm-tool-result-part-id part) tools)))
              (when entry
                (let ((error-p (and (llm:llm-tool-result-part-error-p part) t)))
                  (setf (entry-result entry) (%result-string (llm:llm-tool-result-part-content part))
                        (entry-error-p entry) error-p)
                  (when error-p
                    (setf (entry-status entry) :error)))))))))
    (when (eq :canceled (record-finish record))
      (push (make-entry :kind :notice :text "interrupted") entries))
    ;; H3f: one notice per compaction marker.
    (dolist (marker (record-compactions record))
      (push (make-entry :kind :notice :text (compaction-notice-text marker)) entries))
    (nreverse entries)))

(defun session-entries (store &optional (designator +head-ref+))
  "→ fresh ENTRY values for the transcript of DESIGNATOR's line (see the file
header)."
  (loop for record in (session-records store designator)
        append (%record-entries record)))

;;; The tree.

(defun session-tree-lines (store &key (width 80) marked)
  "→ the /tree lines of STORE (strings; see the file header). MARKED (H5b):
revision ids whose rows end their message with \" ◆\"."
  (let* ((all (%all-revisions store))
         (positions (make-hash-table :test 'equal))
         (on-line (make-hash-table :test 'equal))
         (head (session-head store))
         (head-id (and head (rev:revision-id head)))
         (visited (make-hash-table :test 'equal))
         (lines '()))
    (when (null all)
      (return-from session-tree-lines (list "no turns yet")))
    (loop for r in all for i from 0 do (setf (gethash (rev:revision-id r) positions) i))
    (dolist (r (session-line store)) (setf (gethash (rev:revision-id r) on-line) t))
    (labels ((children (r)
               (sort (copy-list (rev:revision-children store (rev:revision-id r)))
                     #'< :key (lambda (c) (gethash (rev:revision-id c) positions))))
             (label (r prefix)
               (let* ((id (rev:revision-id r))
                      (fixed (format nil "~a~a ~a " prefix
                                     (if (gethash id on-line) "●" "○")
                                     (subseq id 0 (min 8 (length id)))))
                      (suffix (concatenate 'string
                                      (if (member id marked :test #'equal) " ◆" "")
                                      (if (equal id head-id) "  (head)" "")))
                      (message (or (rev:revision-message r) ""))
                      (line (concatenate 'string fixed message suffix)))
                 (if (> (length line) width)
                     (let ((room (max 0 (- width (length fixed) (length suffix) 1))))
                       (concatenate 'string fixed (subseq message 0 (min room (length message)))
                                    "…" suffix))
                     line)))
             (walk (r first continuation)
               (unless (gethash (rev:revision-id r) visited)
                 (setf (gethash (rev:revision-id r) visited) t)
                 (push (label r first) lines)
                 (let ((kids (remove-if (lambda (k) (gethash (rev:revision-id k) visited))
                                        (children r))))
                   (if (rest kids)
                       (loop for (kid . more) on kids
                             do (walk kid
                                      (concatenate 'string continuation (if more "├─ " "└─ "))
                                      (concatenate 'string continuation (if more "│  " "   "))))
                       (when kids
                         (walk (first kids) continuation continuation)))))))
      (dolist (r all)
        (when (null (rev:revision-parent-ids r))
          (walk r "" ""))))
    (nreverse lines)))

;;; --list-sessions.

(defun %cut (text n)
  (if (> (length text) n)
      (concatenate 'string (subseq text 0 (1- n)) "…")
      text))

(defun session-summary-lines (sessions-dir)
  "→ one --list-sessions line per session of LIST-SESSIONS, in its order:
\"<id>  <N> turn[s]  <prompt>\", N = the length of the head's line (\"1
turn\", \"2 turns\", \"0 turns\"), PROMPT the first line of the line's root
prompt cut to 60 characters (59 and \"…\"); with 0 turns the line ends after
\"0 turns\"."
  (loop for store in (list-sessions sessions-dir)
        collect (let* ((line (session-line store))
                       (prompt (and line (record-prompt (revision-record (first line))))))
                  (format nil "~a  ~d turn~:p~@[  ~a~]"
                          (session-id store) (length line)
                          (and prompt (%cut (subseq prompt 0 (or (position #\Newline prompt) (length prompt))) 60))))))

;;; Export.

(defun %fence (text)
  "Backticks one longer than the longest run in TEXT, at least 3."
  (let ((longest 0) (run 0))
    (loop for c across text
          do (if (char= c #\`)
                 (setf longest (max longest (incf run)))
                 (setf run 0)))
    (make-string (max 3 (1+ longest)) :initial-element #\`)))

(defun %markdown-blocks (entry)
  (ecase (entry-kind entry)
    (:user (list "**User**" (entry-text entry)))
    (:assistant (list "**Assistant**" (entry-text entry)))
    (:tool (let ((head (format nil "**Tool** `~a` ~a~:[~; (error)~]"
                               (entry-name entry) (or (entry-input entry) "")
                               (entry-error-p entry)))
                 (result (entry-result entry)))
             (if result
                 (let ((fence (%fence result)))
                   (list head (format nil "~a~%~a~%~a" fence result fence)))
                 (list head))))
    (:notice (list (format nil "_~a_" (entry-text entry))))
    (:error (list (format nil "_~a_" (entry-text entry))))))

(defun %part-object (state)
  (let ((type (getf state :type)))
    (case type
      (:text (%json-object "type" "text" "text" (or (getf state :text) "")))
      (:tool-call (%json-object "type" "tool_call" "id" (getf state :id) "name" (getf state :name)
                                "arguments" (or (getf state :arguments) "{}")))
      (:tool-result (%json-object "type" "tool_result" "id" (getf state :id)
                                  "name" (or (getf state :name) :null)
                                  "content" (%result-string (getf state :content))
                                  "is_error" (and (getf state :error-p) t)))
      (:thinking (%json-object "type" "thinking" "text" (or (getf state :text) "")))
      (t (%json-object "type" (substitute #\_ #\- (string-downcase (string type))))))))

(defun %turn-object (revision)
  (let ((record (revision-record revision)))
    (%json-object
     "revision" (rev:revision-id revision)
     "parent" (or (first (rev:revision-parent-ids revision)) :null)
     "prompt" (record-prompt record)
     "model" (or (record-model record) :null)
     "permission_mode" (permission-mode-name (record-permission-mode record))
     "finish" (substitute #\_ #\- (string-downcase (string (record-finish record))))
     "usage" (%usage-object (record-usage record))
     "steering" (coerce (record-steering record) 'vector)
     "messages" (map 'vector
                     (lambda (turn)
                       (let ((state (llm:turn-state turn)))
                         (%json-object "role" (string-downcase (string (getf state :role)))
                                       "parts" (map 'vector #'%part-object (getf state :parts)))))
                     (record-turns record)))))

(defun export-session (store stream &key (format :markdown) (designator +head-ref+))
  "Write DESIGNATOR's line of STORE to STREAM as FORMAT (:MARKDOWN or :JSON;
see the file header). → the number of turns written."
  (let ((line (session-line store designator)))
    (ecase format
      (:markdown
       (let ((blocks (list (format nil "# Session ~a" (session-id store)))))
         (loop for revision in line
               for n from 1
               do (setf blocks (append blocks (list (format nil "## Turn ~d" n))))
                  (dolist (entry (%record-entries (revision-record revision)))
                    (setf blocks (append blocks (%markdown-blocks entry)))))
         (format stream "~{~a~^~%~%~}~%" blocks)))
      (:json
       (let ((head (session-head store))
             (project (session-project-dir store)))
         (json:encode (%json-object "session_id" (session-id store)
                                    "project" (if project (uiop:native-namestring project) :null)
                                    "head" (if head (rev:revision-id head) :null)
                                    "turns" (map 'vector #'%turn-object line))
                      :stream stream)
         (terpri stream))))
    (length line)))
