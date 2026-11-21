(in-package #:cl-stack-code)

;;; H8d: observe and control running units (supervisor-protocol 0.3.0,
;;; agent-tools 0.3.0). This file holds the model shared by the TUI panel
;;; (src/unit-panel.lisp, src/program.lisp), the SDK (src/client.lisp) and
;;; --rpc (src/rpc.lisp): the supervisor of a session, the unit tree, the
;;; JSON objects, the resource sampler and the permission decision. The
;;; panel and --rpc read the same functions, so they cannot disagree.
;;;
;;; The supervisor
;;;   One supervisor per interactive program (MAKE-CODE-PROGRAM), per SDK /
;;;   --rpc session (CODE-SESSION) and per -p run, made with
;;;   MAKE-CODE-SUPERVISOR before the tools (given). Its state directory is
;;;   UNITS-DIRECTORY of the working directory: <data-dir>/units/<project
;;;   key>/, the same key as SESSIONS-DIRECTORY. Every supervisor of a
;;;   project shares it, so the H8a sweep reaps what a crashed cl-stack-code
;;;   left behind in that project (other live supervisors are kept), and
;;;   unit-tools sees earlier runs' logs as previous logs (read-only). The
;;;   supervisor outlives conversation changes (/clear, /clone, a conflict
;;;   fork): it belongs to the process side of the session, not to one
;;;   conversation id. The root scope is the session; MAKE-CODE-TOOLS adds a
;;;   :tool-source "shell" scope (agent-tools); a plan's area tools (H5a) get
;;;   their own "shell" scope under an :agent scope named "plan-<id8>".
;;;   Tools: MAKE-CODE-TOOLS :SUPERVISOR (src/tools.lisp): every bash command
;;;   is a :shell-job unit, and the unit tools (unit_list, unit_search,
;;;   unit_read, unit_tail, unit_control) are offered after the other
;;;   sources, in -p, the TUI and the SDK alike.
;;;   Close: CLOSE-CODE-PROGRAM, CLIENT-CLOSE-SESSION / CLOSE-CLIENT and the
;;;   end of a -p run close the unit tools (their index), the shell tools,
;;;   then SUP:SHUTDOWN-SUPERVISOR (every unit stopped, one wave; logs kept).
;;;   An unhandled SUP:STOP-TIMEOUT forces, SUP:STOP-FAILED abandons, as the
;;;   exit hook does.
;;;
;;; The unit tree (UNIT-TREE)
;;;   Rows in panel order: depth first from the root scope (not shown); in
;;;   each scope first its own units (start order, SUP:SCOPE-UNITS
;;;   :RECURSIVE NIL), then its child scopes (creation order), each child
;;;   scope as a (:scope S :depth D) row followed by its subtree at D + 1.
;;;   Units of the root are at depth 0. A scope with no unit in its subtree
;;;   gives no row. Evicted units are gone.
;;;
;;; Units as text (the panel) and as JSON (--rpc)
;;;   UNIT-STATUS-WORD = agent-tools' status word: "running", "starting",
;;;   "exited N" / "failed N" (process units), "exited" / "failed" (threads),
;;;   "killed". UNIT-LAST-LINE = the text of the last output record (either
;;;   stream) with ANSI escapes and control characters (except TAB → one
;;;   space) removed, NIL without output or without a log.
;;;   Uptime = now − SUP:UNIT-START-TIME while live; NIL once finished.
;;;   UNIT-OBJECT (keys, in this order):
;;;     "id" "kind" (lower case) "state" (lower case) "status" (the status
;;;     word) "owner" (SCOPE-PATH joined by "/", "-" for the root, as
;;;     unit_list) "owner_path" [names] "depth" (the UNIT-TREE depth)
;;;     "labels" {key (lower case): PRINC-TO-STRING of the value} "command"
;;;     [argv] | null (threads) "pid" | null "started" (RFC 3339 UTC,
;;;     seconds) | null "uptime_s" (integer) | null "exit_code" | null
;;;     "signal" ("term" "kill") | null "restarts" (SUP:UNIT-RESTART-COUNT)
;;;     "lines" (SUP:LOG-LAST-LINE) | null "last_line" | null "cpu_percent"
;;;     (number, one decimal) | null "cpu_time_s" (number) | null
;;;     "rss_bytes" (integer) | null.
;;;   UNIT-EVENT-OBJECT: {"type": "unit", "session_id", "subscription",
;;;   "seq", "time" (RFC 3339 UTC with milliseconds), "unit_id", "kind",
;;;   "event" ("state" "restart_scheduled" "evicted" "log_error"), "from",
;;;   "to" (lower-case state names or null), "detail" {snake_case keys of
;;;   EVENT-DETAIL: keyword values lower case, T/NIL as booleans, numbers and
;;;   strings as they are}}.
;;;   UNIT-RECORD-OBJECT: {"line", "time" (RFC 3339 ms), "stream" ("stdout"
;;;   "stderr"), "text" (SUP:LOG-RECORD-TEXT, unchanged), "continued"
;;;   (boolean)}. UNIT-GAP-OBJECT: {"first_line", "last_line", "records",
;;;   "bytes" (or null), "reasons" [lower-case names]}.
;;;
;;; Resources (CPU and RSS)
;;;   SAMPLE-UNIT-RESOURCES units → an EQUAL hash table: unit id → (:cpu-time
;;;   SECONDS :rss BYTES), summed over the unit's whole process tree, for
;;;   live process units only (threads, finished units and units whose
;;;   processes vanished are absent). One OS call per sample for all units:
;;;     macOS, Linux  `ps -A -o pid= -o pgid= -o rss= -o time=` (LC_ALL=C)
;;;                   through PP:RUN; the processes whose pgid is the unit's
;;;                   SUP:UNIT-PGID (the group the supervisor stops, so the
;;;                   tree it kills is the tree it measures); rss is KiB,
;;;                   time is [[DD-]HH:]MM:SS[.ff] (PARSE-PS-CPU-TIME).
;;;     Windows       `powershell.exe -NoProfile -NonInteractive -Command`
;;;                   Get-CimInstance Win32_Process → ProcessId,
;;;                   ParentProcessId, WorkingSetSize (bytes), KernelModeTime +
;;;                   UserModeTime (100 ns); the unit's pid and its
;;;                   descendants by ParentProcessId (as the H8a sweep does).
;;;   CPU% = UNIT-CPU-PERCENT of two samples: Δcpu-time / Δwall × 100 (one
;;;   core = 100, as top); NIL until a unit has two samples. The panel
;;;   samples every +UNIT-STATS-INTERVAL+ seconds while it is open (2 s on
;;;   Unix; 5 s on Windows, where one PowerShell start costs ~0.5-1 s); --rpc
;;;   samples when units/list asks for resources. Why: `ps -o pgid,rss,time`
;;;   is on every macOS and Linux (/proc is Linux-only, libproc is
;;;   macOS-only, both native), and CIM is the H8a inspector's source on
;;;   Windows; no native code, the same tree as stop and sweep.
;;;   Per-thread CPU has no portable source, so thread units show "-".
;;;
;;; Permission (UNIT-ACTION-PERMISSION) — one layer for the agent, the TUI
;;; and --rpc
;;;   A panel or RPC action is the unit_control call the agent would make:
;;;   UNIT-CONTROL-ARGUMENTS action unit → its JSON arguments ("stop",
;;;   "restart" as they are; "input" with "input"; "close_input" → action
;;;   "input", input "", eof true, so its resource is input:<id>).
;;;   UNIT-ACTION-PERMISSION agent unit-tools action unit &key input mode →
;;;   (values EFFECT RULE RESOURCES) = AI-AGENT-PROTOCOL:AGENT-PERMISSION of
;;;   AGENT on UNIT-TOOLS for "unit_control" with those arguments (the
;;;   agent's rules, its saved "always" rules, unit_control's default ask),
;;;   then MODE :bypass-permissions turns an :ask into :allow (as the
;;;   product approves every ask in that mode); a deny stays a deny. The
;;;   action itself is TOOLS:CALL-UNIT-TOOL "unit_control" with the same
;;;   arguments, so the text and the effects are the agent tool's.
;;;   UNIT-ACTION-MESSAGE action unit → the confirm dialog's message:
;;;   "<action> <id> (<kind>, <status word>): <command joined by spaces |
;;;   <thread>>" ("close input" for close_input), plus, for input, a second
;;;   line "input: <the text, LF shown as ⏎>".
;;;
;;; Notices
;;;   UNIT-FAILURE-NOTICE event → for a :state event whose TO is :failed:
;;;   "unit <id> (<kind>) failed with exit code N; /ps to inspect" (process),
;;;   "unit <id> (<kind>) failed; /ps to inspect" (thread, or no code);
;;;   anything else → NIL.

;;; Given: constants.

(defparameter +unit-panel-key+ '(:p (:ctrl))
  "(KEY MODIFIERS) that opens and closes the unit panel (Ctrl-P).")

(defparameter +unit-log-scrollback+ 2000
  "Output lines the panel's log view keeps (it loads the last ones, follows,
and drops the oldest beyond this).")

(defparameter +unit-tick-interval+ 1
  "Seconds between the panel's refreshes of uptime and last lines while open.")

(defparameter +unit-stats-interval+ (if (uiop:os-windows-p) 5 2)
  "Seconds between resource samples while the panel is open.")

(defparameter +unit-rpc-actions+ '("stop" "restart" "input" "close_input")
  "units/control's actions; the panel's keys s, r, i, e.")

(defparameter +unit-action-choices+
  '((:yes "Yes") (:no "No"))
  "The unit confirm dialog's choices (W:CONFIRM-DIALOG :choices). No
\"always\": a unit id is per supervisor, so a saved rule for one would match a
different unit in the next session; rules are written by hand
(unit_control(stop:shell-job-*)).")

(defparameter +unit-panel-columns+
  '("UNIT" "STATE" "KIND" "PID" "UP" "CPU%" "RSS" "LAST")
  "The panel's column header names (UNIT-ROW-TEXT :header).")

(defparameter +unit-list-help+
  "  ↑↓ select · Enter follow · s stop · r restart · i input · e close input · Esc close"
  "The help row of the panel's list view.")

(defparameter +unit-log-help+
  "  ↑↓ PgUp PgDn scroll · End follow · / search · n N next hit · s r i e · Esc back"
  "The help row of the panel's log view.")

;;; Given: where the supervisor lives, and making it.

(defun units-directory (cwd &key data-dir)
  "→ <DATA-DIR>/units/<PROJECT-SESSION-KEY of the project directory>/ for
working directory CWD, as SESSIONS-DIRECTORY. Creates nothing."
  (let* ((cwd (uiop:ensure-directory-pathname cwd))
         (project (or (find-project-root cwd) (probe-file cwd) cwd))
         (data (uiop:ensure-directory-pathname (or data-dir (user-data-directory)))))
    (uiop:merge-pathnames* (uiop:parse-unix-namestring
                            (format nil "units/~a/" (project-session-key project)))
                           data)))

(defun make-code-supervisor (cwd &key data-dir (getenv #'uiop:getenv) (exit-hook t))
  "→ a SUP:SUPERVISOR for a session in working directory CWD: state directory
UNITS-DIRECTORY (created; the H8a sweep runs first), rotated logs on (H8b
defaults), the exit hook registered unless EXIT-HOOK is NIL. DATA-DIR
defaults to USER-DATA-DIRECTORY with GETENV."
  (let ((dir (units-directory cwd :data-dir (or data-dir (user-data-directory :getenv getenv)))))
    (ensure-directories-exist dir)
    (sup:make-supervisor :state-directory dir :exit-hook exit-hook)))

;;; The supervisor's lifecycle (shared by the program, the SDK and -p).

(defun %abandon-on-stop-failed (condition)
  "SUP:STOP-FAILED during a shutdown: take SUP:ABANDON (of CONDITION), as the
exit hook does."
  (let ((restart (find-restart 'sup:abandon condition)))
    (when restart
      (invoke-restart restart))))

(defun %close-code-units (supervisor &key unit-tools shell-tools)
  "Close UNIT-TOOLS (a list of UNIT-TOOLS sources), then SHELL-TOOLS (a list of
SHELL-TOOLS sources), then SUP:SHUTDOWN-SUPERVISOR SUPERVISOR (one stop wave;
logs kept). NILs are skipped; every step is idempotent. An unhandled
SUP:STOP-TIMEOUT forces; SUP:STOP-FAILED abandons."
  (dolist (tools unit-tools)
    (when tools (tools:close-unit-tools tools)))
  (dolist (tools shell-tools)
    (when tools (tools:close-shell-tools tools)))
  (when (and supervisor (not (sup:supervisor-closed-p supervisor)))
    (handler-bind ((sup:stop-failed #'%abandon-on-stop-failed))
      (sup:shutdown-supervisor supervisor)))
  nil)

(defun %plan-unit-scope (supervisor plan)
  "The :agent scope \"plan-<id8>\" of PLAN under SUPERVISOR's root (an open one
with that name is reused)."
  (let* ((id (plan-id plan))
         (name (format nil "plan-~a" (subseq id 0 (min 8 (length id)))))
         (root (sup:supervisor-root-scope supervisor)))
    (or (find-if (lambda (scope)
                   (and (equal name (sup:scope-name scope)) (not (sup:scope-closed-p scope))))
                 (sup:scope-children root))
        (sup:make-scope supervisor :agent name :parent root))))

;;; Text helpers.

(defun %text (control &rest args)
  "FORMAT NIL of CONTROL and ARGS into a CHARACTER string (FORMAT NIL with an
ASCII control string may make a BASE-STRING, which a non-ASCII argument does
not fit)."
  (with-output-to-string (out)
    (apply #'format out control args)))

(defun %clean-text (text &key (tab :space))
  "TEXT without ANSI escapes and control characters. TAB :SPACE → one space;
:EXPAND → spaces to the next multiple of 8 columns of the cleaned text."
  (let ((stripped (ss:strip-ansi text)))
    (with-output-to-string (out)
      (let ((column 0))
        (loop for c across stripped
              for code = (char-code c)
              do (cond ((char= c #\Tab)
                        (if (eq tab :expand)
                            (let ((n (- 8 (mod column 8))))
                              (dotimes (i n) (write-char #\Space out))
                              (incf column n))
                            (progn (write-char #\Space out) (incf column))))
                       ((or (< code 32) (= code 127) (<= 128 code 159)) nil)
                       (t (write-char c out) (incf column))))))))

(defun %lower (x)
  (string-downcase (string x)))

(defun %one-line (text)
  "TEXT on one line: line breaks become spaces, trailing blanks trimmed."
  (string-right-trim '(#\Space)
                     (substitute #\Space #\Newline (remove #\Return text))))

(defun %unit-log-or-nil (unit)
  "UNIT's SUP:UNIT-LOG, or NIL when it has no log file."
  (handler-case (sup:unit-log unit)
    (sup:log-not-found () nil)))

;;; The model.

(defun unit-status-word (unit)
  "→ UNIT's status word (see the header)."
  (let ((code (sup:unit-exit-code unit)))
    (ecase (sup:unit-state unit)
      (:running "running")
      (:starting "starting")
      (:killed "killed")
      (:exited (if code (format nil "exited ~d" code) "exited"))
      (:failed (if code (format nil "failed ~d" code) "failed")))))

(defun unit-tree (supervisor &key scope)
  "→ the rows of SUPERVISOR's units below SCOPE (default the root), in panel
order: (:unit UNIT :depth D) and (:scope SCOPE :depth D) plists (see the
header)."
  (let ((by-owner (make-hash-table :test 'eq)))
    ;; One copy of the registry (start order); no user code under its lock.
    (dolist (u (sup:supervisor-units supervisor))
      (push u (gethash (sup:unit-owner u) by-owner)))
    (labels ((walk (s depth)
               (append (mapcar (lambda (u) (list :unit u :depth depth))
                               (reverse (gethash s by-owner)))
                       (loop for child in (sup:scope-children s)
                             for below = (walk child (1+ depth))
                             when below
                               append (cons (list :scope child :depth depth) below)))))
      (walk (or scope (sup:supervisor-root-scope supervisor)) 0))))

(defun unit-last-line (unit)
  "→ the cleaned text of UNIT's last output record, or NIL (see the header)."
  (let ((log (%unit-log-or-nil unit)))
    (when log
      (let ((record (car (last (handler-case (sup:log-tail log 1)
                                 (sup:log-not-found () nil))))))
        (and record (%clean-text (sup:log-record-text record) :tab :space))))))

(defun format-unit-uptime (seconds)
  "→ SECONDS (a non-negative real, or NIL) as \"-\" (NIL), \"<s>s\" under a
minute, \"<m>m<ss>s\" under an hour, \"<h>h<mm>m\" under a day, else
\"<d>d<hh>h\" (fractions truncated): 0 → \"0s\", 59 → \"59s\", 64 → \"1m04s\",
3720 → \"1h02m\", 183600 → \"2d03h\"."
  (if (null seconds)
      "-"
      (let ((s (max 0 (floor seconds))))
        (cond ((< s 60) (format nil "~ds" s))
              ((< s 3600) (multiple-value-bind (m r) (floor s 60)
                            (format nil "~dm~2,'0ds" m r)))
              ((< s 86400) (multiple-value-bind (h r) (floor s 3600)
                             (format nil "~dh~2,'0dm" h (floor r 60))))
              (t (multiple-value-bind (d r) (floor s 86400)
                   (format nil "~dd~2,'0dh" d (floor r 3600))))))))

(defun %tenths (x)
  "X (a real) in tenths, rounded half up (exact arithmetic)."
  (floor (+ (* 10 (rational x)) 1/2)))

(defun %decimal (tenths)
  (multiple-value-bind (whole fraction) (floor tenths 10)
    (format nil "~d.~d" whole fraction)))

(defun format-unit-rss (bytes)
  "→ BYTES (an integer, or NIL) as \"-\", \"<n>K\" (KiB rounded, under 1 MiB),
\"<x.y>M\" (under 1 GiB) or \"<x.y>G\", 1024-based, one decimal rounded half
up: 524288 → \"512K\", 12897485 → \"12.3M\", 1288490189 → \"1.2G\"."
  (cond ((null bytes) "-")
        ((< bytes 1048576)
         (let ((k (floor (+ bytes 512) 1024)))
           (if (< k 1024) (format nil "~dK" k) "1.0M")))
        ((< bytes 1073741824) (format nil "~aM" (%decimal (%tenths (/ bytes 1048576)))))
        (t (format nil "~aG" (%decimal (%tenths (/ bytes 1073741824)))))))

(defun format-unit-cpu (percent)
  "→ PERCENT (a non-negative real, or NIL) as \"-\" or one decimal (\"0.0\",
\"12.5\", \"250.0\")."
  (if (null percent)
      "-"
      (%decimal (%tenths (max 0 percent)))))

(defun %all-digits-p (string)
  (and (plusp (length string)) (every #'digit-char-p string)))

(defun parse-ps-cpu-time (string)
  "→ seconds (a real) of a ps `time` field: \"MM:SS\", \"HH:MM:SS\",
\"DD-HH:MM:SS\", each optionally with \".ff\" fractions (macOS prints
\"0:00.03\"); leading blanks ignored. Anything else → NIL."
  (when (stringp string)
    (let* ((s (string-trim '(#\Space #\Tab #\Return #\Newline) string))
           (dash (position #\- s))
           (days 0))
      (when dash
        (let ((d (subseq s 0 dash)))
          (unless (%all-digits-p d)
            (return-from parse-ps-cpu-time nil))
          (setf days (parse-integer d)
                s (subseq s (1+ dash)))))
      (let ((parts (uiop:split-string s :separator ":")))
        (when (<= 2 (length parts) 3)
          (let* ((last (car (last parts)))
                 (dot (position #\. last))
                 (whole (if dot (subseq last 0 dot) last))
                 (fraction (and dot (subseq last (1+ dot)))))
            (when (and (every #'%all-digits-p (butlast parts))
                       (%all-digits-p whole)
                       (or (null fraction) (%all-digits-p fraction)))
              (+ (* 86400 days)
                 (* 60 (reduce (lambda (acc part) (+ (* 60 acc) (parse-integer part)))
                               (butlast parts) :initial-value 0))
                 (parse-integer whole)
                 (if fraction
                     (/ (parse-integer fraction) (expt 10 (length fraction)))
                     0)))))))))

;;; Resources.

(defun %words (line)
  (remove "" (uiop:split-string line :separator '(#\Space #\Tab #\Return)) :test #'string=))

(defun %os-output (argv &rest keys)
  "ARGV's standard output (PP:RUN), exit status ignored."
  (or (nth-value 1 (apply #'pp:run argv :output :string :error-output nil keys)) ""))

(defun %sample-ps (units table)
  "Unix: one ps call; sums per process group (SUP:UNIT-PGID)."
  (let ((sums (make-hash-table)))       ; pgid → (cpu-seconds . rss-bytes)
    (dolist (line (uiop:split-string (%os-output '("ps" "-A" "-o" "pid=" "-o" "pgid=" "-o" "rss=" "-o" "time=")
                                                 :env '(("LC_ALL" . "C")))
                                     :separator '(#\Newline)))
      (destructuring-bind (&optional pid pgid rss time &rest more) (%words line)
        (declare (ignore pid more))
        (let ((group (and pgid (%all-digits-p pgid) (parse-integer pgid)))
              (kib (and rss (%all-digits-p rss) (parse-integer rss)))
              (cpu (and time (parse-ps-cpu-time time))))
          (when (and group kib cpu)
            (let ((cell (or (gethash group sums) (setf (gethash group sums) (cons 0 0)))))
              (incf (car cell) cpu)
              (incf (cdr cell) (* 1024 kib)))))))
    (dolist (u units)
      (let ((cell (and (sup:unit-pgid u) (gethash (sup:unit-pgid u) sums))))
        (when cell
          (setf (gethash (sup:unit-id u) table)
                (list :cpu-time (float (car cell) 1d0) :rss (cdr cell))))))))

(defparameter +unit-cim-command+
  "Get-CimInstance Win32_Process | ForEach-Object { '{0} {1} {2} {3}' -f $_.ProcessId, $_.ParentProcessId, $_.WorkingSetSize, ($_.KernelModeTime + $_.UserModeTime) }"
  "PowerShell: one line per process: pid ppid working-set-bytes cpu-100ns.")

(defun %sample-cim (units table)
  "Windows: one CIM call; each unit's pid and its descendants."
  (let ((procs (make-hash-table))       ; pid → (ws . t100)
        (children (make-hash-table)))   ; ppid → pids
    (dolist (line (uiop:split-string (%os-output (list "powershell.exe" "-NoProfile" "-NonInteractive"
                                                       "-Command" +unit-cim-command+))
                                     :separator '(#\Newline)))
      (destructuring-bind (&optional pid ppid ws t100 &rest more) (%words line)
        (declare (ignore more))
        (when (and pid ppid ws t100 (every #'%all-digits-p (list pid ppid ws t100)))
          (let ((pid (parse-integer pid)) (ppid (parse-integer ppid)))
            (setf (gethash pid procs) (cons (parse-integer ws) (parse-integer t100)))
            (unless (= pid ppid)
              (push pid (gethash ppid children)))))))
    (dolist (u units)
      (let ((root (sup:unit-pid u)))
        (when (and root (gethash root procs))
          (let ((seen (make-hash-table)) (queue (list root)) (ws 0) (t100 0))
            (loop while queue
                  do (let ((pid (pop queue)))
                       (unless (gethash pid seen)
                         (setf (gethash pid seen) t)
                         (let ((p (gethash pid procs)))
                           (when p
                             (incf ws (car p))
                             (incf t100 (cdr p))))
                         (setf queue (append queue (gethash pid children))))))
            (setf (gethash (sup:unit-id u) table)
                  (list :cpu-time (float (/ t100 10000000) 1d0) :rss ws))))))))

(defun sample-unit-resources (units)
  "→ an EQUAL hash table: unit id → (:cpu-time SECONDS :rss BYTES) for the
live process units of UNITS (see the header). Never signals: a failed OS
call gives an empty table."
  (let ((table (make-hash-table :test 'equal))
        (live (remove-if-not (lambda (u) (and (sup:unit-pid u) (sup:unit-live-p u))) units)))
    (when live
      ;; The one OS call may fail in any way (no ps, a killed powershell):
      ;; the contract is an empty sample, never a condition.
      (handler-case (if (uiop:os-windows-p)
                        (%sample-cim live table)
                        (%sample-ps live table))
        (error () (clrhash table))))
    table))

(defun unit-cpu-percent (previous current seconds)
  "→ CPU percent between two samples of one unit (plists as
SAMPLE-UNIT-RESOURCES gives), SECONDS of wall time apart: Δcpu-time /
SECONDS × 100, never negative; NIL when either sample is NIL or SECONDS is
not positive."
  (when (and previous current (realp seconds) (plusp seconds))
    (float (max 0 (/ (* 100 (- (getf current :cpu-time) (getf previous :cpu-time)))
                     seconds))
           1d0)))

(defun %cpu-table (previous current seconds)
  "→ an EQUAL table id → UNIT-CPU-PERCENT for the ids in both samples."
  (let ((table (make-hash-table :test 'equal)))
    (when (and previous current)
      (maphash (lambda (id now)
                 (let ((pct (unit-cpu-percent (gethash id previous) now seconds)))
                   (when pct (setf (gethash id table) pct))))
               current))
    table))

;;; JSON.

(defconstant +unix-epoch-universal-time+ 2208988800
  "The universal time of 1970-01-01T00:00:00Z.")

(defun %rfc3339 (universal-time &optional ms)
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d~@[.~3,'0d~]Z" y mo d h mi s ms)))

(defun %rfc3339-ms (unix-ms)
  (multiple-value-bind (secs ms) (floor unix-ms 1000)
    (%rfc3339 (+ secs +unix-epoch-universal-time+) ms)))

(defun %json-null (value)
  (if (null value) :null value))

(defun %owner-text (unit)
  (let ((path (sup:scope-path (sup:unit-owner unit))))
    (if path (format nil "~{~a~^/~}" path) "-")))

(defun %unit-depth (unit)
  "UNIT's UNIT-TREE depth below the root."
  (length (sup:scope-path (sup:unit-owner unit))))

(defun unit-object (unit &key stats cpu-percent (depth 0) (now (get-universal-time)))
  "→ UNIT's object (see the header). STATS: its SAMPLE-UNIT-RESOURCES plist or
NIL; CPU-PERCENT: a number or NIL; DEPTH: its UNIT-TREE depth; NOW: the
universal time uptime is measured to."
  (let* ((log (%unit-log-or-nil unit))
         (start (sup:unit-start-time unit))
         (label-object (let ((object (%json-object)))
                   (loop for (k v) on (sup:unit-labels unit) by #'cddr
                         do (setf (gethash (%lower k) object) (princ-to-string v)))
                   object))
         (lines (and log (handler-case (sup:log-last-line log)
                           (sup:log-not-found () nil)))))
    (%json-object
     "id" (sup:unit-id unit)
     "kind" (%lower (sup:unit-kind unit))
     "state" (%lower (sup:unit-state unit))
     "status" (unit-status-word unit)
     "owner" (%owner-text unit)
     "owner_path" (coerce (sup:scope-path (sup:unit-owner unit)) 'vector)
     "depth" depth
     "labels" label-object
     "command" (let ((argv (sup:unit-command unit)))
                 (if argv (coerce argv 'vector) :null))
     "pid" (%json-null (sup:unit-pid unit))
     "started" (if start (%rfc3339 start) :null)
     "uptime_s" (if (and start (sup:unit-live-p unit))
                    (max 0 (floor (- now start)))
                    :null)
     "exit_code" (%json-null (sup:unit-exit-code unit))
     "signal" (let ((signal (sup:unit-signal unit)))
                (if signal (%lower signal) :null))
     "restarts" (sup:unit-restart-count unit)
     "lines" (%json-null lines)
     "last_line" (%json-null (unit-last-line unit))
     "cpu_percent" (if cpu-percent (/ (round (* 10 cpu-percent)) 10.0) :null)
     "cpu_time_s" (%json-null (getf stats :cpu-time))
     "rss_bytes" (%json-null (getf stats :rss)))))

(defun %glob-match-p (pattern string)
  "T when PATTERN (* = any run of characters) matches all of STRING."
  (labels ((match (p s)
             (cond ((= p (length pattern)) (= s (length string)))
                   ((char= #\* (char pattern p))
                    (loop for i from s to (length string)
                            thereis (match (1+ p) i)))
                   ((and (< s (length string)) (char= (char pattern p) (char string s)))
                    (match (1+ p) (1+ s)))
                   (t nil))))
    (match 0 0)))

(defun %state-filter (state)
  "→ a predicate on units for STATE (see UNIT-OBJECTS), or NIL for none; an
unknown STATE → CODE-USAGE-ERROR."
  (when state
    (let ((name (and (or (stringp state) (symbolp state)) (string-downcase (string state)))))
      (cond ((equal name "live") #'sup:unit-live-p)
            ((equal name "finished") #'sup:unit-finished-p)
            ((and name (find name sup:+unit-states+ :key #'%lower :test #'string=))
             (let ((keyword (find name sup:+unit-states+ :key #'%lower :test #'string=)))
               (lambda (u) (eq keyword (sup:unit-state u)))))
            (t (%usage-fail "state must be live, finished or one of ~{~a~^, ~}: not ~a"
                            (mapcar #'%lower sup:+unit-states+) state))))))

(defun unit-objects (supervisor &key kind state owner stats cpu (now (get-universal-time)))
  "→ UNIT-OBJECTs of SUPERVISOR's units in UNIT-TREE order. KIND: a keyword
or a kind name; STATE: :live, :finished, a state keyword or the same names
as strings; OWNER: a glob (* any run) over the \"owner\" field. STATS: a
SAMPLE-UNIT-RESOURCES table or NIL; CPU: an EQUAL table id → percent, or
NIL."
  (let ((state-p (%state-filter state))
        (kind-name (and kind (%lower kind))))
    (when (and owner (not (stringp owner)))
      (%usage-fail "owner must be a string (a glob): not ~s" owner))
    (loop for row in (unit-tree supervisor)
          for u = (getf row :unit)
          when (and u
                    (or (null kind-name) (string= kind-name (%lower (sup:unit-kind u))))
                    (or (null state-p) (funcall state-p u))
                    (or (null owner) (%glob-match-p owner (%owner-text u))))
            collect (unit-object u :stats (and stats (gethash (sup:unit-id u) stats))
                                   :cpu-percent (and cpu (gethash (sup:unit-id u) cpu))
                                   :depth (getf row :depth)
                                   :now now))))

(defun %detail-value (value)
  (cond ((member value '(t nil)) value)
        ((keywordp value) (%lower value))
        ((or (numberp value) (stringp value)) value)
        (t (princ-to-string value))))

(defun unit-event-object (event &key subscription session-id)
  "→ the \"unit\" event object of SUP:UNIT-EVENT EVENT (see the header);
SUBSCRIPTION and SESSION-ID are strings or NIL (null)."
  (let ((detail (%json-object)))
    (loop for (k v) on (sup:event-detail event) by #'cddr
          do (setf (gethash (substitute #\_ #\- (%lower k)) detail) (%detail-value v)))
    (%json-object
     "type" "unit"
     "session_id" (%json-null session-id)
     "subscription" (%json-null subscription)
     "seq" (sup:event-seq event)
     "time" (%rfc3339 (sup:event-time event) 0)
     "unit_id" (sup:event-unit-id event)
     "kind" (%lower (sup:event-unit-kind event))
     "event" (substitute #\_ #\- (%lower (sup:event-type event)))
     "from" (let ((from (sup:event-from event))) (if from (%lower from) :null))
     "to" (let ((to (sup:event-to event))) (if to (%lower to) :null))
     "detail" detail)))

(defun unit-record-object (record)
  "→ the object of SUP:LOG-RECORD RECORD (see the header)."
  (%json-object "line" (sup:log-record-line record)
                "time" (let ((ms (sup:log-record-wall-time record)))
                         (if ms (%rfc3339-ms ms) :null))
                "stream" (let ((stream (sup:log-record-stream record)))
                           (if stream (%lower stream) :null))
                "text" (sup:log-record-text record)
                "continued" (and (sup:log-record-continued-p record) t)))

(defun unit-gap-object (gap)
  "→ the object of SUP:LOG-GAP GAP (see the header)."
  (%json-object "first_line" (sup:log-gap-first-line gap)
                "last_line" (sup:log-gap-last-line gap)
                "records" (sup:log-gap-records gap)
                "bytes" (%json-null (sup:log-gap-bytes gap))
                "reasons" (map 'vector #'%lower (sup:log-gap-reasons gap))))

;;; Control.

(defun unit-control-arguments (action unit-id &key input)
  "→ the unit_control arguments (a JSON object string) of ACTION (one of
+UNIT-RPC-ACTIONS+) on UNIT-ID: {\"unit\",\"action\"} for stop and restart,
{\"unit\",\"action\":\"input\",\"input\"} for input (INPUT required),
{\"unit\",\"action\":\"input\",\"input\":\"\",\"eof\":true} for close_input.
Another action → CODE-USAGE-ERROR naming the actions."
  (flet ((encode (&rest keys-and-values)
           (json:encode (apply #'%json-object keys-and-values))))
    (cond ((member action '("stop" "restart") :test #'equal)
           (encode "unit" unit-id "action" action))
          ((equal action "input")
           (unless (stringp input)
             (%usage-fail "unit action input needs the text to send (a string)"))
           (encode "unit" unit-id "action" "input" "input" input))
          ((equal action "close_input")
           (encode "unit" unit-id "action" "input" "input" "" "eof" t))
          (t (%usage-fail "unknown unit action ~s: use one of ~{~a~^, ~}" action +unit-rpc-actions+)))))

(defun unit-action-permission (agent unit-tools action unit-id &key input mode)
  "→ (values EFFECT RULE RESOURCES): the decision the agent's unit_control
call with UNIT-CONTROL-ARGUMENTS would get (AI-AGENT-PROTOCOL:AGENT-PERMISSION
of AGENT on UNIT-TOOLS), an :ask turned into :allow under MODE
:bypass-permissions (see the header)."
  (multiple-value-bind (effect rule resources)
      (agent:agent-permission agent unit-tools "unit_control"
                              (unit-control-arguments action unit-id :input input))
    (values (if (and (eq effect :ask) (eq mode :bypass-permissions)) :allow effect)
            rule
            resources)))

(defun unit-action-message (action unit &key input)
  "→ the confirm dialog's message for ACTION on UNIT (see the header)."
  (let ((argv (sup:unit-command unit)))
    (%text "~a ~a (~a, ~a): ~a~@[~%input: ~a~]"
            (if (equal action "close_input") "close input" action)
            (sup:unit-id unit)
            (%lower (sup:unit-kind unit))
            (unit-status-word unit)
            (if argv (format nil "~{~a~^ ~}" argv) "<thread>")
            (and (equal action "input") (stringp input)
                 (map '(vector character) (lambda (c) (if (char= c #\Newline) (code-char #x23CE) c)) input)))))

(defun unit-failure-notice (event)
  "→ the transcript notice for SUP:UNIT-EVENT EVENT, or NIL (see the header)."
  (when (and (eq :state (sup:event-type event)) (eq :failed (sup:event-to event)))
    (let ((code (getf (sup:event-detail event) :exit-code)))
      (%text "unit ~a (~a) failed~@[ with exit code ~d~]; /ps to inspect"
              (sup:event-unit-id event) (%lower (sup:event-unit-kind event)) code))))

(defun %unit-rule-text (rule)
  "FORMAT-PERMISSION-RULE of RULE as a string, or NIL."
  (and rule
       (let ((form (format-permission-rule rule)))
         (if (stringp form) form (json:encode form)))))

(defun %sources-lisp-tools (sources)
  "The LISP-TOOLS of MAKE-CODE-TOOLS' SOURCES (third when the image is on), or
NIL: with a supervisor and no image, the third source is the unit tools."
  (let ((third (third sources)))
    (and (lt:lisp-tools-p third) third)))
