(in-package #:cl-stack-code)

;;; The agent-tools sources for a run.

(defun %offered-names (settings names)
  "NAMES (in order) without the ones SETTINGS hides."
  (let ((hidden (hidden-tool-names settings names)))
    (remove-if (lambda (name) (member name hidden :test #'string=)) names)))

(defun make-code-tools (cwd &key settings)
  "→ (file-tools shell-tools), both rooted at CWD. The shell tools need
approval and get SETTINGS-ENV of SETTINGS as their :env."
  (let* ((settings (or settings (make-settings)))
         (root (uiop:ensure-directory-pathname cwd))
         (files (tools:make-file-tools
                 :root root
                 :tools (%offered-names settings tools:+file-tool-names+))))
    (list files
          (tools:make-shell-tools
           :root root
           :needs-approval t
           :env (settings-env settings)
           :tools (%offered-names settings tools:+shell-tool-names+)))))
