(in-package #:cl-stack-code/tests)

;;; R4d-4b end to end against a real kernel sandbox (macOS: Seatbelt; Linux:
;;; Landlock / bubblewrap): `cl-stack-code -p --permission-mode plan` (RUN-CLI
;;; in this image) against the scripted mock LLM, which runs bash commands.
;;; DEFINE-REAL-PLAN-TESTS defines the same tests for each backend; each skips
;;; with the backend's reason when it cannot confine here (a CI container
;;; without Landlock or namespaces, a harness that is itself sandboxed).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets))

(defun real-plan-refusal (backend)
  "NIL when BACKEND can run a plan-shaped confinement here (available, the
policy supported, a canary command exits 0), else the reason (a string). Test
code: it does not use OPEN-PLAN-SANDBOX."
  (let ((dir (temp-directory-named "csc-real-probe")))
    (unwind-protect
         (multiple-value-bind (ok reason) (sc:confinement-available-p backend)
           (if (not ok)
               (or reason "unavailable")
               (handler-case
                   (let* ((c (sc:make-confinement :writable (list (native dir)) :read :all
                                                  :network :none))
                          (r (progn
                               (sc:check-confinement backend c)
                               (sc:run-confined backend c '("/bin/sh" "-c" "exit 0")
                                              :directory (native dir) :wall-clock 20))))
                     (cond ((null r) "the canary did not finish")
                           ((/= 0 (sc:sandbox-result-exit-code r))
                            (format nil "the canary exited ~d: ~a" (sc:sandbox-result-exit-code r)
                                    (sc:sandbox-result-stderr r)))
                           (t nil)))
                 (sc:compute-error (e) (princ-to-string e)))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defun call-with-outside-victim (fn)
  "FN on the native namestring of a file holding \"orig\" in a fresh temp
directory outside the project, the area and the data directory."
  (let ((dir (temp-directory-named "csc-outside")))
    (unwind-protect
         (let ((victim (merge-pathnames "victim.txt" dir)))
           (with-open-file (s victim :direction :output :if-exists :supersede)
             (write-line "orig" s))
           (funcall fn (native victim)))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defun file-text (native)
  (uiop:read-file-string (uiop:parse-native-namestring native)))

(defun call-with-loopback-server (fn)
  "FN on (port hits): an HTTP/1.0 server on 127.0.0.1 answering \"ok\"; HITS
is a function → how many connections it accepted."
  (let ((server (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
        (hits (list 0))
        (stop (list nil))
        (thread nil))
    (unwind-protect
         (progn
           (setf (sb-bsd-sockets:sockopt-reuse-address server) t)
           (sb-bsd-sockets:socket-bind server #(127 0 0 1) 0)
           (sb-bsd-sockets:socket-listen server 8)
           (setf (sb-bsd-sockets:non-blocking-mode server) t)
           (setf thread
                 (bt:make-thread
                  (lambda ()
                    (loop until (car stop)
                          do (let ((c (handler-case (sb-bsd-sockets:socket-accept server)
                                        (error () nil))))
                               (if (null c)
                                   (sleep 0.02)
                                   (progn
                                     (incf (car hits))
                                     (ignore-errors
                                      (setf (sb-bsd-sockets:non-blocking-mode c) nil)
                                      (let ((s (sb-bsd-sockets:socket-make-stream
                                                c :input t :output t :element-type 'character
                                                  :external-format :latin-1 :timeout 3)))
                                        (loop for line = (read-line s nil "")
                                              until (<= (length (string-right-trim '(#\Return) line)) 0))
                                        (format s "HTTP/1.0 200 OK~c~cContent-Length: 2~c~c~c~cok"
                                                #\Return #\Linefeed #\Return #\Linefeed
                                                #\Return #\Linefeed)
                                        (finish-output s)))
                                     (ignore-errors (sb-bsd-sockets:socket-close c)))))))
                  :name "cl-stack-code loopback server"))
           (funcall fn (nth-value 1 (sb-bsd-sockets:socket-name server))
                    (lambda () (car hits))))
      (setf (car stop) t)
      (when thread (ignore-errors (bt:join-thread thread)))
      (ignore-errors (sb-bsd-sockets:socket-close server)))))

(defun curl-command (port)
  (format nil "curl -s -m 5 -o /dev/null http://127.0.0.1:~d/; echo \"curl=$?\"" port))

(defun have-curl-p ()
  (zerop (nth-value 2 (uiop:run-program '("/bin/sh" "-c" "command -v curl")
                                        :ignore-error-status t :output nil))))

(defmacro with-real-plan-backend ((backend backend-form label) &body body)
  "BODY with BACKEND (BACKEND-FORM) as *PLAN-COMPUTE-BACKEND*; skip with the
reason when it cannot confine here."
  (let ((why (gensym "WHY")))
    `(let* ((,backend ,backend-form)
            (,why (real-plan-refusal ,backend)))
       (if ,why
           (skip (format nil "~a: ~a" ,label ,why))
           (let ((*plan-compute-backend* ,backend))
             ,@body)))))

(defmacro define-real-plan-tests (prefix backend-form)
  "The e2e tests <PREFIX>-…, confined by BACKEND-FORM."
  (flet ((name (suffix) (intern (format nil "~a-~a" prefix suffix)))
         (label () (string-downcase prefix)))
    `(progn
       (deftest ,(name "plan-write-outside-denied")
         (call-with-outside-victim
          (lambda (victim)
            (with-project (project config) '(("a.txt" "alpha"))
              (with-real-plan-backend (b ,backend-form ,(label))
                (multiple-value-bind (exit out)
                    (plan-run project config
                              (list (bash-step (format nil "echo pwned > '~a'" victim))
                                    (bash-step (format nil "rm -f '~a'" victim))
                                    "ok"))
                  (ok (eql 0 exit))
                  (ok (equal (format nil "orig~%") (file-text victim)) "the victim is unchanged")
                  (let ((results (tool-results out "bash")))
                    (ok (= 2 (length results)))
                    (ok (every (lambda (r) (equal "done" (jget r "status"))) results)
                        "it ran without asking, confined")
                    (ok (has "[sandbox:" (jget (first results) "content"))
                        "the result says it was the sandbox"))
                  (let ((sandbox (plan-sandbox-event out)))
                    (ok (and sandbox (equal "confined" (jget sandbox "status")))))))))))

       (deftest ,(name "plan-write-inside-in-the-diff")
         (with-project (project config) '(("a.txt" "alpha"))
           (with-real-plan-backend (b ,backend-form ,(label))
             (multiple-value-bind (exit out)
                 (plan-run project config
                           (list (bash-step "echo made > made.txt; mkdir -p sub; echo deep > sub/b.txt; cat made.txt")
                                 "ok"))
               (ok (eql 0 exit))
               (ok (has "made" (jget (first (tool-results out "bash")) "content")))
               (let* ((projected (plan-event out "projected"))
                      (diff (and projected (jget projected "diff"))))
                 (ok (has "made.txt" diff) "the shell's write is in the projected diff")
                 (ok (has "+made" diff))
                 (ok (has "sub/b.txt" diff)))
               (ok (not (file-exists project "made.txt")) "the project is untouched")
               (ok (equal "made" (string-right-trim '(#\Newline)
                                                    (area-file (only-plan project config) "made.txt"))))))))

       (deftest ,(name "plan-network-denied")
         (if (not (have-curl-p))
             (skip "curl is not installed")
             (call-with-loopback-server
              (lambda (port hits)
                (with-project (project config) '()
                  (with-real-plan-backend (b ,backend-form ,(label))
                    (multiple-value-bind (exit out)
                        (plan-run project config (list (bash-step (curl-command port)) "ok"))
                      (ok (eql 0 exit))
                      (ok (eql 0 (funcall hits)) "the server saw no connection")
                      (let ((content (jget (first (tool-results out "bash")) "content")))
                        (ok (has "curl=" content))
                        (ok (not (has "curl=0" content)) "curl failed")))))))))

       (deftest ,(name "plan-allow-network")
         (if (not (have-curl-p))
             (skip "curl is not installed")
             (call-with-loopback-server
              (lambda (port hits)
                (with-project (project config) '()
                  (with-real-plan-backend (b ,backend-form ,(label))
                    (multiple-value-bind (exit out)
                        (plan-run project config (list (bash-step (curl-command port)) "ok")
                                  "--allow-network")
                      (ok (eql 0 exit))
                      (ok (has "curl=0" (jget (first (tool-results out "bash")) "content"))
                          "--allow-network opts into :allow")
                      (ok (plusp (funcall hits)))))))))))))
