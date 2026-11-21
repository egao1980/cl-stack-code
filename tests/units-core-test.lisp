(in-package #:cl-stack-code/tests)

;;; H8d: the core's unit events, /ps and the status line (no terminal).

(deftest units-core-ps
  (let ((s (fresh-state)))
    (ok (equal '((:units-panel)) (effects s '(:submit "/ps"))))
    (ok (null (state-transcript s)) "no entry")
    (ok (null (effects s '(:submit "/ps all"))))
    (ok (eq :error (entry-kind (last-entry s))))
    (ok (equal "usage: /ps" (entry-text (last-entry s)))))
  (let ((s (busy-state)))
    (ok (equal '((:units-panel)) (effects s '(:submit "/ps"))) "also while a turn runs")
    (ok (null (state-queue s)) "not queued")))

(deftest units-core-running-count
  (let ((s (fresh-state :cwd #p"/srv/app/")))
    (ok (eql 0 (state-units-running s)))
    (multiple-value-bind (left right) (status-line-text s)
      (declare (ignore left))
      (ok (equal "0 in · 0 out " right) "no units: unchanged"))
    (ok (null (effects s '(:units :running 3))))
    (ok (eql 3 (state-units-running s)))
    (ok (null (state-transcript s)) "no entry")
    (multiple-value-bind (left right) (status-line-text s)
      (ok (equal "3 running · 0 in · 0 out " right))
      (ok (not (search "running" left)) "the left side is unchanged"))
    (feed s '(:usage (10 5 0 0)) '(:units :running 1))
    (ok (equal "1 running · 10 in · 5 out " (nth-value 1 (status-line-text s))))
    (feed s '(:units :running 0))
    (ok (equal "10 in · 5 out " (nth-value 1 (status-line-text s))))))

(deftest units-core-failure-notice
  (let ((s (fresh-state)))
    (ok (null (effects s '(:unit-failed :notice "unit shell-job-2 (shell-job) failed with exit code 3; /ps to inspect"))))
    (ok (equal '(:notice) (kinds s)))
    (ok (equal "unit shell-job-2 (shell-job) failed with exit code 3; /ps to inspect"
               (entry-text (last-entry s)))))
  (let ((s (busy-state)))
    (feed s '(:unit-failed :notice "unit rpc-1 (rpc) failed with exit code 1; /ps to inspect"))
    (ok (eq :notice (entry-kind (last-entry s))) "while busy too")
    (ok (state-busy-p s) "the turn goes on")))
