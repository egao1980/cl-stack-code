(in-package #:cl-stack-code/tests)

;;; R4d-4b on macOS: plan mode under real Seatbelt (compute-backend-seatbelt,
;;; sandbox-exec). Skips with the backend's reason when sandbox-exec cannot
;;; run here.

(define-real-plan-tests seatbelt
  (stack-compute-seatbelt:make-seatbelt-backend))
