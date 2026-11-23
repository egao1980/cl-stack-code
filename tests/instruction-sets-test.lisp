(in-package #:cl-stack-code/tests)

;;; H3e-1: the instruction set as revisions (src/instruction-sets.lisp): the
;;; component protocol (with fake components), content-addressed ids, texts,
;;; the sidecar files and re-hydration, turn records, clones, the built-in
;;; components, and the rules loaded through a linked discovery (a restore
;;; drops later rules; they load again lazily).

;;; Fake components.

(defclass fake-component ()
  ((role :initarg :role :reader component-role)
   (value :initarg :value :accessor fake-value)
   (restored :initform '() :accessor fake-restored))
  (:documentation "Snapshot = VALUE as is; restore sets it and notes the snapshot."))

(defmethod component-snapshot ((c fake-component) store)
  (declare (ignore store))
  (fake-value c))

(defmethod component-restore ((c fake-component) snapshot store)
  (declare (ignore store))
  (push snapshot (fake-restored c))
  (setf (fake-value c) snapshot))

(defclass text-component (fake-component) ()
  (:documentation "Snapshot = (:text HASH) of VALUE through the store's texts."))

(defmethod component-snapshot ((c text-component) store)
  (list :text (intern-instruction-text store (fake-value c))))

(defmethod component-restore ((c text-component) snapshot store)
  (push snapshot (fake-restored c))
  (setf (fake-value c) (instruction-text store (getf snapshot :text))))

(defun fake (role value &optional (class 'fake-component))
  (make-instance class :role role :value value))

(defun fake-set (session &rest components)
  "An INSTRUCTION-SET on SESSION's instruction store with COMPONENTS only."
  (let ((set (make-instruction-set (session-instruction-store session))))
    (dolist (c components set)
      (add-instruction-component set c))))

(defun printed-data (form)
  (with-standard-io-syntax
    (let ((*package* (find-package :keyword)))
      (format nil "~s~%" form))))

(defun expected-set-id (content)
  "The 64 hex digits of the sha256 of CONTENT printed as H3c prints files."
  (subseq (p:octets-hash (p:utf8-encode (printed-data content))) (length "sha256:")))

(defun text-hash (string)
  (p:octets-hash (p:utf8-encode string)))

(defun read-data (path)
  (with-standard-io-syntax
    (let ((*package* (find-package :keyword))
          (*read-eval* nil))
      (read-from-string (uiop:read-file-string path :external-format :utf-8)))))

(defun set-revision-count (store)
  "Instruction-set revisions are roots, so each one is a head."
  (length (rev:heads store)))

(defun hex-64-p (x)
  (and (stringp x) (= 64 (length x))
       (every (lambda (c) (find c "0123456789abcdef")) x)))

;;; Records.

(defparameter +set-a+ (make-string 64 :initial-element #\a))
(defparameter +set-b+ (make-string 64 :initial-element #\b))

(deftest iset-record-content
  (let* ((with (make-turn-record :prompt "p" :instructions +set-a+))
         (without (make-turn-record :prompt "p")))
    (ok (equal +set-a+ (getf (record-content with) :instructions)))
    (ok (not (member :instructions (record-content without))) "older record shapes are unchanged")
    (ok (equal +set-a+ (record-instructions (content-record (record-content with)))))
    (ok (null (record-instructions (content-record (record-content without)))))
    (ok (not (member :rules (record-content with))) "no per-turn rules list")
    (dolist (bad (list 3 "abc" (list +set-a+)))
      (ok (signals (content-record (append (record-content without) (list :instructions bad)))
                   'session-error)))))

;;; Components, commits and restores.

(deftest iset-commit-and-restore
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (c (fake :fake "a"))
           (set (fake-set s c))
           (store (instruction-set-store set)))
      (ok (instruction-set-p set))
      (ok (instruction-store-p store))
      (ok (eq store (session-instruction-store s)) "one store per session store object")
      (ok (eq s (instruction-store-session store)))
      (ok (null (instruction-set-current set)) "nothing committed yet")
      (multiple-value-bind (id1 new-1) (commit-instruction-set set :start)
        (ok (hex-64-p id1))
        (ok new-1)
        (ok (equal id1 (instruction-set-current set)))
        (setf (fake-value c) "b")
        (multiple-value-bind (id2 new-2) (commit-instruction-set set :component)
          (ok (not (equal id1 id2)))
          (ok new-2)
          (ok (equal id2 (instruction-set-current set)))
          (ok (equal '((:fake . "a")) (read-instruction-set store id1)))
          (ok (equal '((:fake . "b")) (read-instruction-set store (subseq id2 0 8))) "an id prefix")
          (ok (equal id1 (restore-instruction-set set id1)))
          (ok (equal "a" (fake-value c)) "the component is restored")
          (ok (equal '("a") (fake-restored c)))
          (ok (equal id1 (instruction-set-current set)))
          (ok (= 2 (set-revision-count store)) "a restore commits nothing")
          (ok (typep (failure (restore-instruction-set set +set-b+)) 'rev:revision-not-found)))))))

(deftest iset-revision-shape
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (set (fake-set s (fake :fake '(:x 1 "y" (t nil)))))
           (store (instruction-set-store set))
           (id (commit-instruction-set set :start))
           (r (rev:resolve-revision store id))
           (content '(:instruction-set 1 :components ((:role :fake :snapshot (:x 1 "y" (t nil)))))))
      (ok (equal content (rev:revision-content r)))
      (ok (equal id (expected-set-id content)) "the id is the sha256 of the printed content")
      (ok (equal id (instruction-set-id content)))
      (ok (null (rev:revision-parent-ids r)) "a root")
      (ok (equal "instructions: start" (rev:revision-message r)))
      (ok (equal (list :kind :instructions :reason :start :version +version+)
                 (rev:revision-provenance r))))))

(deftest iset-content-addressed
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (c (fake :fake "a"))
           (set (fake-set s c))
           (store (instruction-set-store set))
           (id1 (commit-instruction-set set :start)))
      (multiple-value-bind (again new-p) (commit-instruction-set set :resume)
        (ok (equal id1 again) "an unchanged set is the same revision")
        (ok (null new-p)))
      (ok (= 1 (set-revision-count store)))
      (setf (fake-value c) "b")
      (commit-instruction-set set :component)
      (setf (fake-value c) "a")
      (multiple-value-bind (back new-p) (commit-instruction-set set :component)
        (ok (equal id1 back) "back to the first state, back to its revision")
        (ok (null new-p)))
      (ok (= 2 (set-revision-count store)))
      (ok (equal :start (getf (rev:revision-provenance (rev:resolve-revision store id1)) :reason))
          "the first commit's reason stays")
      (let ((other (fake-set (create-session dir) (fake :fake "a"))))
        (ok (equal id1 (commit-instruction-set other :start))
            "the same set has the same id in another session")))))

(deftest iset-component-order-and-roles
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (a (fake :a 1))
           (b (fake :b 2))
           (set (fake-set s a b)))
      (ok (equal (list a b) (instruction-set-components set)) "registration order")
      (let ((id (commit-instruction-set set :start)))
        (ok (equal '((:a . 1) (:b . 2)) (read-instruction-set (instruction-set-store set) id))))
      (ok (typep (failure (add-instruction-component set (fake :a 3))) 'instruction-set-error)
          "one component per role")
      (ok (equal (list a b) (instruction-set-components set))))))

(deftest iset-absent-role-left-alone
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (a (fake :a 1))
           (set (fake-set s a))
           (id1 (commit-instruction-set set :start))
           (b (fake :b "x")))
      (add-instruction-component set b)
      (commit-instruction-set set :component)
      (setf (fake-value a) 2 (fake-value b) "y")
      (restore-instruction-set set id1)
      (ok (eql 1 (fake-value a)))
      (ok (equal "y" (fake-value b)) "a role the revision lacks keeps its live state")
      (ok (null (fake-restored b))))))

(deftest iset-snapshot-must-be-data
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (c (fake :fake "a"))
           (set (fake-set s c))
           (id (commit-instruction-set set :start)))
      (setf (fake-value c) (make-hash-table))
      (ok (typep (failure (commit-instruction-set set :component)) 'instruction-set-error))
      (ok (equal id (instruction-set-current set)) "nothing committed")
      (ok (= 1 (set-revision-count (instruction-set-store set)))))))

(deftest iset-texts
  (with-sessions-dir (dir)
    (let* ((s (create-session dir))
           (store (session-instruction-store s))
           (h (intern-instruction-text store "héllo")))
      (ok (equal (text-hash "héllo") h) "\"sha256:\" and 64 hex, of the UTF-8")
      (ok (equal "héllo" (instruction-text store h)))
      (ok (equal h (intern-instruction-text store "héllo")))
      (ok (typep (failure (instruction-text store (text-hash "never interned"))) 'instruction-set-error)))))

;;; The sidecar: persist on reference, re-hydrate on open.

(defun sidecar-session (dir)
  "A session whose start set holds a text-component \"hello\" and whose one
turn names it. → (values session id)."
  (let* ((s (create-session dir))
         (set (fake-set s (fake :notes "hello" 'text-component)))
         (id (commit-instruction-set set :start)))
    (values s id set)))

(deftest iset-sidecar-written-with-the-session
  (with-sessions-dir (dir)
    (multiple-value-bind (s id) (sidecar-session dir)
      (ok (not (probe-file (session-directory s))) "a commit alone writes nothing")
      (commit-turn s (simple-record "one" "1" :instructions id))
      (let* ((idir (instructions-directory s))
             (file (merge-pathnames (format nil "revisions/~a.sexp" id) idir))
             (hex (subseq (text-hash "hello") 7)))
        (ok (same-path (merge-pathnames "instructions/" (session-directory s)) idir))
        (ok (probe-file file) "the revision a record names is written with it")
        (when (probe-file file)
          (let ((plist (read-data file)))
            (ok (eql 1 (getf plist :format)))
            (ok (equal id (getf plist :id)))
            (ok (null (getf plist :parents)))
            (ok (equal "instructions: start" (getf plist :message)))
            (ok (equal (list :kind :instructions :reason :start :version +version+)
                       (getf plist :provenance)))
            (ok (equal (list :instruction-set 1
                             :components (list (list :role :notes
                                                     :snapshot (list :text (text-hash "hello")))))
                       (getf plist :content)))))
        (ok (equal "hello" (file-string (merge-pathnames (format nil "texts/~a" hex) idir)))
            "texts/<hex>: the text's UTF-8")
        (ok (equal (format nil "~a~%" id) (file-string (merge-pathnames "refs/start" idir)))
            "refs/start names the :start revision")
        (ok (equal id (record-instructions
                       (first (session-records (open-session dir (session-id s))))))
            "the record names it on disk")))))

(deftest iset-rehydrated-on-open
  (with-sessions-dir (dir)
    (multiple-value-bind (s id) (sidecar-session dir)
      (commit-turn s (simple-record "one" "1" :instructions id))
      (let* ((again (open-session dir (session-id s)))
             (store (session-instruction-store again)))
        (ok (not (eq store (session-instruction-store s))))
        (ok (equal id (rev:revision-id (rev:resolve-revision store id))) "re-hydrated")
        (ok (equal (list (cons :notes (list :text (text-hash "hello"))))
                   (read-instruction-set store id)))
        (ok (equal "hello" (instruction-text store (text-hash "hello"))) "texts read from disk")
        (ok (equal id (session-instruction-set again)))
        (ok (equal id (session-instruction-set again "0")) "the start ref")
        (let* ((c (fake :notes "?" 'text-component))
               (set (make-instruction-set store)))
          (add-instruction-component set c)
          (restore-instruction-set set id)
          (ok (equal "hello" (fake-value c)) "a resumed process restores from the sidecar")
          (setf (fake-value c) "hello")
          (multiple-value-bind (same new-p) (commit-instruction-set set :resume)
            (ok (equal id same))
            (ok (null new-p))))
        (commit-turn again (simple-record "two" "2" :instructions id))
        (ok (= 1 (length (uiop:directory-files (merge-pathnames "revisions/" (instructions-directory again)))))
            "one revision file for a set two turns share")))))

(deftest iset-sidecar-checked
  (with-sessions-dir (dir)
    (multiple-value-bind (s id) (sidecar-session dir)
      (commit-turn s (simple-record "one" "1" :instructions id))
      (let* ((idir (instructions-directory s))
             (file (merge-pathnames (format nil "revisions/~a.sexp" id) idir))
             (text (merge-pathnames (format nil "texts/~a" (subseq (text-hash "hello") 7)) idir)))
        (p:write-text text "tampered" :atomic t)
        (let ((store (session-instruction-store (open-session dir (session-id s)))))
          (ok (typep (failure (instruction-text store (text-hash "hello"))) 'instruction-set-error)
              "a text that does not match its hash"))
        (let ((plist (read-data file)))
          (setf (getf plist :content)
                (list :instruction-set 1 :components (list (list :role :notes :snapshot "changed"))))
          (p:write-text file (printed-data plist) :atomic t))
        (ok (typep (failure (session-instruction-store (open-session dir (session-id s))))
                   'session-error)
            "a revision whose content does not hash to its name")))))

;;; Sessions: the set at a turn, clones.

(deftest iset-session-instruction-set
  (with-sessions-dir (dir)
    (let ((plain (create-session dir)))
      (commit-turn plain (simple-record "one" "1"))
      (ok (null (session-instruction-set plain)) "records without the wiring, no start ref")
      (ok (null (session-instruction-set (create-session dir)))))
    (multiple-value-bind (s start) (sidecar-session dir)
      (ok (equal start (session-instruction-set s)) "no head: the start ref")
      (let ((r1 (commit-turn s (simple-record "one" "1" :instructions +set-a+)))
            (r2 (commit-turn s (simple-record "two" "2"))))
        (commit-turn s (simple-record "three" "3" :instructions +set-b+))
        (ok (equal +set-b+ (session-instruction-set s)))
        (ok (equal +set-a+ (session-instruction-set s (rev:revision-id r2)))
            "a record without one: the nearest earlier record's")
        (ok (equal +set-a+ (session-instruction-set s (rev:revision-id r1))))
        (ok (equal start (session-instruction-set s "0")))))))

(deftest iset-clone-copies
  (with-sessions-dir (dir)
    (multiple-value-bind (s start set) (sidecar-session dir)
      (let* ((c (first (instruction-set-components set)))
             (r1 (progn (setf (fake-value c) "turn one")
                        (commit-turn s (simple-record "one" "1"
                                                      :instructions (commit-instruction-set set :component)))))
             (id1 (record-instructions (revision-record r1)))
             (id2 (progn (setf (fake-value c) "turn two")
                         (commit-instruction-set set :component))))
        (commit-turn s (simple-record "two" "2" :instructions id2))
        (let* ((clone (clone-session s :at (rev:revision-id r1)))
               (idir (instructions-directory clone)))
          (ok (probe-file (merge-pathnames (format nil "revisions/~a.sexp" id1) idir))
              "the revisions the copied records name")
          (ok (probe-file (merge-pathnames (format nil "revisions/~a.sexp" start) idir)) "and the start one")
          (ok (not (probe-file (merge-pathnames (format nil "revisions/~a.sexp" id2) idir)))
              "not those of records left behind")
          (ok (equal (format nil "~a~%" start) (file-string (merge-pathnames "refs/start" idir))))
          (ok (equal "turn one" (file-string (merge-pathnames (format nil "texts/~a" (subseq (text-hash "turn one") 7))
                                                             idir))))
          (ok (equal id1 (session-instruction-set clone)))
          (let ((reopened (open-session dir (session-id clone))))
            (ok (equal (list (cons :notes (list :text (text-hash "turn one"))))
                       (read-instruction-set (session-instruction-store reopened) id1)))))))))

;;; The built-in components, from a context.

(defun iset-project ()
  (list (list "AGENTS.md" "Project rules.
@extra.md
")
        (list "extra.md" "Extra.
")
        (list ".claude/rules/always.md" "Always on.
")
        (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp rule."))
        (list "src/a.lisp" "(a)
")))

(defun snapshot-of (store id role)
  (cdr (assoc role (read-instruction-set store id))))

(deftest iset-builtin-components
  (with-project (project config) (iset-project)
    (write-skill project ".claude/skills/" "demo" "Demo skill.")
    (let* ((ctx-file (write-file config "ctx.md" "Context.
"))
           (settings (make-settings :context-files (list ctx-file)))
           (ctx (load-instruction-context project :settings settings :user-config-dir config :home config))
           (agents (merge-pathnames "AGENTS.md" project))
           (always (native (truename (merge-pathnames ".claude/rules/always.md" project))))
           (lisp (native (truename (merge-pathnames ".claude/rules/lisp.md" project)))))
      (with-sessions-dir (dir)
        (let* ((s (create-session dir :project-dir project))
               (store (session-instruction-store s))
               (set (make-instruction-set store :context ctx))
               (id (commit-instruction-set set :start)))
          (ok (equal +instruction-set-roles+ (mapcar #'component-role (instruction-set-components set))))
          (ok (equal +instruction-set-roles+ (mapcar #'car (read-instruction-set store id))))
          (let ((files (snapshot-of store id :instruction-files)))
            (ok (equal (list (native (truename ctx-file)) (native (truename agents)))
                       (mapcar (lambda (e) (getf e :path)) files)))
            (ok (equal '(:context :project) (mapcar (lambda (e) (getf e :source)) files)))
            (let ((entry (second files)))
              (ok (equal (text-hash "Project rules.
@extra.md
") (getf entry :sha256)) "the file's own text")
              (ok (equal (list (list :path (native (truename (merge-pathnames "extra.md" project)))
                                     :from (native (truename agents))
                                     :sha256 (text-hash "Extra.
")))
                         (getf entry :imports)))
              (ok (has "Extra." (instruction-text store (getf entry :block))) "the block, imports expanded")))
          (ok (equal (list (list :path (native (truename ctx-file)) :found t))
                     (snapshot-of store id :context-files)))
          (let ((skills (snapshot-of store id :skills))
                (skill (merge-pathnames ".claude/skills/demo/SKILL.md" project)))
            (ok (equal '("demo") (mapcar (lambda (e) (getf e :name)) skills)))
            (ok (equal (list (native (truename skill))) (mapcar (lambda (e) (getf e :path)) skills)))
            (ok (equal (list (skill-source (first (context-skills ctx))))
                       (mapcar (lambda (e) (getf e :source)) skills)))
            (ok (equal (list (text-hash (file-string skill))) (mapcar (lambda (e) (getf e :sha256)) skills))))
          (let ((rules (snapshot-of store id :rules)))
            (ok (equal (list always lisp) (mapcar (lambda (e) (getf e :path)) (getf rules :found))))
            (ok (equal '(nil ("**/*.lisp")) (mapcar (lambda (e) (getf e :paths)) (getf rules :found))))
            (ok (equal "Always on." (instruction-text store (getf (first (getf rules :found)) :text))))
            (ok (equal (list always) (getf rules :loaded)) "the always-on rule is in context")
            (ok (equal (list always) (instruction-set-loaded-rules store id)))))))))

(deftest iset-blocks-are-the-prompt-and-stay
  (with-project (project config) (iset-project)
    (write-skill project ".claude/skills/" "demo" "Demo skill.")
    (let* ((ctx (load-instruction-context project :user-config-dir config :home config))
           (prompt (assemble-system-prompt project :tools '("read") :backend (make-scripted-backend '())
                                                   :settings (make-settings) :user-config-dir config
                                                   :context ctx)))
      (with-sessions-dir (dir)
        (let* ((store (session-instruction-store (create-session dir :project-dir project)))
               (set (make-instruction-set store :context ctx))
               (id (commit-instruction-set set :start))
               (blocks (instruction-set-blocks store id)))
          (ok (= (+ (length (context-files ctx)) 2) (length blocks))
              "the files' blocks, one always-on rule, the skills section")
          (ok (has (format nil "~{~a~^~%~%~}" blocks) prompt)
              "exactly the blocks the system prompt has, in order")
          (ok (uiop:string-prefix-p "# Skills" (car (last blocks))))
          (write-file project "AGENTS.md" "Edited on disk.
")
          (ok (equal blocks (instruction-set-blocks store id)) "an old revision never changes")
          (let ((now (make-instruction-set store :context (load-instruction-context
                                                            project :user-config-dir config :home config))))
            (ok (not (equal id (commit-instruction-set now :resume))) "the edited set is a new revision")
            (ok (has "Edited on disk." (first (instruction-set-blocks store (instruction-set-current now)))))))))))

;;; Rules through a linked discovery.

(deftest iset-rule-loads-commit-and-restore-drops-them
  (with-project (project config) (list (list ".claude/rules/lisp.md" (rule-md '("**/*.lisp") "Lisp rule."))
                                       (list "src/a.lisp" "a") (list "src/b.lisp" "b"))
    (let* ((ctx (load-instruction-context project :user-config-dir config :home config))
           (rule (native (truename (merge-pathnames ".claude/rules/lisp.md" project))))
           (disc (make-code-instruction-discovery project :rules (context-rules ctx)
                                                          :project-dir project
                                                          :loaded (context-loaded-rules ctx))))
      (with-sessions-dir (dir)
        (let* ((store (session-instruction-store (create-session dir :project-dir project)))
               (set (make-instruction-set store :context ctx :discovery disc))
               (id0 (commit-instruction-set set :start)))
          (ok (null (instruction-set-loaded-rules store id0)))
          (ok (= 1 (length (steer:discover-instructions (steer:copy-instruction-discovery disc)
                                                        (list "src/a.lisp")))))
          (let ((id1 (instruction-set-current set)))
            (ok (not (equal id0 id1)) "a rule load commits the set")
            (ok (equal (list rule) (instruction-set-loaded-rules store id1)))
            (ok (equal :rule (getf (rev:revision-provenance (rev:resolve-revision store id1)) :reason)))
            (ok (null (steer:discover-instructions disc (list "src/b.lisp"))))
            (ok (equal id1 (instruction-set-current set)) "nothing loaded, nothing committed")
            (restore-instruction-set set id0)
            (ok (null (discovery-loaded-rules disc)) "a restore to before the load drops the rule")
            (let ((again (steer:discover-instructions (steer:copy-instruction-discovery disc)
                                                      (list "src/b.lisp"))))
              (ok (= 1 (length again)) "it loads again on the next matching path")
              (ok (equal rule (steer:steer-directive-name (first again)))))
            (ok (equal id1 (instruction-set-current set)) "the same set, the same revision")
            (restore-instruction-set set id1)
            (ok (null (steer:discover-instructions disc (list "src/a.lisp")))
                "restored with the rule: not loaded twice")
            (steer:forget-instructions disc)
            (ok (equal id0 (instruction-set-current set)) "a forget commits the set without it")
            (ok (= 2 (set-revision-count store)))))))))
