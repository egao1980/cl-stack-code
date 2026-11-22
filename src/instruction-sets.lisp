(in-package #:cl-stack-code)

;;; H3e-1: the instruction set, one revisioned thing.
;;; Brief: cl-stack/docs/capabilities/cl-stack-code.md, "H3e-1 — locked",
;;; "The instruction set".
;;;
;;; What the model is told besides the conversation: the instruction files
;;; with their expanded imports, the contextFiles, the skills index and the
;;; rules (always-on ones and the path-scoped ones loaded so far); H3e-2 adds
;;; the MCP servers and their tools. That set changes during a session (a
;;; rule loads) and between processes (an instruction file was edited), and a
;;; rewind, a fork or a resume must give the model the set that goes with the
;;; conversation it continues. So the set is kept as REVISIONS in
;;; revision-protocol's in-memory store, as the conversation (H3c) and the
;;; files (H5b) are, and each turn record names the revision current at its
;;; end (RECORD-INSTRUCTIONS).
;;;
;;; Components. The set is made of COMPONENTS, objects behind three generic
;;; functions:
;;;   (COMPONENT-ROLE c)                → a keyword, unique in the set
;;;   (COMPONENT-SNAPSHOT c store)      → the component's state now, as DATA:
;;;                                       strings, integers, keywords, T, NIL
;;;                                       and lists of those (nothing else).
;;;                                       Long texts go through
;;;                                       INTERN-INSTRUCTION-TEXT and the
;;;                                       snapshot keeps their hash
;;;   (COMPONENT-RESTORE c snapshot store) make the live state equal SNAPSHOT
;;;                                       (a value COMPONENT-SNAPSHOT
;;;                                       returned); the value is ignored
;;; INSTRUCTION-SET-COMPONENTS set → the components, in registration order
;;; (ADD-INSTRUCTION-COMPONENT; a second component with a role already
;;; present → INSTRUCTION-SET-ERROR). A later slice adds a component with
;;; one ADD-INSTRUCTION-COMPONENT call where it makes its live object (H3e-2:
;;; :MCP-SERVERS, when the servers are connected) and calls
;;; COMMIT-INSTRUCTION-SET when its state changes; nothing in this file or in
;;; the built-in components changes.
;;;
;;; Built-in components (+INSTRUCTION-SET-ROLES+), registered in this order
;;; by MAKE-INSTRUCTION-SET with a :CONTEXT (an INSTRUCTION-CONTEXT):
;;;   :instruction-files  ((:path NATIVE :source S :sha256 H :block B
;;;                         :imports ((:path NATIVE :from NATIVE :sha256 H) …))
;;;                        …) one entry per CONTEXT-FILES file, prompt order.
;;;                        S :user (the user AGENTS.md), :context (a
;;;                        contextFiles entry) or :project (the chain). :sha256
;;;                        the hash of the file's text as read (P:OCTETS-HASH
;;;                        of its octets); B the INTERN-INSTRUCTION-TEXT hash of
;;;                        its INSTRUCTION-BLOCK (imports expanded). Imports are
;;;                        CONTEXT-IMPORTS of that file, prompt order.
;;;   :context-files      ((:path NATIVE :found BOOL) …) the configured
;;;                        SETTINGS-CONTEXT-FILES in order (NIL: none), FOUND
;;;                        false for a missing or blank one.
;;;   :skills             ((:name N :description D :path NATIVE :source S
;;;                         :sha256 H) …) CONTEXT-SKILLS, listing order; PATH
;;;                        the SKILL.md, S its SKILL-SOURCE, H the SKILL.md's
;;;                        hash, D the frontmatter description as parsed.
;;;   :rules              (:found ((:path NATIVE :paths (P …) or NIL :text H) …)
;;;                        :loaded (NATIVE …)) every rule found (rule order;
;;;                        H the INTERN-INSTRUCTION-TEXT hash of its body,
;;;                        trimmed) and the rules in context: the discovery's
;;;                        loaded set (DISCOVERY-LOADED-RULES, load order).
;;; NATIVE is a truename's native namestring. Skill bodies and skill files are
;;; still read from disk when the skill tool runs (only the index is in the
;;; set).
;;;
;;; Revisions. COMMIT-INSTRUCTION-SET set reason → (values id new-p). The
;;; CONTENT is
;;;   (:instruction-set 1 :components ((:role R :snapshot S) …))
;;; one entry per component, in INSTRUCTION-SET-COMPONENTS order. Its id is
;;; INSTRUCTION-SET-ID: the 64 lowercase hex digits of P:OCTETS-HASH of the
;;; UTF-8 of the content printed as H3c prints files (standard syntax,
;;; *PACKAGE* the keyword package, then LF). Ids are content hashes, so they
;;; are the same in every process and store, and an unchanged set is one
;;; revision however often it is committed: when the store has the id
;;; already, nothing is committed and NEW-P is NIL. Otherwise the revision is
;;; committed with REV:COMMIT-REVISION :ID id :PARENTS () (a root: the
;;; history is in the turn records, and parents would make the id depend on
;;; it), message "instructions: <reason in lower case>", provenance (:kind
;;; :instructions :reason REASON :version +VERSION+) (the first commit's
;;; reason stays). Either way INSTRUCTION-SET-CURRENT becomes the id. A
;;; snapshot that is not data → INSTRUCTION-SET-ERROR, nothing committed and
;;; the current id unchanged. REASON is a keyword: +INSTRUCTION-SET-REASONS+
;;; lists H3e-1's; a later component may use its own. A :START commit also
;;; points the store's ref "start" (+INSTRUCTION-START-REF+) at the id when
;;; the store has no such ref.
;;;   When:  :start   a new session's process start
;;;          :resume  a process continuing a session (--resume, --continue,
;;;                   the SDK's resume, --rpc session/load): the set read from
;;;                   disk again (a changed instruction file, skill directory,
;;;                   rule or contextFiles list gives a new revision; an
;;;                   unchanged one gives the head's id back)
;;;          :rule    the discovery loaded one or more path-scoped rules (one
;;;                   commit per STEER:DISCOVER-INSTRUCTIONS call that loaded
;;;                   any)
;;;          :forget  STEER:FORGET-INSTRUCTIONS removed loaded rules
;;;          :component  another component changed (H3e-2's servers)
;;;
;;; RESTORE-INSTRUCTION-SET set id → id: READ-INSTRUCTION-SET of ID; then for
;;; each component, in order, whose role the revision has,
;;; (COMPONENT-RESTORE c snapshot store). A component whose role the
;;; revision lacks is left as it is; a role without a component is ignored.
;;; INSTRUCTION-SET-CURRENT becomes ID. Nothing is committed. An unknown id →
;;; REV:REVISION-NOT-FOUND. The built-in components restore:
;;;   :rules   the loaded set becomes the snapshot's :LOADED exactly (the
;;;            discovery and its copies share it): rules loaded after the
;;;            revision are no longer loaded, so the next matching tool path
;;;            loads them again, and rules the revision had are not loaded
;;;            twice. The always-on rule blocks come from its :FOUND.
;;;   :instruction-files, :context-files, :skills
;;;            the set renders the system prompt from the snapshot
;;;            (INSTRUCTION-SET-BLOCKS), and the skill tool knows the
;;;            snapshot's skills.
;;;
;;; Reading. READ-INSTRUCTION-SET store id → ((role . snapshot) …) in content
;;; order (ID: an id or a unique prefix of at least 4). INSTRUCTION-SET-BLOCKS
;;; store id → the prompt blocks of the revision, strings in this order: each
;;; :instruction-files :block text, each always-on :rules :found entry as
;;; "<rule path=\"NATIVE\">" LF text LF "</rule>", then the "# Skills" section
;;; of the :skills entries (SKILL-LISTING-SECTION's rules) when there is one.
;;; For a revision just committed from a context these are exactly the blocks
;;; ASSEMBLE-SYSTEM-PROMPT puts between the environment and plan sections
;;; and appendSystemPrompt, and they never change afterwards (the texts are
;;; stored, so a later edit on disk does not change an old revision).
;;; ASSEMBLE-SYSTEM-PROMPT :INSTRUCTION-SET set renders them from the set's
;;; current revision. INSTRUCTION-SET-LOADED-RULES store id → the :rules
;;; :loaded list (NIL without a :rules role).
;;;
;;; Texts. INTERN-INSTRUCTION-TEXT store string → "sha256:<64 hex>" (P:OCTETS-
;;; HASH of the UTF-8), kept in the store; INSTRUCTION-TEXT store hash → the
;;; string (from memory, else the texts/ file; a missing file, or one whose
;;; hash differs → INSTRUCTION-SET-ERROR).
;;;
;;; The store and its files. SESSION-INSTRUCTION-STORE session → the
;;; session's INSTRUCTION-STORE (one per session store object, made on first
;;; use). INSTRUCTIONS-DIRECTORY session = <session dir>/instructions/:
;;;   revisions/<id>.sexp   one immutable file per revision, H3c's revision
;;;                         file format: (:format 1 :id ID :parents ()
;;;                         :recorded-at (S N) :message M :provenance P
;;;                         :content CONTENT)
;;;   texts/<64 hex>        one immutable file per text: its UTF-8 octets, the
;;;                         name being the hex part of its hash
;;;   refs/start            H3c ref file: the session's :start revision
;;; Persist on reference: nothing is written when a revision is committed.
;;; The session's next write (COMMIT-TURN, MOVE-SESSION-HEAD, CLONE-SESSION,
;;; anything that writes through the session store) first writes, under the
;;; session's lock, every revision, text and the start ref of the instruction
;;; store that are not on disk yet. A program started and quit still leaves
;;; nothing; a turn record is never on disk without the revision it names.
;;; Files are written atomically and never rewritten: a file already there
;;; (another process wrote the same content-addressed file) is kept. No lock
;;; of its own: the files are immutable and content-addressed, and refs/start
;;; is written only when absent.
;;; Re-hydration: SESSION-INSTRUCTION-STORE of a session that is on disk
;;; reads every revisions/*.sexp and refs/start into the memory store
;;; (texts are read on demand); SYNC-SESSION reads the revision files written
;;; since. A file that does not read as above, or a revision file whose
;;; content does not hash to its name, signals SESSION-ERROR naming it.
;;; Durability lives in the sidecar, not in the turn records: a record keeps
;;; one id, and a set that many turns share is stored once.
;;;
;;; Sessions. SESSION-INSTRUCTION-SET session &optional (designator head) →
;;; the id for DESIGNATOR: "0" → the start ref's id; otherwise the
;;; RECORD-INSTRUCTIONS of the deepest record on DESIGNATOR's first-parent
;;; line that has one; else the start ref's id; else NIL (no head and no
;;; start ref, or records written without the wiring). Records with no
;;; :INSTRUCTIONS read as before.
;;;
;;; The process (the implementation wires it; -p, the TUI, the SDK and --rpc
;;; alike):
;;;   - a new session: LOAD-INSTRUCTION-CONTEXT, MAKE-INSTRUCTION-SET with the
;;;     context and the session's CODE-INSTRUCTION-DISCOVERY (linked: its rule
;;;     loads and forgets commit), commit :START; the init event's
;;;     "instruction_set" is the id;
;;;   - a continued session: H = SESSION-INSTRUCTION-SET of the head;
;;;     LOAD-INSTRUCTION-CONTEXT :SESSION-RULES (INSTRUCTION-SET-LOADED-RULES
;;;     store H), the set, commit :RESUME (H again when nothing changed);
;;;   - every turn record: :INSTRUCTIONS = INSTRUCTION-SET-CURRENT at its end;
;;;   - the head moved in this process (REWIND-TO's conversation part, H3c's
;;;     /rewind, /fork at an earlier turn, the SDK's rewind): RESTORE-
;;;     INSTRUCTION-SET to SESSION-INSTRUCTION-SET of the new head ("0" for
;;;     no head) before the next model call. The instruction set follows the
;;;     conversation: a files-only rewind leaves it alone, and there is no
;;;     rewind mode of its own (a loaded rule's text is in the conversation's
;;;     history, so the two can only move together);
;;;   - a fork into a new session (--fork-session, /clone, the SDK's fork, a
;;;     conflict fork): CLONE-SESSION copies the instruction revisions the
;;;     copied records name, the start ref, and their texts, into the clone's
;;;     instruction store, written with the clone; the process then goes on
;;;     as a continued session of the clone;
;;;   - checkpoints (H5b): each new checkpoint's manifest gets an
;;;     :INSTRUCTIONS part, see src/checkpoints.lisp;
;;;   - events: the init event's "instruction_set" (the id after the :start
;;;     or :resume commit) and the instructions event's "instruction_set"
;;;     (the id after the load).
;;;   Compaction (H3f) re-injects the loaded rules' texts from the current
;;;   revision (INSTRUCTION-TEXT of their :text hashes) instead of forgetting
;;;   them; until then a FORGET-INSTRUCTIONS commits :FORGET.
;;;
;;; Threads: a set is committed from one thread at a time (the agent thread);
;;; INSTRUCTION-SET-CURRENT may be read from any thread.

(defparameter +instruction-set-format+ 1
  "The :INSTRUCTION-SET format number of a revision's content.")

(defparameter +instruction-set-roles+ '(:instruction-files :context-files :skills :rules)
  "The built-in components' roles, in registration order. H3e-2 adds :MCP-SERVERS.")

(defparameter +instruction-set-reasons+ '(:start :resume :rule :forget :component)
  "COMMIT-INSTRUCTION-SET reasons H3e-1 uses (any keyword is accepted).")

(defparameter +instruction-start-ref+ "start"
  "The instruction store's ref naming the session's :START revision.")

;;; The component protocol.

(defgeneric component-role (component)
  (:documentation "→ COMPONENT's role: a keyword, unique within its instruction set."))

(defgeneric component-snapshot (component store)
  (:documentation "→ COMPONENT's state now as data (strings, integers, keywords,
T, NIL, lists of those). Texts go through INTERN-INSTRUCTION-TEXT STORE."))

(defgeneric component-restore (component snapshot store)
  (:documentation "Make COMPONENT's live state equal SNAPSHOT (a value
COMPONENT-SNAPSHOT returned). Texts come back through INSTRUCTION-TEXT STORE.
The value is ignored."))

(defgeneric instruction-set-components (set)
  (:documentation "→ SET's components in registration order (a fresh list)."))

;;; The store.

(defclass instruction-store (rev:in-memory-store)
  ((session :initarg :session :initform nil :reader instruction-store-session
            :documentation "The SESSION-STORE this store belongs to.")
   (texts :initform (make-hash-table :test 'equal) :reader %instruction-store-texts
          :documentation "\"sha256:…\" → string, the texts known in this image.")
   (written :initform (make-hash-table :test 'equal) :reader %instruction-store-written
            :documentation "Revision ids and text hashes known to be on disk."))
  (:documentation "A session's instruction-set revisions: revision-protocol's
in-memory store plus a text table, written to INSTRUCTIONS-DIRECTORY by the
session's writes (see the file header). Get it with SESSION-INSTRUCTION-STORE."))

(defun instruction-store-p (x) (typep x 'instruction-store))

(defun instructions-directory (session)
  "→ <session dir>/instructions/ of the SESSION-STORE SESSION (it may not exist)."
  (merge-pathnames "instructions/" (session-directory session)))

;;; The live set.

(defclass instruction-set ()
  ((store :initarg :store :reader instruction-set-store
          :documentation "The INSTRUCTION-STORE revisions go to.")
   (components :initform '() :accessor %instruction-set-components
               :documentation "Components, registration order.")
   (current :initform nil :accessor %instruction-set-current
            :documentation "The id of the current revision, or NIL before the first commit."))
  (:documentation "H3e-1: a process's instruction set over a session's
INSTRUCTION-STORE (see the file header). Make it with MAKE-INSTRUCTION-SET."))

(defun instruction-set-p (x) (typep x 'instruction-set))

(defun instruction-set-current (set)
  "→ the id of SET's current revision, or NIL before its first commit."
  (%instruction-set-current set))

(defmethod instruction-set-components ((set instruction-set))
  (copy-list (%instruction-set-components set)))

;;; Errors.

(defun %iset-fail (control &rest args)
  (error 'instruction-set-error :message (apply #'format nil control args)))

;;; Texts.

(defun %instruction-texts-directory (session)
  (merge-pathnames "texts/" (instructions-directory session)))

(defun %instruction-revisions-directory (session)
  (merge-pathnames "revisions/" (instructions-directory session)))

(defun %instruction-start-file (session)
  (merge-pathnames "refs/start" (instructions-directory session)))

(defun %text-hash-p (x)
  (and (stringp x) (= 71 (length x)) (uiop:string-prefix-p "sha256:" x)
       (%hex-string-p (subseq x 7))))

(defun %text-file (session hash)
  (make-pathname :name (subseq hash 7) :type nil :version nil
                 :defaults (%instruction-texts-directory session)))

(defun intern-instruction-text (store string)
  "→ \"sha256:<hex>\" of STRING, kept in STORE."
  (check-type string string)
  (let ((hash (p:octets-hash (p:utf8-encode string))))
    (setf (gethash hash (%instruction-store-texts store)) string)
    hash))

(defun instruction-text (store hash)
  "→ the text whose INTERN-INSTRUCTION-TEXT hash is HASH, or INSTRUCTION-SET-ERROR."
  (or (gethash hash (%instruction-store-texts store))
      (let* ((session (instruction-store-session store))
             (file (and session (%text-hash-p hash) (%text-file session hash))))
        (unless (and file (probe-file file))
          (%iset-fail "instruction text ~a is missing" hash))
        (let* ((octets (handler-case (p:read-bytes (uiop:native-namestring file))
                         (error (e) (%iset-fail "instruction text ~a cannot be read: ~a"
                                                (uiop:native-namestring file) e))))
               (text (handler-case (p:utf8-decode octets)
                       (error () nil))))
          (unless (and text (equal hash (p:octets-hash octets)))
            (%iset-fail "instruction text ~a does not match its hash" (uiop:native-namestring file)))
          (setf (gethash hash (%instruction-store-texts store)) text)))))

(defun %content-text-hashes (form)
  "The \"sha256:…\" strings in FORM (a revision content), in order, no duplicates."
  (let ((out '()))
    (labels ((walk (x)
               (cond ((%text-hash-p x) (pushnew x out :test #'string=))
                     ((consp x) (walk (car x)) (walk (cdr x))))))
      (walk form))
    (nreverse out)))

;;; Ids and data.

(defun %data-p (x)
  "Strings, integers, keywords, T, NIL and proper lists of those."
  (typecase x
    (null t)
    (string t)
    (integer t)
    (keyword t)
    ((eql t) t)
    (cons (let ((n (handler-case (list-length x) (error () nil))))
            (and n (every #'%data-p x))))
    (t nil)))

(defun instruction-set-id (content)
  "→ the 64-hex id of the revision CONTENT. See the header."
  (subseq (p:octets-hash (p:utf8-encode (%print-data content))) (length "sha256:")))

;;; The store and the sidecar.

(defun %find-set-revision (store id)
  (handler-case (rev:resolve-revision store id)
    (rev:revision-not-found () nil)))

(defun %write-instruction-file (file text)
  "Write TEXT to FILE atomically unless FILE is there already (immutable,
content-addressed)."
  (unless (probe-file file)
    (ensure-directories-exist file)
    (%write-file-atomically file text)))

(defun %flush-instruction-store (store)
  "Write every revision, text and the start ref of the INSTRUCTION-STORE STORE
that is not on disk yet (persist on reference; see the header)."
  (let ((session (instruction-store-session store))
        (written (%instruction-store-written store)))
    (when session
      (dolist (r (rev:heads store))
        (let ((id (rev:revision-id r)))
          (unless (gethash id written)
            (dolist (hash (%content-text-hashes (rev:revision-content r)))
              (unless (gethash hash written)
                (let ((text (gethash hash (%instruction-store-texts store))))
                  (when text
                    (let ((file (%text-file session hash)))
                      (unless (probe-file file)
                        (ensure-directories-exist file)
                        (p:write-text file text :atomic t)))
                    (setf (gethash hash written) t)))))
            (%write-instruction-file
             (make-pathname :name id :type "sexp" :defaults (%instruction-revisions-directory session))
             (%print-data (%revision-plist r)))
            (setf (gethash id written) t))))
      (let ((ref (rev:find-ref store +instruction-start-ref+)))
        (when (and ref (not (gethash :start-ref written)))
          (%write-instruction-file (%instruction-start-file session) (%ref-text ref))
          (setf (gethash :start-ref written) t))))
    store))

(defun %hydrate-instruction-store (store)
  "Read the revision files (and refs/start) of STORE's session that STORE does
not hold yet. A bad file → SESSION-ERROR naming it."
  (let* ((session (instruction-store-session store))
         (written (%instruction-store-written store))
         (dir (and session (%instruction-revisions-directory session))))
    (when (and dir (uiop:directory-exists-p dir))
      (dolist (file (uiop:directory-files dir "*.sexp"))
        (let ((name (pathname-name file)))
          (unless (or (%hidden-name-p name) (%find-set-revision store name))
            (let ((plist (%read-revision-file session file)))
              (destructuring-bind (&key id parents recorded-at message provenance content
                                   &allow-other-keys)
                  plist
                (unless (and (null parents) (equal id (instruction-set-id content)))
                  (%session-file-error session file "does not hash to its name"))
                (dt:with-fixed-clock ((dt:make-instant (first recorded-at) (second recorded-at)))
                  (rev:commit-revision store content :id id :parents '()
                                                     :message message :provenance provenance))
                (setf (gethash id written) t)))))))
    (let ((file (and session (%instruction-start-file session))))
      (when (and file (not (rev:find-ref store +instruction-start-ref+)) (probe-file file))
        (let ((text (handler-case (uiop:read-file-string file :external-format :utf-8)
                      (error (e) (%session-file-error session file "cannot be read: ~a" e)))))
          (multiple-value-bind (kind target) (%parse-ref-text session file text)
            (unless (and (eq kind :movable) (%find-set-revision store target))
              (%session-file-error session file "names revision ~a, which is not in the session" target))
            (rev:move-ref store +instruction-start-ref+ target)
            (setf (gethash :start-ref written) t)))))
    store))

(defun %session-write-instructions (session)
  "%PERSIST's first step: the session's instruction sidecar."
  (when (typep session 'session-store)
    (let ((store (%session-instructions session)))
      (when store (%flush-instruction-store store)))))

(defun %session-read-instructions (session)
  "%SYNC's last step: revision files other processes wrote."
  (when (typep session 'session-store)
    (let ((store (%session-instructions session)))
      (when store (%hydrate-instruction-store store)))))

(defun session-instruction-store (session)
  "→ the INSTRUCTION-STORE of the SESSION-STORE SESSION, re-hydrated from its
directory on first use. See the header."
  (check-type session session-store)
  (or (%session-instructions session)
      (let ((store (make-instance 'instruction-store
                                  :engine (make-instance 'diff:sexp-diff-engine)
                                  :session session))
            (done nil))
        (setf (%session-instructions session) store)
        (unwind-protect
             (progn (%hydrate-instruction-store store)
                    (setf done t)
                    store)
          (unless done
            (setf (%session-instructions session) nil))))))

(defun %copy-instruction-revisions (from to ids)
  "Copy the revisions IDS (those FROM's instruction store has), their texts
and FROM's start ref (with its revision) into TO's instruction store, not
written yet: TO's next write writes them. FROM and TO are session stores."
  (let* ((src (session-instruction-store from))
         (dst (session-instruction-store to))
         (start (rev:find-ref src +instruction-start-ref+))
         (ids (remove-duplicates (append (remove nil ids) (and start (list (rev:ref-target start))))
                                 :test #'equal :from-end t)))
    (dolist (id ids)
      (let ((r (%find-set-revision src id)))
        (when (and r (not (%find-set-revision dst (rev:revision-id r))))
          (let ((at (rev:revision-recorded-at r)))
            (dt:with-fixed-clock (at)
              (rev:commit-revision dst (rev:revision-content r)
                                   :id (rev:revision-id r) :parents '()
                                   :message (rev:revision-message r)
                                   :provenance (rev:revision-provenance r))))
          (dolist (hash (%content-text-hashes (rev:revision-content r)))
            (let ((text (handler-case (instruction-text src hash)
                          (instruction-set-error () nil))))
              (when text
                (setf (gethash hash (%instruction-store-texts dst)) text)))))))
    (when (and start (not (rev:find-ref dst +instruction-start-ref+))
               (%find-set-revision dst (rev:ref-target start)))
      (rev:move-ref dst +instruction-start-ref+ (rev:ref-target start)))
    dst))

;;; Built-in components.

(defclass %builtin-component ()
  ((role :initarg :role :reader component-role)
   (data :initarg :data :accessor %component-data
         :documentation "The snapshot (data), as made from the context or restored."))
  (:documentation "H3e-1: a built-in component whose live state is its data."))

(defclass %instruction-files-component (%builtin-component) ())
(defclass %context-files-component (%builtin-component) ())

(defclass %skills-component (%builtin-component)
  ((tools :initform '() :accessor %component-tools
          :documentation "SKILL-TOOLS sources that serve this component's skills."))
  (:documentation ":skills: the index; a restore gives the linked skill tools its skills."))

(defclass %rules-component (%builtin-component)
  ((cell :initarg :cell :reader %component-cell
         :documentation "The loaded set's cons (the discovery's, or its own)."))
  (:documentation ":rules: DATA is the :found list; the loaded set lives in CELL."))

(defmethod component-snapshot ((c %builtin-component) store)
  (declare (ignore store))
  (copy-tree (%component-data c)))

(defmethod component-restore ((c %builtin-component) snapshot store)
  (declare (ignore store))
  (setf (%component-data c) (copy-tree snapshot)))

(defmethod component-snapshot ((c %rules-component) store)
  (declare (ignore store))
  (list :found (copy-tree (%component-data c))
        :loaded (copy-list (car (%component-cell c)))))

(defmethod component-restore ((c %rules-component) snapshot store)
  (declare (ignore store))
  (setf (%component-data c) (copy-tree (getf snapshot :found))
        (car (%component-cell c)) (copy-list (getf snapshot :loaded))))

(defun %snapshot-skill (entry)
  "A STEER-DIRECTIVE (kind :SKILL, no body: the tool reads it) from a :skills entry."
  (steer:make-steer-directive :kind :skill
                              :name (getf entry :name)
                              :description (getf entry :description)
                              :body nil
                              :path (uiop:parse-native-namestring (getf entry :path))
                              :extra (list :source (getf entry :source))))

(defmethod component-restore :after ((c %skills-component) snapshot store)
  (declare (ignore store))
  (let ((skills (mapcar #'%snapshot-skill snapshot)))
    (dolist (tools (%component-tools c))
      (setf (slot-value tools 'skills) skills))))

(defun %native (path) (uiop:native-namestring path))

(defun %safe-file-sha256 (path)
  (handler-case (%file-sha256 path)
    (error () nil)))

(defun %instruction-files-data (context store)
  (loop for entry in (%context-file-entries context)
        collect (list :path (%native (getf entry :path))
                      :source (getf entry :source)
                      :sha256 (getf entry :sha256)
                      :block (intern-instruction-text store (getf entry :block))
                      :imports (loop for (path . from) in (getf entry :imports)
                                     collect (list :path (%native path)
                                                   :from (%native from)
                                                   :sha256 (%safe-file-sha256 path))))))

(defun %skills-data (context)
  (loop for skill in (context-skills context)
        for path = (steer:steer-directive-path skill)
        collect (list :name (steer:steer-directive-name skill)
                      :description (steer:steer-directive-description skill)
                      :path (%native path)
                      :source (skill-source skill)
                      :sha256 (%safe-file-sha256 path))))

(defun %rules-data (context store)
  (loop for rule in (context-rules context)
        collect (list :path (%rule-native rule)
                      :paths (rule-patterns rule)
                      :text (intern-instruction-text store (steer:steer-directive-body rule)))))

(defun make-instruction-set (store &key context discovery)
  "→ an INSTRUCTION-SET on STORE: the built-in components for CONTEXT (an
INSTRUCTION-CONTEXT; none when NIL), linked to DISCOVERY (a
CODE-INSTRUCTION-DISCOVERY) when given. Commits nothing."
  (check-type store instruction-store)
  (let ((set (make-instance 'instruction-set :store store)))
    (when context
      (add-instruction-component
       set (make-instance '%instruction-files-component
                          :role :instruction-files :data (%instruction-files-data context store)))
      (add-instruction-component
       set (make-instance '%context-files-component
                          :role :context-files
                          :data (loop for (native . found) in (%context-configured context)
                                      collect (list :path native :found found))))
      (add-instruction-component
       set (make-instance '%skills-component :role :skills :data (%skills-data context)))
      (add-instruction-component
       set (make-instance '%rules-component
                          :role :rules
                          :data (%rules-data context store)
                          :cell (if discovery
                                    (%discovery-loaded discovery)
                                    (list (copy-list (context-loaded-rules context)))))))
    (when discovery
      (setf (car (%discovery-link discovery)) set))
    set))

(defun %link-skill-tools (set tools)
  "Let SET's :skills component restore the SKILL-TOOLS source TOOLS (NIL: nothing)."
  (let ((c (and set tools (find :skills (%instruction-set-components set) :key #'component-role))))
    (when (typep c '%skills-component)
      (pushnew tools (%component-tools c)))
    tools))

(defun add-instruction-component (set component)
  "Register COMPONENT last in SET → COMPONENT. A role already in SET →
INSTRUCTION-SET-ERROR. Commits nothing."
  (let ((role (component-role component)))
    (when (find role (%instruction-set-components set) :key #'component-role)
      (%iset-fail "the instruction set already has a ~(~s~) component" role))
    (setf (%instruction-set-components set)
          (append (%instruction-set-components set) (list component)))
    component))

(defun commit-instruction-set (set reason)
  "→ (values id new-p): the revision of SET's components now. See the header."
  (check-type reason keyword)
  (let* ((store (instruction-set-store set))
         (content (list :instruction-set +instruction-set-format+
                        :components
                        (loop for c in (%instruction-set-components set)
                              for snapshot = (component-snapshot c store)
                              unless (%data-p snapshot)
                                do (%iset-fail "the ~(~s~) component's snapshot is not data"
                                               (component-role c))
                              collect (list :role (component-role c) :snapshot snapshot))))
         (id (instruction-set-id content))
         (new-p (null (%find-set-revision store id))))
    (when new-p
      (rev:commit-revision store content
                           :id id :parents '()
                           :message (format nil "instructions: ~(~a~)" reason)
                           :provenance (list :kind :instructions :reason reason :version +version+)))
    (when (and (eq reason :start) (null (rev:find-ref store +instruction-start-ref+)))
      (rev:move-ref store +instruction-start-ref+ id))
    (setf (%instruction-set-current set) id)
    (values id new-p)))

(defun read-instruction-set (store id)
  "→ ((role . snapshot) …) of revision ID in STORE, content order."
  (let ((content (rev:revision-content (rev:resolve-revision store id))))
    (loop for entry in (getf (cddr content) :components)
          collect (cons (getf entry :role) (getf entry :snapshot)))))

(defun restore-instruction-set (set id)
  "Restore SET's components to revision ID → ID. See the header."
  (let* ((store (instruction-set-store set))
         (full (rev:revision-id (rev:resolve-revision store id)))
         (alist (read-instruction-set store full)))
    (dolist (c (%instruction-set-components set))
      (let ((hit (assoc (component-role c) alist)))
        (when hit
          (component-restore c (cdr hit) store))))
    (setf (%instruction-set-current set) full)
    full))

(defun %rule-text-block (native text)
  (format nil "<rule path=\"~a\">~%~a~%</rule>" native text))

(defun instruction-set-blocks (store id)
  "→ the system prompt blocks of revision ID. See the header."
  (let ((alist (read-instruction-set store id)))
    (append (loop for entry in (cdr (assoc :instruction-files alist))
                  collect (instruction-text store (getf entry :block)))
            (loop for entry in (getf (cdr (assoc :rules alist)) :found)
                  unless (getf entry :paths)
                    collect (%rule-text-block (getf entry :path)
                                              (instruction-text store (getf entry :text))))
            (let ((section (skill-listing-section
                            (mapcar #'%snapshot-skill (cdr (assoc :skills alist))))))
              (and section (list section))))))

(defun instruction-set-loaded-rules (store id)
  "→ native paths of the rules in context in revision ID, load order."
  (copy-list (getf (cdr (assoc :rules (read-instruction-set store id))) :loaded)))

(defun %start-id (store)
  (let ((ref (rev:find-ref store +instruction-start-ref+)))
    (and ref (rev:ref-target ref))))

(defun session-instruction-set (session &optional (designator +head-ref+))
  "→ the instruction-set revision id for DESIGNATOR on SESSION, or NIL. See the
header."
  (let ((store (session-instruction-store session)))
    (or (and (not (equal designator "0"))
             (loop for r in (reverse (session-line session designator))
                   for id = (record-instructions (revision-record r))
                   when id return id))
        (%start-id store))))

;;; The process (src/headless.lisp, src/client.lisp, src/program.lisp).

(defun %open-session-instructions (cwd settings session &key user-config-dir)
  "One context, discovery and set per session per process: :RESUME when
SESSION has a head or a start revision, else :START. → (values context
discovery set)."
  (let* ((store (session-instruction-store session))
         (head (session-instruction-set session))
         (context (load-instruction-context
                   cwd :settings settings :user-config-dir user-config-dir
                       :session-rules (and head (%find-set-revision store head)
                                           (instruction-set-loaded-rules store head))))
         (discovery (make-code-instruction-discovery
                     cwd :rules (context-rules context)
                         :project-dir (context-project-dir context)
                         :loaded (context-loaded-rules context)))
         (set (make-instruction-set store :context context :discovery discovery)))
    (commit-instruction-set set (if (or (session-head session) head) :resume :start))
    (values context discovery set)))

(defun %follow-head (set session)
  "After an in-process head move: restore SET to SESSION-INSTRUCTION-SET of the
new head (the start revision for no head). → the id, or NIL (nothing known)."
  (when set
    (let ((id (session-instruction-set session)))
      (when (and id (%find-set-revision (instruction-set-store set) id))
        (restore-instruction-set set id)))))

(defun %rehome-instruction-set (set session)
  "SESSION (a fork or a clone of SET's session) is where SET's revisions go
from now on: its instruction store gets SET's current revision (its next
write writes it), and SET moves to it. → SET."
  (when (and set (not (eq (instruction-store-session (instruction-set-store set)) session)))
    (let ((old (instruction-store-session (instruction-set-store set))))
      (%copy-instruction-revisions old session (list (instruction-set-current set)))
      (setf (slot-value set 'store) (session-instruction-store session))))
  set)

(defun %restart-instruction-set (set discovery session)
  "A new conversation in this process (SESSION, a new session): SET moves to
it with only the always-on rules loaded, committed :START. → the id or NIL."
  (when set
    (setf (slot-value set 'store) (session-instruction-store session))
    (when discovery
      (setf (car (%discovery-loaded discovery))
            (loop for rule in (discovery-rules discovery)
                  when (rule-always-p rule) collect (%rule-native rule))))
    (commit-instruction-set set :start)))
