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
   (lock :initform (bt:make-lock "cl-stack-code checkpoints") :reader %checkpoint-store-lock)
   (blobs :initform nil :accessor %checkpoint-store-blobs
          :documentation "The DIRECTORY-SNAPSHOT-STORE on <checkpoints dir>/store/, made on first use."))
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
          :documentation "The GIT-STORE or JJ-STORE opened on the project, or NIL.")
   (others :initform nil :accessor %checkpointer-others
           :documentation "Alist kind → store opened later for checkpoints of another kind.")
   (pending :initform nil :accessor %checkpointer-pending
            :documentation "Ids of :copy PRE states read by BEGIN-CHECKPOINT-TURN and not ended yet
(kept by the blob sweep)."))
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

;;; The checkpoint store's files. H3c's file engine (src/sessions.lisp: the
;;; lock, atomic writes, revision and ref files, %SYNC) reaches a store only
;;; through the generic readers SESSION-DIRECTORY and SESSION-ID, so these two
;;; methods point it at <session dir>/checkpoints/ and the session's id. The
;;; transaction and the persist step are this file's: they never write
;;; session.sexp or "last", and they translate the content (a manifest in
;;; memory, the :CHECKPOINT plist on disk).

(defmethod session-directory ((store checkpoint-store))
  (%checkpoint-store-directory store))

(defmethod session-id ((store checkpoint-store))
  (session-id (checkpoint-store-session store)))

(defun %checkpoint-fail (store control &rest args)
  (error 'checkpoint-error :session (session-id store)
                           :message (apply #'format nil control args)))

(defun %checkpoint-file-errors (store thunk)
  "Run THUNK (H3c's engine on STORE): a SESSION-ERROR about a checkpoint file
becomes a CHECKPOINT-ERROR. The lock conditions keep their type and restarts."
  (handler-bind ((session-error
                   (lambda (e)
                     (unless (typep e '(or session-locked session-lock-error))
                       (error 'checkpoint-error :session (session-id store)
                                                :message (princ-to-string e))))))
    (funcall thunk)))

(defun %blob-store (cs)
  "The :copy kind's DIRECTORY-SNAPSHOT-STORE <checkpoints dir>/store/ (created
on its first write)."
  (or (%checkpoint-store-blobs cs)
      (setf (%checkpoint-store-blobs cs)
            (p:make-directory-snapshot-store
             (uiop:native-namestring
              (merge-pathnames "store/" (%checkpoint-store-directory cs)))))))

(defun %checkpoint-content-p (content)
  (and (consp content) (eq :checkpoint (first content))))

(defun %conversation-part (session turn-id)
  (rev:make-manifest-part :conversation session turn-id :depends-on (list :files)))

(defun %content->manifest (cs content)
  "The REV:REVISION-MANIFEST of a checkpoint content plist read from disk."
  (let ((session (checkpoint-store-session cs)))
    (unless (and (%plist-p content)
                 (eql +checkpoint-format+ (getf content :checkpoint))
                 (listp (getf content :parts)))
      (%checkpoint-fail cs "malformed checkpoint content: ~s" content))
    (rev:make-manifest
     (loop for part in (getf content :parts)
           for role = (and (%plist-p part) (getf part :role))
           for id = (and (%plist-p part) (getf part :revision))
           do (unless (and (member role '(:files :conversation)) (stringp id))
                (%checkpoint-fail cs "malformed checkpoint part: ~s" part))
           collect (if (eq role :files)
                       (rev:make-manifest-part :files nil id)
                       (handler-case (%conversation-part session id)
                         (rev:revision-error ()
                           ;; Written by another process after this session's last sync.
                           (sync-session session)
                           (handler-case (%conversation-part session id)
                             (rev:revision-error ()
                               (%checkpoint-fail cs "checkpoint names turn ~a, which is not in session ~a"
                                                 id (session-id session)))))))))))

(defun %manifest->content (revision)
  "The on-disk content plist of the checkpoint REVISION."
  (let ((kind (getf (rev:revision-provenance revision) :files-kind)))
    (list :checkpoint +checkpoint-format+
          :parts (loop for part in (rev:manifest-parts (rev:revision-content revision))
                       collect (ecase (rev:part-role part)
                                 (:files (list :role :files :kind kind
                                               :revision (rev:part-revision-id part)))
                                 (:conversation (list :role :conversation :kind :session
                                                      :revision (rev:part-revision-id part)
                                                      :depends-on (list :files))))))))

(defun %persist-checkpoints (cs)
  "Write what CS's memory has and its directory lacks: new revision files
(parents first), then changed and deleted refs. No session.sexp, no \"last\"."
  (let ((on-disk (make-hash-table :test 'equal)))
    (loop for (id) in (%revision-file-ids cs) do (setf (gethash id on-disk) t))
    (dolist (r (%all-revisions cs))
      (unless (gethash (rev:revision-id r) on-disk)
        (let ((plist (%revision-plist r)))
          (setf (getf plist :content) (%manifest->content r))
          (%write-file-atomically (%revision-file cs (rev:revision-id r)) (%print-data plist)))))
    (let ((disk-refs (%disk-refs cs)))
      (dolist (ref (rev:list-refs cs))
        (let ((text (%ref-text ref)))
          (unless (equal text (second (assoc (rev:ref-name ref) disk-refs :test #'equal)))
            (%write-file-atomically (%ref-file cs (rev:ref-name ref)) text))))
      (loop for (name) in disk-refs
            unless (rev:find-ref cs name)
              do (delete-file (%ref-file cs name))))
    cs))

(defun %call-checkpoint-writing (cs thunk)
  "Run THUNK as one write transaction on CS: H3c's rules with the checkpoint
store's own lock file (see the file header)."
  (if (member cs *%writing* :test #'eq)
      (funcall thunk)
      (bt:with-lock-held ((%checkpoint-store-lock cs))
        (let ((token (%acquire-lock cs)))
          (unwind-protect
               (let ((*%writing* (cons cs *%writing*)))
                 (%checkpoint-file-errors cs (lambda () (%sync cs)))
                 (multiple-value-prog1 (funcall thunk)
                   (%checkpoint-file-errors cs (lambda () (%persist-checkpoints cs)))))
            (%release-lock cs token))))))

(defmethod rev:commit-revision :around ((store checkpoint-store) content &rest keys
                                        &key ref id &allow-other-keys)
  (when ref (%check-name store ref "ref name"))
  (when id (%check-name store id "revision id"))
  (%call-checkpoint-writing
   store
   (lambda ()
     (if (%checkpoint-content-p content)
         ;; A revision file read back (%SYNC → %IMPORT-REVISION).
         (apply #'call-next-method store (%content->manifest store content) keys)
         (call-next-method)))))

(defmethod rev:move-ref :around ((store checkpoint-store) name designator &key &allow-other-keys)
  (declare (ignore designator))
  (%check-name store name "ref name")
  (%call-checkpoint-writing store (lambda () (call-next-method))))

(defmethod rev:delete-ref :around ((store checkpoint-store) name &key &allow-other-keys)
  (%check-name store name "ref name")
  (%call-checkpoint-writing store (lambda () (call-next-method))))

(defun %sync-checkpoints (cs)
  "Read the checkpoint files other processes wrote since (nothing when the
directory does not exist yet: a read creates nothing). → CS."
  (unless (member cs *%writing* :test #'eq)
    (when (uiop:directory-exists-p (merge-pathnames "revisions/" (%checkpoint-store-directory cs)))
      (bt:with-lock-held ((%checkpoint-store-lock cs))
        (let ((*%writing* (cons cs *%writing*)))
          (%checkpoint-file-errors cs (lambda () (%sync cs)))))))
  cs)

(defun checkpoint-store (store)
  "→ the CHECKPOINT-STORE of the SESSION-STORE STORE (made once per store
object, synced from disk)."
  (check-type store session-store)
  (%sync-checkpoints
   (or (%session-checkpoints store)
       (setf (%session-checkpoints store)
             (make-instance 'checkpoint-store
                            :engine (make-instance 'diff:sexp-diff-engine)
                            :session store
                            :directory (checkpoints-directory store))))))

;;; Checkpoints as values.

(defun %ordinal (revision)
  (or (getf (rev:revision-provenance revision) :ordinal) 0))

(defun %files-kind (revision)
  (getf (rev:revision-provenance revision) :files-kind))

(defun %part (revision role)
  (find role (rev:manifest-parts (rev:revision-content revision)) :key #'rev:part-role))

(defun %revision-files-id (revision)
  (rev:part-revision-id (%part revision :files)))

(defun %tip-revision (cs)
  (let ((ref (rev:find-ref cs +checkpoint-ref+)))
    (and ref (rev:resolve-revision cs (rev:ref-target ref)))))

(defun %expired-ordinal (cs)
  "The ordinal refs/expired names, 0 without it."
  (let ((ref (rev:find-ref cs +expired-ref+)))
    (if ref (%ordinal (rev:resolve-revision cs (rev:ref-target ref))) 0)))

(defun %chain (cs)
  "Every checkpoint revision of CS, oldest first."
  (let ((tip (%tip-revision cs)))
    (and tip (copy-list (rev:walk-revisions cs (rev:revision-id tip) :order :first-parent)))))

(defun %revision-checkpoint (revision expired-ordinal)
  (let* ((prov (rev:revision-provenance revision))
         (conversation (%part revision :conversation))
         (ordinal (%ordinal revision)))
    (%make-checkpoint :id (rev:revision-id revision)
                      :ordinal ordinal
                      :reason (getf prov :reason)
                      :turn (or (getf prov :turn) 0)
                      :turn-id (and conversation (rev:part-revision-id conversation))
                      :files-kind (getf prov :files-kind)
                      :files-id (%revision-files-id revision)
                      :message (or (rev:revision-message revision) "")
                      :recorded-at (rev:revision-recorded-at revision)
                      :expired-p (<= ordinal expired-ordinal)
                      :revision revision)))

(defun session-checkpoints (store &key all)
  "→ the CHECKPOINTs of the SESSION-STORE STORE, oldest first: the retained
ones, or every one with ALL."
  (let* ((cs (checkpoint-store store))
         (expired (%expired-ordinal cs))
         (checkpoints (mapcar (lambda (r) (%revision-checkpoint r expired)) (%chain cs))))
    (if all checkpoints (remove-if #'checkpoint-expired-p checkpoints))))

(defun tip-checkpoint (store)
  "→ the newest CHECKPOINT of STORE, or NIL."
  (let* ((cs (checkpoint-store store))
         (tip (%tip-revision cs)))
    (and tip (%revision-checkpoint tip (%expired-ordinal cs)))))

(defun find-checkpoint (store designator)
  "→ the CHECKPOINT with id or unique id prefix (>= 4) DESIGNATOR;
CHECKPOINT-NOT-FOUND otherwise."
  (let ((hits (and (stringp designator)
                   (>= (length designator) rev:+minimum-id-prefix+)
                   (let ((prefix (string-downcase designator)))
                     (remove-if-not (lambda (k) (uiop:string-prefix-p prefix (checkpoint-id k)))
                                    (session-checkpoints store :all t))))))
    (if (and hits (null (rest hits)))
        (first hits)
        (error 'checkpoint-not-found
               :session (session-id store) :designator designator
               :message (format nil "session ~a has no checkpoint ~a" (session-id store) designator)))))

;;; Kinds and the checkpointer.

(defun %close-store (store)
  (when (git:git-store-p store)
    (git:close-git-store store))
  nil)

(defun %jj-store-at (project)
  "→ a JJ-STORE whose workspace root is the directory PROJECT, or NIL."
  (let ((store (handler-case (jj:make-jj-store project)
                 ((or jj:jj-command-error jj:vc-tool-version-error rev:revision-error) () nil))))
    (and store
         (jj:jj-store-path store)
         (equal (uiop:native-namestring (%truename-directory (jj:jj-store-path store)))
                (uiop:native-namestring project))
         store)))

(defun %git-store-at (project)
  "→ a GIT-STORE whose worktree top level is PROJECT (H5a's rule), or NIL."
  (multiple-value-bind (kind store) (%choose-kind project :auto)
    (and (eq kind :git) store)))

(defun %open-kind (project kind)
  "→ (values kind store) for the truename directory PROJECT (see \"Kinds\")."
  (flet ((fail (what)
           (error 'checkpoint-error
                  :message (format nil "checkpoints.kind ~(~a~): ~a is not a ~a"
                                   kind (uiop:native-namestring project) what))))
    (ecase kind
      (:copy (values :copy nil))
      (:jj (let ((store (%jj-store-at project)))
             (if store (values :jj store) (fail "jj workspace"))))
      (:git (let ((store (%git-store-at project)))
              (if store (values :git store) (fail "git worktree"))))
      (:auto (let ((jj (%jj-store-at project)))
               (if jj
                   (values :jj jj)
                   (let ((git (%git-store-at project)))
                     (if git (values :git git) (values :copy nil)))))))))

(defun resolve-checkpoint-kind (project-dir &key (kind :auto))
  "→ :JJ, :GIT or :COPY for PROJECT-DIR (see \"Kinds\")."
  (check-type kind (member :auto :jj :git :copy))
  (multiple-value-bind (resolved store) (%open-kind (%truename-directory project-dir) kind)
    (%close-store store)
    resolved))

(defun make-checkpointer (project-dir &key (kind :auto) (keep +default-checkpoint-keep+)
                                           (enabled t) data-dir)
  "→ a CHECKPOINTER for PROJECT-DIR (see \"The checkpointer\")."
  (check-type kind (member :auto :jj :git :copy))
  (check-type keep (integer 1))
  (let ((project (%truename-directory project-dir)))
    (multiple-value-bind (resolved store) (%open-kind project kind)
      (let ((cp (make-instance 'checkpointer :project-dir project :kind resolved :keep keep
                                             :enabled (and enabled t) :data-dir data-dir)))
        (setf (%checkpointer-store cp) store)
        cp))))

(defun close-checkpointer (checkpointer)
  "Release the backend store CHECKPOINTER opened. → NIL."
  (%close-store (%checkpointer-store checkpointer))
  (loop for (nil . store) in (%checkpointer-others checkpointer)
        do (%close-store store))
  nil)

(defun %kind-store (cp kind)
  "The GIT-STORE / JJ-STORE for checkpoints of KIND: the checkpointer's own,
or one opened on the project for a checkpoint of another kind."
  (cond ((eq kind :copy) nil)
        ((eq kind (checkpointer-kind cp)) (%checkpointer-store cp))
        (t (or (cdr (assoc kind (%checkpointer-others cp)))
               (let ((store (nth-value 1 (%open-kind (checkpointer-project-dir cp) kind))))
                 (push (cons kind store) (%checkpointer-others cp))
                 store)))))

;;; Files states.

(defun %read-files (cp blobs)
  "→ the FILES-STATE of CP's project now; a :copy snapshot goes into the
pathlib store BLOBS (its TREE)."
  (let ((project (checkpointer-project-dir cp)))
    (ecase (checkpointer-kind cp)
      (:copy
       (%make-files-state :copy (p:fs-snapshot (%local-fs) project :ignore :auto :store blobs) blobs))
      (:git
       ;; What `git add -A` would record, through the backend's private stat
       ;; index: HEAD, the index and the files stay.
       (let ((store (%checkpointer-store cp)))
         (%make-files-state :git (git:git-projection-tree
                                  (rev:project-state store (git:make-git-working-copy store))))))
      (:jj
       (let ((store (%checkpointer-store cp)))
         (%make-files-state :jj (getf (rev:revision-provenance
                                       (jj:working-copy-revision (jj:make-jj-working-copy store)))
                                      :commit-id)))))))

(defun read-files-state (checkpointer store)
  "→ the FILES-STATE of the project now (see \"Turns\")."
  (%read-files checkpointer (%blob-store (checkpoint-store store))))

(defun %files-key (cp x)
  "→ (values kind id) of X (a FILES-STATE or a CHECKPOINT), ids comparable
per kind (:git the tree id)."
  (etypecase x
    (files-state (values (files-state-kind x) (files-state-id x)))
    (checkpoint
     (let ((kind (checkpoint-files-kind x))
           (id (checkpoint-files-id x)))
       (values kind (if (eq kind :git) (%git-commit-tree (%kind-store cp :git) id) id))))))

(defun %same-files-p (cp a b)
  "True when A and B (FILES-STATEs or CHECKPOINTs) have the same files (see
\"Same files\")."
  (multiple-value-bind (ka ia) (%files-key cp a)
    (multiple-value-bind (kb ib) (%files-key cp b)
      (and (eq ka kb)
           (or (string= ia ib)
               (and (eq ka :jj)
                    (diff:diff-empty-p
                     (rev:state-diff (%kind-store cp :jj) ia ib :level :summary))))))))

(defun %copy-blobs (from to id)
  "Make the snapshot ID of the pathlib store FROM readable in the store TO."
  (unless (eq from to)
    (dolist (blob (p:snapshot-reachable-ids from (list id)))
      (unless (p:snapshot-store-contains-p to blob)
        (p:snapshot-store-put to (p:snapshot-store-get from blob))))))

(defun %git-ref-name (store ordinal)
  (format nil "~a~a/~d" +checkpoint-ref-prefix+ (session-id store) ordinal))

(defun %record-files (cp store cs ordinal files)
  "Record the files part of checkpoint ORDINAL: FILES (a FILES-STATE read
earlier) or the files now. → (values kind files-id part-store)."
  (let ((kind (if files (files-state-kind files) (checkpointer-kind cp))))
    (ecase kind
      (:copy
       (let* ((blobs (%blob-store cs))
              (state (or files (%read-files cp blobs))))
         (when (files-state-tree state)
           (%copy-blobs (files-state-tree state) blobs (files-state-id state)))
         (values :copy (files-state-id state) nil)))
      (:git
       (let* ((git (%kind-store cp :git))
              (ref (%git-ref-name store ordinal))
              (message (format nil "cl-stack-code checkpoint ~a ~d" (session-id store) ordinal))
              (head (rev:target-revisions (git:make-git-working-copy git)))
              (id (if files
                      (let ((commit (rev:revision-id
                                     (rev:commit-revision git (files-state-id files)
                                                          :parents head :message message))))
                        (%cas-ref git ref commit nil)
                        commit)
                      (rev:revision-id
                       (rev:capture-revision (git:make-git-working-copy git :stamp-ref ref) git
                                             :parents head :message message)))))
         (values :git id git)))
      (:jj
       (let ((state (or files (%read-files cp nil))))
         (values :jj (files-state-id state) (%kind-store cp :jj)))))))

;;; Recording.

(defun record-checkpoint (checkpointer store reason &key turn files)
  "Record a checkpoint in the SESSION-STORE STORE. → the CHECKPOINT. REASON one
of +CHECKPOINT-REASONS+; TURN a session revision (or its id) for the
conversation part, NIL for none; FILES a FILES-STATE (default: read now).
Then GC-CHECKPOINTS. Works whether or not CHECKPOINTER is enabled."
  (check-type checkpointer checkpointer)
  (check-type store session-store)
  (unless (member reason +checkpoint-reasons+)
    (error 'type-error :datum reason :expected-type (cons 'member +checkpoint-reasons+)))
  (check-type files (or null files-state))
  (let* ((cs (checkpoint-store store))
         (turn-id (%revision-designator-id store turn)))
    (%call-checkpoint-writing
     cs
     (lambda ()
       (let* ((tip (%tip-revision cs))
              (tip-id (and tip (rev:revision-id tip)))
              (ordinal (1+ (if tip (%ordinal tip) 0)))
              (turn (and turn-id (rev:resolve-revision store turn-id))))
         (multiple-value-bind (kind files-id part-store)
             (%record-files checkpointer store cs ordinal files)
           (let* ((files-part
                    (if (eq kind :jj)
                        ;; A jj revision id is its change id; the part keeps the
                        ;; commit id, which names this snapshot for ever.
                        (make-instance 'rev:manifest-part :role :files :store part-store
                                                          :revision-id files-id)
                        (rev:make-manifest-part :files part-store files-id)))
                  (parts (cons files-part
                               (and turn (list (%conversation-part store (rev:revision-id turn))))))
                  (revision
                    (rev:commit-composite
                     cs parts
                     :ref +checkpoint-ref+
                     :parents (and tip-id (list tip-id))
                     :expected tip-id
                     :message (if turn (or (rev:revision-message turn) "") "session start")
                     :provenance (list :kind :checkpoint :reason reason
                                       :turn (if turn
                                                 (length (session-line store (rev:revision-id turn)))
                                                 0)
                                       :ordinal ordinal :files-kind kind :version +version+))))
             (setf (%checkpoint-store-base cs) (rev:revision-id revision))
             (gc-checkpoints checkpointer store)
             (%revision-checkpoint revision (%expired-ordinal cs)))))))))

(defun begin-checkpoint-turn (checkpointer store)
  "Before a turn: → the FILES-STATE now, or NIL when CHECKPOINTER is disabled."
  (when (checkpointer-enabled-p checkpointer)
    (let ((pre (read-files-state checkpointer store)))
      (when (eq :copy (files-state-kind pre))
        (push (files-state-id pre) (%checkpointer-pending checkpointer)))
      pre)))

(defun %turn-unchanged-p (cp post pre tip)
  (or (%same-files-p cp post pre)
      (and tip (%same-files-p cp post tip))))

(defun end-checkpoint-turn (checkpointer store pre turn)
  "After TURN (a committed session revision) ran: → the checkpoints recorded,
oldest first (see \"Turns\")."
  (when pre
    (unwind-protect
         (let ((post (read-files-state checkpointer store)))
           ;; Nothing to record: no lock, no file.
           (unless (%turn-unchanged-p checkpointer post pre (tip-checkpoint store))
             (%call-checkpoint-writing
              (checkpoint-store store)
              (lambda ()
                (let ((tip (tip-checkpoint store)))
                  (unless (%turn-unchanged-p checkpointer post pre tip)
                    (let ((turn (rev:resolve-revision store (%revision-designator-id store turn))))
                      (append
                       (when (or (null tip) (not (%same-files-p checkpointer tip pre)))
                         (list (record-checkpoint checkpointer store :before
                                                  :turn (first (rev:revision-parent-ids turn))
                                                  :files pre)))
                       ;; git: the files now, through CAPTURE-REVISION.
                       (list (record-checkpoint checkpointer store :turn
                                                :turn turn
                                                :files (unless (eq :git (files-state-kind post))
                                                         post)))))))))))
      (setf (%checkpointer-pending checkpointer)
            (remove (files-state-id pre) (%checkpointer-pending checkpointer)
                    :test #'equal :count 1)))))

(defun record-plan-checkpoints (checkpointer store pre turn)
  "After an approved plan: record :PLAN-BEFORE (PRE) and :PLAN-AFTER (now) with
TURN as the conversation part. → them, or NIL when PRE is NIL (see \"Plan
mode\")."
  (when pre
    (%call-checkpoint-writing
     (checkpoint-store store)
     (lambda ()
       (list (record-checkpoint checkpointer store :plan-before :turn turn :files pre)
             (record-checkpoint checkpointer store :plan-after :turn turn))))))

(defun %expire-files (cp store cs expired retained)
  "Delete what the product owns of the EXPIRED checkpoint revisions (see
\"Retention\"); RETAINED are the ones that stay."
  (let ((kinds (mapcar #'%files-kind expired)))
    (when (member :git kinds)
      (let ((git (%kind-store cp :git)))
        (loop for r in expired
              for kind in kinds
              when (eq kind :git)
                ;; `git update-ref -d`: git's own gc prunes the objects later.
                do (git:run-git git (list "update-ref" "-d" (%git-ref-name store (%ordinal r)))
                                :ok-exit-codes '(0 1)))))
    (when (member :copy kinds)
      (let* ((blobs (%blob-store cs))
             (live (make-hash-table :test 'equal))
             (keep (append (remove-if-not (lambda (id) (p:snapshot-store-contains-p blobs id))
                                          (%checkpointer-pending cp))
                           (loop for r in retained
                                 when (eq :copy (%files-kind r))
                                   collect (%revision-files-id r)))))
        (dolist (id (p:snapshot-reachable-ids blobs keep))
          (setf (gethash id live) t))
        (dolist (id (p:snapshot-store-ids blobs))
          (unless (gethash id live)
            (p:snapshot-store-delete blobs id)))))))

(defun gc-checkpoints (checkpointer store)
  "Expire the checkpoints of STORE beyond CHECKPOINTER-KEEP. → the number
newly expired (see \"Retention\")."
  (let ((cs (checkpoint-store store)))
    (%call-checkpoint-writing
     cs
     (lambda ()
       (let* ((chain (%chain cs))
              (cut (- (length chain) (checkpointer-keep checkpointer)))
              (old (%expired-ordinal cs))
              (newest (and (plusp cut) (nth (1- cut) chain))))
         (if (or (null newest) (<= (%ordinal newest) old))
             0
             (let ((expired (remove-if-not (lambda (r) (< old (%ordinal r) (1+ (%ordinal newest))))
                                           chain)))
               (%expire-files checkpointer store cs expired (nthcdr cut chain))
               (rev:move-ref cs +expired-ref+ (rev:revision-id newest))
               (length expired))))))))

;;; The files at a turn.

(defun %resolve-at (store at)
  "→ the revision id AT names, NIL for \"0\" (see \"The files at a turn\")."
  (if (equal at "0")
      nil
      (rev:revision-id (resolve-turn store at))))

(defun turn-checkpoint (store at)
  "→ the CHECKPOINT holding the files at turn AT, or NIL (see \"The files at a
turn\")."
  (let* ((at-id (%resolve-at store at))
         (depth (make-hash-table :test 'equal))
         (all (session-checkpoints store :all t))
         (best nil)
         (best-depth -1))
    (when at-id
      (loop for r in (session-line store at-id)
            for i from 1
            do (setf (gethash (rev:revision-id r) depth) i)))
    (dolist (k all)
      (let ((d (if (checkpoint-turn-id k) (gethash (checkpoint-turn-id k) depth) 0)))
        ;; Oldest first, so >= keeps the most recently recorded among equals.
        (when (and d (>= d best-depth))
          (setf best k best-depth d))))
    (or best
        (let ((first (first all)))
          (and first
               (or (null at-id)
                   (and (checkpoint-turn-id first)
                        (member at-id (session-line store (checkpoint-turn-id first))
                                :key #'rev:revision-id :test #'equal)))
               first)))))

;;; Rewind.

(defvar *%rewind-diff-hook* nil
  "NIL, or a function of the rewind plan, called before each approval of a
files rewind (headless text mode keeps that plan's PLAN-DIFF-TEXT).")

(defun %checkpoint-snapshot (cp store checkpoint into)
  "→ CHECKPOINT's files as a snapshot id in the pathlib store INTO (:git / :jj
read through the backend's revision filesystem). Files that are gone →
CHECKPOINT-EXPIRED."
  (flet ((expired ()
           (error 'checkpoint-expired :session (session-id store) :checkpoint checkpoint)))
    (when (checkpoint-expired-p checkpoint)
      (expired))
    (let ((id (checkpoint-files-id checkpoint)))
      (ecase (checkpoint-files-kind checkpoint)
        (:copy
         (let ((blobs (%blob-store (checkpoint-store store))))
           (unless (p:snapshot-store-contains-p blobs id)
             (expired))
           (handler-case (%copy-blobs blobs into id)
             (p:snapshot-not-found () (expired)))
           id))
        (:git
         (let ((path (handler-case (git:revision-path (%kind-store cp :git) id)
                       ((or rev:revision-error git:git-command-error) () (expired)))))
           (p:snapshot path :ignore :auto :store into)))
        (:jj
         (let ((path (handler-case (jj:revision-path (%kind-store cp :jj) id)
                       ((or rev:revision-error jj:jj-command-error) () (expired)))))
           (p:snapshot path :ignore :auto :store into)))))))

(defun %checkpoint-paths (cp store from to)
  "The paths whose files differ between the checkpoints FROM and TO."
  (let ((ms (p:make-memory-snapshot-store)))
    (mapcar #'p:fs-change-path
            (p:snapshot-changes (%checkpoint-snapshot cp store from ms)
                                (%checkpoint-snapshot cp store to ms)
                                :store ms))))

(defun %open-rewind-plan (cp store target tip)
  "An H5a :copy plan whose base is TIP's files and whose area holds TARGET's
(see \"Rewind\"), written to plan.sexp. Nothing of it stays on an error."
  (let* ((project (checkpointer-project-dir cp))
         (id (%session-id))
         (directory (uiop:merge-pathnames*
                     (format nil "~a/" id)
                     (plans-directory project :data-dir (checkpointer-data-dir cp))))
         (plan (make-instance 'plan :id id :kind :copy :project-dir project
                                    :root (uiop:merge-pathnames* "tree/" directory)
                                    :base nil :status :open :session-id (session-id store)
                                    :directory directory :opened-at (get-universal-time)
                                    :rewind (list :session (session-id store)
                                                  :to (checkpoint-id target)
                                                  :from (checkpoint-id tip))))
         (done nil))
    (unwind-protect
         (let ((plans-store (%copy-store plan)))
           (ensure-directories-exist directory)
           (setf (plan-base plan) (%checkpoint-snapshot cp store tip plans-store))
           (p:restore-snapshot (uiop:native-namestring (plan-root plan))
                               (%checkpoint-snapshot cp store target plans-store)
                               :store plans-store)
           (%write-plan-file plan)
           (setf done t)
           plan)
      (unless done
        (%undo-open plan)))))

(defun %rewind-empty-p (plan)
  "True when the working copy already has the area's version of every path
the rewind plan changes."
  (%with-plan-store (plan)
    (let* ((base (%base-view plan))
           (area (%area-view plan))
           (working (%working-view plan)))
      (every (lambda (change)
               (%entry= (%at working (second change)) (%at area (second change))))
             (%changes plan base area)))))

(defun %rewind-files (cp store at)
  "The files part of REWIND-TO. → (values files changes conflicts drift)."
  (let ((target (turn-checkpoint store at)))
    (unless target
      (error 'checkpoint-not-found :session (session-id store) :designator at))
    (when (checkpoint-expired-p target)
      (error 'checkpoint-expired :session (session-id store) :checkpoint target))
    (let ((plan (%open-rewind-plan cp store target (tip-checkpoint store)))
          (drift nil)
          (conflicts nil)
          (rebased nil))
      (flet ((approve ()
               (when *%rewind-diff-hook*
                 (funcall *%rewind-diff-hook* plan))
               ;; Declines: the caller's handler picks H5a's restart.
               (handler-bind ((plan-drift (lambda (c)
                                            (when (and (eq plan (plan-error-plan c)) (null drift))
                                              (setf drift (plan-drift-paths c))))))
                 (approve-plan plan))))
        (unwind-protect
             (if (%rewind-empty-p plan)
                 (progn (reject-plan plan)
                        (values :empty nil nil nil))
                 (loop
                   (multiple-value-bind (result status) (approve)
                     (ecase status
                       ((:applied :empty)
                        (return (values (if rebased :merged status)
                                        (if (eq status :applied) result nil)
                                        conflicts drift)))
                       (:rebased
                        ;; The merge is in the area: approve again at once.
                        (setf rebased t
                              conflicts (union conflicts result :test #'equal)))
                       (:aborted
                        (reject-plan plan)
                        (return (values :aborted nil conflicts drift)))))))
          ;; A non-local exit (an unhandled drift): nothing written, discarded.
          (when (eq :open (plan-status plan))
            (reject-plan plan)))))))

(defun rewind-to (checkpointer store at &key (parts +rewind-parts+))
  "Rewind the SESSION-STORE STORE to turn AT, per part. → the RESULT plist
(see \"Rewind\")."
  (unless (and (consp parts)
               (every (lambda (part) (member part '(:conversation :files))) parts))
    (error 'type-error :datum parts :expected-type '(cons (member :conversation :files) list)))
  (let* ((at-id (%resolve-at store at))
         (turn (if at-id (length (session-line store at-id)) 0))
         (conversation-p (member :conversation parts))
         (files-p (member :files parts)))
    (when conversation-p
      (sync-session store)
      (let* ((head (session-head store))
             (head-id (and head (rev:revision-id head))))
        (unless (equal head-id (session-base store))
          (error 'session-conflict :session (session-id store)
                                   :expected (session-base store) :actual head-id))))
    (multiple-value-bind (files changes conflicts drift)
        (if files-p
            (%rewind-files checkpointer store at)
            (values :skipped nil nil nil))
      (let* ((conversation (cond ((not conversation-p) :skipped)
                                 ((eq files :aborted) :unchanged)
                                 ((equal at-id (session-base store)) :unchanged)
                                 (t (move-session-head store at-id) :moved)))
             (checkpoint (and (member files '(:applied :merged))
                              (checkpointer-enabled-p checkpointer)
                              (record-checkpoint checkpointer store :rewind
                                                 :turn (session-head store)))))
        (list :turn turn :parts (copy-list parts) :conversation conversation :files files
              :changes changes :conflicts conflicts :drift drift :checkpoint checkpoint)))))

(defun rewind-description (result)
  "→ the phrase for a REWIND-TO RESULT (see \"Rewind\")."
  (let* ((conversation (getf result :conversation))
         (files (getf result :files))
         (n (length (getf result :changes)))
         (files-text
           (case files
             (:empty "files (no changes)")
             (:applied (format nil "files (~d file~:p changed)" n))
             (:merged (format nil "files (~d file~:p changed, merged with the working copy~@[; conflicts in ~{~a~^, ~}~])"
                              n (getf result :conflicts)))))
         (conversation-p (and conversation (not (eq conversation :skipped)))))
    (cond ((eq files :aborted) "nothing restored")
          ((and conversation-p files-text) (concatenate 'string "conversation and " files-text))
          (conversation-p "conversation")
          (files-text files-text)
          (t "nothing restored"))))

;;; Views.

(defun %reason-label (reason)
  (ecase reason
    (:before "before")
    (:turn "after")
    (:plan-before "plan-before")
    (:plan-after "plan-after")
    (:rewind "rewind")))

(defun checkpoint-summary-lines (store &key (width 80))
  "→ the /checkpoints and --list-checkpoints lines (see \"Views\")."
  (let ((checkpoints (reverse (session-checkpoints store)))
        (line (mapcar #'rev:revision-id (session-line store))))
    (if (null checkpoints)
        (list "no checkpoints yet")
        (mapcar (lambda (k)
                  (let ((id (checkpoint-id k))
                        (turn-id (checkpoint-turn-id k)))
                    (%cut (format nil "~a ~a turn ~d ~a ~a"
                                  (if (or (null turn-id) (member turn-id line :test #'equal)) "●" "○")
                                  (subseq id 0 (min 8 (length id)))
                                  (checkpoint-turn k)
                                  (%reason-label (checkpoint-reason k))
                                  (checkpoint-message k))
                          width)))
                checkpoints))))

;;; Plan mode.

(defun %approve-plan-with-checkpoints (plan message checkpointer)
  "APPROVE-PLAN :CHECKPOINTER (see \"Plan mode\")."
  ;; PRE before anything is written; :copy blobs go to the plans' store
  ;; (RECORD-PLAN-CHECKPOINTS copies them into the session's).
  (let ((pre (%read-files checkpointer
                          (p:make-directory-snapshot-store
                           (uiop:native-namestring
                            (uiop:merge-pathnames* "store/" (%plans-dir-of plan)))))))
    (multiple-value-bind (result status) (approve-plan plan :message message)
      (values result status (and (eq status :applied) pre)))))
