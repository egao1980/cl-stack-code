(in-package #:cl-stack-code)

;;; H3c: sessions as a revision-protocol store.
;;;
;;; A session is one conversation, headless or interactive. Its store is a
;;; SESSION-STORE: revision-protocol's in-memory store (the graph, refs, CAS,
;;; walks and restarts are that store's) written through to a directory, so
;;; the session outlives the process. Each turn is one revision whose content
;;; is a turn record (below); the ref "head" (+HEAD-REF+) is where the next
;;; turn goes. The conversation at a revision is the fold of the records on
;;; its first-parent line, root first.
;;;
;;; Where
;;;   <data-dir>      USER-DATA-DIRECTORY: $CL_STACK_CODE_DATA_DIR, else
;;;                   $XDG_DATA_HOME/cl-stack-code/, else (Windows)
;;;                   %LOCALAPPDATA%\cl-stack-code\, else
;;;                   ~/.local/share/cl-stack-code/. Empty or relative values
;;;                   are ignored.
;;;   <sessions-dir>  SESSIONS-DIRECTORY: <data-dir>/sessions/<key>/, KEY =
;;;                   PROJECT-SESSION-KEY of the project directory (the project
;;;                   root, else the working directory, as for settings).
;;;
;;; Files in <sessions-dir>
;;;   last                         the id of the session that committed last,
;;;                                one line; --continue reads it
;;;   <id>/session.sexp            (:format 1 :id "<id>" :project-dir
;;;                                "<native namestring>" :cloned-from
;;;                                ("<session id>" "<revision id>") or NIL
;;;                                :version "<+version+>")
;;;   <id>/revisions/<rev>.sexp    one immutable file per revision:
;;;                                (:format 1 :id "<rev>" :parents ("<id>" …)
;;;                                :recorded-at (UNIX-SECONDS NANOSECONDS)
;;;                                :message "…" :provenance (…) :content (…))
;;;   <id>/refs/<name>             one file per ref: "<rev id>" LF for a
;;;                                movable ref (refs/head); "tag <rev id>" LF
;;;                                and the annotation, if any, for a tag. Ref
;;;                                names are [A-Za-z0-9._-]+; another name →
;;;                                SESSION-ERROR before anything is written
;;;   <id>/lock                    exists while a process writes:
;;;                                "<pid or 0> <universal-time>" LF
;;;
;;; Every file is written to a temporary name in its directory and renamed
;;; into place, so a reader sees the old file or the new one. A revision file
;;; is never rewritten. Files are read with *READ-EVAL* NIL and keywords only
;;; (*PACKAGE* the keyword package); a file that does not read as the plist
;;; above signals SESSION-ERROR naming it. Session ids are 32 lowercase hex
;;; characters; revision ids are the in-memory store's (40 hex), kept as they
;;; are by clones.
;;;
;;; Laziness. CREATE-SESSION touches no file: a session's directory,
;;; session.sexp and the "last" pointer are written by its first write (a
;;; commit, a ref move, a clone). A program started and quit leaves nothing.
;;;
;;; Writes and concurrency. Every write through the store (COMMIT-REVISION,
;;; MOVE-REF, TAG-REVISION, DELETE-REF on a SESSION-STORE, and the functions
;;; below that use them) runs as: take <id>/lock (create it exclusively;
;;; retry for *SESSION-LOCK-TIMEOUT* seconds, then SESSION-LOCKED; a lock whose
;;; recorded time is more than +STALE-LOCK-SECONDS+ old is removed and taken;
;;; a lock file that cannot be read or removed signals SESSION-LOCK-ERROR,
;;; with the restart BREAK-LOCK while waiting),
;;; read the revision and ref files other processes wrote since (SYNC-SESSION),
;;; run the in-memory operation, write the new revision files and the changed
;;; refs, release the lock (also on a non-local exit). The in-memory ref CAS
;;; therefore runs against the state on disk: two processes on one session
;;; cannot both move "head" from the same revision. Handlers of REF-CONFLICT
;;; run while the lock is held; REVISION-PROTOCOL:RETRY re-runs against the
;;; same synced state. Reads (SESSION-TURNS, SESSION-LINE, …) use the
;;; in-memory state as of OPEN-SESSION or the last sync.
;;;
;;; Base. Each SESSION-STORE remembers SESSION-BASE: the head id it read at
;;; OPEN-SESSION (NIL for a new or empty session), updated only by its own
;;; successful head writes (COMMIT-TURN, MOVE-SESSION-HEAD, REWIND-SESSION,
;;; FORK-TURN). A sync does not change it. Those functions default :EXPECTED
;;; to it, so a turn built on what this process saw fails with
;;; SESSION-CONFLICT when another process moved the head meanwhile.

(defparameter +head-ref+ "head"
  "The movable ref naming a session's current turn.")

(defparameter +session-format+ 1
  "The :FORMAT of session.sexp, revision files and turn records.")

(defvar *session-lock-timeout* 5
  "Seconds a write waits for a session's lock file before SESSION-LOCKED.")

(defparameter +stale-lock-seconds+ 30
  "A lock file whose recorded universal time is older than this is stale: the
next writer removes it and takes the lock.")

;;; Where sessions live.

(defun user-data-directory (&key (getenv #'uiop:getenv)
                                 (platform #+(or windows win32) :windows
                                           #-(or windows win32) :posix))
  "→ directory pathname: $CL_STACK_CODE_DATA_DIR, else
$XDG_DATA_HOME/cl-stack-code/, else on PLATFORM :WINDOWS
%LOCALAPPDATA%/cl-stack-code/, else ~/.local/share/cl-stack-code/ (under
USER-HOMEDIR-PATHNAME). Empty or relative values are ignored, as in
USER-CONFIG-DIRECTORY. PLATFORM is :WINDOWS or :POSIX."
  (check-type platform (member :windows :posix))
  (flet ((under (var)
           (let ((dir (%absolute-directory (funcall getenv var))))
             (and dir (merge-pathnames "cl-stack-code/" dir)))))
    (or (%absolute-directory (funcall getenv "CL_STACK_CODE_DATA_DIR"))
        (under "XDG_DATA_HOME")
        (and (eq platform :windows) (under "LOCALAPPDATA"))
        (merge-pathnames ".local/share/cl-stack-code/" (user-homedir-pathname)))))

(defun %ascii-alnum-p (char)
  (or (char<= #\a char #\z) (char<= #\A char #\Z) (char<= #\0 char #\9)))

(defun project-session-key (directory)
  "→ the sessions subdirectory name for DIRECTORY: its native namestring as a
directory, without the trailing separator, with every character that is not
an ASCII letter or digit replaced by #\\-.
  /Users/me/my proj/  → \"-Users-me-my-proj\"
  C:\\Users\\me\\x\\     → \"C--Users-me-x\""
  (let* ((native (uiop:native-namestring (uiop:ensure-directory-pathname directory)))
         (trimmed (string-right-trim "/\\" native))
         (key (map 'string (lambda (c) (if (%ascii-alnum-p c) c #\-)) trimmed)))
    (if (zerop (length key)) "-" key)))

(defun sessions-directory (cwd &key data-dir)
  "→ <DATA-DIR>/sessions/<PROJECT-SESSION-KEY of the project directory>/ for
working directory CWD (a directory pathname). The project directory is
FIND-PROJECT-ROOT of CWD, else CWD's truename. DATA-DIR defaults to
USER-DATA-DIRECTORY. Creates nothing."
  (let* ((cwd (uiop:ensure-directory-pathname cwd))
         (project (or (find-project-root cwd) (probe-file cwd) cwd))
         (data (uiop:ensure-directory-pathname (or data-dir (user-data-directory)))))
    (uiop:merge-pathnames* (uiop:parse-unix-namestring
                            (format nil "sessions/~a/" (project-session-key project)))
                           data)))

(defun %hex-string-p (string)
  (and (stringp string) (every (lambda (c) (digit-char-p c 16)) string)))

(defun normalize-session-id (string)
  "→ STRING as a session id (32 lowercase hex characters), or NIL. Accepts 32
hex digits in any case, or a UUID (8-4-4-4-12 hex digits, any case; the
dashes are dropped)."
  (when (stringp string)
    (cond ((and (= 32 (length string)) (%hex-string-p string))
           (string-downcase string))
          ((and (= 36 (length string))
                (every (lambda (i) (char= #\- (char string i))) '(8 13 18 23))
                (= 4 (count #\- string)))
           (let ((hex (remove #\- string)))
             (and (= 32 (length hex)) (%hex-string-p hex) (string-downcase hex))))
          (t nil))))

(defun %session-id ()
  "32 lowercase hex characters, random."
  (format nil "~(~32,'0x~)" (random (ash 1 128) (make-random-state t))))

;;; Turn records: a revision's content.

(defstruct (turn-record (:constructor make-turn-record
                            (&key prompt turns replace-p (finish :stop) model
                                  (permission-mode :default) (usage (list 0 0 0 0))
                                  steering plan (version +version+)))
                        (:conc-name record-))
  "One turn of a session. PROMPT is the user's message as typed (before @
mentions were expanded). TURNS are the LLM-TURNs the turn added to the
conversation: its user turn first, then what the run appended (assistant
turns, tool results, steering and injected instructions), never :SYSTEM
turns. REPLACE-P true means TURNS is the whole conversation from here on (a
run that rewrote its history; cl-stack-code does not enable compaction, so it
does not write such records itself). FINISH is :STOP, :MAX-STEPS, :CANCELED
or :FAILED. MODEL is the model designator the turn ran with,
PERMISSION-MODE its mode keyword, USAGE (input output cache-read
cache-write) summed over the turn's responses, STEERING the steering
messages delivered into the turn, as typed, in order. PLAN (H5a) is the
PLAN-RECORD of the plan the turn ran in (plan mode), or NIL."
  (prompt "" :type string)
  (turns '() :type list)
  (replace-p nil)
  (finish :stop :type keyword)
  (model nil)
  (permission-mode :default :type keyword)
  (usage (list 0 0 0 0) :type list)
  (steering '() :type list)
  (plan nil :type list)
  (version +version+))

(defparameter +record-finishes+ '(:stop :max-steps :canceled :failed))

(defun record-content (record)
  "→ RECORD as a revision content plist of strings, numbers, keywords and
lists:
  (:format 1 :prompt S :turns (LLM:TURN-STATE …) :replace BOOL :finish K
   :model S-or-NIL :permission-mode K :usage (I O CR CW) :steering (S …)
   :version S [:plan (:id S :kind K :base S :root S :status K)])
The :PLAN key (H5a) is present only when the record has a plan."
  (check-type record turn-record)
  (append
   (list :format +session-format+
        :prompt (record-prompt record)
        :turns (mapcar #'llm:turn-state (record-turns record))
        :replace (and (record-replace-p record) t)
        :finish (record-finish record)
        :model (record-model record)
        :permission-mode (record-permission-mode record)
        :usage (copy-list (record-usage record))
        :steering (copy-list (record-steering record))
        :version (record-version record))
   (when (record-plan record)
     (list :plan (copy-list (record-plan record))))))

(defun %malformed-record (content &optional cause)
  (error 'session-error
         :message (format nil "malformed turn record~@[ (~a)~]: ~s" cause content)))

(defun content-record (content)
  "→ the TURN-RECORD of a RECORD-CONTENT plist (turns read back with
LLM:STATE-TURN). A plist that is not one signals SESSION-ERROR."
  (unless (and (listp content) (evenp (length content))
               (handler-case (progn (getf content :format) t) (error () nil)))
    (%malformed-record content "not a plist"))
  (destructuring-bind (&key format prompt turns replace finish model permission-mode
                            usage steering version plan &allow-other-keys)
      content
    (unless (eql format +session-format+) (%malformed-record content ":format"))
    (unless (stringp prompt) (%malformed-record content ":prompt"))
    (unless (and (listp turns) (every #'listp turns)) (%malformed-record content ":turns"))
    (unless (member finish +record-finishes+) (%malformed-record content ":finish"))
    (unless (or (null model) (stringp model)) (%malformed-record content ":model"))
    (unless (keywordp permission-mode) (%malformed-record content ":permission-mode"))
    (unless (and (listp usage) (= 4 (length usage)) (every #'integerp usage))
      (%malformed-record content ":usage"))
    (unless (and (listp steering) (every #'stringp steering))
      (%malformed-record content ":steering"))
    (unless (and (listp plan) (evenp (length plan)))
      (%malformed-record content ":plan"))
    (make-turn-record :prompt prompt
                      :turns (mapcar #'llm:state-turn turns)
                      :replace-p (and replace t)
                      :finish finish
                      :model model
                      :permission-mode permission-mode
                      :usage (copy-list usage)
                      :steering (copy-list steering)
                      :plan (copy-list plan)
                      :version version)))

(defun revision-record (revision)
  "→ the TURN-RECORD of a session revision (CONTENT-RECORD of its content)."
  (content-record (rev:revision-content revision)))

;;; The store.

(defclass session-store (rev:in-memory-store)
  ((id :initarg :id :reader session-id
       :documentation "32 lowercase hex characters.")
   (directory :initarg :directory :reader session-directory
              :documentation "<sessions-dir>/<id>/ (it may not exist yet).")
   (project-dir :initarg :project-dir :initform nil :reader session-project-dir
                :documentation "The project directory (a pathname), or NIL.")
   (cloned-from :initarg :cloned-from :initform nil :reader session-cloned-from
                :documentation "(session-id revision-id) of the clone's source, or NIL.")
   (base :initarg :base :initform nil :accessor session-base
         :documentation "The head id this store read or last wrote (see the
file header), or NIL.")
   (lock :initform (bt:make-lock "cl-stack-code session") :reader %session-lock
         :documentation "Serializes this object's own writes and syncs."))
  (:documentation "A session: revision-protocol's in-memory store written
through to its directory (see the file header). Make one with CREATE-SESSION,
OPEN-SESSION or CLONE-SESSION, not MAKE-INSTANCE."))

(defun session-store-p (x)
  (typep x 'session-store))

(defmethod print-object ((store session-store) stream)
  (print-unreadable-object (store stream :type t)
    (format stream "~a" (session-id store))))

;;; Files (private). Every write: temp file in the same directory + rename
;;; (cl-stack-pathlib's atomic write). Every read: standard syntax, keywords,
;;; no read-time evaluation; anything else is a SESSION-ERROR naming the file.

(defun %session-file-error (store file control &rest args)
  (error 'session-error
         :session (and store (session-id store))
         :message (format nil "session file ~a ~?" (uiop:native-namestring file) control args)))

(defun %print-data (form)
  "FORM printed readably with keywords unqualified, and a final LF."
  (with-standard-io-syntax
    (let ((*package* (find-package :keyword)))
      (format nil "~s~%" form))))

(defun %write-file-atomically (file text)
  (p:write-text file text :atomic t)
  file)

(defun %read-data-file (store file)
  "The one form in FILE, read as data. → the form."
  (let ((text (handler-case (uiop:read-file-string file :external-format :utf-8)
                (error (e) (%session-file-error store file "cannot be read: ~a" e)))))
    (handler-case
        (with-standard-io-syntax
          (let ((*package* (find-package :keyword))
                (*read-eval* nil))
            (multiple-value-bind (form end) (read-from-string text)
              (unless (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return)))
                             (subseq text end))
                (error "text after the form"))
              form)))
      (error (e) (%session-file-error store file "is unreadable: ~a" e)))))

(defun %plist-p (x)
  (and (listp x)
       (handler-case (evenp (length x)) (error () nil))
       (loop for (k) on x by #'cddr always (keywordp k))))

(defun %meta-file (store) (merge-pathnames "session.sexp" (session-directory store)))
(defun %lock-file (store) (merge-pathnames "lock" (session-directory store)))
(defun %revisions-directory (store) (merge-pathnames "revisions/" (session-directory store)))
(defun %refs-directory (store) (merge-pathnames "refs/" (session-directory store)))
(defun %sessions-dir-of (store) (uiop:pathname-parent-directory-pathname (session-directory store)))
(defun %last-file (sessions-dir) (merge-pathnames "last" (uiop:ensure-directory-pathname sessions-dir)))

(defun %revision-file (store id)
  (make-pathname :name id :type "sexp" :defaults (%revisions-directory store)))

(defun %ref-file (store name)
  (uiop:merge-pathnames* (uiop:parse-unix-namestring name) (%refs-directory store)))

(defun %hidden-name-p (name)
  (or (zerop (length name)) (char= #\. (char name 0))))

(defun %check-name (store name what)
  "NAME must be a file name made of [A-Za-z0-9._-]: not empty, not starting
with \".\" (temporary files do). Otherwise SESSION-ERROR, before anything."
  (unless (and (stringp name)
               (plusp (length name))
               (every (lambda (c) (or (%ascii-alnum-p c) (member c '(#\. #\_ #\-)))) name)
               (not (%hidden-name-p name)))
    (error 'session-error
           :session (session-id store)
           :message (format nil "bad ~a ~s: use letters, digits, \".\", \"_\" and \"-\"~
                                 (not starting with \".\")"
                            what name))))

(defun %meta-plist (store)
  (list :format +session-format+
        :id (session-id store)
        :project-dir (and (session-project-dir store)
                          (uiop:native-namestring (session-project-dir store)))
        :cloned-from (copy-list (session-cloned-from store))
        :version +version+))

(defun %read-meta (store-or-nil file)
  (let ((meta (%read-data-file store-or-nil file)))
    (unless (and (%plist-p meta)
                 (eql +session-format+ (getf meta :format))
                 (stringp (getf meta :id))
                 (let ((p (getf meta :project-dir))) (or (null p) (stringp p)))
                 (listp (getf meta :cloned-from)))
      (%session-file-error store-or-nil file "is not a session file"))
    meta))

(defun %revision-plist (revision)
  (let ((at (rev:revision-recorded-at revision)))
    (list :format +session-format+
          :id (rev:revision-id revision)
          :parents (rev:revision-parent-ids revision)
          :recorded-at (list (dt:instant-seconds at) (dt:instant-nanos at))
          :message (rev:revision-message revision)
          :provenance (rev:revision-provenance revision)
          :content (rev:revision-content revision))))

(defun %read-revision-file (store file)
  (let ((plist (%read-data-file store file)))
    (unless (and (%plist-p plist)
                 (eql +session-format+ (getf plist :format))
                 (equal (getf plist :id) (pathname-name file))
                 (listp (getf plist :parents))
                 (every #'stringp (getf plist :parents))
                 (let ((at (getf plist :recorded-at)))
                   (and (listp at) (= 2 (length at)) (every #'integerp at)))
                 (let ((m (getf plist :message))) (or (null m) (stringp m)))
                 (%plist-p (getf plist :provenance)))
      (%session-file-error store file "is not a revision file"))
    plist))

(defun %revision-file-ids (store)
  "→ (id . pathname) of every revision file of STORE on disk."
  (loop for file in (uiop:directory-files (%revisions-directory store))
        for name = (pathname-name file)
        when (and name (equal "sexp" (pathname-type file)) (not (%hidden-name-p name)))
          collect (cons name file)))

(defun %ref-text (ref)
  (if (eq :tag (rev:ref-kind ref))
      (format nil "tag ~a~%~@[~a~]" (rev:ref-target ref) (rev:ref-annotation ref))
      (format nil "~a~%" (rev:ref-target ref))))

(defun %parse-ref-text (store file text)
  "→ (values kind target annotation) of a ref file's TEXT."
  (let* ((lf (position #\Newline text))
         (line (string-right-trim '(#\Return) (subseq text 0 (or lf (length text)))))
         (rest (if lf (subseq text (1+ lf)) "")))
    (multiple-value-bind (kind target)
        (if (uiop:string-prefix-p "tag " line)
            (values :tag (subseq line 4))
            (values :movable line))
      (unless (and (plusp (length target)) (%hex-string-p target))
        (%session-file-error store file "is not a ref file"))
      (values kind target (and (eq kind :tag) (plusp (length rest)) rest)))))

(defun %disk-refs (store)
  "→ list of (name text kind target annotation) for STORE's ref files."
  (loop for file in (uiop:directory-files (%refs-directory store))
        for name = (file-namestring file)
        unless (%hidden-name-p name)
          collect (let ((text (handler-case (uiop:read-file-string file :external-format :utf-8)
                                (error (e) (%session-file-error store file "cannot be read: ~a" e)))))
                    (multiple-value-bind (kind target annotation) (%parse-ref-text store file text)
                      (list name text kind target annotation)))))

(defun %all-revisions (store)
  "Every revision of STORE, parents before children (insertion order)."
  (let ((heads (rev:heads store)))
    (and heads (rev:walk-revisions store (mapcar #'rev:revision-id heads) :order :topo))))

(defun %write-last (store)
  (let ((file (%last-file (%sessions-dir-of store))))
    (%write-file-atomically file (format nil "~a~%" (session-id store)))))

;;; The lock file.

(defun %pid ()
  #+sbcl (sb-posix:getpid)
  #-sbcl 0)

(defun %lock-file-gone-p (file)
  (handler-case (null (probe-file file))
    (file-error () nil)))

(defparameter +lock-io-retry-seconds+
  #+(or windows win32) 1
  #-(or windows win32) 0
  "How long a lock file read or removal that fails while the file still
exists is retried. On Windows a file another process (or thread) has open
cannot be deleted (a sharing violation), and a file being deleted cannot be
opened (delete pending): both last only as long as the other side's few
microseconds of I/O on the lock file, so they are retried. POSIX has no such
transient errors: 0, the first error is final.")

(defun %lock-io (store file operation thunk)
  "→ THUNK's value, THUNK reading (OPERATION :READ) or removing (:DELETE) the
lock FILE; NIL when FILE vanished meanwhile (another process released or
broke the lock: the expected race). An error while FILE still exists is
retried for +LOCK-IO-RETRY-SECONDS+ (Windows sharing violations); after that
any file or stream error → SESSION-LOCK-ERROR."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* +lock-io-retry-seconds+ internal-time-units-per-second)))))
    (loop
      (handler-case (return (funcall thunk))
        ((or file-error stream-error) (e)
          (cond ((%lock-file-gone-p file) (return nil))
                ((>= (get-internal-real-time) deadline)
                 (error 'session-lock-error :session (and store (session-id store))
                                            :file file :operation operation :cause e))
                (t (sleep 0.005))))))))

(defun %read-lock-file (store file)
  (%lock-io store file :read
            (lambda () (uiop:read-file-string file :external-format :utf-8))))

(defun %remove-lock-file (store file)
  (%lock-io store file :delete (lambda () (delete-file file) t)))

(defun %stale-lock-p (store file)
  "True when lock FILE's recorded universal time (or, when its text is not
\"<pid> <time>\", its write date) is more than +STALE-LOCK-SECONDS+ old. NIL
when FILE is gone; SESSION-LOCK-ERROR when it cannot be read."
  (let* ((text (%read-lock-file store file))
         (words (and text (uiop:split-string (string-trim '(#\Space #\Newline #\Return) text))))
         (time (and text
                    (or (and (= 2 (length words))
                             (every #'digit-char-p (second words))
                             (plusp (length (second words)))
                             (parse-integer (second words)))
                        (%lock-io store file :read (lambda () (file-write-date file)))))))
    (and time (> (- (get-universal-time) time) +stale-lock-seconds+))))

(defun %acquire-lock (store)
  "Create STORE's lock file exclusively (its directory too). Wait up to
*SESSION-LOCK-TIMEOUT* seconds, then SESSION-LOCKED; a stale lock is removed.
A lock that cannot be read or removed signals SESSION-LOCK-ERROR, with the
restart BREAK-LOCK while probing. → the token written into it."
  (let* ((file (%lock-file store))
         (deadline (+ (get-internal-real-time)
                      (round (* *session-lock-timeout* internal-time-units-per-second)))))
    (ensure-directories-exist file)
    (loop
      (let* ((token (format nil "~d ~d~%" (%pid) (get-universal-time)))
             (stream (open file :direction :output :if-exists nil
                                :if-does-not-exist :create :external-format :utf-8)))
        (when stream
          (with-open-stream (s stream)
            (write-string token s)
            (finish-output s))
          (return token)))
      ;; Two breakers of one stale lock may race for a moment; the lock
      ;; assumes one local filesystem and a 30 s dead holder (file header).
      (when (restart-case (%stale-lock-p store file)
              (break-lock ()
                :report "Remove the session's lock file and take the lock (no other process may hold it)"
                t))
        (%remove-lock-file store file))
      (when (> (get-internal-real-time) deadline)
        (error 'session-locked :session (session-id store) :file file))
      (sleep 0.01))))

(defun %release-lock (store token)
  "Remove STORE's lock file when it still holds TOKEN (ours). A lock file
that cannot be read or removed → SESSION-LOCK-ERROR."
  (let ((file (%lock-file store)))
    (when (equal token (%read-lock-file store file))
      (%remove-lock-file store file))))

;;; Sync and persist. *%WRITING* lists the stores this thread is inside a
;;; write (or sync) of: their nested store calls run the in-memory methods
;;; directly.

(defvar *%writing* '()
  "Stores whose write transaction this thread is inside.")

(defun %import-revision (store plist)
  "Insert the revision PLIST (as written) into STORE's memory, with its id,
parents and recorded time. *%WRITING* must hold STORE."
  (destructuring-bind (&key id parents recorded-at message provenance content &allow-other-keys)
      plist
    (dt:with-fixed-clock ((dt:make-instant (first recorded-at) (second recorded-at)))
      (rev:commit-revision store content :id id :parents parents
                                         :message message :provenance provenance))))

(defun %sync (store)
  "Make STORE's memory hold every revision on disk and the refs on disk.
*%WRITING* holds STORE. Refs are read first: writers write revision files
before refs."
  (let* ((disk-refs (%disk-refs store))
         (known (make-hash-table :test 'equal))
         (new '()))
    (dolist (r (%all-revisions store))
      (setf (gethash (rev:revision-id r) known) t))
    (loop for (id . file) in (%revision-file-ids store)
          unless (gethash id known)
            do (push (cons (%read-revision-file store file) file) new))
    (setf new (sort new #'string< :key (lambda (x) (getf (car x) :id))))
    (loop while new
          do (let ((ready (remove-if-not (lambda (x)
                                           (every (lambda (p) (gethash p known))
                                                  (getf (car x) :parents)))
                                         new)))
               (unless ready
                 (%session-file-error store (cdr (first new))
                                      "names a parent revision that is not in the session"))
               (dolist (x ready)
                 (%import-revision store (car x))
                 (setf (gethash (getf (car x) :id) known) t))
               (setf new (set-difference new ready :test #'eq))))
    (loop for (name nil kind target annotation) in disk-refs
          for mem = (rev:find-ref store name)
          do (unless (gethash target known)
               (%session-file-error store (%ref-file store name)
                                    "names revision ~a, which is not in the session" target))
             (ecase kind
               (:movable
                (cond ((and mem (eq :tag (rev:ref-kind mem)))
                       (%session-file-error store (%ref-file store name) "is a tag in memory"))
                      ((not (and mem (equal target (rev:ref-target mem))))
                       (rev:move-ref store name target))))
               (:tag
                (unless mem
                  (rev:tag-revision store name target :annotation annotation)))))
    (dolist (ref (rev:list-refs store :kind :movable))
      (unless (assoc (rev:ref-name ref) disk-refs :test #'equal)
        (rev:delete-ref store (rev:ref-name ref))))
    store))

(defun %persist (store &key force-meta)
  "Write what STORE's memory has and its directory lacks: new revision files
(parents first), changed and deleted refs, then session.sexp on the first
write, and \"last\" when revisions were added (or FORCE-META)."
  (let* ((on-disk (make-hash-table :test 'equal))
         (changed nil)
         (added nil))
    (loop for (id) in (%revision-file-ids store) do (setf (gethash id on-disk) t))
    (dolist (r (%all-revisions store))
      (unless (gethash (rev:revision-id r) on-disk)
        (%write-file-atomically (%revision-file store (rev:revision-id r))
                                (%print-data (%revision-plist r)))
        (setf changed t added t)))
    (let ((disk-refs (%disk-refs store)))
      (dolist (ref (rev:list-refs store))
        (let ((text (%ref-text ref)))
          (unless (equal text (second (assoc (rev:ref-name ref) disk-refs :test #'equal)))
            (%write-file-atomically (%ref-file store (rev:ref-name ref)) text)
            (setf changed t))))
      (loop for (name) in disk-refs
            unless (rev:find-ref store name)
              do (delete-file (%ref-file store name))
                 (setf changed t)))
    (when (and (or changed force-meta) (not (probe-file (%meta-file store))))
      (%write-file-atomically (%meta-file store) (%print-data (%meta-plist store))))
    (when (or added force-meta)
      (%write-last store))
    store))

(defun %call-writing (store thunk &key force-meta)
  "Run THUNK as one write transaction on STORE (see the file header)."
  (if (member store *%writing* :test #'eq)
      (funcall thunk)
      (bt:with-lock-held ((%session-lock store))
        (let ((token (%acquire-lock store)))
          (unwind-protect
               (let ((*%writing* (cons store *%writing*)))
                 (%sync store)
                 (multiple-value-prog1 (funcall thunk)
                   (%persist store :force-meta force-meta)))
            (%release-lock store token))))))

(defmethod rev:commit-revision :around ((store session-store) content &key ref id &allow-other-keys)
  (declare (ignore content))
  (when ref (%check-name store ref "ref name"))
  (when id (%check-name store id "revision id"))
  (%call-writing store (lambda () (call-next-method))))

(defmethod rev:move-ref :around ((store session-store) name designator &key &allow-other-keys)
  (declare (ignore designator))
  (%check-name store name "ref name")
  (%call-writing store (lambda () (call-next-method))))

(defmethod rev:tag-revision :around ((store session-store) name designator &key &allow-other-keys)
  (declare (ignore designator))
  (%check-name store name "ref name")
  (%call-writing store (lambda () (call-next-method))))

(defmethod rev:delete-ref :around ((store session-store) name &key &allow-other-keys)
  (%check-name store name "ref name")
  (%call-writing store (lambda () (call-next-method))))

;;; Creating, opening, listing.

(defun %make-session-store (sessions-dir id &key project-dir cloned-from base)
  (make-instance 'session-store
                 :engine (make-instance 'diff:sexp-diff-engine)
                 :id id
                 :directory (uiop:merge-pathnames* (uiop:parse-unix-namestring (format nil "~a/" id))
                                                   (uiop:ensure-directory-pathname sessions-dir))
                 :project-dir (and project-dir (uiop:ensure-directory-pathname project-dir))
                 :cloned-from cloned-from
                 :base base))

(defun %session-exists-p (sessions-dir id)
  (uiop:directory-exists-p
   (uiop:merge-pathnames* (uiop:parse-unix-namestring (format nil "~a/" id))
                          (uiop:ensure-directory-pathname sessions-dir))))

(defun %new-session-id (sessions-dir id)
  "ID normalized and unused in SESSIONS-DIR (NIL → random). → the id."
  (let ((normal (if id (normalize-session-id id) (%session-id))))
    (unless normal
      (error 'session-error
             :message (format nil "bad session id ~s: use 32 hex digits or a UUID" id)))
    (when (%session-exists-p sessions-dir normal)
      (error 'session-error :session normal
                            :message (format nil "session ~a already exists" normal)))
    normal))

(defun create-session (sessions-dir &key id project-dir)
  "→ a new, empty SESSION-STORE in SESSIONS-DIR. ID (normalized with
NORMALIZE-SESSION-ID; NIL → 32 random hex characters) must not name an
existing session there (SESSION-ERROR \"session ID already exists\"); a
string NORMALIZE-SESSION-ID refuses signals SESSION-ERROR too. PROJECT-DIR is
recorded in session.sexp. Nothing is written yet (see Laziness)."
  (%make-session-store sessions-dir (%new-session-id sessions-dir id) :project-dir project-dir))

(defun %session-ids (sessions-dir)
  "Ids of the subdirectories of SESSIONS-DIR that hold a session.sexp, sorted."
  (let ((dir (uiop:directory-exists-p sessions-dir)))
    (and dir
         (sort (loop for sub in (uiop:subdirectories dir)
                     for name = (car (last (pathname-directory sub)))
                     when (and (stringp name) (probe-file (merge-pathnames "session.sexp" sub)))
                       collect name)
               #'string<))))

(defun %meta-file-of (sessions-dir id)
  (uiop:merge-pathnames* (uiop:parse-unix-namestring (format nil "~a/session.sexp" id))
                         (uiop:ensure-directory-pathname sessions-dir)))

(defun %open-session-id (sessions-dir id &optional (meta (%read-meta nil (%meta-file-of sessions-dir id))))
  (let* ((project (getf meta :project-dir))
         (store (%make-session-store sessions-dir id
                                     :project-dir (and project
                                                       (uiop:parse-native-namestring
                                                        project :ensure-directory t))
                                     :cloned-from (getf meta :cloned-from))))
    (sync-session store)
    (let ((head (session-head store)))
      (setf (session-base store) (and head (rev:revision-id head))))
    store))

(defun open-session (sessions-dir designator)
  "→ the SESSION-STORE of the session DESIGNATOR names in SESSIONS-DIR, with
every revision and ref read from disk (recorded times as written) and
SESSION-BASE = its head id. DESIGNATOR is an id, a UUID, or a unique hex
prefix of at least 4 characters. None → SESSION-NOT-FOUND (DESIGNATOR as
given); several → SESSION-NOT-FOUND whose message lists them. An unreadable
file → SESSION-ERROR naming it."
  (let ((ids (%session-ids sessions-dir))
        (exact (normalize-session-id designator)))
    (cond ((and exact (member exact ids :test #'string=))
           (%open-session-id sessions-dir exact))
          ((and (stringp designator)
                (<= rev:+minimum-id-prefix+ (length designator) 32)
                (%hex-string-p designator))
           (let* ((prefix (string-downcase designator))
                  (hits (remove-if-not (lambda (id) (uiop:string-prefix-p prefix id)) ids)))
             (cond ((null hits) (error 'session-not-found :designator designator))
                   ((rest hits)
                    (error 'session-not-found
                           :designator designator
                           :message (format nil "session prefix ~s is ambiguous: ~{~a~^, ~}"
                                            designator hits)))
                   (t (%open-session-id sessions-dir (first hits))))))
          (t (error 'session-not-found :designator designator)))))

(defun sync-session (store)
  "Read the revision and ref files other processes wrote since STORE last
read its directory. SESSION-BASE is not changed. → STORE."
  (if (member store *%writing* :test #'eq)
      (%sync store)
      (bt:with-lock-held ((%session-lock store))
        (let ((*%writing* (cons store *%writing*)))
          (%sync store))))
  store)

(defun %latest-time (store)
  (let ((times (mapcar #'rev:revision-recorded-at (%all-revisions store))))
    (and times (reduce (lambda (a b) (if (dt:< a b) b a)) times))))

(defun list-sessions (sessions-dir)
  "→ the sessions in SESSIONS-DIR (opened as by OPEN-SESSION), newest first:
by the latest recorded time of their revisions; sessions without revisions
last; ties by id. Directories without a readable session.sexp are skipped. A
missing SESSIONS-DIR → NIL."
  (let ((entries
          (loop for id in (%session-ids sessions-dir)
                ;; Only an unreadable session.sexp skips the directory; a
                ;; corrupt revision or ref still signals.
                for meta = (handler-case (%read-meta nil (%meta-file-of sessions-dir id))
                             (session-error () nil))
                for store = (and meta (%open-session-id sessions-dir id meta))
                when store collect (cons store (%latest-time store)))))
    (mapcar #'car
            (sort entries
                  (lambda (a b)
                    (let ((ta (cdr a)) (tb (cdr b)))
                      (cond ((and ta tb (dt:< tb ta)) t)
                            ((and ta tb (dt:< ta tb)) nil)
                            ((and ta (null tb)) t)
                            ((and tb (null ta)) nil)
                            (t (string< (session-id (car a)) (session-id (car b)))))))))))

(defun last-session (sessions-dir)
  "→ the session the \"last\" file of SESSIONS-DIR names (opened), or NIL when
there is no such file or that session is gone."
  (let* ((file (%last-file sessions-dir))
         (text (and (probe-file file)
                    (ignore-errors (uiop:read-file-string file :external-format :utf-8))))
         (id (and text (string-trim '(#\Space #\Tab #\Newline #\Return) text))))
    (and id
         (normalize-session-id id)
         (handler-case (open-session sessions-dir id)
           (session-not-found () nil)))))

;;; Reading a session.

(defun session-head (store)
  "→ the revision \"head\" names, or NIL (a new session, or one rewound to
before its first turn)."
  (let ((ref (rev:find-ref store +head-ref+)))
    (and ref (rev:resolve-revision store (rev:ref-target ref)))))

(defun session-line (store &optional (designator +head-ref+))
  "→ the revisions of DESIGNATOR's first-parent line, root first (a fresh
list). DESIGNATOR is any revision-protocol designator; the string \"head\"
means the head ref (REV:REV-REF), and with no head the line is NIL."
  (if (equal designator +head-ref+)
      (let ((head (session-head store)))
        (and head (copy-list (rev:walk-revisions store (rev:revision-id head)
                                                 :order :first-parent))))
      (copy-list (rev:walk-revisions store designator :order :first-parent))))

(defun session-records (store &optional (designator +head-ref+))
  "→ the TURN-RECORDs of SESSION-LINE, root first."
  (mapcar #'revision-record (session-line store designator)))

(defun session-turns (store &optional (designator +head-ref+))
  "→ the conversation at DESIGNATOR: fresh LLM-TURNs, the fold of
SESSION-RECORDS root first (a record appends its TURNS; a REPLACE-P record's
TURNS replace everything before). No head → NIL. Never :SYSTEM turns: the
system prompt is assembled again by every process that runs the session."
  (let ((turns '()))
    (dolist (record (session-records store designator))
      (setf turns (if (record-replace-p record)
                      (copy-list (record-turns record))
                      (append turns (record-turns record)))))
    (remove :system turns :key #'llm:llm-turn-role)))

;;; Writing a session.

(defun %turn-message (prompt)
  "PROMPT's first line, trimmed, cut to 72 characters (71 and \"…\")."
  (let* ((line (subseq prompt 0 (or (position #\Newline prompt) (length prompt))))
         (line (string-trim '(#\Space #\Tab #\Return) line)))
    (if (> (length line) 72)
        (concatenate 'string (subseq line 0 71) "…")
        line)))

(defun %revision-designator-id (store designator)
  "A revision id string for DESIGNATOR (NIL stays NIL)."
  (cond ((null designator) nil)
        ((rev:revision-p designator) (rev:revision-id designator))
        ((stringp designator) designator)
        (t (rev:revision-id (rev:resolve-revision store designator)))))

(defun commit-turn (store record &key (expected nil expected-p) id)
  "Commit RECORD (a TURN-RECORD) as one revision on STORE's head and move the
head to it. → (values revision store-it-went-to).

The parent is EXPECTED (default SESSION-BASE; NIL → a root) and the head
moves by compare-and-swap from EXPECTED. The message is the prompt's first
line, trimmed, cut to 72 characters (71 and \"…\" when longer); the
provenance (:kind :turn :version +VERSION+); ID, when given, is the
revision id (as REV:COMMIT-REVISION :ID). The \"last\" file of the sessions
directory then names STORE. SESSION-BASE becomes the new revision's id.

When the head on disk is not EXPECTED, nothing is written and
SESSION-CONFLICT is signalled (expected, actual) with the restart
FORK-SESSION (&optional new-id): clone STORE at EXPECTED (CLONE-SESSION :AT,
NIL → an empty new session), commit RECORD there, and return (values
revision new-store). SESSION-LOCKED and file errors propagate."
  (check-type record turn-record)
  (let* ((expected (%revision-designator-id store (if expected-p expected (session-base store))))
         (conflict nil)
         (revision (handler-case
                       (rev:commit-revision store (record-content record)
                                            :parents (and expected (list expected))
                                            :ref +head-ref+
                                            :expected expected
                                            :message (%turn-message (record-prompt record))
                                            :provenance (list :kind :turn :version +version+)
                                            :id id)
                     ;; Unwinds out of the write: the lock is released and
                     ;; nothing was persisted.
                     (rev:ref-conflict (c) (setf conflict c) nil))))
    (if revision
        (progn (setf (session-base store) (rev:revision-id revision))
               (values revision store))
        (restart-case
            (error 'session-conflict :session (session-id store)
                                     :expected expected
                                     :actual (rev:ref-conflict-actual conflict))
          (fork-session (&optional new-id)
            :report "Save this turn as a new session cloned at the expected head."
            (commit-turn (clone-session store :id new-id :at expected) record :id id))))))

(defun %line-number-p (string)
  (and (stringp string) (plusp (length string)) (every #'digit-char-p string)))

(defun resolve-turn (store at)
  "→ the revision AT names: a decimal number N ≥ 1 is the Nth revision of the
head's line (1 = its root); otherwise a revision id or a unique id prefix of
at least 4 characters anywhere in the session (REV:RESOLVE-REVISION). Anything
else, out of range, ambiguous or unknown → SESSION-TURN-NOT-FOUND (AT as
given)."
  (flet ((fail () (error 'session-turn-not-found :session (session-id store) :designator at)))
    (unless (stringp at) (fail))
    (let ((line (session-line store)))
      (or (and (%line-number-p at)
               (let ((n (parse-integer at)))
                 (and (<= 1 n (length line)) (nth (1- n) line))))
          (and (>= (length at) rev:+minimum-id-prefix+)
               (handler-case (rev:resolve-revision store at)
                 (rev:revision-error () nil)))
          (fail)))))

(defun %cas-head (store target expected)
  "Move the head to TARGET (an id or NIL: delete) by CAS from EXPECTED (an id
or NIL). A failed swap → SESSION-CONFLICT. → the new head or NIL."
  (let ((conflict nil)
        (actual nil))
    (handler-case
        (if target
            (rev:move-ref store +head-ref+ target :expected expected)
            (rev:delete-ref store +head-ref+ :expected expected))
      (rev:ref-conflict (c) (setf conflict t actual (rev:ref-conflict-actual c)))
      (rev:revision-not-found (c)
        ;; DELETE-REF of a head that is not there: done when none was
        ;; expected, a lost race otherwise.
        (cond (target (error c))
              (expected (setf conflict t actual nil)))))
    (when conflict
      (error 'session-conflict :session (session-id store) :expected expected :actual actual))
    (setf (session-base store) target)
    (session-head store)))

(defun move-session-head (store designator &key (expected nil expected-p))
  "Move the head to DESIGNATOR (a revision designator), or delete it when
DESIGNATOR is NIL, by compare-and-swap from EXPECTED (default SESSION-BASE).
A failed swap → SESSION-CONFLICT (no restarts besides ABORT). SESSION-BASE
follows. → the new head revision or NIL."
  (%cas-head store
             (%revision-designator-id store designator)
             (%revision-designator-id store (if expected-p expected (session-base store)))))

(defun rewind-session (store n)
  "Move the head N (≥ 1) turns back along its first-parent line: to the Nth
ancestor, or delete it when N equals the number of turns on the line. N
larger than that, or no head → SESSION-TURN-NOT-FOUND (N). The revisions
stay in the store (the /tree shows them). → the new head revision or NIL."
  (let* ((line (session-line store))
         (len (length line)))
    (unless (and (integerp n) (<= 1 n len))
      (error 'session-turn-not-found :session (session-id store) :designator n))
    (move-session-head store (if (= n len) nil (rev:revision-id (nth (- len n 1) line))))))

(defun fork-turn (store at)
  "Branch off before turn AT (RESOLVE-TURN; NIL = the head): the head moves to
AT's first parent, or is deleted when AT is a root; the next turn then starts
a new branch beside AT. → (values new-head-or-NIL prompt), PROMPT being AT's
record prompt (the interactive mode puts it back into the input). No head and
AT NIL → SESSION-TURN-NOT-FOUND."
  (let ((revision (if at
                      (resolve-turn store at)
                      (or (session-head store)
                          (error 'session-turn-not-found :session (session-id store)
                                                         :designator at)))))
    (values (move-session-head store (first (rev:revision-parent-ids revision)))
            (record-prompt (revision-record revision)))))

(defun clone-session (store &key id (at +head-ref+) sessions-dir)
  "→ a new SESSION-STORE holding the revisions of STORE's line at AT (same
ids, contents, messages, provenance and recorded times; other branches are
not copied), its head at AT (none when AT is NIL or STORE has no head), and
SESSION-CLONED-FROM (STORE's id, AT's id or NIL). ID as for CREATE-SESSION;
SESSIONS-DIR defaults to the directory holding STORE's. The project
directory is STORE's. Written at once, and \"last\" names the clone."
  (let* ((dir (or sessions-dir (%sessions-dir-of store)))
         (line (and at (session-line store at)))
         (tip (and line (rev:revision-id (car (last line)))))
         (clone (%make-session-store dir (%new-session-id dir id)
                                     :project-dir (session-project-dir store)
                                     :cloned-from (list (session-id store) tip))))
    (%call-writing clone
                   (lambda ()
                     (loop for previous = nil then r
                           for r in line
                           do (%import-revision
                               clone (list :id (rev:revision-id r)
                                           :parents (and previous (list (rev:revision-id previous)))
                                           :recorded-at (let ((i (rev:revision-recorded-at r)))
                                                          (list (dt:instant-seconds i)
                                                                (dt:instant-nanos i)))
                                           :message (rev:revision-message r)
                                           :provenance (rev:revision-provenance r)
                                           :content (rev:revision-content r))))
                     (when tip
                       (rev:move-ref clone +head-ref+ tip)))
                   :force-meta t)
    (setf (session-base clone) tip)
    clone))

;;; JSON helpers shared by the views and headless output.

(defun %json-object (&rest keys-and-values)
  "A json-protocol object (EQUAL hash table) from alternating string keys and
values."
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on keys-and-values by #'cddr
          do (setf (gethash key object) value))
    object))

(defun %usage-object (counts)
  (destructuring-bind (input output cache-read cache-write) counts
    (%json-object "input_tokens" input "output_tokens" output
                  "cache_read_tokens" cache-read "cache_write_tokens" cache-write)))
