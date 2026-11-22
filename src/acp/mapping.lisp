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
  (declare (ignore id))
  (%acp2-pending 'mode-id-permission-mode))

(defun permission-mode-mode-id (mode)
  (declare (ignore mode))
  (%acp2-pending 'permission-mode-mode-id))

(defun permission-kind-decision (kind)
  (declare (ignore kind))
  (%acp2-pending 'permission-kind-decision))

(defun decision-permission-kind (decision)
  (declare (ignore decision))
  (%acp2-pending 'decision-permission-kind))

(defun result-stop-reason (result)
  (declare (ignore result))
  (%acp2-pending 'result-stop-reason))

(defun tool-kind (name)
  (declare (ignore name))
  (%acp2-pending 'tool-kind))

(defun event-updates (event &key cwd)
  (declare (ignore event cwd))
  (%acp2-pending 'event-updates))
