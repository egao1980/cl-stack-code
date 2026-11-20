(in-package #:cl-stack-code/tests)

;;; H5a: the plan API (src/plans.lisp header), for both kinds. :git runs in
;;; a real repository; :copy in a project whose .git/ is not one.

(defmacro with-plan ((plan kind project config &key base) entries &body body)
  "A fresh project of KIND holding ENTRIES and PLAN opened on it (rejected on
exit when still open)."
  `(with-kind-project (,kind ,project ,config ,@(and base (list :base base))) ,entries
     (let ((,plan (open-test-plan ,project ,config ,kind)))
       (unwind-protect (progn ,@body)
         (when (eq :open (plan-status ,plan))
           (ignore-errors (reject-plan ,plan)))))))

(defparameter +ten-lines+ (nl "1" "2" "3" "4" "5" "6" "7" "8" "9" "10"))

(defun replace-line (text old new)
  "TEXT with the line OLD replaced by NEW."
  (let ((pos (search (format nil "~a~%" old) text)))
    (concatenate 'string (subseq text 0 pos) new (string #\Newline)
                 (subseq text (+ pos (length old) 1)))))

;;; Kinds.

(deftest plan-kind-auto
  (with-git-project (project config) '(("a.txt" "alpha"))
    (let ((plan (open-plan project :data-dir (data-dir-of config))))
      (ok (eq :git (plan-kind plan)) "a git worktree → :git")
      (reject-plan plan)))
  (with-project (project config) '(("a.txt" "alpha"))
    (let ((plan (open-plan project :data-dir (data-dir-of config))))
      (ok (eq :copy (plan-kind plan)) "a .git/ that is not a repository → :copy")
      (reject-plan plan)))
  (with-project (project config :git nil) '(("a.txt" "alpha"))
    (let ((plan (open-plan project :data-dir (data-dir-of config))))
      (ok (eq :copy (plan-kind plan)) "no repository → :copy")
      (reject-plan plan))))

(deftest plan-kind-git-needs-a-worktree
  (with-project (project config) '(("a.txt" "alpha"))
    (let ((c (failure (open-plan project :kind :git :data-dir (data-dir-of config)))))
      (ok (typep c 'plan-error))
      (ok (has "not a git worktree" (princ-to-string c)))
      (ok (null (project-plans project config)) "nothing was left behind"))))

;;; Opening.

(deftest-parametrize plan-open-copies-the-project
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config)
      '(("a.txt" "alpha
") ("src/b.lisp" "(b)
") (".gitignore" "build/
") ("build/x.o" "obj"))
    ;; Uncommitted work is part of the base.
    (write-file project "a.txt" (nl "alpha" "edited"))
    (write-file project "new.txt" "untracked")
    (let ((plan (open-test-plan project config kind)))
      (unwind-protect
           (progn
             (ok (eq kind (plan-kind plan)))
             (ok (eq :open (plan-status plan)))
             (ok (= 32 (length (plan-id plan))))
             (ok (every (lambda (c) (digit-char-p c 16)) (plan-id plan)))
             (ok (same-path project (plan-project-dir plan)))
             (ok (equal (nl "alpha" "edited") (area-file plan "a.txt")) "uncommitted edits copied")
             (ok (equal "untracked" (area-file plan "new.txt")) "untracked files copied")
             (ok (equal (nl "(b)") (area-file plan "src/b.lisp")))
             (ok (not (file-exists (plan-root plan) "build/x.o")) "ignored files are not copied")
             (ok (null (plan-changes plan)) "a fresh plan has no changes")
             (ok (equal "" (plan-diff-text plan)))
             (ok (equal (nl "alpha" "edited") (read-file project "a.txt")) "the project is untouched")
             (ok (same-path (subdir (plan-directory plan) "tree/") (plan-root plan)))
             (ok (same-path (subdir (project-plans-dir project config) (format nil "~a/" (plan-id plan)))
                            (plan-directory plan)))
             (ok (file-exists (plan-directory plan) "plan.sexp"))
             (ok (not (uiop:subpathp (plan-root plan) project)) "the area is outside the project"))
        (reject-plan plan)))))

(deftest-parametrize plan-open-ids
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) '(("a.txt" "alpha"))
    (let* ((id "0123456789abcdef0123456789abcdef")
           (plan (open-plan project :kind kind :data-dir (data-dir-of config) :id id
                                    :session-id "fedcba9876543210fedcba9876543210")))
      (ok (equal id (plan-id plan)))
      (ok (equal "fedcba9876543210fedcba9876543210" (plan-session-id plan)))
      (ok (typep (failure (open-plan project :kind kind :data-dir (data-dir-of config) :id id))
                 'plan-error)
          "an existing id is refused")
      (reject-plan plan))))

(deftest plan-copy-base-is-a-stored-snapshot
  (with-plan (plan :copy project config) '(("a.txt" "alpha"))
    (ok (eql 0 (search "sha256:" (plan-base plan))))
    (let ((store (p:make-directory-snapshot-store (subdir (project-plans-dir project config) "store/"))))
      (ok (p:snapshot-store-contains-p store (plan-base plan)) "the base outlives the process"))))

(deftest plan-git-base-is-a-commit
  (with-plan (plan :git project config) '(("a.txt" "alpha"))
    (ok (= 40 (length (plan-base plan))))
    (ok (equal (plan-base plan) (string-trim '(#\Newline) (git project "rev-parse" (plan-ref plan))))
        "the plan ref names the base")
    (ok (equal (list (head-of project)) (parents-of project (plan-base plan)))
        "its parent is HEAD")))

;;; The tool root.

(deftest-parametrize plan-tool-root
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("sub/a.txt" "alpha"))
    (ok (same-path (plan-root plan) (plan-tool-root plan project)))
    (ok (same-path (subdir (plan-root plan) "sub/") (plan-tool-root plan (subdir project "sub/"))))
    (ok (typep (failure (plan-tool-root plan (uiop:pathname-parent-directory-pathname project)))
               'plan-error)
        "a directory outside the project")))

;;; Changes and the diff.

(deftest-parametrize plan-changes
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha
") ("c.txt" "gone
") ("same.txt" "same
") ("run.sh" "#!/bin/sh
"))
    (write-area plan "a.txt" (nl "beta"))
    (write-area plan "new/b.txt" (nl "bee"))
    (delete-file (merge-pathnames "c.txt" (plan-root plan)))
    (write-area plan "same.txt" (nl "other"))
    (write-area plan "same.txt" (nl "same"))
    (when (unix-p) (chmod+x (plan-root plan) "run.sh"))
    (ok (equal (append '((:modified "a.txt") (:removed "c.txt") (:added "new/b.txt"))
                       (and (unix-p) '((:mode-changed "run.sh"))))
               (plan-changes plan))
        "sorted by path; a file edited back is no change")
    (ok (equal (nl "alpha") (read-file project "a.txt")) "the project is untouched")))

(deftest-parametrize plan-changes-from-a-shell
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (if (not (unix-p))
      (skip "/bin/sh")
      (with-plan (plan kind project config) '(("a.txt" "alpha"))
        (sh-in (plan-root plan) "echo made > s.txt")
        (ok (equal '((:added "s.txt")) (plan-changes plan)) "edits made outside Lisp are found"))))

(deftest-parametrize plan-diff-text
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "one
two
three
") ("c.txt" "bye
"))
    (write-area plan "a.txt" (nl "one" "TWO" "three"))
    (write-area plan "b.txt" (nl "new"))
    (delete-file (merge-pathnames "c.txt" (plan-root plan)))
    (let ((text (plan-diff-text plan)))
      (ok (equal (expected-diff (list (list "a.txt" (nl "one" "two" "three") (nl "one" "TWO" "three"))
                                      (list "b.txt" nil (nl "new"))
                                      (list "c.txt" (nl "bye") nil)))
                 text)
          "the tree engine's unified text, the same for both kinds")
      (ok (has "diff --git a/a.txt b/a.txt" text))
      (ok (has (nl "-two" "+TWO") text))
      (ok (has "new file mode 100644" text))
      (ok (has "deleted file mode 100644" text))
      (ok (let ((e (diff:diff-engine (plan-diff plan))))
            (or (eq e :tree) (typep e 'diff:tree-diff-engine)))
          "a tree diff"))))

(deftest-parametrize plan-diff-binary
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '()
    (write-bytes (plan-root plan) "blob.bin" '(0 1 2 255))
    (ok (has "Binary files /dev/null and b/blob.bin differ" (plan-diff-text plan)))))

;;; Approving without drift.

(deftest-parametrize plan-approve
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha
") ("keep.txt" "keep
") ("c.txt" "bye
") ("d/e.txt" "e
"))
    (write-area plan "a.txt" (nl "beta"))
    (write-area plan "b.txt" (nl "bee"))
    (delete-file (merge-pathnames "c.txt" (plan-root plan)))
    (delete-file (merge-pathnames "d/e.txt" (plan-root plan)))
    (let ((root (plan-root plan)))
      (multiple-value-bind (result status) (approve-plan plan)
        (ok (eq :applied status))
        (ok (equal '((:modified "a.txt") (:added "b.txt") (:removed "c.txt") (:removed "d/e.txt"))
                   result))
        (ok (equal (nl "beta") (read-file project "a.txt")))
        (ok (equal (nl "bee") (read-file project "b.txt")))
        (ok (not (file-exists project "c.txt")))
        (ok (not (uiop:directory-exists-p (subdir project "d/"))) "emptied directories go")
        (ok (equal (nl "keep") (read-file project "keep.txt")))
        (ok (eq :applied (plan-status plan)))
        (ok (not (uiop:directory-exists-p root)) "the area is gone")
        (ok (has ":APPLIED" (string-upcase (read-file (plan-directory plan) "plan.sexp"))))
        (ok (typep (failure (reopen-plan (project-plans-dir project config) (plan-id plan)))
                   'plan-not-found))
        (ok (typep (failure (approve-plan plan)) 'plan-error) "approving twice")))))

(deftest-parametrize plan-approve-empty
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha"))
    (multiple-value-bind (result status) (approve-plan plan)
      (ok (null result))
      (ok (eq :empty status))
      (ok (eq :applied (plan-status plan)) "the plan is closed all the same"))))

(deftest-parametrize plan-approve-execute-bit
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (if (not (unix-p))
      (skip "modes")
      (with-plan (plan kind project config) '(("run.sh" "#!/bin/sh
echo hi
"))
        (chmod+x (plan-root plan) "run.sh")
        (approve-plan plan)
        (ok (equal (nl "hi") (sh-in project "./run.sh")) "the execute bit follows the area"))))

;;; Drift.

(deftest-parametrize plan-drift-elsewhere-is-kept
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha
") ("b.txt" "bee
"))
    (write-area plan "a.txt" (nl "plan"))
    (write-file project "b.txt" (nl "user"))
    (write-file project "u.txt" (nl "user too"))
    (multiple-value-bind (result status)
        (handler-bind ((plan-drift (lambda (c) (declare (ignore c)) (ok nil "no drift signalled"))))
          (approve-plan plan))
      (ok (eq :applied status))
      (ok (equal '((:modified "a.txt")) result))
      (ok (equal (nl "plan") (read-file project "a.txt")))
      (ok (equal (nl "user") (read-file project "b.txt")) "drift elsewhere stays")
      (ok (equal (nl "user too") (read-file project "u.txt"))))))

(deftest-parametrize plan-drift-identical-edits
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha
"))
    (write-area plan "a.txt" (nl "same"))
    (write-file project "a.txt" (nl "same"))
    (ok (eq :applied (nth-value 1 (approve-plan plan))) "the same edit on both sides is no conflict")
    (ok (equal (nl "same") (read-file project "a.txt")))))

(defmacro with-drift ((plan kind project config) &body body)
  "PLAN over a.txt = +TEN-LINES+ and b.txt; the area and the working copy both
changed a.txt (lines 1 and 10: different regions)."
  `(with-plan (,plan ,kind ,project ,config) (list (list "a.txt" +ten-lines+) (list "b.txt" (nl "bee")))
     (write-area ,plan "a.txt" (replace-line +ten-lines+ "1" "one"))
     (write-file ,project "a.txt" (replace-line +ten-lines+ "10" "ten"))
     ,@body))

(deftest-parametrize plan-drift-signalled
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-drift (plan kind project config)
    (let ((restarts nil))
      (let ((c (handler-case
                   (handler-bind ((plan-drift
                                    (lambda (c)
                                      (setf restarts (mapcar #'restart-name (compute-restarts c))))))
                     (approve-plan plan)
                     nil)
                 (plan-drift (c) c))))
        (ok (typep c 'plan-drift) "unhandled, it escapes")
        (ok (equal '("a.txt") (plan-drift-paths c)))
        (ok (eq plan (plan-error-plan c)))
        (ok (has "a.txt" (princ-to-string c)))
        (dolist (r '(rebase-plan overwrite-plan abort-approval))
          (ok (member r restarts) (string r)))
        (ok (equal (replace-line +ten-lines+ "10" "ten") (read-file project "a.txt")) "nothing written")
        (ok (eq :open (plan-status plan)) "the plan stays open")
        (ok (equal '((:modified "a.txt")) (plan-changes plan)))))))

(deftest-parametrize plan-drift-abort
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-drift (plan kind project config)
    (multiple-value-bind (result status)
        (handler-bind ((plan-drift (lambda (c) (invoke-restart (find-restart 'abort-approval c)))))
          (approve-plan plan))
      (ok (null result))
      (ok (eq :aborted status))
      (ok (eq :open (plan-status plan)))
      (ok (equal (replace-line +ten-lines+ "10" "ten") (read-file project "a.txt")))
      (ok (equal (replace-line +ten-lines+ "1" "one") (area-file plan "a.txt"))))))

(deftest-parametrize plan-drift-overwrite
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-drift (plan kind project config)
    (write-file project "u.txt" (nl "user"))
    (multiple-value-bind (result status)
        (handler-bind ((plan-drift (lambda (c) (invoke-restart (find-restart 'overwrite-plan c)))))
          (approve-plan plan))
      (ok (eq :applied status))
      (ok (equal '((:modified "a.txt")) result))
      (ok (equal (replace-line +ten-lines+ "1" "one") (read-file project "a.txt"))
          "the plan's version wins")
      (ok (equal (nl "user") (read-file project "u.txt")) "other drift stays"))))

(deftest-parametrize plan-drift-rebase-clean
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-drift (plan kind project config)
    (write-file project "b.txt" (nl "user bee"))
    (let ((old-base (plan-base plan))
          (merged (replace-line (replace-line +ten-lines+ "1" "one") "10" "ten")))
      (multiple-value-bind (result status)
          (handler-bind ((plan-drift (lambda (c) (invoke-restart (find-restart 'rebase-plan c)))))
            (approve-plan plan))
        (ok (eq :rebased status))
        (ok (null result) "the regions do not overlap: no conflicts")
        (ok (eq :open (plan-status plan)))
        (ok (not (equal old-base (plan-base plan))) "the working copy is the new base")
        (ok (equal merged (area-file plan "a.txt")) "both edits, no markers")
        (ok (equal (nl "user bee") (area-file plan "b.txt")) "the working copy's other drift came in")
        (ok (equal (replace-line +ten-lines+ "10" "ten") (read-file project "a.txt")) "nothing applied")
        (ok (equal '((:modified "a.txt")) (plan-changes plan)) "changes are against the new base")
        (ok (has "+one" (plan-diff-text plan)))
        (ok (not (has "ten" (plan-diff-text plan))))
        (ok (eq :applied (nth-value 1 (approve-plan plan))) "no drift now")
        (ok (equal merged (read-file project "a.txt")))))))

(deftest-parametrize plan-drift-rebase-markers
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) (list (list "a.txt" +ten-lines+))
    (write-area plan "a.txt" (replace-line +ten-lines+ "5" "plan five"))
    (write-file project "a.txt" (replace-line +ten-lines+ "5" "user five"))
    (multiple-value-bind (result status)
        (handler-bind ((plan-drift (lambda (c) (invoke-restart (find-restart 'rebase-plan c)))))
          (approve-plan plan))
      (ok (eq :rebased status))
      (ok (equal '("a.txt") result))
      (let ((text (area-file plan "a.txt")))
        (ok (equal (nth-value 0 (diff:merge-texts +ten-lines+
                                                  (replace-line +ten-lines+ "5" "plan five")
                                                  (replace-line +ten-lines+ "5" "user five")
                                                  :ours-label "plan" :theirs-label "working copy"))
                   text)
            "DIFF:MERGE-TEXTS with the plan and working copy labels")
        (ok (has "<<<<<<< plan" text))
        (ok (has ">>>>>>> working copy" text)))
      (ok (equal (replace-line +ten-lines+ "5" "user five") (read-file project "a.txt"))))))

(deftest-parametrize plan-drift-rebase-binary-keeps-the-area
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-kind-project (kind project config) '()
    (write-bytes project "blob.bin" '(0 1 2))
    (when (eq kind :git) (git-commit-all project "blob"))
    (let ((plan (open-test-plan project config kind)))
      (write-bytes (plan-root plan) "blob.bin" '(0 9 9))
      (write-bytes project "blob.bin" '(0 7 7))
      (multiple-value-bind (result status)
          (handler-bind ((plan-drift (lambda (c) (invoke-restart (find-restart 'rebase-plan c)))))
            (approve-plan plan))
        (ok (eq :rebased status))
        (ok (equal '("blob.bin") result) "an unmergeable path is reported")
        (ok (equalp (coerce '(0 9 9) '(vector (unsigned-byte 8)))
                    (with-open-file (in (merge-pathnames "blob.bin" (plan-root plan))
                                        :element-type '(unsigned-byte 8))
                      (let ((v (make-array 3 :element-type '(unsigned-byte 8))))
                        (read-sequence v in)
                        v)))
            "the area keeps its version"))
      (reject-plan plan))))

;;; Rejecting and reopening.

(deftest-parametrize plan-reject
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha"))
    (write-area plan "a.txt" "beta")
    (let ((root (plan-root plan)))
      (ok (eq :discarded (reject-plan plan)))
      (ok (eq :discarded (plan-status plan)))
      (ok (not (uiop:directory-exists-p root)))
      (ok (equal "alpha" (read-file project "a.txt")))
      (ok (has ":DISCARDED" (string-upcase (read-file (plan-directory plan) "plan.sexp"))))
      (ok (typep (failure (reject-plan plan)) 'plan-error))
      (ok (typep (failure (approve-plan plan)) 'plan-error)))))

(deftest-parametrize plan-reopen
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha"))
    (write-area plan "a.txt" "beta")
    (let* ((dir (project-plans-dir project config))
           (again (reopen-plan dir (plan-id plan))))
      (ok (not (eq plan again)) "a new object")
      (ok (equal (plan-id plan) (plan-id again)))
      (ok (eq kind (plan-kind again)))
      (ok (equal (plan-base plan) (plan-base again)))
      (ok (same-path (plan-root plan) (plan-root again)))
      (ok (same-path (plan-project-dir plan) (plan-project-dir again)))
      (ok (= (plan-opened-at plan) (plan-opened-at again)))
      (ok (equal '((:modified "a.txt")) (plan-changes again)) "the area's edits are still there")
      (ok (equal (list (plan-id plan)) (mapcar #'plan-id (list-plans dir))))
      (let ((c (failure (reopen-plan dir "00000000000000000000000000000000"))))
        (ok (typep c 'plan-not-found))
        (ok (equal "00000000000000000000000000000000" (plan-not-found-designator c))))
      (ok (eq :applied (nth-value 1 (approve-plan again))))
      (ok (equal "beta" (read-file project "a.txt"))))))

(deftest plan-reopen-needs-the-area
  (with-plan (plan :copy project config) '(("a.txt" "alpha"))
    (uiop:delete-directory-tree (plan-root plan) :validate t)
    (ok (typep (failure (reopen-plan (project-plans-dir project config) (plan-id plan)))
               'plan-not-found))))

(deftest plan-unreadable-plan-file
  (with-plan (plan :copy project config) '(("a.txt" "alpha"))
    (write-file (plan-directory plan) "plan.sexp" "(:format 1 :id #.(error \"no\")")
    (let ((c (failure (reopen-plan (project-plans-dir project config) (plan-id plan)))))
      (ok (typep c 'plan-error))
      (ok (has "plan.sexp" (princ-to-string c)) "the message names the file"))))

(deftest plan-list-order
  (with-project (project config) '(("a.txt" "alpha"))
    (let* ((one (open-test-plan project config :copy))
           (two (open-test-plan project config :copy)))
      (reject-plan one)
      (ok (equal (sort (list (plan-id one) (plan-id two)) #'string<)
                 (sort (mapcar #'plan-id (project-plans project config)) #'string<))
          "every plan, whatever its status")
      (ok (equal '(:discarded :open)
                 (mapcar (lambda (id)
                           (plan-status (find id (project-plans project config)
                                              :key #'plan-id :test #'equal)))
                         (list (plan-id one) (plan-id two)))))
      (reject-plan two))))

(deftest-parametrize plan-record
    ((kind) :ids ("copy" "git") (:copy) (:git))
  (with-plan (plan kind project config) '(("a.txt" "alpha"))
    (let ((r (plan-record plan)))
      (ok (equal (plan-id plan) (getf r :id)))
      (ok (eq kind (getf r :kind)))
      (ok (equal (plan-base plan) (getf r :base)))
      (ok (equal (native (plan-root plan)) (getf r :root)))
      (ok (eq :open (getf r :status))))))

;;; Git specifics.

(deftest plan-git-area-is-a-linked-worktree
  (with-git-project (project config) '(("a.txt" "alpha
"))
    (write-file project "u.txt" "user")
    (let ((head (head-of project))
          (index (index-hash project))
          (plan (open-test-plan project config :git)))
      (unwind-protect
           (progn
             (ok (member (dir-native (plan-root plan)) (worktree-paths project) :test #'equal)
                 "listed by git worktree list")
             (ok (equal (plan-base plan) (head-of (plan-root plan))) "the area's HEAD is the base")
             (write-area plan "a.txt" (nl "beta"))
             (ok (equal (list " M a.txt")
                        (git-lines (plan-root plan) "status" "--porcelain"))
                 "git inside the area shows the projected change")
             (ok (equal head (head-of project)) "HEAD untouched")
             (ok (equal index (index-hash project)) "the real index untouched")
             (ok (equal (list "?? u.txt") (git-lines project "status" "--porcelain"))))
        (reject-plan plan)))))

(deftest plan-git-approve-records-a-commit
  (with-git-project (project config) '(("a.txt" "alpha
"))
    (let* ((head (head-of project))
           (plan (open-test-plan project config :git))
           (base (plan-base plan))
           (root (plan-root plan)))
      (write-area plan "a.txt" (nl "beta"))
      (approve-plan plan :message "make it beta")
      (let ((applied (string-trim '(#\Newline) (git project "rev-parse" (plan-ref plan)))))
        (ok (not (equal base applied)) "the ref moved to the approved commit")
        (ok (equal (list base) (parents-of project applied)) "its parent is the base")
        (ok (equal (nl "beta") (git project "show" (format nil "~a:a.txt" applied))))
        (ok (has "make it beta" (git project "log" "-1" "--format=%B" applied))))
      (ok (equal head (head-of project)) "HEAD and the branch stay")
      (ok (equal (list " M a.txt") (git-lines project "status" "--porcelain"))
          "the change lands as an uncommitted edit")
      (ok (not (uiop:directory-exists-p root)) "the area is gone")
      (ok (= 1 (length (worktree-paths project))) "the linked worktree is gone"))))

(deftest plan-git-reject-cleans-up
  (with-git-project (project config) '(("a.txt" "alpha"))
    (let ((plan (open-test-plan project config :git)))
      (reject-plan plan)
      (ok (not (ref-exists-p project (plan-ref plan))) "the plan ref is deleted")
      (ok (= 1 (length (worktree-paths project))))
      (ok (null (git-lines project "status" "--porcelain"))))))
