(in-package #:cl-stack-code)

;;; H5a: plans — plan → project → approve.
;;;
;;; A PLAN is a writable copy of the project (its AREA) bound to a BASE: the
;;; project as it was when the plan opened. In plan mode the agent's file and
;;; shell tools are rooted in the area, so its edits, and anything its shell
;;; commands write (tests, builds), land there. The projected change is the
;;; difference between the base and the area. APPROVE-PLAN applies it to the
;;; real working copy; REJECT-PLAN discards the area; keeping the plan open
;;; and sending more messages continues it. A plan outlives the process: its
;;; directory holds everything needed to reopen it (sessions, H3c, record its
;;; id in the turn record).
;;;
;;; Kinds
;;;   :copy  cl-stack-pathlib R4a. The area is FS-OPEN-AREA :COPY of the
;;;          project directory with :IGNORE :AUTO (.gitignore / .ignore, .git/
;;;          pruned) into <plan dir>/tree/; the pathlib AREA object is closed
;;;          with :KEEP at once (the copy stays). The base is FS-SNAPSHOT of
;;;          the fresh copy (:IGNORE :AUTO) into the project's directory
;;;          snapshot store <plans dir>/store/, so the base content (blobs)
;;;          survives the process and serves three-way merges.
;;;   :git   revision-backend-git. The base is a commit of the working copy's
;;;          state: PROJECT-STATE of the store's GIT-WORKING-COPY (uncommitted
;;;          and untracked files included, ignored ones not), committed with
;;;          COMMIT-PROJECTION (parents = TARGET-REVISIONS, i.e. HEAD, or none
;;;          on an unborn branch), message "cl-stack-code plan <id> base", ref
;;;          <+PLAN-REF-PREFIX+><id> (created with CAS, expected NIL). The area
;;;          is ADD-WORKTREE of that commit at <plan dir>/tree/ (detached), so
;;;          git works inside it: `git status` / `git diff` there show the
;;;          projected change. The main worktree's HEAD, branch and index are
;;;          never touched.
;;;   :auto  :git when the project directory is the top level of a git
;;;          worktree that MAKE-GIT-STORE opens (any GIT-COMMAND-ERROR,
;;;          VC-TOOL-VERSION-ERROR or REVISION-ERROR there → :copy); :copy
;;;          otherwise. An explicit :git that cannot open → PLAN-ERROR whose
;;;          message names the directory and says it is not a git worktree.
;;;
;;; Where
;;;   PLANS-DIRECTORY cwd &key data-dir = <data-dir>/plans/<project-key>/
;;;   (the project key of SESSIONS-DIRECTORY: project root, else cwd). Each
;;;   plan has <plans dir>/<id>/ with plan.sexp and tree/ (the area). Ids are
;;;   32 lowercase hex characters (the session id format), random unless
;;;   OPEN-PLAN :ID is given (an existing id → PLAN-ERROR).
;;;   plan.sexp, written to a temporary name and renamed, read with
;;;   *READ-EVAL* NIL (an unreadable one → PLAN-ERROR naming it):
;;;     (:format 1 :id S :kind K :project-dir S :root S :base S :status K
;;;      :session S-or-NIL :opened-at UNIVERSAL-TIME :version S)
;;;   PROJECT-DIR and ROOT are native namestrings of directories. BASE is the
;;;   snapshot id ("sha256:…") for :copy, the 40-hex commit id for :git.
;;;   STATUS is :OPEN, :APPLIED or :DISCARDED.
;;;
;;; Reading
;;;   PLAN-TOOL-ROOT plan cwd: the directory in the area that corresponds to
;;;   CWD (CWD relative to PLAN-PROJECT-DIR, under PLAN-ROOT); CWD outside the
;;;   project → PLAN-ERROR. The agent's tools are rooted there.
;;;   PLAN-CHANGES plan: ((KIND PATH) …) from the base to the area now,
;;;   sorted by PATH (string<). KIND :ADDED :REMOVED :MODIFIED :MODE-CHANGED,
;;;   PATH a relative POSIX string. Ignored paths are left out (:copy:
;;;   :IGNORE :AUTO on the area; :git: git's rules in the linked worktree).
;;;   Edits from anything count (the tools, cl:open, a shell, another image).
;;;   An entry edited back to its base content is not a change. Renames are
;;;   not detected (a removal plus an addition).
;;;   PLAN-DIFF plan: a diff-protocol tree diff (engine :tree with
;;;   :DETECT-RENAMES NIL, level :CHANGES, :CONTEXT 3) from a tree of the
;;;   base's versions of the changed paths to a tree of the area's versions
;;;   of them. A file is :TEXT when its content is valid UTF-8 with no NUL in
;;;   its first 8000 octets, else :BINARY; a symlink is a :TEXT file holding
;;;   its target with mode #o120000; modes #o100644 / #o100755.
;;;   PLAN-DIFF-TEXT plan: (DIFF:RENDER-DIFF (PLAN-DIFF plan) :UNIFIED NIL);
;;;   "" when there are no changes. Both kinds give the same text for the
;;;   same edits.
;;;
;;; Approving (APPROVE-PLAN plan &key message → (values result status))
;;;   1. The working copy now is read (:copy: FS-SNAPSHOT of the project
;;;      directory, :IGNORE :AUTO; :git: PROJECT-STATE of the working copy).
;;;   2. Drift: a path P conflicts when the working copy's entry at P now
;;;      differs from the base's AND from the area's (absent counts as an
;;;      entry). Identical edits on both sides, and drift at paths the plan
;;;      did not change, are not conflicts.
;;;   3. Conflicts → PLAN-DRIFT (PATHS = every conflicting path), once,
;;;      before anything is written, with restarts:
;;;        REBASE-PLAN     the working copy becomes the new base: the area
;;;                        is updated to the three-way merge (old base, area,
;;;                        working copy). Paths changed on one side take that
;;;                        side. A conflicting path whose three versions are
;;;                        text (or absent in the base) gets DIFF:MERGE-TEXTS
;;;                        base area working-copy with :OURS-LABEL "plan" and
;;;                        :THEIRS-LABEL "working copy" (clean merges without
;;;                        markers, overlapping regions with markers); any
;;;                        other conflicting path (binary, symlink, mode,
;;;                        modify/delete, add/add) keeps the area's version.
;;;                        :copy: the new base is a snapshot of the working
;;;                        copy as read in step 1. :git: a commit of that
;;;                        state (parents = HEAD) and the plan ref moves to it
;;;                        by CAS; the area's HEAD moves to it too. Nothing is
;;;                        applied. → (values CONFLICTS :REBASED), CONFLICTS =
;;;                        the paths that got markers or kept the area's
;;;                        version (sorted). The plan stays open.
;;;        OVERWRITE-PLAN  apply as in step 4, the area's version winning at
;;;                        every conflicting path.
;;;        ABORT-APPROVAL  → (values NIL :ABORTED); nothing written, the plan
;;;                        stays open.
;;;   4. Apply: for every path the plan changed (and, under OVERWRITE-PLAN,
;;;      every conflicting one) the working copy gets the area's version;
;;;      every other path of the working copy is left alone (drift elsewhere
;;;      is kept; ignored files are never touched). Files are written with
;;;      FS-WRITE-ATOMIC and :EXPECTED-HASH = the hash read in step 1
;;;      (:ABSENT for an absent file), so a file changed after the check
;;;      signals pathlib's CONTENT-HASH-MISMATCH instead of being lost; the
;;;      execute bit follows the area's mode; removals delete the file and
;;;      then directories left empty (never the project directory).
;;;   5. :git only: the area's state is committed with COMMIT-PROJECTION
;;;      (parents = the base commit, MESSAGE or "cl-stack-code plan <id>")
;;;      and the plan ref moves from the base to that commit by CAS, so the
;;;      approved change stays in the repository as one commit. HEAD, the
;;;      branch and the index of the main worktree are not touched: the
;;;      change lands as uncommitted edits. (EXECUTE-PLAN is not used: the
;;;      base commit holds the user's uncommitted work, so moving HEAD to
;;;      the approved commit would commit that work too.)
;;;   6. The area is removed (:copy: the tree deleted; :git: REMOVE-WORKTREE
;;;      :FORCE T), the status becomes :APPLIED, plan.sexp is rewritten.
;;;      → (values CHANGES :APPLIED), CHANGES = PLAN-CHANGES as applied; NIL
;;;      changes → (values NIL :EMPTY) (the plan is closed all the same).
;;;   A plan that is not :OPEN → PLAN-ERROR.
;;;
;;; Rejecting (REJECT-PLAN plan → :DISCARDED)
;;;   The area is removed (:git: REMOVE-WORKTREE :FORCE T and the plan ref
;;;   deleted), status :DISCARDED, plan.sexp rewritten. The working copy is
;;;   never touched. A plan that is not :OPEN → PLAN-ERROR.
;;;
;;; Reopening (REOPEN-PLAN plans-dir id → plan)
;;;   Reads <plans dir>/<id>/plan.sexp. Missing, not :OPEN, or its area
;;;   directory gone → PLAN-NOT-FOUND (designator = ID). LIST-PLANS plans-dir
;;;   → every readable plan (any status), oldest OPENED-AT first, ties by id;
;;;   NIL when PLANS-DIR does not exist. Unreadable plan.sexp files are
;;;   skipped by LIST-PLANS (REOPEN-PLAN signals PLAN-ERROR for one).
;;;
;;; Sessions (H3c)
;;;   PLAN-RECORD plan → (:id S :kind K :base S :root S :status K), the
;;;   TURN-RECORD's PLAN of every turn that ran in the plan (RECORD-PLAN).
;;;   A resume in plan mode reopens the head record's plan when it is still
;;;   open (src/headless.lisp, src/program.lisp).
;;;
;;; Threads: a plan is used from one thread at a time. Processes: nothing
;;; locks a plan against another process (two processes approving one plan
;;; is the user's race, as with pathlib areas).

(defparameter +plan-format+ 1
  "The :FORMAT of plan.sexp.")

(defparameter +plan-ref-prefix+ "refs/cl-stack-code/plans/"
  "Git kind: the plan's ref is this prefix followed by its id.")

(defparameter +plan-kinds+ '(:auto :git :copy)
  "OPEN-PLAN :KIND values (and --plan-area auto, git, copy).")

(defclass plan ()
  ((id :initarg :id :reader plan-id
       :documentation "32 lowercase hex characters.")
   (kind :initarg :kind :reader plan-kind
         :documentation ":COPY or :GIT.")
   (project-dir :initarg :project-dir :reader plan-project-dir
                :documentation "The project directory the plan copies (a directory pathname).")
   (root :initarg :root :reader plan-root
         :documentation "The area: <plan dir>/tree/ (a directory pathname).")
   (base :initarg :base :accessor plan-base
         :documentation "The base: a snapshot id (:copy) or a commit id (:git).")
   (status :initarg :status :initform :open :accessor plan-status
           :documentation ":OPEN, :APPLIED or :DISCARDED.")
   (session-id :initarg :session-id :initform nil :reader plan-session-id
               :documentation "The session the plan was opened for, or NIL.")
   (directory :initarg :directory :reader plan-directory
              :documentation "<plans dir>/<id>/ (a directory pathname).")
   (opened-at :initarg :opened-at :reader plan-opened-at
              :documentation "Universal time the plan was opened.")
   (store :initarg :store :initform nil :accessor %plan-store
          :documentation ":copy: the DIRECTORY-SNAPSHOT-STORE; :git: the GIT-STORE
on the project (opened lazily by the implementation)."))
  (:documentation "A projected change in an area; see the top of src/plans.lisp."))

(defun plan-p (x) (typep x 'plan))

(defmethod print-object ((p plan) stream)
  (print-unreadable-object (p stream :type t)
    (format stream "~a ~s ~s" (plan-id p) (plan-kind p) (plan-status p))))

(defun plans-directory (cwd &key data-dir)
  "→ <data-dir>/plans/<project-key>/ for the project of CWD (DATA-DIR
defaults to USER-DATA-DIRECTORY)."
  (declare (ignore cwd data-dir))
  (%not-implemented 'plans-directory))

(defun open-plan (project-dir &key (kind :auto) data-dir session-id id)
  "→ a new open PLAN over PROJECT-DIR (see the top of the file)."
  (declare (ignore project-dir kind data-dir session-id id))
  (%not-implemented 'open-plan))

(defun reopen-plan (plans-dir id)
  "→ the open PLAN ID under PLANS-DIR; PLAN-NOT-FOUND otherwise."
  (declare (ignore plans-dir id))
  (%not-implemented 'reopen-plan))

(defun list-plans (plans-dir)
  "→ every readable PLAN under PLANS-DIR, oldest first."
  (declare (ignore plans-dir))
  (%not-implemented 'list-plans))

(defun plan-tool-root (plan cwd)
  "→ the directory of PLAN's area that corresponds to CWD."
  (declare (ignore plan cwd))
  (%not-implemented 'plan-tool-root))

(defun plan-changes (plan)
  "→ ((KIND PATH) …) from PLAN's base to its area now, sorted by PATH."
  (declare (ignore plan))
  (%not-implemented 'plan-changes))

(defun plan-diff (plan)
  "→ the diff-protocol tree diff of PLAN's changes."
  (declare (ignore plan))
  (%not-implemented 'plan-diff))

(defun plan-diff-text (plan)
  "→ PLAN-DIFF rendered :UNIFIED, \"\" when there are no changes."
  (declare (ignore plan))
  (%not-implemented 'plan-diff-text))

(defun approve-plan (plan &key message)
  "Apply PLAN to the working copy. → (values result status), status
:APPLIED, :EMPTY, :REBASED or :ABORTED; PLAN-DRIFT with restarts REBASE-PLAN,
OVERWRITE-PLAN and ABORT-APPROVAL."
  (declare (ignore plan message))
  (%not-implemented 'approve-plan))

(defun reject-plan (plan)
  "Discard PLAN's area. → :DISCARDED."
  (declare (ignore plan))
  (%not-implemented 'reject-plan))

(defun plan-record (plan)
  "→ (:id S :kind K :base S :root S :status K) for the turn record."
  (declare (ignore plan))
  (%not-implemented 'plan-record))
