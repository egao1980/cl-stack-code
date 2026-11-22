(in-package #:cl-stack-code)

;;; The agent-tools sources for a run.

(defun %offered-names (settings names)
  "NAMES (in order) without the ones SETTINGS hides."
  (let ((hidden (hidden-tool-names settings names)))
    (remove-if (lambda (name) (member name hidden :test #'string=)) names)))

(defun make-code-tools (cwd &key settings on-image-event supervisor scope
                              confinement compute-backend skills)
  "→ (file-tools shell-tools), both rooted at CWD. The shell tools need
approval and get SETTINGS-ENV of SETTINGS as their :env. H4b: with
LISP-IMAGE-ENABLED-P, (file-tools shell-tools lisp-tools), the lisp tools
from MAKE-CODE-LISP-TOOLS with ON-IMAGE-EVENT.

H8d: with SUPERVISOR (MAKE-CODE-SUPERVISOR), the shell tools run every bash
command as a :shell-job unit of SUPERVISOR (MAKE-SHELL-TOOLS :SUPERVISOR,
:SCOPE SCOPE: their \"shell\" :tool-source scope goes under SCOPE, default
the root), and a UNIT-TOOLS source over SUPERVISOR (approval for
unit_control, every other unit tool free, the names SETTINGS does not hide)
comes LAST: (file-tools shell-tools [lisp-tools] unit-tools). The lisp tools
stay third, so (THIRD sources) is still the lisp tools when the image is on;
CODE-UNIT-TOOLS finds the unit tools.

R4d-4b: CONFINEMENT and COMPUTE-BACKEND (both or neither) go to
MAKE-SHELL-TOOLS unchanged, so every bash command line (and its job) runs
confined, under SUPERVISOR as a confined unit; the bash description then ends
with the policy (AGENT-TOOLS:CONFINEMENT-DESCRIPTION). Plan mode passes its
PLAN-SANDBOX's confinement and backend while the sandbox is :CONFINED.

H3e-1: with SKILLS (STEER-DIRECTIVEs) and \"skill\" not hidden, a SKILL-TOOLS
source over them comes last: (file shell [lisp] [units] skill)."
  (let* ((settings (or settings (make-settings)))
         (root (uiop:ensure-directory-pathname cwd))
         (files (tools:make-file-tools
                 :root root
                 :tools (%offered-names settings tools:+file-tool-names+)))
         (shell (apply #'tools:make-shell-tools
                       :root root
                       :needs-approval t
                       :env (settings-env settings)
                       :tools (%offered-names settings tools:+shell-tool-names+)
                       (append
                        (and supervisor
                             (append (list :supervisor supervisor)
                                     (and scope (list :scope scope))))
                        (and confinement
                             (list :confinement confinement :compute-backend compute-backend)))))
         (lisp nil)
         (units nil))
    ;; Everything made so far is closed when a later source cannot be made.
    (handler-bind ((error (lambda (e)
                            (declare (ignore e))
                            (when units (tools:close-unit-tools units))
                            (when lisp (lt:close-lisp-tools lisp))
                            (tools:close-shell-tools shell))))
      (when (lisp-image-enabled-p settings)
        (setf lisp (make-code-lisp-tools root settings :on-image-event on-image-event)))
      (when supervisor
        (setf units (tools:make-unit-tools
                     :supervisor supervisor
                     :tools (%offered-names settings tools:+unit-tool-names+)))))
    (append (list files shell)
            (and lisp (list lisp))
            (and units (list units))
            (and skills
                 (%offered-names settings (list +skill-tool-name+))
                 (list (make-skill-tools skills))))))

(defun code-unit-tools (sources)
  "H8d: the UNIT-TOOLS in SOURCES (MAKE-CODE-TOOLS' list), or NIL."
  (find-if #'tools:unit-tools-p sources))
