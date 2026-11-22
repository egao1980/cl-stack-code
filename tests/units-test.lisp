(in-package #:cl-stack-code/tests)

;;; H8d: the model shared by the panel and --rpc (src/units.lisp,
;;; src/unit-panel.lisp views), without a terminal or an agent run.

;;; Given code.

(deftest units-constants
  (ok (equal '("stop" "restart" "input" "close_input") +unit-rpc-actions+))
  (ok (equal '((:yes "Yes") (:no "No")) +unit-action-choices+))
  (ok (equal '("UNIT" "STATE" "KIND" "PID" "UP" "CPU%" "RSS" "LAST") +unit-panel-columns+))
  (ok (equal '(:p (:ctrl)) +unit-panel-key+))
  (ok (eql 2000 +unit-log-scrollback+))
  (ok (eql 1 +unit-tick-interval+))
  (ok (eql (if (uiop:os-windows-p) 5 2) +unit-stats-interval+))
  (ok (equal '("units/list" "units/subscribe" "units/unsubscribe" "units/read" "units/search"
               "units/control")
             (last +rpc-methods+ 6)))
  (ok (equal "unit" (car (last +event-types+))))
  (ok (has "/ps" +help-text+))
  (ok (equal "0.9.1" +version+)))

(deftest units-directory-layout
  (with-project (project config) '()
    (let* ((data (data-dir-of config))
           (units (units-directory project :data-dir data))
           (sessions (sessions-directory project :data-dir data)))
      (ok (equal (car (last (pathname-directory sessions)))
                 (car (last (pathname-directory units))))
          "the same project key as the sessions")
      (ok (equal "units" (car (last (pathname-directory units) 2))))
      (ok (same-path (uiop:pathname-parent-directory-pathname
                      (uiop:pathname-parent-directory-pathname units))
                     data))
      (ok (not (uiop:directory-exists-p units)) "creates nothing"))))

(deftest units-make-code-supervisor
  (with-project (project config) '()
    (let ((sup (make-code-supervisor project :data-dir (data-dir-of config) :exit-hook nil)))
      (unwind-protect
           (progn
             (ok (typep sup 'sup:supervisor))
             (ok (same-path (units-directory project :data-dir (data-dir-of config))
                            (sup:supervisor-state-directory sup)))
             (ok (uiop:directory-exists-p (sup:supervisor-state-directory sup)))
             (ok (listp (sup:supervisor-sweep-report sup)) "the sweep ran")
             (ok (sup:supervisor-log-p sup) "rotated logs on")
             (ok (null (sup:supervisor-exit-hook sup))))
        (quiet-shutdown sup)))))

(deftest units-make-code-tools-with-supervisor
  (with-project (project config) '()
    (with-test-supervisor (sup)
      (let ((sources (make-code-tools project :supervisor sup)))
        (unwind-protect
             (progn
               (ok (= 3 (length sources)) "file, shell, unit tools")
               (ok (at:unit-tools-p (third sources)))
               (ok (eq (third sources) (code-unit-tools sources)))
               (ok (eq sup (at:unit-tools-supervisor (third sources))))
               (ok (eq sup (at:shell-tools-supervisor (second sources))))
               (ok (equal '("shell") (sup:scope-path (at:shell-tools-scope (second sources)))))
               (ok (equal (append at:+file-tool-names+ at:+shell-tool-names+ at:+unit-tool-names+)
                          (loop for s in sources
                                append (mapcar #'llm:llm-tool-name (a:list-agent-tools s))))))
          (at:close-unit-tools (third sources))
          (at:close-shell-tools (second sources))))
      (let ((plain (make-code-tools project)))
        (unwind-protect
             (progn
               (ok (= 2 (length plain)) "no supervisor: as before")
               (ok (null (code-unit-tools plain))))
          (at:close-shell-tools (second plain)))))))

(deftest units-make-code-tools-hidden
  (with-project (project config) '()
    (with-test-supervisor (sup)
      (let ((sources (make-code-tools project
                                      :supervisor sup
                                      :settings (make-settings
                                                 :deny (list (parse-permission-rule "unit_control" :deny))))))
        (unwind-protect
             (ok (equal (remove "unit_control" at:+unit-tool-names+ :test #'string=)
                        (mapcar #'llm:llm-tool-name (a:list-agent-tools (code-unit-tools sources)))))
          (at:close-unit-tools (code-unit-tools sources))
          (at:close-shell-tools (second sources)))))))

(deftest-parametrize units-rpc-error-for
    ((condition code name data)
     :ids ("unit-not-found" "unit-control-denied" "unit-control-needs-confirmation"
           "subscription-not-found" "unit-control-failed")
     ((make-condition 'unit-not-found :unit "shell-job-9") -32015 "unit-not-found"
      '("unit" "shell-job-9"))
     ((make-condition 'unit-control-denied :unit "rpc-1" :action "stop" :rule "unit_control(*:rpc-*)")
      -32016 "unit-control-denied" '("unit" "rpc-1" "action" "stop" "rule" "unit_control(*:rpc-*)"))
     ((make-condition 'unit-control-needs-confirmation :unit "rpc-1" :action "stop"
                                                       :resource "stop:rpc-1")
      -32017 "unit-control-needs-confirmation" '("unit" "rpc-1" "action" "stop" "resource" "stop:rpc-1"))
     ((make-condition 'subscription-not-found :id "sub-7") -32018 "subscription-not-found"
      '("subscription" "sub-7"))
     ((make-condition 'unit-control-failed :unit "subagent-1" :action "input" :message "no input")
      -32019 "unit-control-failed" '("unit" "subagent-1" "action" "input")))
  (multiple-value-bind (c message object) (rpc-error-for condition)
    (ok (eql code c))
    (ok (stringp message))
    (ok (equal name (jget object "condition")))
    (loop for (k v) on data by #'cddr
          do (ok (equal v (jget object k)) k))))

;;; Formatting.

(deftest-parametrize units-format-uptime
    ((seconds text)
     :ids ("nil" "zero" "59s" "1m04s" "59m59s" "1h02m" "23h59m" "2d03h" "fraction")
     (nil "-") (0 "0s") (59 "59s") (64 "1m04s") (3599 "59m59s") (3720 "1h02m")
     (86399 "23h59m") (183600 "2d03h") (61.9 "1m01s"))
  (ok (equal text (format-unit-uptime seconds))))

(deftest-parametrize units-format-rss
    ((bytes text)
     :ids ("nil" "zero" "512K" "1023K" "1.0M" "12.3M" "1.2G")
     (nil "-") (0 "0K") (524288 "512K") (1047552 "1023K") (1048576 "1.0M")
     (12897485 "12.3M") (1288490189 "1.2G"))
  (ok (equal text (format-unit-rss bytes))))

(deftest-parametrize units-format-cpu
    ((percent text)
     :ids ("nil" "zero" "12.5" "round" "250")
     (nil "-") (0 "0.0") (12.5 "12.5") (33.333 "33.3") (250 "250.0"))
  (ok (equal text (format-unit-cpu percent))))

(deftest-parametrize units-parse-ps-cpu-time
    ((string seconds)
     :ids ("mm:ss" "macos" "hh:mm:ss" "days" "blanks" "fraction" "empty" "junk" "nil-like")
     ("00:03" 3) ("0:00.03" 0.03) ("01:02:03" 3723) ("2-01:00:00" 176400) ("   1:05" 65)
     ("1:02:03.50" 3723.5) ("" nil) ("abc" nil) ("-" nil))
  (let ((v (parse-ps-cpu-time string)))
    (if seconds
        (ok (and v (< (abs (- v seconds)) 1d-6)) string)
        (ok (null v) string))))

(deftest units-cpu-percent
  (ok (< (abs (- 50 (unit-cpu-percent '(:cpu-time 1.0 :rss 1) '(:cpu-time 2.0 :rss 1) 2))) 1d-6))
  (ok (< (abs (- 150 (unit-cpu-percent '(:cpu-time 0 :rss 1) '(:cpu-time 3 :rss 1) 2))) 1d-6)
      "more than one core")
  (ok (eql 0 (round (unit-cpu-percent '(:cpu-time 5 :rss 1) '(:cpu-time 4 :rss 1) 1)))
      "never negative")
  (ok (null (unit-cpu-percent nil '(:cpu-time 1 :rss 1) 1)))
  (ok (null (unit-cpu-percent '(:cpu-time 1 :rss 1) nil 1)))
  (ok (null (unit-cpu-percent '(:cpu-time 1 :rss 1) '(:cpu-time 2 :rss 1) 0))))

;;; Units.

(deftest units-status-word
  (with-test-supervisor (sup)
    (let ((ok0 (settle (sup:start-unit sup :shell-job :command (exit-argv 0))))
          (bad (settle (sup:start-unit sup :shell-job :command (exit-argv 3))))
          (done (settle (sup:start-unit sup :subagent :function (lambda (u) (declare (ignore u)) 1))))
          (boom (settle (sup:start-unit sup :subagent :function (lambda (u) (declare (ignore u))
                                                                   (error "boom")))))
          (live (sup:start-unit sup :rpc :command (echo-argv))))
      (ok (equal "exited 0" (unit-status-word ok0)))
      (ok (equal "failed 3" (unit-status-word bad)))
      (ok (equal "exited" (unit-status-word done)))
      (ok (equal "failed" (unit-status-word boom)))
      (ok (equal "running" (unit-status-word live)))
      (sup:stop-unit live :grace 1)
      (ok (equal "killed" (unit-status-word live)))
      (dolist (u (list ok0 bad done boom live))
        (ok (equal (status-word* u) (unit-status-word u)) (sup:unit-id u))))))

(deftest units-tree-order
  (with-test-supervisor (sup)
    (let* ((gate (list nil))
           (a (sup:make-scope sup :agent "a"))
           (b (sup:make-scope sup :tool-source "b" :parent a))
           (empty (sup:make-scope sup :agent "empty"))
           (wait (lambda (u) (declare (ignore u)) (loop until (car gate) do (sleep 0.02))))
           (u1 (sup:start-unit sup :subagent :function wait :owner b))
           (u2 (sup:start-unit sup :subagent :function wait :owner a))
           (u3 (sup:start-unit sup :rpc :command (echo-argv)))
           (u4 (sup:start-unit sup :subagent :function wait :owner a)))
      (declare (ignore empty))
      (unwind-protect
           (let ((rows (unit-tree sup)))
             (ok (equal (list (list :unit u3 0) (list :scope a 0) (list :unit u2 1) (list :unit u4 1)
                              (list :scope b 1) (list :unit u1 2))
                        (mapcar (lambda (r)
                                  (if (getf r :unit)
                                      (list :unit (getf r :unit) (getf r :depth))
                                      (list :scope (getf r :scope) (getf r :depth))))
                                rows))
                 "root units, then scopes depth first; own units before child scopes; no empty scope")
             (ok (equal (list (list :unit u1 0))
                        (mapcar (lambda (r) (list :unit (getf r :unit) (getf r :depth)))
                                (unit-tree sup :scope b)))
                 "below a scope"))
        (setf (car gate) t)))))

(deftest units-last-line
  (with-test-supervisor (sup)
    (let ((u (settle (sup:start-unit sup :subagent
                                     :function (lambda (u)
                                                 (declare (ignore u))
                                                 (write-line "first")
                                                 (format t "~c[31mred~c[0m~cdone~c~%" #\Esc #\Esc #\Tab
                                                         (code-char 7))
                                                 (finish-output)))))
          (quiet (settle (sup:start-unit sup :subagent :function (lambda (u) (declare (ignore u)) 1)))))
      (ok (equal "red done" (unit-last-line u)) "ANSI and controls removed, TAB → space")
      (ok (null (unit-last-line quiet)) "no output")))
  (let ((sup (sup:make-supervisor :exit-hook nil)))
    (unwind-protect
         (let ((u (settle (sup:start-unit sup :subagent
                                          :function (lambda (u) (declare (ignore u)) (write-line "x"))))))
           (ok (null (unit-last-line u)) "no log file"))
      (quiet-shutdown sup))))

(deftest units-row-text
  (with-test-supervisor (sup)
    (let* ((gate (list nil))
           (now (get-universal-time))
           (thread (sup:start-unit sup :subagent
                                   :function (lambda (u) (declare (ignore u))
                                               (write-line "hello there")
                                               (finish-output)
                                               (loop until (car gate) do (sleep 0.02)))))
           (proc (sup:start-unit sup :rpc :command (echo-argv)))
           (long (settle (sup:start-unit sup :a-very-long-kind-name
                                         :function (lambda (u) (declare (ignore u)) 1)))))
      (unwind-protect
           (progn
             (ok (wait-text thread "hello there"))
             (let ((start (sup:unit-start-time thread)))
               (ok (equal (string-right-trim
                           " " (format nil "~a~20a ~9a ~9a ~6@a ~6@a ~5@a ~6@a  ~a" "  " "subagent-1"
                                       "running" "subagent" "-" "1m04s" "-" "-" "hello there"))
                          (unit-row-text (list :unit thread :depth 0) 200 :now (+ start 64)))
                   "a thread row"))
             (ok (equal (string-right-trim
                         " " (format nil "~a~20a ~9a ~9a ~6@a ~6@a ~5@a ~6@a  ~a" "> " "  rpc-1" "running"
                                     "rpc" (sup:unit-pid proc) "0s" "12.5" "12.3M" ""))
                        (unit-row-text (list :unit proc :depth 1) 200
                                       :selected t :now (sup:unit-start-time proc)
                                       :stats '(:cpu-time 1 :rss 12897485) :cpu 12.5))
                 "a selected process row with resources")
             (ok (equal (string-right-trim
                         " " (format nil "~a~20a ~9a ~9a ~6@a ~6@a ~5@a ~6@a  ~a" "  "
                                     "a-very-long-kind-na…" "exited" "a-very-l…" "-" "-" "-" "-" ""))
                        (unit-row-text (list :unit long :depth 0) 200 :now now))
                 "long names cut with …, finished: no uptime")
             (ok (equal "    sub/" (unit-row-text (list :scope (sup:make-scope sup :agent "sub") :depth 1) 200))
                 "a scope row")
             (ok (equal (string-right-trim
                         " " (format nil "~a~20a ~9a ~9a ~6@a ~6@a ~5@a ~6@a  ~a" "  " "UNIT" "STATE" "KIND"
                                     "PID" "UP" "CPU%" "RSS" "LAST"))
                        (unit-row-text nil 200 :header t))
                 "the header")
             (ok (equal "  subagent-1" (unit-row-text (list :unit thread :depth 0) 12 :now now))
                 "cut to the width"))
        (setf (car gate) t)))))

(deftest units-panel-lines
  (with-test-supervisor (sup)
    (let* ((gate (list nil))
           (wait (lambda (u) (declare (ignore u)) (loop until (car gate) do (sleep 0.02))))
           (units (loop repeat 6 collect (sup:start-unit sup :subagent :function wait)))
           (done (settle (sup:start-unit sup :shell-job :command (exit-argv 0)))))
      (declare (ignore units done))
      (unwind-protect
           (let* ((rows (unit-tree sup))
                  (now (get-universal-time))
                  (lines (unit-panel-lines rows 100 6 :selected "subagent-5" :now now))
                  (texts (mapcar #'w:runs-string lines)))
             (ok (= 6 (length lines)) "exactly HEIGHT lines")
             (ok (equal "Units · 6 running · 7 total" (string-right-trim " " (first texts))))
             (ok (equal (unit-row-text nil 100 :header t) (string-right-trim " " (second texts))))
             (ok (some (lambda (s) (uiop:string-prefix-p "> subagent-5" s)) texts)
                 "the selection is scrolled into view")
             (ok (notany (lambda (s) (search "subagent-1 " s)) texts) "rows above it scrolled out")
             (let ((selected (find-if (lambda (line) (uiop:string-prefix-p "> " (w:runs-string line)))
                                      lines)))
               (ok (every (lambda (run) (tp:style-inverse (w:text-run-style run)))
                          (remove-if (lambda (run) (zerop (length (w:text-run-text run)))) selected))
                   "the selected row is inverse"))
             (ok (equal (list "Units · 0 running · 0 total"
                              "  no units yet: shell jobs, servers and subagents show up here")
                        (mapcar (lambda (l) (string-right-trim " " (w:runs-string l)))
                                (subseq (unit-panel-lines '() 100 4) 0 2)))
                 "no units"))
        (setf (car gate) t)))))

(defun gap-fixture (sup)
  "A finished thread unit whose first segments were rotated away (SUP made
with small segments: WITH-GAP-SUPERVISOR)."
  (settle (sup:start-unit sup :subagent
                          :function (lambda (u) (declare (ignore u))
                                      (dotimes (i 200) (format t "line ~3,'0d~%" i))
                                      (finish-output)))))

(deftest units-log-lines
  (with-test-supervisor (sup)
    (let ((u (settle (sup:start-unit sup :subagent
                                     :function (lambda (u) (declare (ignore u))
                                                 (write-line "alpha")
                                                 (format t "a~cb~c[1mbold~c[0m~%" #\Tab #\Esc #\Esc)
                                                 (write-line "oops: needle-42 here" *error-output*)
                                                 (finish-output) (finish-output *error-output*))))))
      (multiple-value-bind (records gaps) (sup:log-read u)
        (let* ((alpha (record-of u "alpha"))
               (oops (find-if (lambda (r) (search "needle-42" (sup:log-record-text r))) records))
               (lines (unit-log-lines records gaps 80 :hits (list (sup:log-record-line oops))
                                                      :query "needle-42"))
               (texts (mapcar (lambda (l) (string-right-trim " " (w:runs-string l))) lines)))
          (ok (= 3 (length lines)))
          (ok (equal (log-line* " " (sup:log-record-line alpha) "alpha") (first texts)))
          (ok (equal (log-line* " " (1+ (sup:log-record-line alpha)) "a       bbold") (second texts))
              "TAB to the next 8 columns, ANSI removed")
          (ok (equal (log-line* ">" (sup:log-record-line oops) "oops: needle-42 here") (third texts))
              "the hit mark")
          (let* ((runs (third lines))
                 (hit (find "needle-42" runs :key #'w:text-run-text :test #'string=)))
            (ok hit "the term is its own run")
            (ok (and hit (tp:style-inverse (w:text-run-style hit))) "highlighted")
            (ok (every (lambda (run)
                         (or (eq run hit) (not (tp:style-inverse (w:text-run-style run)))))
                       runs)
                "nothing else inverse")
            (ok (some (lambda (run) (and (search "oops" (w:text-run-text run))
                                         (eql 1 (tp:style-foreground (w:text-run-style run)))))
                      runs)
                "stderr text is red")))))
    (with-gap-supervisor (gs)
     (let ((g (gap-fixture gs)))
      (multiple-value-bind (records gaps) (sup:log-read g)
        (ok gaps "the fixture has a gap")
        (let ((gap (first gaps)))
          (ok (equal (format nil "[gap: lines ~d-~d not in the log (rotated)]"
                             (sup:log-gap-first-line gap) (sup:log-gap-last-line gap))
                     (string-right-trim " " (w:runs-string (first (unit-log-lines records gaps 80)))))
              "a gap line first, in line order")))))))

(deftest units-log-title
  (with-test-supervisor (sup)
    (let ((u (settle (sup:start-unit sup :shell-job :command (exit-argv 3)))))
      (ok (equal "Log shell-job-1 (failed 3) · following" (unit-log-title u :following t)))
      (ok (equal "Log shell-job-1 (failed 3) · lines 4-20" (unit-log-title u :first-line 4 :last-line 20)))
      (ok (equal "Log shell-job-1 (failed 3) · following · search \"boom\": 2 of 5"
                 (unit-log-title u :following t :query "boom" :hit-index 1 :hit-count 5)))
      (ok (equal "Log shell-job-1 (failed 3) · following · search \"x y\": no results"
                 (unit-log-title u :following t :query "x y" :hit-count 0))))))

;;; JSON.

(defparameter +unit-object-keys+
  '("id" "kind" "state" "status" "owner" "owner_path" "depth" "labels" "command" "pid" "started"
    "uptime_s" "exit_code" "signal" "restarts" "lines" "last_line" "cpu_percent" "cpu_time_s"
    "rss_bytes"))

(deftest units-object
  (with-test-supervisor (sup)
    (let* ((scope (sup:make-scope sup :agent "sub"))
           (proc (sup:start-unit sup :rpc :command (echo-argv) :labels '(:role "fake-server")))
           (thread (settle (sup:start-unit sup :subagent :owner scope
                                           :function (lambda (u) (declare (ignore u))
                                                       (write-line "bye") 7))))
           (now (+ 5 (sup:unit-start-time proc)))
           (o (unit-object proc :now now :depth 0 :stats '(:cpu-time 1.5 :rss 4096) :cpu-percent 2.5))
           (to (unit-object thread :depth 1)))
      (ok (same-keys +unit-object-keys+ o) "the keys")
      (ok (equal "rpc-1" (jget o "id")))
      (ok (equal "rpc" (jget o "kind")))
      (ok (equal "running" (jget o "state")))
      (ok (equal "running" (jget o "status")))
      (ok (equal "-" (jget o "owner")))
      (ok (equalp #() (jget o "owner_path")))
      (ok (eql 0 (jget o "depth")))
      (ok (equal "fake-server" (jget o "labels" "role")))
      (ok (equalp (coerce (sup:unit-command proc) 'vector) (jget o "command")))
      (ok (eql (sup:unit-pid proc) (jget o "pid")))
      (ok (equal (rfc3339* (sup:unit-start-time proc)) (jget o "started")))
      (ok (eql 5 (jget o "uptime_s")))
      (ok (eq :null (jget o "exit_code")))
      (ok (eq :null (jget o "signal")))
      (ok (eql 0 (jget o "restarts")))
      (ok (eql 2.5 (jget o "cpu_percent")))
      (ok (eql 1.5 (jget o "cpu_time_s")))
      (ok (eql 4096 (jget o "rss_bytes")))
      (ok (equal "exited" (jget to "state")))
      (ok (equal "exited" (jget to "status")))
      (ok (equal "sub" (jget to "owner")))
      (ok (equalp #("sub") (jget to "owner_path")))
      (ok (eql 1 (jget to "depth")))
      (ok (eq :null (jget to "command")))
      (ok (eq :null (jget to "pid")))
      (ok (eq :null (jget to "uptime_s")) "finished: no uptime")
      (ok (equal "bye" (jget to "last_line")))
      (ok (eql (sup:log-last-line thread) (jget to "lines")))
      (ok (eq :null (jget to "cpu_percent")))
      (ok (eq :null (jget to "rss_bytes")))
      (sup:stop-unit proc :grace 1)
      (let ((k (unit-object proc)))
        (ok (equal "killed" (jget k "state")))
        (ok (member (jget k "signal") '("term" "kill") :test #'equal))))))

(deftest units-objects-order-and-filters
  (with-test-supervisor (sup)
    (let* ((gate (list nil))
           (scope (sup:make-scope sup :agent "sub"))
           (wait (lambda (u) (declare (ignore u)) (loop until (car gate) do (sleep 0.02))))
           (sub (sup:start-unit sup :subagent :owner scope :function wait))
           (done (settle (sup:start-unit sup :shell-job :command (exit-argv 0))))
           (server (sup:start-unit sup :rpc :command (echo-argv))))
      (unwind-protect
           (flet ((ids (&rest keys) (mapcar (lambda (o) (jget o "id")) (apply #'unit-objects sup keys))))
             (ok (equal (list (sup:unit-id done) (sup:unit-id server) (sup:unit-id sub)) (ids))
                 "UNIT-TREE order")
             (ok (equal (list (sup:unit-id sub)) (ids :kind :subagent)))
             (ok (equal (list (sup:unit-id sub)) (ids :kind "subagent")))
             (ok (equal (list (sup:unit-id server) (sup:unit-id sub)) (ids :state :live)))
             (ok (equal (list (sup:unit-id server) (sup:unit-id sub)) (ids :state "live")))
             (ok (equal (list (sup:unit-id done)) (ids :state "finished")))
             (ok (equal (list (sup:unit-id done)) (ids :state :exited)))
             (ok (equal (list (sup:unit-id sub)) (ids :owner "s*")))
             (ok (equal (list (sup:unit-id done) (sup:unit-id server)) (ids :owner "-"))))
        (setf (car gate) t)))))

(deftest units-event-object
  (let* ((time (encode-universal-time 1 0 12 21 11 2026 0))
         (failed (make-instance 'sup:unit-event :seq 7 :time time :monotonic 1.25
                                                :unit-id "shell-job-3" :unit-kind :shell-job
                                                :type :state :from :running :to :failed
                                                :detail '(:exit-code 3 :signal nil :abandoned nil)))
         (o (unit-event-object failed :subscription "sub-1" :session-id "abcd"))
         (r (unit-event-object (make-instance 'sup:unit-event :seq 8 :time time :monotonic 1.5
                                                              :unit-id "rpc-1" :unit-kind :rpc
                                                              :type :restart-scheduled
                                                              :from :failed :to :failed
                                                              :detail '(:attempt 1 :delay 0.5)))))
    (ok (same-keys '("type" "session_id" "subscription" "seq" "time" "unit_id" "kind" "event" "from"
                    "to" "detail")
                  o))
    (ok (equal "unit" (jget o "type")))
    (ok (equal "abcd" (jget o "session_id")))
    (ok (equal "sub-1" (jget o "subscription")))
    (ok (eql 7 (jget o "seq")))
    (ok (equal "2026-11-21T12:00:01.000Z" (jget o "time")))
    (ok (equal "shell-job-3" (jget o "unit_id")))
    (ok (equal "shell-job" (jget o "kind")))
    (ok (equal "state" (jget o "event")))
    (ok (equal "running" (jget o "from")))
    (ok (equal "failed" (jget o "to")))
    (ok (eql 3 (jget o "detail" "exit_code")))
    (ok (multiple-value-bind (v present) (gethash "signal" (jget o "detail")) (and present (null v)))
        "NIL in a detail is false")
    (ok (multiple-value-bind (v present) (gethash "abandoned" (jget o "detail")) (and present (null v))))
    (ok (equal "restart_scheduled" (jget r "event")))
    (ok (eql 1 (jget r "detail" "attempt")))
    (ok (eq :null (jget r "subscription")))
    (ok (eq :null (jget r "session_id")))))

(deftest units-record-and-gap-objects
  (with-test-supervisor (sup)
    (let* ((u (settle (sup:start-unit sup :subagent
                                      :function (lambda (u) (declare (ignore u))
                                                  (write-line "out line")
                                                  (write-string "err part" *error-output*)
                                                  (finish-output) (finish-output *error-output*)))))
           (out (record-of u "out line"))
           (err (record-of u "err part"))
           (o (unit-record-object out))
           (e (unit-record-object err)))
      (ok (same-keys '("line" "time" "stream" "text" "continued") o))
      (ok (eql (sup:log-record-line out) (jget o "line")))
      (ok (equal "stdout" (jget o "stream")))
      (ok (equal "out line" (jget o "text")))
      (ok (null (jget o "continued")))
      (ok (= 24 (length (jget o "time"))) "RFC 3339 with milliseconds")
      (ok (equal "stderr" (jget e "stream")))
      (ok (eq t (jget e "continued")) "no LF: continued"))
    (with-gap-supervisor (gs)
     (let ((g (gap-fixture gs)))
      (let* ((gap (first (nth-value 1 (sup:log-read g))))
             (o (unit-gap-object gap)))
        (ok (same-keys '("first_line" "last_line" "records" "bytes" "reasons") o))
        (ok (eql (sup:log-gap-first-line gap) (jget o "first_line")))
        (ok (eql (sup:log-gap-last-line gap) (jget o "last_line")))
        (ok (eql (sup:log-gap-records gap) (jget o "records")))
        (ok (equalp #("rotated") (jget o "reasons"))))))))

;;; Control.

(deftest units-control-arguments
  (flet ((decoded (&rest args) (json:decode (apply #'unit-control-arguments args))))
    (let ((stop (decoded "stop" "shell-job-1")))
      (ok (equal "shell-job-1" (jget stop "unit")))
      (ok (equal "stop" (jget stop "action")))
      (ok (= 2 (hash-table-count stop))))
    (ok (equal "restart" (jget (decoded "restart" "rpc-1") "action")))
    (let ((input (decoded "input" "rpc-1" :input (format nil "ping~%"))))
      (ok (equal "input" (jget input "action")))
      (ok (equal (format nil "ping~%") (jget input "input")))
      (ok (null (nth-value 1 (gethash "eof" input))) "no eof key"))
    (let ((close (decoded "close_input" "rpc-1")))
      (ok (equal "input" (jget close "action")))
      (ok (equal "" (jget close "input")))
      (ok (eq t (jget close "eof")))))
  (ok (typep (failure (unit-control-arguments "kill" "rpc-1")) 'code-usage-error))
  (ok (typep (failure (unit-control-arguments "input" "rpc-1")) 'code-usage-error)
      "input needs the text"))

(defun control-agent (sup rules)
  "→ (values agent unit-tools): an agent with RULES and unit tools over SUP."
  (let ((ut (at:make-unit-tools :supervisor sup)))
    (values (a:make-ai-agent :name "t" :backend (make-scripted-backend '()) :tools (list ut)
                             :permissions rules)
            ut)))

(deftest-parametrize units-action-permission
    ((rules mode action unit effect)
     :ids ("default-asks" "allow-stop" "allow-stop-restart-asks" "deny-subagents" "bypass"
           "bypass-keeps-deny" "accept-edits-asks" "close-input-is-input" "input-rule")
     ('() :default "stop" "shell-job-1" :ask)
     ('("unit_control(stop:shell-job-*)") :default "stop" "shell-job-1" :allow)
     ('("unit_control(stop:shell-job-*)") :default "restart" "shell-job-1" :ask)
     ('("unit_control(*:subagent-*)!") :default "stop" "subagent-1" :deny)
     ('() :bypass-permissions "stop" "shell-job-1" :allow)
     ('("unit_control(*:subagent-*)!") :bypass-permissions "stop" "subagent-1" :deny)
     ('() :accept-edits "stop" "shell-job-1" :ask)
     ('("unit_control(input:rpc-*)") :default "close_input" "rpc-1" :allow)
     ('("unit_control(input:rpc-*)") :default "input" "rpc-1" :allow))
  (with-test-supervisor (sup)
    (let ((parsed (mapcar (lambda (text)
                            (if (uiop:string-suffix-p text "!")
                                (parse-permission-rule (subseq text 0 (1- (length text))) :deny)
                                (parse-permission-rule text :allow)))
                          rules)))
      (multiple-value-bind (agent ut) (control-agent sup parsed)
        (unwind-protect
             (multiple-value-bind (e rule resources)
                 (unit-action-permission agent ut action unit :mode mode :input "x")
               (ok (eq effect e) (format nil "~a ~a" action unit))
               (ok (equal (list (format nil "~a:~a" (if (string= action "close_input") "input" action) unit))
                          resources)
                   "the agent's own resource")
               (when (and parsed (member e '(:allow :deny)) (not (eq mode :bypass-permissions)))
                 (ok rule "the deciding rule"))
               (multiple-value-bind (agent-effect) (a:agent-permission agent ut "unit_control"
                                                                       (unit-control-arguments
                                                                        action unit :input "x"))
                 (unless (eq mode :bypass-permissions)
                   (ok (eq agent-effect e) "the agent's decision for the same call"))))
          (at:close-unit-tools ut))))))

(deftest units-action-message
  (with-test-supervisor (sup)
    (let ((proc (sup:start-unit sup :rpc :command (echo-argv)))
          (thread (settle (sup:start-unit sup :subagent :function (lambda (u) (declare (ignore u)) 1)))))
      (ok (equal (format nil "stop rpc-1 (rpc, running): ~{~a~^ ~}" (sup:unit-command proc))
                 (unit-action-message "stop" proc)))
      (ok (equal (format nil "close input rpc-1 (rpc, running): ~{~a~^ ~}" (sup:unit-command proc))
                 (unit-action-message "close_input" proc)))
      (ok (equal (format nil "input rpc-1 (rpc, running): ~{~a~^ ~}~%input: a⏎b⏎" (sup:unit-command proc))
                 (unit-action-message "input" proc :input (format nil "a~%b~%"))))
      (ok (equal "restart subagent-1 (subagent, exited): <thread>"
                 (unit-action-message "restart" thread))))))

(deftest units-failure-notice
  (flet ((event (kind to &optional detail (type :state))
           (make-instance 'sup:unit-event :seq 1 :time (get-universal-time) :monotonic 0
                                          :unit-id (format nil "~(~a~)-2" kind) :unit-kind kind
                                          :type type :from :running :to to :detail detail)))
    (ok (equal "unit shell-job-2 (shell-job) failed with exit code 3; /ps to inspect"
               (unit-failure-notice (event :shell-job :failed '(:exit-code 3)))))
    (ok (equal "unit subagent-2 (subagent) failed; /ps to inspect"
               (unit-failure-notice (event :subagent :failed '()))))
    (ok (null (unit-failure-notice (event :shell-job :exited '(:exit-code 0)))))
    (ok (null (unit-failure-notice (event :shell-job :killed '(:signal :term)))))
    (ok (null (unit-failure-notice (event :rpc :failed '(:attempt 1) :restart-scheduled)))
        "only :state events")))

;;; Resources.

(deftest units-sample-resources
  (with-test-supervisor (sup)
    (let* ((gate (list nil))
           (sleeper (sup:start-unit sup :shell-job :command (echo-argv)))
           (busy (sup:start-unit sup :shell-job :command (busy-argv 8)))
           (thread (sup:start-unit sup :subagent :function (lambda (u) (declare (ignore u))
                                                             (loop until (car gate) do (sleep 0.02)))))
           (done (settle (sup:start-unit sup :shell-job :command (exit-argv 0)))))
      (unwind-protect
           (progn
             (sleep 1)
             (let* ((t0 (get-internal-real-time))
                    (a (sample-unit-resources (list sleeper busy thread done))))
               (sleep 2.5)
               (let* ((b (sample-unit-resources (list sleeper busy thread done)))
                      (dt (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
                      (s (gethash (sup:unit-id sleeper) b)))
                 (ok (hash-table-p a))
                 (ok (and s (integerp (getf s :rss)) (> (getf s :rss) (* 1024 1024)))
                     "a live process unit's RSS (an SBCL child is more than 1 MiB)")
                 (ok (and s (realp (getf s :cpu-time)) (>= (getf s :cpu-time) 0)))
                 (let ((pct (unit-cpu-percent (gethash (sup:unit-id busy) a)
                                              (gethash (sup:unit-id busy) b) dt)))
                   (ok (and pct (> pct 20)) (format nil "a busy child uses CPU (~a%)" pct)))
                 (ok (null (gethash (sup:unit-id thread) b)) "threads have none")
                 (ok (null (gethash (sup:unit-id done) b)) "finished units have none"))))
        (setf (car gate) t)))))
