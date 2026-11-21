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

;;; Stubs: the model.

(defun unit-status-word (unit)
  "→ UNIT's status word (see the header)."
  (declare (ignore unit))
  (%h8d-pending "unit-status-word"))

(defun unit-tree (supervisor &key scope)
  "→ the rows of SUPERVISOR's units below SCOPE (default the root), in panel
order: (:unit UNIT :depth D) and (:scope SCOPE :depth D) plists (see the
header)."
  (declare (ignore supervisor scope))
  (%h8d-pending "unit-tree"))

(defun unit-last-line (unit)
  "→ the cleaned text of UNIT's last output record, or NIL (see the header)."
  (declare (ignore unit))
  (%h8d-pending "unit-last-line"))

(defun format-unit-uptime (seconds)
  "→ SECONDS (a non-negative real, or NIL) as \"-\" (NIL), \"<s>s\" under a
minute, \"<m>m<ss>s\" under an hour, \"<h>h<mm>m\" under a day, else
\"<d>d<hh>h\" (fractions truncated): 0 → \"0s\", 59 → \"59s\", 64 → \"1m04s\",
3720 → \"1h02m\", 183600 → \"2d03h\"."
  (declare (ignore seconds))
  (%h8d-pending "format-unit-uptime"))

(defun format-unit-rss (bytes)
  "→ BYTES (an integer, or NIL) as \"-\", \"<n>K\" (KiB rounded, under 1 MiB),
\"<x.y>M\" (under 1 GiB) or \"<x.y>G\", 1024-based, one decimal rounded half
up: 524288 → \"512K\", 12897485 → \"12.3M\", 1288490189 → \"1.2G\"."
  (declare (ignore bytes))
  (%h8d-pending "format-unit-rss"))

(defun format-unit-cpu (percent)
  "→ PERCENT (a non-negative real, or NIL) as \"-\" or one decimal (\"0.0\",
\"12.5\", \"250.0\")."
  (declare (ignore percent))
  (%h8d-pending "format-unit-cpu"))

(defun parse-ps-cpu-time (string)
  "→ seconds (a real) of a ps `time` field: \"MM:SS\", \"HH:MM:SS\",
\"DD-HH:MM:SS\", each optionally with \".ff\" fractions (macOS prints
\"0:00.03\"); leading blanks ignored. Anything else → NIL."
  (declare (ignore string))
  (%h8d-pending "parse-ps-cpu-time"))

(defun sample-unit-resources (units)
  "→ an EQUAL hash table: unit id → (:cpu-time SECONDS :rss BYTES) for the
live process units of UNITS (see the header). Never signals: a failed OS
call gives an empty table."
  (declare (ignore units))
  (%h8d-pending "sample-unit-resources"))

(defun unit-cpu-percent (previous current seconds)
  "→ CPU percent between two samples of one unit (plists as
SAMPLE-UNIT-RESOURCES gives), SECONDS of wall time apart: Δcpu-time /
SECONDS × 100, never negative; NIL when either sample is NIL or SECONDS is
not positive."
  (declare (ignore previous current seconds))
  (%h8d-pending "unit-cpu-percent"))

;;; Stubs: JSON.

(defun unit-object (unit &key stats cpu-percent (depth 0) (now (get-universal-time)))
  "→ UNIT's object (see the header). STATS: its SAMPLE-UNIT-RESOURCES plist or
NIL; CPU-PERCENT: a number or NIL; DEPTH: its UNIT-TREE depth; NOW: the
universal time uptime is measured to."
  (declare (ignore unit stats cpu-percent depth now))
  (%h8d-pending "unit-object"))

(defun unit-objects (supervisor &key kind state owner stats cpu (now (get-universal-time)))
  "→ UNIT-OBJECTs of SUPERVISOR's units in UNIT-TREE order. KIND: a keyword
or a kind name; STATE: :live, :finished, a state keyword or the same names
as strings; OWNER: a glob (* any run) over the \"owner\" field. STATS: a
SAMPLE-UNIT-RESOURCES table or NIL; CPU: an EQUAL table id → percent, or
NIL."
  (declare (ignore supervisor kind state owner stats cpu now))
  (%h8d-pending "unit-objects"))

(defun unit-event-object (event &key subscription session-id)
  "→ the \"unit\" event object of SUP:UNIT-EVENT EVENT (see the header);
SUBSCRIPTION and SESSION-ID are strings or NIL (null)."
  (declare (ignore event subscription session-id))
  (%h8d-pending "unit-event-object"))

(defun unit-record-object (record)
  "→ the object of SUP:LOG-RECORD RECORD (see the header)."
  (declare (ignore record))
  (%h8d-pending "unit-record-object"))

(defun unit-gap-object (gap)
  "→ the object of SUP:LOG-GAP GAP (see the header)."
  (declare (ignore gap))
  (%h8d-pending "unit-gap-object"))

;;; Stubs: control.

(defun unit-control-arguments (action unit-id &key input)
  "→ the unit_control arguments (a JSON object string) of ACTION (one of
+UNIT-RPC-ACTIONS+) on UNIT-ID: {\"unit\",\"action\"} for stop and restart,
{\"unit\",\"action\":\"input\",\"input\"} for input (INPUT required),
{\"unit\",\"action\":\"input\",\"input\":\"\",\"eof\":true} for close_input.
Another action → CODE-USAGE-ERROR naming the actions."
  (declare (ignore action unit-id input))
  (%h8d-pending "unit-control-arguments"))

(defun unit-action-permission (agent unit-tools action unit-id &key input mode)
  "→ (values EFFECT RULE RESOURCES): the decision the agent's unit_control
call with UNIT-CONTROL-ARGUMENTS would get (AI-AGENT-PROTOCOL:AGENT-PERMISSION
of AGENT on UNIT-TOOLS), an :ask turned into :allow under MODE
:bypass-permissions (see the header)."
  (declare (ignore agent unit-tools action unit-id input mode))
  (%h8d-pending "unit-action-permission"))

(defun unit-action-message (action unit &key input)
  "→ the confirm dialog's message for ACTION on UNIT (see the header)."
  (declare (ignore action unit input))
  (%h8d-pending "unit-action-message"))

(defun unit-failure-notice (event)
  "→ the transcript notice for SUP:UNIT-EVENT EVENT, or NIL (see the header)."
  (declare (ignore event))
  (%h8d-pending "unit-failure-notice"))
