(in-package #:cl-stack-code/tests)

;;; H5b helpers. Checkpoint tests run over three kinds of project: a plain
;;; folder (:copy; WITH-PROJECT's .git/ is not a repository), a real git
;;; repository (:git, PLAN-SUPPORT's fixtures) and, when jj is installed at
;;; revision-backend-jj's minimum or later, a colocated jj repository (:jj).
;;; Without jj the :jj rows are skipped (Rove SKIP, the body does not run).
;;; Expected values come from the files on disk and from git / jj run here.
;;; Sessions, checkpoints and rewind plans live under the project's private
;;; data directory (DATA-DIR-OF), never ~/.local/share.

;;; jj.

(defparameter *jj* "jj")

(defvar *jj-available* :unknown
  "Cached JJ-AVAILABLE-P answer.")

(defun jj-available-p ()
  "True when `jj --version` runs and is at least revision-backend-jj's minimum."
  (when (eq *jj-available* :unknown)
    (setf *jj-available*
          (handler-case
              (multiple-value-bind (out err code)
                  (uiop:run-program (list *jj* "--version") :output :string
                                                            :error-output :string
                                                            :ignore-error-status t)
                (declare (ignore err))
                (and (zerop code)
                     (let ((version (jj:parse-jj-version out)))
                       (and version
                            (version-list<= (jj:parse-jj-version jj:*minimum-jj-version*)
                                            version)))))
            (error () nil))))
  *jj-available*)

(defun version-list<= (a b)
  "A <= B for version lists (0 47 1); missing components count as 0."
  (loop for i from 0 below (max (length a) (length b))
        for x = (or (nth i a) 0)
        for y = (or (nth i b) 0)
        do (cond ((< x y) (return t))
                 ((> x y) (return nil)))
        finally (return t)))

(defparameter +no-jj+ "jj is not installed (or older than revision-backend-jj's minimum)")

(defun jj (dir &rest args)
  "Run jj ARGS in the workspace DIR with a fixed identity. → stdout. A non-zero
exit signals an ERROR with jj's stderr."
  (multiple-value-bind (out err code)
      (uiop:run-program (list* *jj* "-R" (native dir) "--no-pager" "--color=never"
                               "--config" "user.name=Checkpoint Test"
                               "--config" "user.email=checkpoint-test@invalid"
                               args)
                        :output :string :error-output :string :ignore-error-status t)
    (unless (zerop code)
      (error "jj ~{~a~^ ~} failed (~d): ~a" args code err))
    out))

(defun jj-init (dir)
  "Make DIR a colocated jj repository."
  (ensure-directories-exist dir)
  (multiple-value-bind (out err code)
      (uiop:run-program (list *jj* "--no-pager" "--color=never" "git" "init" "--colocate"
                              (native dir))
                        :output :string :error-output :string :ignore-error-status t)
    (declare (ignore out))
    (unless (zerop code)
      (error "jj git init failed (~d): ~a" code err)))
  dir)

(defun call-with-jj-project (entries fn)
  "PROJECT: a colocated jj repository whose first change holds ENTRIES, @ an
empty change on it."
  (call-with-project nil
                     (lambda (project config base)
                       (jj-init project)
                       (make-tree project entries)
                       (jj project "describe" "-m" "init")
                       (jj project "new")
                       (funcall fn project config base))))

(defun call-with-checkpoint-project (kind entries fn)
  (ecase kind
    (:copy (call-with-project t (lambda (project config base)
                                  (make-tree project entries)
                                  (funcall fn project config base))))
    (:git (call-with-git-project entries fn))
    (:jj (if (jj-available-p)
             (call-with-jj-project entries fn)
             (skip +no-jj+)))))

(defmacro with-checkpoint-project ((kind project config &key base) entries &body body)
  "KIND :COPY → a plain folder, :GIT → a git repository, :JJ → a colocated jj
repository (skipped without jj), each holding ENTRIES."
  (let ((b (or base (gensym "BASE"))))
    `(call-with-checkpoint-project ,kind ,entries
                                   (lambda (,project ,config ,b)
                                     (declare (ignorable ,b ,config))
                                     ,@body))))

(defmacro with-jj-project ((project config &key base) entries &body body)
  `(with-checkpoint-project (:jj ,project ,config ,@(and base (list :base base))) ,entries ,@body))

;;; Checkpointers and sessions.

(defun test-checkpointer (project config &rest keys)
  "MAKE-CHECKPOINTER on PROJECT with its private data directory."
  (apply #'make-checkpointer project :data-dir (data-dir-of config) keys))

(defmacro with-checkpointer ((cp project config &rest keys) &body body)
  `(let ((,cp (test-checkpointer ,project ,config ,@keys)))
     (unwind-protect (progn ,@body)
       (close-checkpointer ,cp))))

(defun fresh-session (project config)
  (create-session (project-sessions project config) :project-dir project))

(defun cli-session (project config id)
  "The session ID of PROJECT, read from disk."
  (open-session (project-sessions project config) id))

(defun apply-edits (project edits)
  "EDITS: (rel content) writes, (rel NIL) deletes."
  (dolist (e edits)
    (destructuring-bind (rel content) e
      (if content
          (write-file project rel content)
          (delete-file (merge-pathnames rel project))))))

(defun edit-turn (cp store prompt &rest edits)
  "One turn as the product runs it: BEGIN-CHECKPOINT-TURN, the EDITS (see
APPLY-EDITS), COMMIT (a simple record with PROMPT), END-CHECKPOINT-TURN.
→ (values checkpoints-recorded revision)."
  (let ((pre (begin-checkpoint-turn cp store)))
    (apply-edits (checkpointer-project-dir cp) edits)
    (let ((revision (commit store prompt)))
      (values (end-checkpoint-turn cp store pre revision) revision))))

(defun short-id (x)
  "First 8 characters of an id string, a revision's id or a checkpoint's id."
  (let ((id (etypecase x
              (string x)
              (checkpoint (checkpoint-id x))
              (rev:revision (rev:revision-id x)))))
    (subseq id 0 (min 8 (length id)))))

;;; What is on disk.

(defun disk-files (project)
  "Sorted ((rel content) …) of every file under PROJECT outside .git/ and .jj/."
  (let ((out '()))
    (labels ((walk (dir prefix)
               (dolist (f (uiop:directory-files dir))
                 (push (list (concatenate 'string prefix (file-namestring f))
                             (uiop:read-file-string f :external-format :utf-8))
                       out))
               (dolist (d (uiop:subdirectories dir))
                 (let ((name (car (last (pathname-directory d)))))
                   (unless (member name '(".git" ".jj") :test #'string=)
                     (walk d (concatenate 'string prefix name "/")))))))
      (walk project ""))
    (sort out #'string< :key #'first)))

(defun ascii-octets (string)
  (make-array (length string) :element-type '(unsigned-byte 8)
                              :initial-contents (map 'list #'char-code string)))

(defun octets-ascii (octets)
  (map 'string #'code-char octets))

(defun ascii-hash (string)
  "The pathlib blob id of STRING's octets."
  (p:octets-hash (ascii-octets string)))

(defun blob-store (store)
  "The :copy kind's snapshot store of the session STORE."
  (p:make-directory-snapshot-store
   (native (subdir (checkpoints-directory store) "store/"))))

(defun checkpoint-file (checkpoint store project rel)
  "REL's content in CHECKPOINT's files (read independently of the product:
pathlib for :copy, git show / jj file show for :git / :jj), or NIL when absent."
  (let ((id (checkpoint-files-id checkpoint)))
    (ecase (checkpoint-files-kind checkpoint)
      (:copy
       (let* ((blobs (blob-store store))
              (entry (find rel (p:snapshot-entries id :store blobs)
                           :key #'p:snapshot-entry-path :test #'equal)))
         (and entry (octets-ascii (p:snapshot-store-get blobs (p:snapshot-entry-hash entry))))))
      (:git (handler-case (git project "show" (format nil "~a:~a" id rel))
              (error () nil)))
      (:jj (handler-case (jj project "--ignore-working-copy" "file" "show" "-r" id (format nil "root:~s" rel))
             (error () nil))))))

(defun trim (string)
  (string-trim '(#\Space #\Newline #\Return) string))

(defun checkpoint-ref-name (store ordinal)
  (format nil "~a~a/~d" +checkpoint-ref-prefix+ (session-id store) ordinal))

(defun checkpoint-refs (project store)
  "The private checkpoint refs of the session STORE in PROJECT, sorted."
  (sort (lines (git project "for-each-ref" "--format=%(refname)"
                    (format nil "~a~a/" +checkpoint-ref-prefix+ (session-id store))))
        #'string<))

(defun reasons (checkpoints)
  (mapcar #'checkpoint-reason checkpoints))

(defun ids (checkpoints)
  (mapcar #'checkpoint-id checkpoints))

(defun rewind-merge (base target working)
  "The text a rewind's REBASE-PLAN writes for one conflicting text file (H5a's
labels)."
  (nth-value 0 (diff:merge-texts base target working
                                 :ours-label "plan" :theirs-label "working copy")))

;;; Headless runs.

(defun edit-run (project config steps &key (prompt "go") argv)
  "A stream-json acceptEdits run of PROMPT. → (values exit out err backend)."
  (code project config (append '("-p" "--permission-mode" "acceptEdits"
                                 "--output-format" "stream-json")
                               argv (list prompt))
        :steps steps))

(defun edit-run-session (project config steps &rest keys)
  "EDIT-RUN; → the session id of its result."
  (session-id-of (nth-value 1 (apply #'edit-run project config steps keys))))

(defun write-settings-file (path json)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
    (write-string json out))
  path)
