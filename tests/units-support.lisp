(in-package #:cl-stack-code/tests)

;;; H8d helpers (test code, complete). Child processes are this SBCL (no
;;; init files) or portable shell commands, so the same fixtures run on
;;; macOS, Linux and Windows. Expected rows, objects and lines are computed
;;; here from the supervisor and its log reader (supervisor-protocol), never
;;; from the code under test.

;;; Child programs.

(defun child-argv (&rest forms)
  "argv running this SBCL with no init files, evaluating FORMS (strings)."
  (append (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                "--core" (uiop:native-namestring sb-ext:*core-pathname*)
                "--noinform" "--no-sysinit" "--no-userinit" "--non-interactive")
          (loop for f in forms append (list "--eval" f))))

(defun echo-argv ()
  "A stdin echo server: each line read is written back."
  (child-argv "(loop for l = (read-line *standard-input* nil) while l do (write-line l) (finish-output))"))

(defun exit-argv (code)
  (child-argv (format nil "(sb-ext:exit :code ~d :abort t)" code)))

(defun busy-argv (seconds)
  "A child that burns CPU for about SECONDS seconds."
  (child-argv (format nil "(let ((end (+ (get-internal-real-time) (* ~d internal-time-units-per-second)))) (loop while (< (get-internal-real-time) end)))" seconds)))

(defun sleep-command (seconds)
  "A shell command that takes about SECONDS seconds and prints nothing."
  (pick (format nil "sleep ~d" seconds)
        (format nil "ping -n ~d 127.0.0.1 >nul" (1+ seconds))))

(defparameter +sort-command+ "sort"
  "sort reads stdin to EOF, then prints the lines sorted (sort.exe on Windows).")

(defun bg (command)
  "A mock step: bash COMMAND in the background."
  (list :tool "bash" (json-args "command" command "run_in_background" t)))

(defun fg (command)
  "A mock step: bash COMMAND in the foreground."
  (list :tool "bash" (json-args "command" command)))

;;; Supervisors.

(defun quiet-shutdown (sup)
  (handler-case
      (handler-bind ((sup:stop-failed (lambda (c)
                                        (let ((r (find-restart 'sup:abandon c)))
                                          (when r (invoke-restart r))))))
        (sup:shutdown-supervisor sup :grace 0.5 :force-grace 1))
    (error (e)
      (format *error-output* "~&;; quiet-shutdown: ~a: ~a~%" (type-of e) e))))

(defun delete-supervisor-base (base)
  "DELETE-TEMP-BASE, retried for up to 5 s on Windows while a unit log file is
still open there (supervisor-protocol#15: a stopped :rpc unit's segment
sometimes outlives SHUTDOWN-SUPERVISOR for a moment). Elsewhere, once."
  (if (uiop:os-windows-p)
      (loop for try from 1
            do (handler-case (return (delete-temp-base base))
                 (file-error (e)
                   (when (>= try 10) (error e))
                   (format *error-output* "~&;; delete-supervisor-base: retry ~d: ~a~%" try e)
                   (sleep 0.5))))
      (delete-temp-base base)))

(defun call-with-test-supervisor (fn &rest keys)
  (let ((base (temp-base)))
    (unwind-protect
         (let ((sup (apply #'sup:make-supervisor :state-directory (subdir base "units/") :exit-hook nil
                           keys)))
           (unwind-protect (funcall fn sup base)
             (quiet-shutdown sup)))
      (delete-supervisor-base base))))

(defmacro with-test-supervisor ((sup &optional (base (gensym "BASE")) &rest keys) &body body)
  "BODY with SUP a fresh supervisor over a temp state directory under BASE;
KEYS go to SUP:MAKE-SUPERVISOR."
  `(call-with-test-supervisor (lambda (,sup ,base) (declare (ignorable ,base)) ,@body) ,@keys))

(defun settle (unit &key (timeout 20))
  "Wait until UNIT finished and its log has its end record. → UNIT."
  (sup:wait-unit unit :timeout timeout)
  (wait-until (lambda () (ignore-errors (sup:log-closed-p unit))) :timeout 10)
  unit)

(defun unit-texts (unit)
  "The texts of UNIT's output records."
  (handler-case (mapcar #'sup:log-record-text (sup:log-read unit))
    (sup:log-not-found () '())))

(defun wait-text (unit text &key (timeout 20))
  "True once UNIT's log has an output record whose text is TEXT."
  (and (wait-until (lambda () (member text (unit-texts unit) :test #'string=)) :timeout timeout) t))

(defun record-of (unit text)
  "The first output record of UNIT whose text is TEXT."
  (find text (sup:log-read unit) :key #'sup:log-record-text :test #'string=))

(defun wait-state (unit state &key (timeout 20))
  (and (wait-until (lambda () (eq state (sup:unit-state unit))) :timeout timeout) t))

;;; The fixture units: a fake server and a subagent thread (the shell jobs
;;; come from the agent's bash tool, so they prove the wiring).

(defparameter +sub-lines+ '("sub: started" "sub: working on needle-42"))

(defun start-server (sup)
  "A fake stdio server (:rpc, the echo child) owned by SUP's root."
  (sup:start-unit sup :rpc :command (echo-argv) :labels '(:role "fake-server")))

(defun start-subagent (sup gate)
  "A :subagent thread in scope (:agent \"sub\") printing +SUB-LINES+, then
waiting until (CAR GATE), then printing \"sub: done\"."
  (let ((scope (sup:make-scope sup :agent "sub")))
    (sup:start-unit sup :subagent
                    :owner scope
                    :function (lambda (u)
                                (declare (ignore u))
                                (dolist (l +sub-lines+) (write-line l))
                                (finish-output)
                                (loop until (or (car gate) (sup:unit-stop-requested-p sup:*current-unit*))
                                      do (sleep 0.02))
                                (write-line "sub: done")
                                (finish-output)
                                :done))))

(defun two-jobs-steps (&rest more)
  "Mock steps: two background sleeps, then \"Started.\", then MORE."
  (append (list (bg (sleep-command 60)) (bg (sleep-command 60)) "Started.") more))

;;; Independent formatters (the brief's rules, written again).

(defun status-word* (u)
  (let ((code (sup:unit-exit-code u)))
    (ecase (sup:unit-state u)
      (:running "running") (:starting "starting") (:killed "killed")
      (:exited (if code (format nil "exited ~d" code) "exited"))
      (:failed (if code (format nil "failed ~d" code) "failed")))))

(defun owner-text* (u)
  (let ((path (sup:scope-path (sup:unit-owner u))))
    (if path (format nil "~{~a~^/~}" path) "-")))

(defun kind-text* (u) (string-downcase (symbol-name (sup:unit-kind u))))

(defun pid-text* (u) (if (sup:unit-pid u) (princ-to-string (sup:unit-pid u)) "-"))

(defun pad-to (string n)
  (if (< (length string) n)
      (concatenate 'string string (make-string (- n (length string)) :initial-element #\Space))
      (copy-seq string)))

(defun masked (row)
  "ROW with the UP, CPU% and RSS columns (characters 50-68) as ?, trailing
blanks trimmed (they change with time and load)."
  (let ((s (pad-to row 71)))
    (replace s (make-string 19 :initial-element #\?) :start1 50)
    (string-right-trim " " s)))

(defun row* (mark depth id status kind pid last)
  "The expected panel row, masked."
  (masked (format nil "~a~20a ~9a ~9a ~6@a ~6@a ~5@a ~6@a  ~a"
                  mark (concatenate 'string (make-string (* 2 depth) :initial-element #\Space) id)
                  status kind pid "" "" "" last)))

(defun unit-row* (u depth &key selected (last ""))
  (row* (if selected "> " "  ") depth (sup:unit-id u) (status-word* u) (kind-text* u)
        (pid-text* u) last))

(defun scope-row* (name depth)
  (format nil "~a  ~a/" (make-string (* 2 depth) :initial-element #\Space) name))

(defun rfc3339* (universal-time)
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ" y mo d h mi s)))

(defun log-line* (mark line text)
  (format nil "~a~5d  ~a" mark line text))

;;; The TUI.

(defun row-with (tui needle)
  "The first screen row containing NEEDLE, or NIL."
  (find-if (lambda (row) (search needle row)) (screen tui)))

(defun unit-screen-row (tui id)
  "The screen row of unit ID in the panel (its name column ends with ID)."
  (find-if (lambda (row)
             (and (>= (length row) 22)
                  (string= id (string-trim " " (subseq row 2 22)))))
           (screen tui)))

(defun panel-open-p (program) (unit-panel-open-p (code-program-panel program)))

(defun press-panel-key (tui) (ctrl tui :p))

(defun cell-inverse-p (tui x y)
  "True when the emulator cell at column X, row Y is drawn inverse."
  (let* ((snap (h:tui-snapshot tui))
         (row (aref (getf snap :cells) y))
         (cell (and (< x (length row)) (aref row x))))
    (and cell (tp:cell-style cell) (tp:style-inverse (tp:cell-style cell)) t)))

(defun call-with-units-tui (project config fn &key argv (steps (two-jobs-steps)) (cols 120) (rows 30))
  "FN gets (tui program backend sup gate): a program (MAKE-CODE-PROGRAM) whose
agent started two background shell jobs (\"start the jobs\"), plus a fake
server and a subagent thread on its supervisor. GATE (a cons) releases the
subagent; it is released on exit."
  (let ((gate (list nil)))
    (unwind-protect
         (with-code-tui (tui program backend
                             :argv (append '("--allowed-tools" "bash") argv)
                             :steps steps :cols cols :rows rows)
             (project config)
           (send-line tui "start the jobs")
           (wait-screen tui "Started.")
           (let ((sup (code-program-supervisor program)))
             (start-server sup)
             (start-subagent sup gate)
             (funcall fn tui program backend sup gate)))
      (setf (car gate) t))))

(defmacro with-units-tui ((tui program backend sup gate &rest keys) (project config) &body body)
  `(call-with-units-tui ,project ,config
                        (lambda (,tui ,program ,backend ,sup ,gate)
                          (declare (ignorable ,tui ,program ,backend ,sup ,gate))
                          ,@body)
                        ,@keys))

(defun fixture-units (sup)
  "(:jobs (j1 j2) :server s :sub u) of the fixture in SUP."
  (list :jobs (sup:find-units sup :kind :shell-job)
        :server (first (sup:find-units sup :kind :rpc))
        :sub (first (sup:find-units sup :kind :subagent))))

(defmacro with-gap-supervisor ((sup) &body body)
  "BODY with SUP a supervisor whose logs rotate fast (1 KiB × 2 segments)."
  `(with-test-supervisor (,sup ,(gensym "BASE") :log-segment-size 1024 :log-segments 2 :log-max-record 256)
     ,@body))

(defun same-keys (keys object)
  "OBJECT (a JSON object) has exactly KEYS."
  (equal (sort (copy-list keys) #'string<) (jkeys object)))
