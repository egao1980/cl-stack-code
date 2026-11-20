(in-package #:cl-stack-code)

;;; The agent-tools sources for a run.

(defun make-code-tools (cwd &key settings)
  "→ (file-tools shell-tools), both rooted at CWD. The shell tools need
approval and get SETTINGS-ENV of SETTINGS as their :env."
  (declare (ignore cwd settings))
  (%not-implemented 'make-code-tools))
