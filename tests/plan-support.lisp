(in-package #:cl-stack-code/tests)

;;; H5a helpers. Plan tests run against real temporary git repositories
;;; (the `git` on PATH, >= revision-backend-git's minimum) or plain project
;;; directories. Expected values come from the files on disk and from git
;;; run here, independently of the code under test. Plans live under the
;;; project's private data directory (DATA-DIR-OF), never ~/.local/share.

(defparameter *git* "git")

(defun git-env ()
  "Repo-independent settings for every git call the tests make."
  '("GIT_TERMINAL_PROMPT=0" "GIT_CONFIG_NOSYSTEM=1" "LC_ALL=C"))

(defun git (dir &rest args)
  "Run git ARGS in DIR. → stdout (a string). A non-zero exit signals an ERROR
with git's stderr."
  (multiple-value-bind (out err code)
      (uiop:run-program (list* *git* "-C" (native dir) args)
                        :output :string :error-output :string :ignore-error-status t
                        :environment (append (git-env)
                                             #+sbcl (sb-ext:posix-environ)
                                             #-sbcl nil))
    (unless (zerop code)
      (error "git ~{~a~^ ~} failed (~d): ~a" args code err))
    out))

(defun git-lines (dir &rest args)
  (lines (apply #'git dir args)))

(defun git-init (dir)
  "Make DIR a git repository on branch main with a local identity."
  (ensure-directories-exist dir)
  (git dir "init" "-q" "-b" "main")
  (git dir "config" "user.name" "Plan Test")
  (git dir "config" "user.email" "plan-test@invalid")
  (git dir "config" "commit.gpgsign" "false")
  (git dir "config" "core.autocrlf" "false")
  dir)

(defun git-commit-all (dir message)
  (git dir "add" "-A")
  (git dir "commit" "-q" "--allow-empty" "-m" message)
  (string-trim '(#\Newline) (git dir "rev-parse" "HEAD")))

(defun call-with-git-project (entries fn)
  "PROJECT: a real repository holding ENTRIES, committed once."
  (call-with-project nil
                     (lambda (project config base)
                       (git-init project)
                       (make-tree project entries)
                       (git-commit-all project "init")
                       (funcall fn project config base))))

(defmacro with-git-project ((project config &key base) entries &body body)
  "As WITH-PROJECT, but PROJECT is a real git repository with ENTRIES
committed on main."
  (let ((b (or base (gensym "BASE"))))
    `(call-with-git-project ,entries
                            (lambda (,project ,config ,b)
                              (declare (ignorable ,b ,config))
                              ,@body))))

(defmacro with-kind-project ((kind project config &key base) entries &body body)
  "KIND :GIT → WITH-GIT-PROJECT; :COPY → WITH-PROJECT (a .git/ directory that
is not a repository, so :AUTO picks :COPY)."
  `(ecase ,kind
     (:git (with-git-project (,project ,config ,@(and base (list :base base))) ,entries ,@body))
     (:copy (with-project (,project ,config ,@(and base (list :base base))) ,entries ,@body))))

;;; Plans of a project.

(defun project-plans-dir (project config)
  (plans-directory project :data-dir (data-dir-of config)))

(defun project-plans (project config)
  (list-plans (project-plans-dir project config)))

(defun only-plan (project config)
  "The project's single plan (a test failure when there are 0 or several)."
  (let ((plans (project-plans project config)))
    (ok (= 1 (length plans)) "exactly one plan")
    (first plans)))

(defun open-test-plan (project config kind)
  "OPEN-PLAN of PROJECT under its private data directory."
  (open-plan project :kind kind :data-dir (data-dir-of config)))

(defun area-file (plan rel)
  (read-file (plan-root plan) rel))

(defun write-area (plan rel content)
  (write-file (plan-root plan) rel content))

(defun change-paths (changes)
  (mapcar #'second changes))

(defun file-exists (dir rel)
  (and (probe-file (merge-pathnames rel dir)) t))

(defun unix-p ()
  #+(or windows win32) nil
  #-(or windows win32) t)

(defun chmod+x (dir rel)
  (uiop:run-program (list "chmod" "+x" (native (merge-pathnames rel dir)))))

(defun sh-in (dir command)
  "Run COMMAND with /bin/sh in DIR (Unix). → stdout."
  (uiop:run-program (list "/bin/sh" "-c" command) :directory dir :output :string))

(defun worktree-paths (project)
  "Worktree directories `git worktree list --porcelain` reports, as native
namestrings without a trailing separator."
  (loop for line in (git-lines project "worktree" "list" "--porcelain")
        when (and (> (length line) 9) (string= "worktree " line :end2 9))
          collect (subseq line 9)))

(defun dir-native (dir)
  "Native namestring of directory DIR without the trailing separator."
  (string-right-trim "/\\" (native (truename dir))))

(defun plan-ref (plan)
  (concatenate 'string +plan-ref-prefix+ (plan-id plan)))

(defun ref-exists-p (project ref)
  (multiple-value-bind (out err code)
      (uiop:run-program (list *git* "-C" (native project) "rev-parse" "--verify" "-q" ref)
                        :output :string :error-output :string :ignore-error-status t)
    (declare (ignore out err))
    (zerop code)))

(defun head-of (project)
  (string-trim '(#\Newline) (git project "rev-parse" "HEAD")))

(defun index-hash (project)
  "git hash-object of the main worktree's .git/index."
  (string-trim '(#\Newline) (git project "hash-object" ".git/index")))

(defun expected-diff (changes)
  "The unified text diff-protocol renders for CHANGES, a list of
(path old-or-NIL new-or-NIL) text files, the way PLAN-DIFF-TEXT is specified:
tree engine without rename detection, :CONTEXT 3, :UNIFIED."
  (flet ((tree-of (side)
           (apply #'diff:make-tree
                  (loop for (path . texts) in changes
                        for text = (if (eq side :old) (first texts) (second texts))
                        when text
                          append (tree-entry path (diff:make-tree-file text :mode #o100644))))))
    (diff:render-diff (diff:compute-diff (make-instance 'diff:tree-diff-engine :detect-renames nil)
                                         (tree-of :old) (tree-of :new)
                                         :level :changes :context 3)
                      :unified nil)))

(defun tree-entry (path node)
  "NAME NODE arguments of MAKE-TREE for the relative PATH (\"a/b.txt\")."
  (let ((slash (position #\/ path)))
    (if slash
        (list (subseq path 0 slash) (apply #'diff:make-tree (tree-entry (subseq path (1+ slash)) node)))
        (list path node))))

(defun plan-events (out)
  "The stream-json plan events of OUT."
  (events out "plan"))

(defun plan-event (out subtype)
  (find subtype (plan-events out) :key (lambda (e) (jget e "subtype")) :test #'equal))

(defun result-plan (out)
  "The \"plan\" object of the last result line of OUT."
  (jget (car (last (events out "result"))) "plan"))

(defun json-changes (object)
  "(kind path) lists of a JSON \"changes\" vector."
  (map 'list (lambda (c) (list (jget c "kind") (jget c "path"))) (or object #())))

(defun session-id-of (out)
  (jget (car (last (events out "result"))) "session_id"))

(defun parents-of (project rev)
  "Parent commit ids of REV."
  (let ((line (string-trim '(#\Newline) (git project "rev-list" "--parents" "-n" "1" rev))))
    (rest (uiop:split-string line :separator " "))))
