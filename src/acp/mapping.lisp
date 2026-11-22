(in-package #:cl-stack-code/acp)

;;; ACP-2: the mapping tables between the SDK (src/client.lisp) and ACP
;;; (acp-protocol 0.1.0). GIVEN: the constants. STUBBED: the functions.
;;;
;;; Session modes (session/new's and session/load's "modes", session/set_mode)
;;;   +ACP-MODE-IDS+ = CL-STACK-CODE:+PERMISSION-MODE-NAMES+: the ACP mode
;;;   ids ARE the permission mode names ("default" "acceptEdits"
;;;   "bypassPermissions" "plan"), in that order; a SESSION-MODE's name is a
;;;   human title, its id the mode name.
;;;   MODE-ID-PERMISSION-MODE id → :DEFAULT :ACCEPT-EDITS :BYPASS-PERMISSIONS
;;;     :PLAN, or NIL for any other string (exact case).
;;;   PERMISSION-MODE-MODE-ID mode → the id; NIL means :DEFAULT. Another
;;;     keyword → CODE-USAGE-ERROR (as PERMISSION-MODE-NAME).
;;;
;;; Permission (session/request_permission ↔ the SDK's approvals)
;;;   +ACP-PERMISSION-OPTIONS+: the options every request offers, in this
;;;   order, as (option-id name kind) lists (ACP-ASK-PERMISSION's form).
;;;   PERMISSION-KIND-DECISION kind → the CLIENT-RESPOND-APPROVAL decision:
;;;     :allow-once → :once, :allow-always → :always, :reject-once →
;;;     :reject, :reject-always → :reject-all; also the kind strings
;;;     ("allow_once" …); :cancelled or anything else → NIL (the call is
;;;     not answered: the turn is being cancelled).
;;;   DECISION-PERMISSION-KIND decision → the kind keyword, the inverse
;;;     (:once → :allow-once …); another value → NIL.
;;;
;;; Stop reasons
;;;   RESULT-STOP-REASON result → the session/prompt stopReason for the
;;;   turn's "result" event: "success" → "end_turn"; "error_max_turns" →
;;;   "max_turn_requests"; "error_during_execution" with error
;;;   "interrupted" → "cancelled"; any other "error_during_execution" → NIL
;;;   (the prompt request answers an ACP-INTERNAL-ERROR whose message is
;;;   the result's "error").
;;;
;;; Tool kinds
;;;   TOOL-KIND name → an ACP ToolKind string: "read" for read and ls;
;;;   "edit" for write, edit and multi_edit; "search" for grep and glob;
;;;   "execute" for bash and the job_* tools; "other" for anything else.
;;;
;;; Events → session/update
;;;   EVENT-UPDATES event &key CWD → a list (maybe empty) of acp-protocol
;;;   SESSION-UPDATE objects for one SDK event object. CWD (a directory
;;;   pathname) makes tool paths absolute. Pure: no I/O. The table:
;;;     text_delta {text}       → UPDATE-AGENT-MESSAGE-CHUNK, content a
;;;                               TEXT-CONTENT with the text
;;;     thinking_delta {text}   → UPDATE-AGENT-THOUGHT-CHUNK, likewise
;;;                               (thinking_delta is the SDK event the core
;;;                               gains in ACP-2, see .team-solve/task.md)
;;;     tool_use {id,name,input}
;;;                             → UPDATE-TOOL-CALL: toolCallId the id, title
;;;                               CL-STACK-CODE:TOOL-CALL-SUMMARY of name and
;;;                               input, kind TOOL-KIND, status "pending",
;;;                               rawInput the input; locations: one
;;;                               TOOL-CALL-LOCATION (the absolute native
;;;                               path under CWD) when the input has
;;;                               "file_path" or "path", else none. No diff
;;;                               here: the agent adds the diff content of
;;;                               write / edit / multi_edit calls (it needs
;;;                               the file's text, see agent.lisp)
;;;     tool_result {id,status,is_error,content}
;;;                             → UPDATE-TOOL-CALL-UPDATE: the id; status
;;;                               "completed" when status is "done" and not
;;;                               is_error, else "failed"; content one CONTENT
;;;                               whose TEXT-CONTENT is the result text
;;;     plan (H5a plan objects) → UPDATE-PLAN: subtype "projected": one
;;;                               PLAN-ENTRY per change, content "<kind>
;;;                               <path>" (e.g. "modified a.txt"), priority
;;;                               "medium", status "pending"; "applied": the
;;;                               same entries with status "completed";
;;;                               "discarded": no entries. Other subtypes
;;;                               ("opened", "reopened", "drift", "rebased")
;;;                               → no update
;;;     anything else (system, assistant, approval_request,
;;;     approval_resolved, steering, image_event, rewind, session, result,
;;;     unit)                   → no update

(defparameter +acp-mode-ids+ code:+permission-mode-names+
  "The ACP session mode ids: the permission mode names, in their order.")

(defparameter +acp-permission-options+
  '(("allow_once" "Allow once" "allow_once")
    ("allow_always" "Always allow" "allow_always")
    ("reject_once" "Reject" "reject_once")
    ("reject_always" "Reject all" "reject_always"))
  "The options of every permission request: (option-id name kind).")

(defun mode-id-permission-mode (id)
  (and (stringp id) (code:parse-permission-mode id)))

(defun permission-mode-mode-id (mode)
  (code:permission-mode-name mode))

(defparameter +%kind-decisions+
  '((:allow-once . :once) (:allow-always . :always)
    (:reject-once . :reject) (:reject-always . :reject-all))
  "Permission option kind ↔ CLIENT-RESPOND-APPROVAL decision.")

(defun %kind-keyword (kind)
  "KIND as a keyword: itself, or a kind string (\"allow_once\" → :ALLOW-ONCE)."
  (cond ((keywordp kind) kind)
        ((stringp kind)
         (find-symbol (string-upcase (substitute #\- #\_ kind)) :keyword))
        (t nil)))

(defun permission-kind-decision (kind)
  (cdr (assoc (%kind-keyword kind) +%kind-decisions+)))

(defun decision-permission-kind (decision)
  (car (rassoc decision +%kind-decisions+)))

(defun result-stop-reason (result)
  (let ((subtype (code:event-value result "subtype")))
    (cond ((equal subtype "success") "end_turn")
          ((equal subtype "error_max_turns") "max_turn_requests")
          ((and (equal subtype "error_during_execution")
                (equal "interrupted" (code:event-value result "error")))
           "cancelled")
          (t nil))))

(defun tool-kind (name)
  (cond ((member name '("read" "ls") :test #'equal) "read")
        ((member name '("write" "edit" "multi_edit") :test #'equal) "edit")
        ((member name '("grep" "glob") :test #'equal) "search")
        ((and (stringp name)
              (or (string= name "bash") (uiop:string-prefix-p "job_" name)))
         "execute")
        (t "other")))

;;; Events → updates.

(defun %text-content (text)
  (acp:make-acp 'acp:text-content :text (or text "")))

(defun %tool-path (input cwd)
  "The absolute native path of INPUT's \"file_path\" or \"path\" under CWD, or NIL."
  (let ((rel (and (hash-table-p input)
                  (let ((v (or (gethash "file_path" input) (gethash "path" input))))
                    (and (stringp v) (plusp (length v)) v)))))
    (when rel
      (let ((path (uiop:parse-native-namestring rel)))
        (uiop:native-namestring
         (if (or (uiop:absolute-pathname-p path) (null cwd))
             path
             (merge-pathnames path (uiop:ensure-directory-pathname cwd))))))))

(defun tool-call-locations (input cwd)
  "→ a vector of one TOOL-CALL-LOCATION for INPUT's path under CWD, or #()."
  (let ((path (%tool-path input cwd)))
    (if path
        (vector (acp:make-acp 'acp:tool-call-location :path path))
        (vector))))

(defun %result-text-content (text)
  (vector (acp:make-acp 'acp:content :content (%text-content text))))

(defun %plan-entries (event status)
  (map 'vector (lambda (change)
                 (acp:make-acp 'acp:plan-entry
                               :content (format nil "~a ~a"
                                                (code:event-value change "kind")
                                                (code:event-value change "path"))
                               :priority "medium"
                               :status status))
       (or (code:event-value event "changes") #())))

(defun event-updates (event &key cwd)
  (let ((type (code:event-type event)))
    (cond
      ((equal type "text_delta")
       (list (acp:make-acp 'acp:update-agent-message-chunk
                           :content (%text-content (code:event-value event "text")))))
      ((equal type "thinking_delta")
       (list (acp:make-acp 'acp:update-agent-thought-chunk
                           :content (%text-content (code:event-value event "text")))))
      ((equal type "tool_use")
       (let ((name (code:event-value event "name"))
             (input (code:event-value event "input")))
         (list (acp:make-acp 'acp:update-tool-call
                             :tool-call-id (code:event-value event "id")
                             :title (code:tool-call-summary name input)
                             :kind (tool-kind name)
                             :status "pending"
                             :raw-input input
                             :locations (tool-call-locations input cwd)))))
      ((equal type "tool_result")
       (list (acp:make-acp 'acp:update-tool-call-update
                           :tool-call-id (code:event-value event "id")
                           :status (if (and (equal "done" (code:event-value event "status"))
                                            (not (code:event-value event "is_error")))
                                       "completed"
                                       "failed")
                           :content (%result-text-content
                                     (let ((c (code:event-value event "content")))
                                       (if (stringp c) c (princ-to-string (or c ""))))))))
      ((equal type "plan")
       (let ((subtype (code:event-value event "subtype")))
         (cond ((equal subtype "projected")
                (list (acp:make-acp 'acp:update-plan :entries (%plan-entries event "pending"))))
               ((equal subtype "applied")
                (list (acp:make-acp 'acp:update-plan :entries (%plan-entries event "completed"))))
               ((equal subtype "discarded")
                (list (acp:make-acp 'acp:update-plan :entries (vector))))
               (t '()))))
      (t '()))))
