(in-package #:cl-stack-code)

;;; The agent-tools sources for a run.

(defun %offered-names (settings names)
  "NAMES (in order) without the ones SETTINGS hides."
  (let ((hidden (hidden-tool-names settings names)))
    (remove-if (lambda (name) (member name hidden :test #'string=)) names)))

(defun make-code-tools (cwd &key settings on-image-event)
  "→ (file-tools shell-tools), both rooted at CWD. The shell tools need
approval and get SETTINGS-ENV of SETTINGS as their :env. H4b: with
LISP-IMAGE-ENABLED-P, (file-tools shell-tools lisp-tools), the lisp tools
from MAKE-CODE-LISP-TOOLS with ON-IMAGE-EVENT."
  (let* ((settings (or settings (make-settings)))
         (root (uiop:ensure-directory-pathname cwd))
         (files (tools:make-file-tools
                 :root root
                 :tools (%offered-names settings tools:+file-tool-names+)))
         (shell (tools:make-shell-tools
                 :root root
                 :needs-approval t
                 :env (settings-env settings)
                 :tools (%offered-names settings tools:+shell-tool-names+))))
    (if (lisp-image-enabled-p settings)
        (list files shell
              ;; The shell tools are closed when the lisp tools cannot be made.
              (handler-bind ((error (lambda (e)
                                      (declare (ignore e))
                                      (tools:close-shell-tools shell))))
                (make-code-lisp-tools root settings :on-image-event on-image-event)))
        (list files shell))))
