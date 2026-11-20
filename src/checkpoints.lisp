(in-package #:cl-stack-code)

;;; H5b: checkpoints and rewind (with V3: git and jj as the files part).
;;;
;;; A CHECKPOINT is a composite revision (revision-protocol R0b,
;;; COMMIT-COMPOSITE) in the session's CHECKPOINT STORE. Its manifest has
;;; one part per role, in this order:
;;;   :files         the project's files: a cl-stack-pathlib snapshot id
;;;                  (kind :copy), a git commit id (kind :git) or a jj commit
;;;                  id (kind :jj). Always present.
;;;   :conversation  the session revision (H3c turn) the files belong to,
;;;                  DEPENDS-ON (:files). Absent for a checkpoint recorded
;;;                  before the session's first turn ("session start").
;;; :db and :image (+CHECKPOINT-ROLES+) are reserved for H5c / H5d: H5b
;;; never records them, and a rewind that asks for them reports nothing for
;;; them.
;;;
;;; Where
;;;   CHECKPOINTS-DIRECTORY store = <session dir>/checkpoints/, holding
;;;     revisions/<id>.sexp   one immutable file per checkpoint (H3c's
;;;                           revision file format; the content below)
;;;     refs/checkpoints      the tip: the newest checkpoint (H3c ref file)
;;;     refs/expired          the newest garbage-collected checkpoint, absent
;;;                           until the first collection
;;;     lock                  H3c's lock file rules (its own lock, not the
;;;                           session's)
;;;     store/                the :copy kind's DIRECTORY-SNAPSHOT-STORE (also
;;;                           the pre-turn snapshots, see "Turns")
;;;   Nothing is written to the sessions directory's "last" file, and nothing
;;;   at all until the first checkpoint (or pre-turn snapshot) is written.
;;;   Checkpoints form one chain in recording order: each one's parent is the
;;;   tip it was recorded after (whatever conversation branch it belongs to),
;;;   and refs/checkpoints moves to it. A record happens under the checkpoint
;;;   store's lock against the tip on disk, so two processes recording into
;;;   one session append in some order and never conflict.
;;;   A checkpoint revision's content on disk is
;;;     (:checkpoint 1 :parts ((:role :files :kind K :revision ID)
;;;                            (:role :conversation :kind :session :revision ID
;;;                             :depends-on (:files))))
;;;   and in memory a REV:REVISION-MANIFEST (so REV:COMPOSITE-MANIFEST works).
;;;   The :conversation part's REV:PART-STORE is the session store; the
;;;   :files part's is the checkpointer's open GIT-STORE / JJ-STORE for a
;;;   checkpoint recorded through that checkpointer and NIL otherwise (read
;;;   back from disk, or :copy: a pathlib snapshot is not a revision store).
;;;   Message: the conversation revision's message, or "session start".
;;;   Provenance: (:kind :checkpoint :reason R :turn N :ordinal K :files-kind K
;;;   :version +VERSION+). N is the conversation revision's position on its
;;;   first-parent line (1 = the root; 0 without a conversation part), K the
;;;   1-based position in the chain.
;;;
;;; Reasons (+CHECKPOINT-REASONS+)
;;;   :before       the files when a turn that changed them started, recorded
;;;                 when they differ from the tip's files (or there is no
;;;                 tip): the session's first checkpoint is always one; the
;;;                 conversation part is that turn's parent (none for turn 1)
;;;   :turn         the files after a turn that changed them
;;;   :plan-before  the working copy before an approved plan was applied
;;;   :plan-after   the working copy after it
;;;   :rewind       the working copy after a files rewind wrote it
;;;
;;; Kinds (RESOLVE-CHECKPOINT-KIND project-dir &key (kind :auto))
;;;   :jj    PROJECT-DIR is the root of a jj workspace that MAKE-JJ-STORE
;;;          opens (jj >= revision-backend-jj's minimum). The files are the
;;;          commit of @ right after jj's snapshot (JJ:WORKING-COPY-REVISION;
;;;          the id is its :COMMIT-ID provenance, not the change id). Nothing
;;;          else is written: jj keeps every snapshot of @ as a hidden commit
;;;          in its operation log, and a commit id names it for ever (visible
;;;          or hidden). @, its change, bookmarks and the files are never
;;;          touched.
;;;   :git   PROJECT-DIR is the top level of a git worktree that
;;;          MAKE-GIT-STORE opens (H5a's rule). The files are a commit of
;;;          what `git add -A` would record (uncommitted and untracked files,
;;;          not ignored ones), parents = HEAD (none on an unborn branch),
;;;          message "cl-stack-code checkpoint <session id> <ordinal>", on
;;;          the private ref +CHECKPOINT-REF-PREFIX+<session id>/<ordinal>.
;;;          Files read now are recorded with REV:CAPTURE-REVISION on a
;;;          GIT-WORKING-COPY whose :STAMP-REF is that ref (:PARENTS HEAD);
;;;          files read earlier (a :before checkpoint) with REV:COMMIT-REVISION
;;;          of the tree read then, and the ref created by CAS (expected
;;;          absent). HEAD, the branch, the index and the files are never
;;;          touched.
;;;   :copy  anything else: FS-SNAPSHOT of PROJECT-DIR with :IGNORE :AUTO into
;;;          <checkpoints dir>/store/ ("sha256:…").
;;;   :AUTO picks :jj, else :git, else :copy (a colocated jj repository is
;;;   :jj). An explicit :jj or :git that cannot open → CHECKPOINT-ERROR
;;;   "checkpoints.kind jj: DIR is not a jj workspace" / "checkpoints.kind
;;;   git: DIR is not a git worktree" (DIR its native namestring). :copy
;;;   always works. Each checkpoint records its own kind; a session may mix
;;;   kinds (a project that became a repository).
;;;
;;; Same files
;;;   Two files states are the same when they have the same tree: :copy the
;;;   same snapshot id; :git the same tree id; :jj REV:STATE-DIFF :LEVEL
;;;   :SUMMARY of the two commits is empty. States of different kinds are
;;;   never the same.
;;;
;;; The checkpointer (MAKE-CHECKPOINTER project-dir &key (kind :auto)
;;;   (keep +DEFAULT-CHECKPOINT-KEEP+) (enabled t) data-dir)
;;;   One per process (headless run, interactive program), made from the
;;;   settings (CHECKPOINT-SETTINGS) with the project directory (project
;;;   root, else cwd) and the data directory. KIND is resolved at once
;;;   (RESOLVE-CHECKPOINT-KIND, so an explicit kind that does not fit fails
;;;   before the run). KEEP is an integer >= 1. ENABLED NIL turns off every
;;;   automatic checkpoint (turns, plan approvals, rewinds); RECORD-CHECKPOINT,
;;;   rewinds of existing checkpoints and listings still work. DATA-DIR (NIL:
;;;   USER-DATA-DIRECTORY) holds the rewind plans (PLANS-DIRECTORY).
;;;   CLOSE-CHECKPOINTER releases the git / jj store it opened (idempotent).
;;;
;;; Turns (BEGIN-CHECKPOINT-TURN cp store → PRE, END-CHECKPOINT-TURN cp store
;;;   PRE TURN → the checkpoints recorded, oldest first)
;;;   BEGIN reads the files (READ-FILES-STATE) before the run; NIL when the
;;;   checkpointer is disabled. END runs after the turn's revision TURN was
;;;   committed, whatever the turn's finish (:stop :max-steps :canceled
;;;   :failed): with PRE NIL → NIL. Otherwise it reads the files again
;;;   (POST). POST the same as PRE, or as the tip's files → NIL (nothing new:
;;;   the turn changed nothing, user edits made before it are not recorded
;;;   either, and a plan approved during the turn recorded POST already). Else, when there is no
;;;   tip or the tip's files are not the same as PRE, a :before checkpoint
;;;   (conversation part TURN's first parent, or none; files PRE) is recorded
;;;   first; then a :turn checkpoint (TURN, POST). A turn committed to a
;;;   forked session (SESSION-CONFLICT → FORK-SESSION) records into the
;;;   session it went to. In plan mode the agent edits the area, so its turns
;;;   normally change nothing here (an unconfined shell writing the real tree
;;;   does, and is recorded).
;;;   READ-FILES-STATE cp store → FILES-STATE (kind, id): :copy the snapshot
;;;   id (its blobs stored in the session's store/); :git the tree id
;;;   (nothing committed yet); :jj the commit id of @.
;;;
;;; Plan mode (APPROVE-PLAN plan :checkpointer cp → (values result status
;;;   pre), then RECORD-PLAN-CHECKPOINTS cp store pre turn)
;;;   With an enabled checkpointer, an approval that returns :APPLIED also
;;;   returns PRE, the files state read before anything was written (NIL for
;;;   :EMPTY, :REBASED, :ABORTED). RECORD-PLAN-CHECKPOINTS records
;;;   :plan-before (PRE) and :plan-after (the working copy now), both with
;;;   TURN as the conversation part, and returns them; PRE NIL → NIL. The
;;;   plan belongs to the turn that ran it: the interactive approve passes
;;;   the session's head (the plan's last turn), the action-only --apply the
;;;   head too, and the headless run with --apply approves before its turn
;;;   is committed (H5a: the record carries the :applied status), then
;;;   records the plan's checkpoints with the committed revision, then runs
;;;   END-CHECKPOINT-TURN (which records nothing more: the files are the
;;;   tip's).
;;;
;;; Reading
;;;   SESSION-CHECKPOINTS store &key all → CHECKPOINT values oldest first:
;;;   the retained ones, or every one with ALL. TIP-CHECKPOINT store → the
;;;   newest, or NIL. FIND-CHECKPOINT store designator → by full id or a
;;;   unique prefix of at least 4 characters (any checkpoint, expired ones
;;;   too); otherwise CHECKPOINT-NOT-FOUND (the message "session S has no
;;;   checkpoint X"). A store reopened in another process (OPEN-SESSION)
;;;   reads the same checkpoints: same ids, reasons, turns, files ids,
;;;   messages and recorded times (unix seconds).
;;;
;;; The files at a turn (TURN-CHECKPOINT store at → CHECKPOINT or NIL)
;;;   AT is "0" (the session's start) or a RESOLVE-TURN designator (a number
;;;   on the head's line, an id or id prefix); anything else →
;;;   SESSION-TURN-NOT-FOUND. L = AT's first-parent line (root … AT; empty
;;;   for "0"). Among ALL checkpoints, the candidates are those whose
;;;   conversation revision is on L, and those with no conversation part.
;;;   The answer is the candidate whose conversation revision is deepest on L
;;;   (no conversation part counts as depth 0), the most recently recorded
;;;   one among equals. With no candidate: the session's first checkpoint
;;;   when its conversation revision descends from AT (every earlier turn
;;;   left the files alone, so they were as that :before checkpoint has
;;;   them); otherwise NIL. The answer may be expired (CHECKPOINT-EXPIRED-P).
;;;
;;; Rewind (REWIND-TO cp store at &key (parts +REWIND-PARTS+) → RESULT)
;;;   PARTS: a non-empty subset of (:conversation :files) (others → TYPE-ERROR;
;;;   :db / :image are reserved). One transition per part, in the manifest's
;;;   dependency order: files first, then the conversation (it depends on
;;;   the files, so a files rewind that restores nothing leaves the
;;;   conversation alone too).
;;;   1. AT resolved as for TURN-CHECKPOINT; T = its line number (0 for "0").
;;;   2. :conversation in PARTS: SYNC-SESSION, and a head on disk that is not
;;;      SESSION-BASE → SESSION-CONFLICT before anything is restored.
;;;   3. :files in PARTS: TARGET = TURN-CHECKPOINT AT (NIL →
;;;      CHECKPOINT-NOT-FOUND, designator AT; expired, or its backend lost the
;;;      files → CHECKPOINT-EXPIRED), TIP = TIP-CHECKPOINT. A REWIND PLAN is
;;;      opened: an H5a plan of kind :copy under PLANS-DIRECTORY (data dir of
;;;      the checkpointer), PLAN-SESSION-ID the session, PLAN-REWIND
;;;      (:session S :to TARGET-ID :from TIP-ID), whose base is TIP's files
;;;      and whose area holds TARGET's files, both as pathlib snapshots in
;;;      the plans' store (:git / :jj files are read through the backend's
;;;      read-only revision filesystem, MAKE-REVISION-FILESYSTEM on the
;;;      commit id). Then APPROVE-PLAN, so the working copy is compared as H5a
;;;      does (pathlib :IGNORE :AUTO): a path the rewind changes (TIP → TARGET)
;;;      whose working-copy entry differs from both TIP's and TARGET's is
;;;      DRIFT — the user's work since the tip — and PLAN-DRIFT (PLAN = the
;;;      rewind plan, PATHS) is signalled once, before anything is written,
;;;      with H5a's restarts:
;;;        OVERWRITE-PLAN  restore; TARGET wins at the drifted paths
;;;        REBASE-PLAN     merge: H5a's rebase (old base TIP, area TARGET,
;;;                        working copy; DIFF:MERGE-TEXTS with H5a's labels
;;;                        "plan" / "working copy"), then the rewind plan is
;;;                        approved again at once, so the merge is written.
;;;                        Paths only the user changed keep the user's
;;;                        version. Files status :MERGED, CONFLICTS = the
;;;                        rebase's conflicts.
;;;        ABORT-APPROVAL  write nothing; the rewind plan is discarded; files
;;;                        status :ABORTED and the conversation is not moved
;;;      Paths the rewind does not change are never touched (drift there is
;;;      kept), ignored files neither. On a non-local exit (an unhandled
;;;      drift) nothing is written and the rewind plan is discarded. Files
;;;      status :APPLIED (CHANGES = the rewind plan's PLAN-CHANGES), :MERGED,
;;;      :EMPTY (the working copy already had TARGET's files at those paths)
;;;      or :ABORTED.
;;;   4. :conversation in PARTS (and files not :ABORTED): the head moves to
;;;      AT (deleted for "0") by CAS from SESSION-BASE (MOVE-SESSION-HEAD);
;;;      :MOVED, or :UNCHANGED when it was there already (or the files were
;;;      :ABORTED).
;;;   5. Files :APPLIED or :MERGED and the checkpointer enabled: a :rewind
;;;      checkpoint of the working copy, the conversation part being the
;;;      head after step 4 (none when there is no head).
;;;   RESULT: (:turn T :parts PARTS :conversation C :files F :changes CH
;;;   :conflicts X :drift D :checkpoint K): C :MOVED :UNCHANGED or :SKIPPED
;;;   (not asked); F :APPLIED :MERGED :EMPTY :ABORTED or :SKIPPED; CH the
;;;   ((kind path) …) written (NIL unless applied or merged); X the merge
;;;   conflicts; D the drifted paths (NIL without drift); K the :rewind
;;;   CHECKPOINT or NIL.
;;;   REWIND-DESCRIPTION result → the phrase both modes print:
;;;     F :ABORTED                         "nothing restored"
;;;     conversation only                  "conversation"
;;;     files only                         "files (N file[s] changed)"
;;;     both                               "conversation and files (N file[s] changed)"
;;;     F :EMPTY                           "… files (no changes)"
;;;     F :MERGED                          "… files (N file[s] changed, merged with the
;;;                                         working copy[; conflicts in P, Q])"
;;;   (N = the length of CHANGES; "conversation" stands for a C that is not
;;;   :SKIPPED, "files" for an F that is not :SKIPPED.)
;;;
;;; Retention (GC-CHECKPOINTS cp store → the number newly expired)
;;;   Runs after every record. The newest CHECKPOINTER-KEEP checkpoints of
;;;   the chain are retained; older ones expire, for good: refs/expired moves
;;;   to the newest expired one (never back, so raising keep later does not
;;;   revive them). Expiring deletes their files where the product owns them:
;;;   :git their private refs (`git update-ref -d`; git's own gc prunes the
;;;   objects later), :copy every blob of <checkpoints dir>/store/ that no
;;;   retained :copy checkpoint's snapshot uses (its manifest blob and its
;;;   entries' blobs), listed and deleted with pathlib's SNAPSHOT-STORE-IDS
;;;   and SNAPSHOT-STORE-DELETE (cl-stack-pathlib#39, a dependency that ships
;;;   before this is implemented; the pin then moves to that release), :jj
;;;   nothing (jj's operation log owns its commits). The composite revisions
;;;   stay (they are small and immutable): CHECKPOINT-EXPIRED-P is true for
;;;   them, SESSION-CHECKPOINTS leaves them out unless :ALL, and a files
;;;   rewind that needs one signals CHECKPOINT-EXPIRED.
;;;
;;; Views
;;;   CHECKPOINT-SUMMARY-LINES store &key (width 80) → one line per retained
;;;   checkpoint, newest first: "<mark> <id8> turn <N> <label> <message>",
;;;   mark "●" when the conversation revision is on the head's line (or there
;;;   is none) and "○" otherwise; label "before" "after" "plan-before"
;;;   "plan-after" "rewind" for :before :turn :plan-before :plan-after
;;;   :rewind; message the checkpoint's message. A line longer than WIDTH is
;;;   cut to WIDTH − 1 characters and "…". No checkpoints → ("no
;;;   checkpoints yet").
;;;   /tree marks the turns that have a retained checkpoint
;;;   (SESSION-TREE-LINES :MARKED, src/session-views.lisp).
;;;
;;; Threads: a checkpointer is used from one thread at a time (the agent
;;; thread in the interactive program).

(defparameter +checkpoint-format+ 1
  "The :CHECKPOINT format number of a checkpoint revision's content.")

(defparameter +checkpoint-kinds+ '(:auto :jj :git :copy)
  "MAKE-CHECKPOINTER :KIND values (checkpoints.kind).")

(defparameter +checkpoint-reasons+ '(:before :turn :plan-before :plan-after :rewind)
  "CHECKPOINT-REASON values.")

(defparameter +checkpoint-roles+ '(:files :conversation :db :image)
  "Manifest roles. H5b records :files and :conversation; :db (H5c) and :image
(H5d) are reserved.")

(defparameter +checkpoint-ref+ "checkpoints"
  "The checkpoint store's ref naming the tip.")

(defparameter +expired-ref+ "expired"
  "The checkpoint store's ref naming the newest garbage-collected checkpoint.")

(defparameter +checkpoint-ref-prefix+ "refs/cl-stack-code/checkpoints/"
  "Git kind: a checkpoint's private ref is this prefix, the session id, \"/\"
and the checkpoint's ordinal.")

(defparameter +rewind-parts+ '(:conversation :files)
  "REWIND-TO's default PARTS (--rewind-mode both).")

;;; Values.

(defstruct (checkpoint (:constructor %make-checkpoint))
  "One checkpoint, as read from its composite revision (see the file header).
TURN is the line number of TURN-ID (0 when it has none); FILES-ID the
snapshot id (:copy) or commit id (:git, :jj); RECORDED-AT a
DATETIME-PROTOCOL instant; REVISION the composite REV:REVISION."
  (id "" :type string)
  (ordinal 0 :type integer)
  (reason :turn :type keyword)
  (turn 0 :type integer)
  (turn-id nil)
  (files-kind :copy :type keyword)
  (files-id "" :type string)
  (message "" :type string)
  (recorded-at nil)
  (expired-p nil)
  (revision nil))

(defstruct (files-state (:constructor %make-files-state (kind id &optional tree)))
  "The project's files as READ-FILES-STATE read them: KIND :COPY :GIT :JJ and
ID (a snapshot id, a git tree id, a jj commit id)."
  (kind :copy :type keyword)
  (id "" :type string)
  (tree nil))

(defclass checkpoint-store (rev:in-memory-store)
  ((session :initarg :session :reader checkpoint-store-session
            :documentation "The SESSION-STORE this store belongs to.")
   (directory :initarg :directory :reader %checkpoint-store-directory
              :documentation "<session dir>/checkpoints/ (it may not exist yet).")
   (base :initarg :base :initform nil :accessor %checkpoint-store-base
         :documentation "The tip id this store read or last wrote, or NIL.")
   (lock :initform (bt:make-lock "cl-stack-code checkpoints") :reader %checkpoint-store-lock))
  (:documentation "A session's checkpoints: revision-protocol's in-memory store
written through to CHECKPOINTS-DIRECTORY with H3c's file rules (see the file
header). Get it with CHECKPOINT-STORE, not MAKE-INSTANCE."))

(defun checkpoint-store-p (x) (typep x 'checkpoint-store))

(defclass checkpointer ()
  ((project-dir :initarg :project-dir :reader checkpointer-project-dir
                :documentation "The project directory (a directory pathname).")
   (kind :initarg :kind :reader checkpointer-kind
         :documentation "The resolved kind: :JJ, :GIT or :COPY.")
   (keep :initarg :keep :reader checkpointer-keep
         :documentation "Checkpoints a session retains (an integer >= 1).")
   (enabled :initarg :enabled :reader checkpointer-enabled-p
            :documentation "NIL: no automatic checkpoints.")
   (data-dir :initarg :data-dir :initform nil :reader checkpointer-data-dir
             :documentation "The data directory (rewind plans), or NIL for USER-DATA-DIRECTORY.")
   (store :initform nil :accessor %checkpointer-store
          :documentation "The GIT-STORE or JJ-STORE opened on the project, or NIL."))
  (:documentation "Records and rewinds checkpoints for one project; see the
file header. Make one with MAKE-CHECKPOINTER."))

(defun checkpointer-p (x) (typep x 'checkpointer))

(defmethod print-object ((cp checkpointer) stream)
  (print-unreadable-object (cp stream :type t)
    (format stream "~s ~a" (and (slot-boundp cp 'kind) (checkpointer-kind cp))
            (and (slot-boundp cp 'project-dir)
                 (uiop:native-namestring (checkpointer-project-dir cp))))))

(defun checkpoints-directory (store)
  "→ <session dir>/checkpoints/ of the SESSION-STORE STORE."
  (merge-pathnames "checkpoints/" (session-directory store)))

;;; Stubs (the contract).

(defun resolve-checkpoint-kind (project-dir &key (kind :auto))
  "→ :JJ, :GIT or :COPY for PROJECT-DIR (see \"Kinds\")."
  (declare (ignore project-dir kind))
  (%not-implemented 'resolve-checkpoint-kind))

(defun make-checkpointer (project-dir &key (kind :auto) (keep +default-checkpoint-keep+)
                                           (enabled t) data-dir)
  "→ a CHECKPOINTER for PROJECT-DIR (see \"The checkpointer\")."
  (declare (ignore project-dir kind keep enabled data-dir))
  (%not-implemented 'make-checkpointer))

(defun close-checkpointer (checkpointer)
  "Release the backend store CHECKPOINTER opened. → NIL."
  (declare (ignore checkpointer))
  (%not-implemented 'close-checkpointer))

(defun checkpoint-store (store)
  "→ the CHECKPOINT-STORE of the SESSION-STORE STORE (made once per store
object, synced from disk)."
  (declare (ignore store))
  (%not-implemented 'checkpoint-store))

(defmethod rev:commit-revision :around ((store checkpoint-store) content &key &allow-other-keys)
  (declare (ignore content))
  (%not-implemented "checkpoint-store write-through (commit-revision)"))

(defmethod rev:move-ref :around ((store checkpoint-store) name designator &key &allow-other-keys)
  (declare (ignore name designator))
  (%not-implemented "checkpoint-store write-through (move-ref)"))

(defmethod rev:delete-ref :around ((store checkpoint-store) name &key &allow-other-keys)
  (declare (ignore name))
  (%not-implemented "checkpoint-store write-through (delete-ref)"))

(defun read-files-state (checkpointer store)
  "→ the FILES-STATE of the project now (see \"Turns\")."
  (declare (ignore checkpointer store))
  (%not-implemented 'read-files-state))

(defun record-checkpoint (checkpointer store reason &key turn files)
  "Record a checkpoint in the SESSION-STORE STORE. → the CHECKPOINT. REASON one
of +CHECKPOINT-REASONS+; TURN a session revision (or its id) for the
conversation part, NIL for none; FILES a FILES-STATE (default: read now).
Then GC-CHECKPOINTS. Works whether or not CHECKPOINTER is enabled."
  (declare (ignore checkpointer store reason turn files))
  (%not-implemented 'record-checkpoint))

(defun begin-checkpoint-turn (checkpointer store)
  "Before a turn: → the FILES-STATE now, or NIL when CHECKPOINTER is disabled."
  (declare (ignore checkpointer store))
  (%not-implemented 'begin-checkpoint-turn))

(defun end-checkpoint-turn (checkpointer store pre turn)
  "After TURN (a committed session revision) ran: → the checkpoints recorded,
oldest first (see \"Turns\")."
  (declare (ignore checkpointer store pre turn))
  (%not-implemented 'end-checkpoint-turn))

(defun record-plan-checkpoints (checkpointer store pre turn)
  "After an approved plan: record :PLAN-BEFORE (PRE) and :PLAN-AFTER (now) with
TURN as the conversation part. → them, or NIL when PRE is NIL (see \"Plan
mode\")."
  (declare (ignore checkpointer store pre turn))
  (%not-implemented 'record-plan-checkpoints))

(defun gc-checkpoints (checkpointer store)
  "Expire the checkpoints of STORE beyond CHECKPOINTER-KEEP. → the number
newly expired (see \"Retention\")."
  (declare (ignore checkpointer store))
  (%not-implemented 'gc-checkpoints))

(defun session-checkpoints (store &key all)
  "→ the CHECKPOINTs of the SESSION-STORE STORE, oldest first: the retained
ones, or every one with ALL."
  (declare (ignore store all))
  (%not-implemented 'session-checkpoints))

(defun tip-checkpoint (store)
  "→ the newest CHECKPOINT of STORE, or NIL."
  (declare (ignore store))
  (%not-implemented 'tip-checkpoint))

(defun find-checkpoint (store designator)
  "→ the CHECKPOINT with id or unique id prefix (>= 4) DESIGNATOR;
CHECKPOINT-NOT-FOUND otherwise."
  (declare (ignore store designator))
  (%not-implemented 'find-checkpoint))

(defun turn-checkpoint (store at)
  "→ the CHECKPOINT holding the files at turn AT, or NIL (see \"The files at a
turn\")."
  (declare (ignore store at))
  (%not-implemented 'turn-checkpoint))

(defun rewind-to (checkpointer store at &key (parts +rewind-parts+))
  "Rewind the SESSION-STORE STORE to turn AT, per part. → the RESULT plist
(see \"Rewind\")."
  (declare (ignore checkpointer store at parts))
  (%not-implemented 'rewind-to))

(defun rewind-description (result)
  "→ the phrase for a REWIND-TO RESULT (see \"Rewind\")."
  (declare (ignore result))
  (%not-implemented 'rewind-description))

(defun checkpoint-summary-lines (store &key (width 80))
  "→ the /checkpoints and --list-checkpoints lines (see \"Views\")."
  (declare (ignore store width))
  (%not-implemented 'checkpoint-summary-lines))

(defun %approve-plan-with-checkpoints (plan message checkpointer)
  "APPROVE-PLAN :CHECKPOINTER (see \"Plan mode\")."
  (declare (ignore plan message checkpointer))
  (%not-implemented "approve-plan :checkpointer"))
