(in-package #:cl-stack-code/acp)

;;; ACP-2: the mapping tables between the SDK (src/client.lisp) and ACP
;;; (acp-protocol 0.1.0). GIVEN: the constants. STUBBED: the functions.
;;;
;;; Session modes (session/new's and session/load's "modes", session/set_mode)
;;;   +ACP-MODE-IDS+ = CL-STACK-CODE:+PERMISSION-MODE-NAMES+: the ACP mode
;;;   ids ARE the permission mode names ("default" "acceptEdits"
;;;   "bypassPermissions" "plan" "preview"), in that order; a SESSION-MODE's
;;;   name is a human title, its id the mode name.
;;;   MODE-ID-PERMISSION-MODE id → :DEFAULT :ACCEPT-EDITS :BYPASS-PERMISSIONS
;;;     :PLAN :PREVIEW, or NIL for any other string (exact case).
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
;;;     plan (H5c-0 plan documents)
;;;                             → UPDATE-PLAN: subtype "proposed": one
;;;                               PLAN-ENTRY per element of "steps", content
;;;                               its text, priority "medium", status
;;;                               "pending"; "step": the whole "steps" list
;;;                               again (ACP replaces it), status "pending" /
;;;                               "in_progress" / "completed" (a step's
;;;                               "done"); "rejected": no entries. Other
;;;                               subtypes ("opened", "approved", "executed",
;;;                               and H5a's "projected" / "applied" /
;;;                               "discarded", which no producer sends since
;;;                               0.15.0, #64) → none
;;;     preview (H5a's events, renamed) → no update
;;;     instructions {files: [{path, kind}]} (#41)
;;;                             → per file an UPDATE-TOOL-CALL, id
;;;                               "instructions:<path>", kind "read", status
;;;                               "completed", title "Rule loaded: P" (kind
;;;                               "rule") or "Instructions loaded: P" (P
;;;                               relative to CWD when below it), the path
;;;                               as its location
;;;     image_event {text} (#41) → UPDATE-AGENT-MESSAGE-CHUNK with the
;;;                               notice between blank lines; no text → none
;;;     anything else (system, assistant, approval_request,
;;;     approval_resolved, steering, rewind, session, result,
;;;     unit)                   → no update
;;;   SESSION-INIT-UPDATES init &key CWD (#41) → for the session's init
;;;   object (CODE-SESSION-INIT): one finished "read" UPDATE-TOOL-CALL, id
;;;   "session-context", title "Context: FILES · skills: NAMES · rules: N",
;;;   its text content the full lists (path-scoped rules not loaded yet
;;;   marked "(GLOBS, on demand)"), locations the instruction files; NIL
;;;   when nothing was found. The agent sends it before the session's first
;;;   turn.

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
        ;; H3e-2b: tool_search (src/mcp-context.lisp)
        ((member name '("grep" "glob" "tool_search") :test #'equal) "search")
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

(defun %plan-entry-status (status)
  "A plan step status (\"pending\" \"in_progress\" \"done\") → the ACP one."
  (cond ((equal status "done") "completed")
        ((equal status "in_progress") "in_progress")
        (t "pending")))

(defun %plan-entries (event &optional status)
  "H5c-0: one PLAN-ENTRY per step of a plan document event's \"steps\", with
STATUS, else the step's own status mapped to ACP's."
  (map 'vector (lambda (step)
                 (acp:make-acp 'acp:plan-entry
                               :content (or (code:event-value step "text") "")
                               :priority "medium"
                               :status (or status
                                           (%plan-entry-status (code:event-value step "status")))))
       (let ((steps (code:event-value event "steps")))
         (if (typep steps 'sequence) steps #()))))

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
       ;; H5c-0: plan document events. The core sends H5a's preview events as
       ;; "preview" (no update).
       (let ((subtype (code:event-value event "subtype")))
         (cond ((equal subtype "proposed")
                (list (acp:make-acp 'acp:update-plan :entries (%plan-entries event "pending"))))
               ((equal subtype "step")
                (list (acp:make-acp 'acp:update-plan :entries (%plan-entries event))))
               ((equal subtype "rejected")
                (list (acp:make-acp 'acp:update-plan :entries (vector))))
               ;; #64 (0.17.0): H5a's subtypes (projected / applied / discarded) are
               ;; "preview" events since 0.15.0 and map to none, like any other.
               (t '()))))
      ((equal type "instructions")
       ;; #41: a lazily loaded AGENTS.md or path-scoped rule, as a finished
       ;; read tool call the editor shows.
       (map 'list (lambda (file)
                    (let ((path (code:event-value file "path")))
                      (acp:make-acp 'acp:update-tool-call
                                    :tool-call-id (format nil "instructions:~a" path)
                                    :title (format nil "~:[Instructions~;Rule~] loaded: ~a"
                                                   (equal "rule" (code:event-value file "kind"))
                                                   (%display-path path cwd))
                                    :kind "read"
                                    :status "completed"
                                    :locations (vector (acp:make-acp 'acp:tool-call-location
                                                                     :path path)))))
            (or (code:event-value event "files") #())))
      ((equal type "image_event")
       ;; #41: the Lisp image entered the debugger or finished a job.
       (let ((text (code:event-value event "text")))
         (and (stringp text) (plusp (length text))
              (list (acp:make-acp 'acp:update-agent-message-chunk
                                  :content (%text-content
                                            (format nil "~%~%~a~%~%" text)))))))
      (t '()))))

(defun %display-path (path cwd)
  "PATH relative to CWD when it is below it, else PATH."
  (let ((p (uiop:parse-native-namestring path)))
    (if (and cwd (uiop:subpathp p (uiop:ensure-directory-pathname cwd)))
        (uiop:native-namestring (uiop:enough-pathname p (uiop:ensure-directory-pathname cwd)))
        path)))

(defun %names (seq key)
  (remove nil (map 'list (lambda (x) (if key (code:event-value x key) x)) (or seq #()))))

(defun session-init-updates (init &key cwd)
  "#41: the session's init object (CODE:CODE-SESSION-INIT) as one finished
read tool call, id \"session-context\", so the editor shows what the session
found: its instruction files, skills and rules (path-scoped ones load on
demand). NIL when there is nothing to show."
  (when init
    (let* ((files (map 'list (lambda (p) (%display-path p cwd))
                       (%names (code:event-value init "instructions") nil)))
           (skills (%names (code:event-value init "skills") "name"))
           (rules (map 'list (lambda (r)
                               (let ((paths (code:event-value r "paths")))
                                 (format nil "~a~@[ (~{~a~^, ~}, on demand)~]"
                                         (%display-path (code:event-value r "path") cwd)
                                         (and (typep paths 'sequence) (not (stringp paths))
                                              (plusp (length paths))
                                              (not (code:event-value r "loaded"))
                                              (coerce paths 'list)))))
                       (or (code:event-value init "rules") #()))))
      (when (or files skills rules)
        (let ((text (format nil "~@[Instructions: ~{~a~^, ~}~]~@[~%Skills: ~{~a~^, ~}~]~@[~%Rules: ~{~a~^; ~}~]"
                            files skills rules)))
          (list (acp:make-acp 'acp:update-tool-call
                              :tool-call-id "session-context"
                              :title (format nil "Context: ~{~a~^ · ~}"
                                             (remove nil
                                                     (list (and files (format nil "~{~a~^, ~}" files))
                                                           (and skills (format nil "skills: ~{~a~^, ~}" skills))
                                                           (and rules (format nil "rules: ~d" (length rules))))))
                              :kind "read"
                              :status "completed"
                              :content (%result-text-content text)
                              :locations (map 'vector (lambda (p)
                                                        (acp:make-acp 'acp:tool-call-location :path p))
                                              (%names (code:event-value init "instructions") nil)))))))))
