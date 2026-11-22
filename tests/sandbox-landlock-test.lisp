(in-package #:cl-stack-code/tests)

;;; R4d-4b on Linux: plan mode under real Landlock / bubblewrap
;;; (compute-backend-landlock, the best mechanism available). :read :all with
;;; the default deny-read needs a mount namespace (bwrap or the trampoline's);
;;; where there is none, or no Landlock at all (e.g. the CI container), the
;;; tests skip with the backend's reason.

(define-real-plan-tests landlock
  (stack-compute-landlock:make-landlock-backend))
