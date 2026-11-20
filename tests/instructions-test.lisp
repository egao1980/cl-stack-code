(in-package #:cl-stack-code/tests)

;;; Project root, instruction discovery and system prompt assembly.

(defun platform-name ()
  #+darwin "darwin"
  #+linux "linux"
  #+(or windows win32) "windows"
  #-(or darwin linux windows win32) "other")

(defun block-for (path text)
  (format nil "<instructions path=\"~a\">~%~a~%</instructions>" (native (truename path)) text))

(defun env-section (cwd root mode)
  (format nil "# Environment~%- Working directory: ~a~%- Project root: ~a~%- Platform: ~a~%- Permission mode: ~a"
          (native cwd) (if root (native root) "none") (platform-name) mode))

(deftest project-root-git-directory
  (with-project (project config) '("a/b/")
    (ok (same-path project (find-project-root (subdir project "a/b/"))))
    (ok (same-path project (find-project-root project)))))

(deftest project-root-git-file
  (with-project (project config :git nil) '(("wt/.git" "gitdir: /elsewhere/.git/worktrees/wt
") "wt/src/")
    (ok (same-path (subdir project "wt/") (find-project-root (subdir project "wt/src/")))
        "a .git file (worktree) counts")))

(deftest project-root-none
  (with-project (project config :git nil) '("a/")
    (let ((root (find-project-root (subdir project "a/"))))
      (ok (or (null root)
              (not (uiop:subpathp project root)))
          "nothing at or below the base"))))

(deftest instruction-files-order
  (with-project (project config) '(("AGENTS.md" "root rules
") ("a/AGENTS.md" "a rules
") ("a/b/AGENTS.md" "b rules
") ("a/b/c/AGENTS.md" "below cwd
"))
    (write-file config "AGENTS.md" "user rules
")
    (let ((files (instruction-files (subdir project "a/b/") :user-config-dir config)))
      (ok (same-paths (list (merge-pathnames "AGENTS.md" config)
                            (merge-pathnames "AGENTS.md" project)
                            (merge-pathnames "a/AGENTS.md" project)
                            (merge-pathnames "a/b/AGENTS.md" project))
                      files)
          "user, then root down to cwd; nothing below cwd"))))

(deftest instruction-files-claude-fallback
  (with-project (project config) '(("AGENTS.md" "agents
") ("CLAUDE.md" "claude
") ("a/CLAUDE.md" "only claude
") "a/b/")
    (let ((files (instruction-files (subdir project "a/b/") :user-config-dir config)))
      (ok (same-paths (list (merge-pathnames "AGENTS.md" project)
                            (merge-pathnames "a/CLAUDE.md" project))
                      files)
          "AGENTS.md wins where both exist; CLAUDE.md is the fallback"))))

(deftest instruction-files-skip-blank-and-directories
  (with-project (project config) '(("AGENTS.md" "

") "a/AGENTS.md/" ("a/CLAUDE.md" "real
"))
    (let ((files (instruction-files (subdir project "a/") :user-config-dir config)))
      (ok (same-paths (list (merge-pathnames "a/CLAUDE.md" project)) files)
          "a blank file is skipped; a directory named AGENTS.md is not a file"))))

(deftest instruction-files-without-project-root
  (with-project (project config :git nil :base base) '(("AGENTS.md" "p
") ("sub/AGENTS.md" "s
"))
    (write-file base "AGENTS.md" "above the project
")
    (let ((files (instruction-files (subdir project "sub/") :user-config-dir config)))
      (ok (same-paths (list (merge-pathnames "AGENTS.md" base)
                            (merge-pathnames "AGENTS.md" project)
                            (merge-pathnames "sub/AGENTS.md" project))
                      (last files 3))
          "the walk goes past the project toward the filesystem root"))))

(deftest instruction-files-stop-at-project-root
  (with-project (project config :base base) '(("AGENTS.md" "p
"))
    (write-file base "AGENTS.md" "outside the repo
")
    (ok (same-paths (list (merge-pathnames "AGENTS.md" project))
                    (instruction-files project :user-config-dir config)))))

(deftest system-prompt-sections
  (with-project (project config) '(("AGENTS.md" "Root rules.
") ("src/AGENTS.md" "Src rules.

"))
    (write-file config "AGENTS.md" "User rules.
")
    (let* ((backend (make-scripted-backend '()))
           (cwd (subdir project "src/"))
           (tools '("read" "edit" "bash")))
      (multiple-value-bind (prompt files)
          (assemble-system-prompt cwd :tools tools :backend backend
                                      :settings (make-settings :append-system-prompt "Answer in French.")
                                      :user-config-dir config)
        (ok (= 3 (length files)))
        (ok (equal (format nil "~a~%~%~a~%~%~a~%~%~a~%~%~a~%~%~a"
                           (steer:build-system-prompt :tools tools :model backend)
                           (env-section (truename cwd) project "default")
                           (block-for (merge-pathnames "AGENTS.md" config) "User rules.")
                           (block-for (merge-pathnames "AGENTS.md" project) "Root rules.")
                           (block-for (merge-pathnames "src/AGENTS.md" project) "Src rules.")
                           "Answer in French.")
                   prompt))))))

(deftest system-prompt-minimal
  (with-project (project config :git nil) '()
    (let* ((backend (make-scripted-backend '()))
           (prompt (assemble-system-prompt project :tools '("read") :backend backend
                                                   :settings (make-settings :permission-mode :plan)
                                                   :user-config-dir config)))
      (ok (has (env-section project (find-project-root project) "plan") prompt))
      (ok (eql 0 (search (steer:build-system-prompt :tools '("read") :model backend) prompt)))
      (ok (not (has "Answer in" prompt))))))

(deftest system-prompt-truncates-long-files
  (with-project (project config) (list (list "AGENTS.md" (make-string 40000 :initial-element #\x)))
    (let* ((prompt (assemble-system-prompt project :tools '() :backend (make-scripted-backend '())
                                                   :settings (make-settings) :user-config-dir config))
           (path (native (truename (merge-pathnames "AGENTS.md" project)))))
      (ok (has (format nil "~a~%[truncated: ~a is over 32000 characters]"
                       (make-string 32000 :initial-element #\x) path)
               prompt))
      (ok (not (has (make-string 32001 :initial-element #\x) prompt))))))
