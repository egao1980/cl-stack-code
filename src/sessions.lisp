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
;;; recorded time is more than +STALE-LOCK-SECONDS+ old is removed and taken),
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
  (declare (ignore getenv platform))
  (%not-implemented 'user-data-directory))

(defun project-session-key (directory)
  "→ the sessions subdirectory name for DIRECTORY: its native namestring as a
directory, without the trailing separator, with every character that is not
an ASCII letter or digit replaced by #\\-.
  /Users/me/my proj/  → \"-Users-me-my-proj\"
  C:\\Users\\me\\x\\     → \"C--Users-me-x\""
  (declare (ignore directory))
  (%not-implemented 'project-session-key))

(defun sessions-directory (cwd &key data-dir)
  "→ <DATA-DIR>/sessions/<PROJECT-SESSION-KEY of the project directory>/ for
working directory CWD (a directory pathname). The project directory is
FIND-PROJECT-ROOT of CWD, else CWD's truename. DATA-DIR defaults to
USER-DATA-DIRECTORY. Creates nothing."
  (declare (ignore cwd data-dir))
  (%not-implemented 'sessions-directory))

(defun normalize-session-id (string)
  "→ STRING as a session id (32 lowercase hex characters), or NIL. Accepts 32
hex digits in any case, or a UUID (8-4-4-4-12 hex digits, any case; the
dashes are dropped)."
  (declare (ignore string))
  (%not-implemented 'normalize-session-id))

;;; Turn records: a revision's content.

(defstruct (turn-record (:constructor make-turn-record
                            (&key prompt turns replace-p (finish :stop) model
                                  (permission-mode :default) (usage (list 0 0 0 0))
                                  steering (version +version+)))
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
messages delivered into the turn, as typed, in order."
  (prompt "" :type string)
  (turns '() :type list)
  (replace-p nil)
  (finish :stop :type keyword)
  (model nil)
  (permission-mode :default :type keyword)
  (usage (list 0 0 0 0) :type list)
  (steering '() :type list)
  (version +version+))

(defun record-content (record)
  "→ RECORD as a revision content plist of strings, numbers, keywords and
lists:
  (:format 1 :prompt S :turns (LLM:TURN-STATE …) :replace BOOL :finish K
   :model S-or-NIL :permission-mode K :usage (I O CR CW) :steering (S …)
   :version S)"
  (declare (ignore record))
  (%not-implemented 'record-content))

(defun content-record (content)
  "→ the TURN-RECORD of a RECORD-CONTENT plist (turns read back with
LLM:STATE-TURN). A plist that is not one signals SESSION-ERROR."
  (declare (ignore content))
  (%not-implemented 'content-record))

(defun revision-record (revision)
  "→ the TURN-RECORD of a session revision (CONTENT-RECORD of its content)."
  (declare (ignore revision))
  (%not-implemented 'revision-record))

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

(defun create-session (sessions-dir &key id project-dir)
  "→ a new, empty SESSION-STORE in SESSIONS-DIR. ID (normalized with
NORMALIZE-SESSION-ID; NIL → 32 random hex characters) must not name an
existing session there (SESSION-ERROR \"session ID already exists\"); a
string NORMALIZE-SESSION-ID refuses signals SESSION-ERROR too. PROJECT-DIR is
recorded in session.sexp. Nothing is written yet (see Laziness)."
  (declare (ignore sessions-dir id project-dir))
  (%not-implemented 'create-session))

(defun open-session (sessions-dir designator)
  "→ the SESSION-STORE of the session DESIGNATOR names in SESSIONS-DIR, with
every revision and ref read from disk (recorded times as written) and
SESSION-BASE = its head id. DESIGNATOR is an id, a UUID, or a unique hex
prefix of at least 4 characters. None → SESSION-NOT-FOUND (DESIGNATOR as
given); several → SESSION-NOT-FOUND whose message lists them. An unreadable
file → SESSION-ERROR naming it."
  (declare (ignore sessions-dir designator))
  (%not-implemented 'open-session))

(defun sync-session (store)
  "Read the revision and ref files other processes wrote since STORE last
read its directory. SESSION-BASE is not changed. → STORE."
  (declare (ignore store))
  (%not-implemented 'sync-session))

(defun list-sessions (sessions-dir)
  "→ the sessions in SESSIONS-DIR (opened as by OPEN-SESSION), newest first:
by the latest recorded time of their revisions; sessions without revisions
last; ties by id. Directories without a readable session.sexp are skipped. A
missing SESSIONS-DIR → NIL."
  (declare (ignore sessions-dir))
  (%not-implemented 'list-sessions))

(defun last-session (sessions-dir)
  "→ the session the \"last\" file of SESSIONS-DIR names (opened), or NIL when
there is no such file or that session is gone."
  (declare (ignore sessions-dir))
  (%not-implemented 'last-session))

(defun session-head (store)
  "→ the revision \"head\" names, or NIL (a new session, or one rewound to
before its first turn)."
  (declare (ignore store))
  (%not-implemented 'session-head))

(defun session-line (store &optional (designator +head-ref+))
  "→ the revisions of DESIGNATOR's first-parent line, root first (a fresh
list). DESIGNATOR is any revision-protocol designator; the string \"head\"
means the head ref (REV:REV-REF), and with no head the line is NIL."
  (declare (ignore store designator))
  (%not-implemented 'session-line))

(defun session-records (store &optional (designator +head-ref+))
  "→ the TURN-RECORDs of SESSION-LINE, root first."
  (declare (ignore store designator))
  (%not-implemented 'session-records))

(defun session-turns (store &optional (designator +head-ref+))
  "→ the conversation at DESIGNATOR: fresh LLM-TURNs, the fold of
SESSION-RECORDS root first (a record appends its TURNS; a REPLACE-P record's
TURNS replace everything before). No head → NIL. Never :SYSTEM turns: the
system prompt is assembled again by every process that runs the session."
  (declare (ignore store designator))
  (%not-implemented 'session-turns))

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
  (declare (ignore store record expected expected-p id))
  (%not-implemented 'commit-turn))

(defun resolve-turn (store at)
  "→ the revision AT names: a decimal number N ≥ 1 is the Nth revision of the
head's line (1 = its root); otherwise a revision id or a unique id prefix of
at least 4 characters anywhere in the session (REV:RESOLVE-REVISION). Anything
else, out of range, ambiguous or unknown → SESSION-TURN-NOT-FOUND (AT as
given)."
  (declare (ignore store at))
  (%not-implemented 'resolve-turn))

(defun move-session-head (store designator &key (expected nil expected-p))
  "Move the head to DESIGNATOR (a revision designator), or delete it when
DESIGNATOR is NIL, by compare-and-swap from EXPECTED (default SESSION-BASE).
A failed swap → SESSION-CONFLICT (no restarts besides ABORT). SESSION-BASE
follows. → the new head revision or NIL."
  (declare (ignore store designator expected expected-p))
  (%not-implemented 'move-session-head))

(defun rewind-session (store n)
  "Move the head N (≥ 1) turns back along its first-parent line: to the Nth
ancestor, or delete it when N equals the number of turns on the line. N
larger than that, or no head → SESSION-TURN-NOT-FOUND (N). The revisions
stay in the store (the /tree shows them). → the new head revision or NIL."
  (declare (ignore store n))
  (%not-implemented 'rewind-session))

(defun fork-turn (store at)
  "Branch off before turn AT (RESOLVE-TURN; NIL = the head): the head moves to
AT's first parent, or is deleted when AT is a root; the next turn then starts
a new branch beside AT. → (values new-head-or-NIL prompt), PROMPT being AT's
record prompt (the interactive mode puts it back into the input). No head and
AT NIL → SESSION-TURN-NOT-FOUND."
  (declare (ignore store at))
  (%not-implemented 'fork-turn))

(defun clone-session (store &key id (at +head-ref+) sessions-dir)
  "→ a new SESSION-STORE holding the revisions of STORE's line at AT (same
ids, contents, messages, provenance and recorded times; other branches are
not copied), its head at AT (none when AT is NIL or STORE has no head), and
SESSION-CLONED-FROM (STORE's id, AT's id or NIL). ID as for CREATE-SESSION;
SESSIONS-DIR defaults to the directory holding STORE's. The project
directory is STORE's. Written at once, and \"last\" names the clone."
  (declare (ignore store id at sessions-dir))
  (%not-implemented 'clone-session))

;;; Write-through: every ref or revision write on a SESSION-STORE takes the
;;; lock, syncs, runs the in-memory method and writes the files (see the
;;; file header).

(defmethod rev:commit-revision :around ((store session-store) content &key &allow-other-keys)
  (declare (ignore content))
  (%not-implemented 'session-commit-revision))

(defmethod rev:move-ref :around ((store session-store) name designator &key &allow-other-keys)
  (declare (ignore name designator))
  (%not-implemented 'session-move-ref))

(defmethod rev:tag-revision :around ((store session-store) name designator &key &allow-other-keys)
  (declare (ignore name designator))
  (%not-implemented 'session-tag-revision))

(defmethod rev:delete-ref :around ((store session-store) name &key &allow-other-keys)
  (declare (ignore name))
  (%not-implemented 'session-delete-ref))
