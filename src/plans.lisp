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

;;; Implementation. Every rule below is written once over VIEWS: a view is
;;; one side of a plan (its base, its area now, or the working copy now) as
;;; a table path → entry (mode :FILE / :EXECUTABLE / :SYMLINK and a content
;;; id). The three views of one plan share a hash domain (:copy: pathlib
;;; sha256 digests in the plans' snapshot store; :git: git blob ids), so equal
;;; mode and id is equal content. Only producing views and the lifecycle
;;; (open, new base, approved commit, area removal) differ per kind.

(defstruct (%entry (:constructor %make-entry (path mode hash)))
  (path "" :type string)                ; relative POSIX path
  (mode :file :type (member :file :executable :symlink))
  (hash "" :type string))

(defstruct (%view (:constructor %make-view (kind table octets handle)))
  kind                                  ; :COPY or :GIT
  table                                 ; EQUAL hash table path → %ENTRY
  octets                                ; function %ENTRY → its content octets
  handle)                               ; :copy the snapshot id; :git the GIT-PROJECTION

(defun %at (view path)
  (gethash path (%view-table view)))

(defun %entry-octets (view entry)
  (funcall (%view-octets view) entry))

(defun %entry= (a b)
  "Equal entries (NIL, absent, equals NIL)."
  (or (and (null a) (null b))
      (and a b
           (eq (%entry-mode a) (%entry-mode b))
           (string= (%entry-hash a) (%entry-hash b)))))

(defun %table (entries)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (e entries table)
      (setf (gethash (%entry-path e) table) e))))

(defun %view-paths (&rest views)
  "Every path of VIEWS, sorted (STRING<)."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (v views)
      (loop for path being the hash-keys of (%view-table v)
            do (setf (gethash path seen) t)))
    (sort (loop for path being the hash-keys of seen collect path) #'string<)))

(defun %change-kind (old new)
  "pathlib's change rule between two entries, or NIL when equal."
  (cond ((%entry= old new) nil)
        ((null old) :added)
        ((null new) :removed)
        ((and (string= (%entry-hash old) (%entry-hash new))
              (member (%entry-mode old) '(:file :executable))
              (member (%entry-mode new) '(:file :executable)))
         :mode-changed)
        (t :modified)))

;;; Files and directories.

(defun %local-fs () (p:make-local-filesystem))

(defun %plans-dir-of (plan)
  (uiop:pathname-parent-directory-pathname (plan-directory plan)))

(defun %plan-file (directory)
  (merge-pathnames "plan.sexp" directory))

(defun %plan-ref (plan)
  (concatenate 'string +plan-ref-prefix+ (plan-id plan)))

(defun %plan-fail (plan control &rest args)
  (error 'plan-error :plan plan :message (apply #'format nil control args)))

(defun %under (top rel)
  "The file pathname of the relative POSIX path REL under directory TOP."
  (uiop:merge-pathnames* (uiop:parse-unix-namestring rel) top))

(defun %set-executable (pathname executable)
  "Make the regular file PATHNAME's execute bits follow EXECUTABLE (owner +x,
and group / other +x where readable, as git does; clear all three)."
  (let* ((fs (%local-fs))
         (mode (p:file-stat-mode (p:fs-stat fs pathname :follow-symlinks nil))))
    (when mode
      (let* ((perm (logand mode #o7777))
             (new (if executable
                      (logior perm #o100 (ash (logand perm #o044) -2))
                      (logandc2 perm #o111))))
        (unless (= new perm)
          #+(and sbcl unix) (sb-posix:chmod (uiop:native-namestring pathname) new)
          #-(and sbcl unix)
          (uiop:run-program (list "chmod" (format nil "~o" new)
                                  (uiop:native-namestring pathname))))))))

(defun %prune-empty-parents (top rel)
  "Remove the parent directories of REL under TOP left empty, bottom-up;
never TOP."
  (let ((fs (%local-fs)))
    (loop for k = (position #\/ rel :from-end t) then (position #\/ rel :from-end t :end k)
          while (and k (plusp k))
          do (let ((dir (uiop:ensure-directory-pathname (%under top (subseq rel 0 k)))))
               (if (and (p:fs-directory-p fs dir)
                        (not (p:fs-symlink-p fs (%under top (subseq rel 0 k))))
                        (null (p:fs-iterdir fs dir)))
                   (p:fs-rmdir fs dir)
                   (return))))))

(defun %remove-entry (top rel)
  "Delete the file or symlink REL under TOP (if any), then the directories
it leaves empty."
  (let ((fs (%local-fs))
        (pn (%under top rel)))
    (when (or (p:fs-symlink-p fs pn) (p:fs-file-p fs pn))
      (p:fs-unlink fs pn :missing-ok t))
    (%prune-empty-parents top rel)))

(defun %write-entry (top rel mode octets &key (expected-hash nil expected-p))
  "Make REL under TOP hold OCTETS with MODE (a symlink's octets are its UTF-8
target). EXPECTED-HASH (when given) goes to FS-WRITE-ATOMIC."
  (let ((fs (%local-fs))
        (pn (%under top rel)))
    (ecase mode
      (:symlink
       (when (or (p:fs-symlink-p fs pn) (p:fs-file-p fs pn))
         (p:fs-unlink fs pn))
       (ensure-directories-exist pn)
       (p:fs-create-symlink fs pn (p:utf8-decode octets)))
      ((:file :executable)
       ;; FS-WRITE-ATOMIC writes through a symlink: drop one first.
       (when (p:fs-symlink-p fs pn)
         (p:fs-unlink fs pn))
       (if expected-p
           (p:fs-write-atomic fs pn octets :expected-hash expected-hash)
           (p:fs-write-atomic fs pn octets))
       (%set-executable pn (eq mode :executable))))))

;;; plan.sexp

(defun %write-plan-file (plan)
  (let ((form (list :format +plan-format+
                    :id (plan-id plan)
                    :kind (plan-kind plan)
                    :project-dir (uiop:native-namestring (plan-project-dir plan))
                    :root (uiop:native-namestring (plan-root plan))
                    :base (plan-base plan)
                    :status (plan-status plan)
                    :session (plan-session-id plan)
                    :opened-at (plan-opened-at plan)
                    :version +version+)))
    (p:write-text (%plan-file (plan-directory plan))
                  (with-standard-io-syntax
                    (let ((*package* (find-package :keyword)))
                      (format nil "~s~%" form)))
                  :atomic t)
    plan))

(defun %read-plan-file (directory)
  "The PLAN in DIRECTORY's plan.sexp. Missing → NIL; unreadable → PLAN-ERROR
naming the file."
  (let ((file (%plan-file directory)))
    (unless (probe-file file)
      (return-from %read-plan-file nil))
    (flet ((bad (e)
             (error 'plan-error
                    :message (format nil "plan file ~a is unreadable: ~a"
                                     (uiop:native-namestring file) e))))
      (let ((form (handler-case
                      (with-standard-io-syntax
                        (let ((*package* (find-package :keyword))
                              (*read-eval* nil))
                          (read-from-string (uiop:read-file-string file :external-format :utf-8))))
                    (error (e) (bad e)))))
        (destructuring-bind (&key format id kind project-dir root base status session opened-at
                             &allow-other-keys)
            (if (%plist-p form) form (bad "not a property list"))
          (unless (and (eql format +plan-format+)
                       (stringp id) (member kind '(:copy :git))
                       (stringp project-dir) (stringp root) (stringp base)
                       (member status '(:open :applied :discarded))
                       (or (null session) (stringp session))
                       (integerp opened-at))
            (bad "unexpected contents"))
          (make-instance 'plan
                         :id id :kind kind
                         :project-dir (uiop:parse-native-namestring project-dir :ensure-directory t)
                         :root (uiop:parse-native-namestring root :ensure-directory t)
                         :base base :status status :session-id session
                         :directory (uiop:ensure-directory-pathname directory)
                         :opened-at opened-at))))))

;;; Stores.

(defun %copy-store (plan)
  (or (%plan-store plan)
      (setf (%plan-store plan)
            (p:make-directory-snapshot-store
             (uiop:merge-pathnames* "store/" (%plans-dir-of plan))))))

(defun %git-store (plan)
  (or (%plan-store plan)
      (setf (%plan-store plan) (git:make-git-store (plan-project-dir plan)))))

(defun %release-store (plan)
  "Stop the git store's batch process (the store stays usable)."
  (let ((store (%plan-store plan)))
    (when (git:git-store-p store)
      (git:close-git-store store))))

(defmacro %with-plan-store ((plan) &body body)
  `(unwind-protect (progn ,@body)
     (%release-store ,plan)))

;;; Views.

(defun %snapshot-view (store id)
  (%make-view :copy
              (%table (mapcar (lambda (e)
                                (%make-entry (p:snapshot-entry-path e)
                                             (p:snapshot-entry-mode e)
                                             (p:snapshot-entry-hash e)))
                              (p:snapshot-entries id :store store)))
              (lambda (entry) (p:snapshot-store-get store (%entry-hash entry)))
              id))

(defun %copy-snapshot (plan directory)
  "FS-SNAPSHOT of DIRECTORY (:IGNORE :AUTO) into the plans' store → its id."
  (p:fs-snapshot (%local-fs) directory :ignore :auto :store (%copy-store plan)))

(defun %git-view (store tree projection)
  (%make-view :git
              (%table (loop for e in (git:parse-ls-tree
                                      (git:run-git store (list "ls-tree" "-r" "-z" tree)))
                            for mode = (and (eq :blob (getf e :type))
                                            (case (getf e :mode)
                                              (#o100644 :file)
                                              (#o100755 :executable)
                                              (#o120000 :symlink)))
                            when mode
                              collect (%make-entry (getf e :path) mode (getf e :id))))
              (lambda (entry)
                (git:run-git store (list "cat-file" "blob" (%entry-hash entry)) :output :octets))
              projection))

(defun %git-worktree-view (store worktree-store)
  "The view of what `git add -A` would record in WORKTREE-STORE's worktree."
  (let ((projection (rev:project-state worktree-store (git:make-git-working-copy worktree-store))))
    (%git-view store (git:git-projection-tree projection) projection)))

(defun %git-commit-tree (store commit)
  (string-trim '(#\Newline #\Return)
               (git:run-git store (list "rev-parse" "--verify" (format nil "~a^{tree}" commit)))))

(defun %base-view (plan)
  (ecase (plan-kind plan)
    (:copy (%snapshot-view (%copy-store plan) (plan-base plan)))
    (:git (let ((store (%git-store plan)))
            (%git-view store (%git-commit-tree store (plan-base plan)) nil)))))

(defun %area-view (plan)
  (ecase (plan-kind plan)
    (:copy (%snapshot-view (%copy-store plan) (%copy-snapshot plan (plan-root plan))))
    (:git (git:with-git-store (area (plan-root plan))
            (%git-worktree-view (%git-store plan) area)))))

(defun %working-view (plan)
  (ecase (plan-kind plan)
    (:copy (%snapshot-view (%copy-store plan) (%copy-snapshot plan (plan-project-dir plan))))
    (:git (let ((store (%git-store plan)))
            (%git-worktree-view store store)))))

(defun %changes (plan base area)
  "((KIND PATH) …) from BASE to AREA, sorted by path."
  (ecase (plan-kind plan)
    (:copy
     (mapcar (lambda (c) (list (p:fs-change-kind c) (p:fs-change-path c)))
             (p:snapshot-changes (%view-handle base) (%view-handle area)
                                 :store (%copy-store plan))))
    (:git
     (loop for path in (%view-paths base area)
           for kind = (%change-kind (%at base path) (%at area path))
           when kind collect (list kind path)))))

(defun %content-hash (view entry)
  "The pathlib digest of ENTRY's content."
  (if (eq :copy (%view-kind view))
      (%entry-hash entry)
      (p:octets-hash (%entry-octets view entry))))

;;; Text, the diff.

(defun %text-or-nil (octets)
  "OCTETS as a string when they are valid UTF-8 with no NUL in the first
8000 octets, else NIL."
  (unless (find 0 octets :end (min 8000 (length octets)))
    (handler-case (p:utf8-decode-strict octets)
      (p:utf8-decoding-error () nil))))

(defun %entry-text (view entry)
  "ENTRY's text (a regular file's), or NIL when it is binary or a symlink."
  (and entry (member (%entry-mode entry) '(:file :executable))
       (%text-or-nil (%entry-octets view entry))))

(defun %diff-node (view entry)
  (let ((octets (%entry-octets view entry)))
    (if (eq :symlink (%entry-mode entry))
        (diff:make-tree-file (p:utf8-decode octets) :type :text :mode #o120000)
        (let ((mode (if (eq :executable (%entry-mode entry)) #o100755 #o100644))
              (text (%text-or-nil octets)))
          (if text
              (diff:make-tree-file text :type :text :mode mode)
              (diff:make-tree-file octets :type :binary :mode mode))))))

(defun %diff-tree (pairs)
  "A diff-protocol tree of PAIRS ((relative-path . file-node) …)."
  (let ((groups '()))
    (dolist (pair pairs)
      (let* ((path (car pair))
             (slash (position #\/ path)))
        (if slash
            (let* ((name (subseq path 0 slash))
                   (group (assoc name groups :test #'string=)))
              (unless group
                (setf group (list name :directory))
                (push group groups))
              (push (cons (subseq path (1+ slash)) (cdr pair)) (cddr group)))
            (push (list path :file (cdr pair)) groups))))
    (apply #'diff:make-tree
           (loop for (name kind . more) in (reverse groups)
                 append (list name (if (eq kind :file)
                                       (first more)
                                       (%diff-tree (reverse more))))))))

(defun %side-tree (view paths)
  (%diff-tree (loop for path in paths
                    for entry = (%at view path)
                    when entry collect (cons path (%diff-node view entry)))))

(defun %compute-diff (base area changes)
  (let ((paths (mapcar #'second changes)))
    (diff:compute-diff (make-instance 'diff:tree-diff-engine :detect-renames nil)
                       (%side-tree base paths) (%side-tree area paths)
                       :level :changes :context 3)))

;;; Public functions.

(defun plans-directory (cwd &key data-dir)
  "→ <data-dir>/plans/<project-key>/ for the project of CWD (DATA-DIR
defaults to USER-DATA-DIRECTORY)."
  (let* ((cwd (uiop:ensure-directory-pathname cwd))
         (project (or (find-project-root cwd) (probe-file cwd) cwd))
         (data (uiop:ensure-directory-pathname (or data-dir (user-data-directory)))))
    (uiop:merge-pathnames* (uiop:parse-unix-namestring
                            (format nil "plans/~a/" (project-session-key project)))
                           data)))

(defun %choose-kind (project kind)
  "→ (values :git store) or (values :copy NIL) for the directory PROJECT."
  (let ((store (and (member kind '(:auto :git))
                    (handler-case (git:make-git-store project)
                      ((or git:git-command-error git:vc-tool-version-error rev:revision-error) ()
                        nil)))))
    (if (and store
             (git:git-store-path store)
             (equal (uiop:native-namestring (%truename-directory (git:git-store-path store)))
                    (uiop:native-namestring project)))
        (values :git store)
        (progn
          (when store (git:close-git-store store))
          (when (eq kind :git)
            (error 'plan-error
                   :message (format nil "~a is not a git worktree"
                                    (uiop:native-namestring project))))
          (values :copy nil)))))

(defun %open-copy (plan)
  (let ((area (p:fs-open-area (%local-fs) (plan-project-dir plan)
                              :mechanism :copy :ignore :auto :directory (plan-root plan))))
    (p:fs-close-area area :action :keep))
  (setf (plan-base plan) (%copy-snapshot plan (plan-root plan))))

(defun %cas-ref (store ref new old)
  "Move REF from OLD (NIL: it must not exist) to NEW (NIL: delete it) with
git's own compare-and-swap; a mismatch is git's GIT-COMMAND-ERROR."
  (let ((zero (make-string (length (or new old)) :initial-element #\0)))
    (git:run-git store (if new
                           (list "update-ref" ref new (or old zero))
                           (list "update-ref" "-d" ref old)))))

(defun %commit-base (plan store projection)
  "Commit PROJECTION (a working-copy state, parents = HEAD or none) as the
plan's base. → the commit id."
  (rev:revision-id
   (rev:commit-projection store projection
                          :message (format nil "cl-stack-code plan ~a base" (plan-id plan)))))

(defun %open-git (plan)
  (let* ((store (%git-store plan))
         (projection (rev:project-state store (git:make-git-working-copy store)))
         (base (%commit-base plan store projection)))
    (%cas-ref store (%plan-ref plan) base nil)
    (setf (plan-base plan) base)
    (git:close-git-store (git:add-worktree store (plan-root plan) base))))

(defun %remove-area (plan)
  "Remove PLAN's area (and, for :git, its linked worktree)."
  (let ((root (plan-root plan)))
    (ecase (plan-kind plan)
      (:copy
       (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))
      (:git
       (let ((store (%git-store plan)))
         (if (uiop:directory-exists-p root)
             (git:remove-worktree store root :force t)
             (git:run-git store '("worktree" "prune"))))))))

(defun %undo-open (plan)
  "Best effort after a failed OPEN-PLAN: nothing of the plan stays behind."
  (ignore-errors
   (when (and (eq :git (plan-kind plan)) (plan-base plan))
     (when (uiop:directory-exists-p (plan-root plan))
       (%remove-area plan))
     (%cas-ref (%git-store plan) (%plan-ref plan) nil (plan-base plan))))
  (ignore-errors (%release-store plan))
  (ignore-errors
   (uiop:delete-directory-tree (plan-directory plan) :validate t :if-does-not-exist :ignore)))

(defun open-plan (project-dir &key (kind :auto) data-dir session-id id)
  "→ a new open PLAN over PROJECT-DIR (see the top of the file)."
  (check-type kind (member :auto :git :copy))
  (let* ((project (%truename-directory project-dir))
         (plans-dir (plans-directory project :data-dir data-dir))
         (id (cond ((null id) (%session-id))
                   ((normalize-session-id id))
                   (t (error 'plan-error
                             :message (format nil "bad plan id ~s: use 32 hex digits" id)))))
         (directory (uiop:merge-pathnames* (format nil "~a/" id) plans-dir)))
    (when (uiop:directory-exists-p directory)
      (error 'plan-error :message (format nil "plan ~a already exists" id)))
    (multiple-value-bind (kind store) (%choose-kind project kind)
      (let ((plan (make-instance 'plan :id id :kind kind :project-dir project
                                       :root (uiop:merge-pathnames* "tree/" directory)
                                       :base nil :status :open :session-id session-id
                                       :directory directory
                                       :opened-at (get-universal-time)
                                       :store store))
            (done nil))
        (unwind-protect
             (progn
               (ensure-directories-exist directory)
               (ecase kind
                 (:copy (%open-copy plan))
                 (:git (%open-git plan)))
               (%write-plan-file plan)
               (setf done t)
               plan)
          (if done
              (%release-store plan)
              (%undo-open plan)))))))

(defun reopen-plan (plans-dir id)
  "→ the open PLAN ID under PLANS-DIR; PLAN-NOT-FOUND otherwise."
  (let* ((normal (normalize-session-id id))
         (plan (and normal
                    (%read-plan-file (uiop:merge-pathnames*
                                      (format nil "~a/" normal)
                                      (uiop:ensure-directory-pathname plans-dir))))))
    (unless (and plan
                 (eq :open (plan-status plan))
                 (uiop:directory-exists-p (plan-root plan)))
      (error 'plan-not-found :designator id))
    plan))

(defun list-plans (plans-dir)
  "→ every readable PLAN under PLANS-DIR, oldest first."
  (let ((dir (uiop:directory-exists-p plans-dir)))
    (and dir
         (sort (loop for sub in (uiop:subdirectories dir)
                     for plan = (handler-case (%read-plan-file sub)
                                  (plan-error () nil))
                     when plan collect plan)
               (lambda (a b)
                 (or (< (plan-opened-at a) (plan-opened-at b))
                     (and (= (plan-opened-at a) (plan-opened-at b))
                          (string< (plan-id a) (plan-id b)))))))))

(defun plan-tool-root (plan cwd)
  "→ the directory of PLAN's area that corresponds to CWD."
  (let* ((cwd (%truename-directory cwd))
         (project (%truename-directory (plan-project-dir plan)))
         (rel (uiop:subpathp cwd project)))
    (unless rel
      (%plan-fail plan "~a is outside the project ~a of plan ~a"
                  (uiop:native-namestring cwd) (uiop:native-namestring project) (plan-id plan)))
    (uiop:ensure-directory-pathname (uiop:merge-pathnames* rel (plan-root plan)))))

(defun plan-changes (plan)
  "→ ((KIND PATH) …) from PLAN's base to its area now, sorted by PATH."
  (%with-plan-store (plan)
    (%changes plan (%base-view plan) (%area-view plan))))

(defun plan-diff (plan)
  "→ the diff-protocol tree diff of PLAN's changes."
  (%with-plan-store (plan)
    (let* ((base (%base-view plan))
           (area (%area-view plan)))
      (%compute-diff base area (%changes plan base area)))))

(defun plan-diff-text (plan)
  "→ PLAN-DIFF rendered :UNIFIED, \"\" when there are no changes."
  (%with-plan-store (plan)
    (let* ((base (%base-view plan))
           (area (%area-view plan))
           (changes (%changes plan base area)))
      (if changes
          (diff:render-diff (%compute-diff base area changes) :unified nil)
          ""))))

(defun %check-open (plan)
  (unless (eq :open (plan-status plan))
    (%plan-fail plan "plan ~a is ~(~a~), not open" (plan-id plan) (plan-status plan))))

(defun %conflicts (changes base area working)
  "Changed paths where WORKING differs from both BASE and AREA."
  (loop for (nil path) in changes
        for w = (%at working path)
        unless (or (%entry= w (%at base path)) (%entry= w (%at area path)))
          collect path))

(defun %apply (plan area working changes)
  "Step 4: give the working copy AREA's version of every changed path, CAS
against WORKING (read in step 1). No handler here: pathlib's
CONTENT-HASH-MISMATCH reaches the caller as signalled."
  (let ((top (plan-project-dir plan)))
    (loop for (kind path) in (reverse changes)
          when (eq kind :removed)
            do (%remove-entry top path))
    (loop for (kind path) in changes
          for a = (%at area path)
          for w = (%at working path)
          unless (or (eq kind :removed) (%entry= a w))
            do (%write-entry top path (%entry-mode a) (%entry-octets area a)
                             :expected-hash (if (and w (not (eq :symlink (%entry-mode w))))
                                                (%content-hash working w)
                                                :absent)))))

(defun %close-plan (plan status)
  "Step 6 / reject: remove the area, set STATUS, rewrite plan.sexp."
  (%remove-area plan)
  (when (and (eq status :discarded) (eq :git (plan-kind plan)))
    (let ((store (%git-store plan)))
      (when (plusp (length (git:run-git store (list "rev-parse" "--verify" "-q" (%plan-ref plan))
                                        :ok-exit-codes '(0 1))))
        (%cas-ref store (%plan-ref plan) nil (plan-base plan)))))
  (setf (plan-status plan) status)
  (%write-plan-file plan)
  status)

(defun %merge-path (base b area a working w)
  "A conflicting path whose three sides allow a text merge → (values octets
markers-p); otherwise NIL."
  (when (and a w
             (member (%entry-mode a) '(:file :executable))
             (eq (%entry-mode a) (%entry-mode w))
             (or (null b) (member (%entry-mode b) '(:file :executable))))
    (let ((ta (%entry-text area a))
          (tw (%entry-text working w))
          (tb (if b (%entry-text base b) "")))
      (when (and ta tw tb)
        (multiple-value-bind (text conflicts)
            (diff:merge-texts tb ta tw :ours-label "plan" :theirs-label "working copy")
          (values (p:utf8-encode text) (and conflicts t)))))))

(defun %rebase (plan base area working)
  "REBASE-PLAN: the working copy (as read in step 1) becomes the base and
the area gets the three-way merge. → (values conflicts :rebased)."
  (let ((writes '())                    ; (path mode octets) or (path NIL) = delete
        (reported '()))
    (dolist (path (%view-paths base area working))
      (let ((b (%at base path)) (a (%at area path)) (w (%at working path)))
        (cond ((%entry= a w))
              ((%entry= a b)
               (push (if w
                         (list path (%entry-mode w) (%entry-octets working w))
                         (list path nil))
                     writes))
              ((%entry= w b))
              (t
               (multiple-value-bind (octets markers-p) (%merge-path base b area a working w)
                 (cond (octets
                        (push (list path (%entry-mode a) octets) writes)
                        (when markers-p (push path reported)))
                       (t (push path reported))))))))
    ;; The new base first, so a failed ref CAS leaves the area as it was.
    (let ((new-base
            (ecase (plan-kind plan)
              (:copy (%view-handle working))
              (:git (let* ((store (%git-store plan))
                           (new (%commit-base plan store (%view-handle working))))
                      (%cas-ref store (%plan-ref plan) new (plan-base plan))
                      new))))
          (root (plan-root plan)))
      (dolist (write (reverse writes))
        (destructuring-bind (path mode &optional octets) write
          (if mode
              (%write-entry root path mode octets)
              (%remove-entry root path))))
      (when (eq :git (plan-kind plan))
        (git:with-git-store (store root)
          (rev:target-stamp (git:make-git-working-copy store) (list new-base))
          (git:run-git store (list "read-tree" new-base))))
      (setf (plan-base plan) new-base)
      (%write-plan-file plan)
      (values (sort reported #'string<) :rebased))))

(defun %record-approved-commit (plan area message)
  "Step 5 (:git): commit the area state that was applied (parents = the
base) and move the plan ref to it by CAS."
  (let* ((store (%git-store plan))
         (new (rev:revision-id
               (rev:commit-projection store (%view-handle area)
                                      :parents (list (plan-base plan))
                                      :message (or message
                                                   (format nil "cl-stack-code plan ~a"
                                                           (plan-id plan)))))))
    (%cas-ref store (%plan-ref plan) new (plan-base plan))
    new))

(defun approve-plan (plan &key message)
  "Apply PLAN to the working copy. → (values result status), status
:APPLIED, :EMPTY, :REBASED or :ABORTED; PLAN-DRIFT with restarts REBASE-PLAN,
OVERWRITE-PLAN and ABORT-APPROVAL."
  (check-type message (or null string))
  (%check-open plan)
  (%with-plan-store (plan)
    (let* ((base (%base-view plan))
           (area (%area-view plan))
           (working (%working-view plan))
           (changes (%changes plan base area))
           (conflicts (%conflicts changes base area working)))
      (when conflicts
        (restart-case (error 'plan-drift :plan plan :paths conflicts)
          (rebase-plan ()
            :report "Make the working copy the plan's base and merge the area onto it; apply nothing."
            (return-from approve-plan (%rebase plan base area working)))
          (overwrite-plan ()
            :report "Apply the plan; its version wins at the conflicting paths."
            nil)
          (abort-approval ()
            :report "Write nothing; the plan stays open."
            (return-from approve-plan (values nil :aborted)))))
      (%apply plan area working changes)
      (when (and changes (eq :git (plan-kind plan)))
        (%record-approved-commit plan area message))
      (%close-plan plan :applied)
      (if changes
          (values changes :applied)
          (values nil :empty)))))

(defun reject-plan (plan)
  "Discard PLAN's area. → :DISCARDED."
  (%check-open plan)
  (%with-plan-store (plan)
    (%close-plan plan :discarded)))

(defun plan-record (plan)
  "→ (:id S :kind K :base S :root S :status K) for the turn record."
  (list :id (plan-id plan)
        :kind (plan-kind plan)
        :base (plan-base plan)
        :root (uiop:native-namestring (plan-root plan))
        :status (plan-status plan)))
