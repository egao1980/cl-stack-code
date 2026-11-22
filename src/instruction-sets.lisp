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

;;; Stubs.

(defun session-instruction-store (session)
  "→ the INSTRUCTION-STORE of the SESSION-STORE SESSION, re-hydrated from its
directory on first use. See the header."
  (declare (ignore session))
  (%h3e1-pending "session-instruction-store"))

(defun intern-instruction-text (store string)
  "→ \"sha256:<hex>\" of STRING, kept in STORE."
  (declare (ignore store string))
  (%h3e1-pending "intern-instruction-text"))

(defun instruction-text (store hash)
  "→ the text whose INTERN-INSTRUCTION-TEXT hash is HASH, or INSTRUCTION-SET-ERROR."
  (declare (ignore store hash))
  (%h3e1-pending "instruction-text"))

(defun instruction-set-id (content)
  "→ the 64-hex id of the revision CONTENT. See the header."
  (declare (ignore content))
  (%h3e1-pending "instruction-set-id"))

(defun make-instruction-set (store &key context discovery)
  "→ an INSTRUCTION-SET on STORE: the built-in components for CONTEXT (an
INSTRUCTION-CONTEXT; none when NIL), linked to DISCOVERY (a
CODE-INSTRUCTION-DISCOVERY) when given. Commits nothing."
  (declare (ignore store context discovery))
  (%h3e1-pending "make-instruction-set"))

(defun add-instruction-component (set component)
  "Register COMPONENT last in SET → COMPONENT. A role already in SET →
INSTRUCTION-SET-ERROR. Commits nothing."
  (declare (ignore set component))
  (%h3e1-pending "add-instruction-component"))

(defun commit-instruction-set (set reason)
  "→ (values id new-p): the revision of SET's components now. See the header."
  (declare (ignore set reason))
  (%h3e1-pending "commit-instruction-set"))

(defun restore-instruction-set (set id)
  "Restore SET's components to revision ID → ID. See the header."
  (declare (ignore set id))
  (%h3e1-pending "restore-instruction-set"))

(defun read-instruction-set (store id)
  "→ ((role . snapshot) …) of revision ID in STORE, content order."
  (declare (ignore store id))
  (%h3e1-pending "read-instruction-set"))

(defun instruction-set-blocks (store id)
  "→ the system prompt blocks of revision ID. See the header."
  (declare (ignore store id))
  (%h3e1-pending "instruction-set-blocks"))

(defun instruction-set-loaded-rules (store id)
  "→ native paths of the rules in context in revision ID, load order."
  (declare (ignore store id))
  (%h3e1-pending "instruction-set-loaded-rules"))

(defun session-instruction-set (session &optional (designator +head-ref+))
  "→ the instruction-set revision id for DESIGNATOR on SESSION, or NIL. See the
header."
  (declare (ignore session designator))
  (%h3e1-pending "session-instruction-set"))
