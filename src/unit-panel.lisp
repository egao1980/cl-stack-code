(in-package #:cl-stack-code)

;;; H8d: the unit panel of the interactive mode. Pure views here (tested
;;; without a terminal); the program (src/program.lisp, "H8d") keeps a
;;; UNIT-PANEL, feeds it supervisor events, keys and timer ticks, and draws
;;; these lines.
;;;
;;; Opening
;;;   /ps (idle or busy; the core's (:units-panel) effect) or Ctrl-P
;;;   (+UNIT-PANEL-KEY+, anywhere but in a dialog) opens it; Ctrl-P, Esc in
;;;   the list view, or q close it. While open the panel has the keys; the
;;;   input keeps its text but is not shown.
;;;
;;; Layout on W × H while open, from the bottom:
;;;   row H − 1    the status line (unchanged)
;;;   above it     a dialog (approvals first, then the unit confirm dialog),
;;;                else the panel's prompt (W:TEXT-INPUT: prompt "search> "
;;;                in the log view after /, "input> " after i), else one help
;;;                row: the last action's result or error text until the next
;;;                key, else +UNIT-LIST-HELP+ / +UNIT-LOG-HELP+, cut to W
;;;   above it     one row of "─" × W
;;;   the rest     the panel (R rows): its title row, then the view. The
;;;                queued, steering, spinner and image banner rows are not
;;;                shown while it is open.
;;;
;;; List view (UNIT-PANEL-LINES)
;;;   Row 0: "Units · <N> running · <M> total" (N = live units, M = rows of
;;;   units). Row 1: UNIT-ROW-TEXT :header. Then one row per UNIT-TREE row,
;;;   scrolled so the selected unit is visible. No unit: row 1 is "  no units
;;;   yet: shell jobs, servers and subagents show up here" and no header.
;;;   Unit row: (format nil "~a~20a ~9a ~9a ~6@a ~6@a ~5@a ~6@a  ~a" mark name
;;;   status kind pid up cpu rss last), trailing blanks trimmed, cut to W:
;;;     mark   "> " for the selected unit, else "  "
;;;     name   2 × depth spaces + the id; longer than 20 → its first 19
;;;            characters + "…" (status and kind likewise at 9)
;;;     status UNIT-STATUS-WORD
;;;     kind   lower case
;;;     pid    the pid, "-" for threads
;;;     up     FORMAT-UNIT-UPTIME (live), "-" (finished)
;;;     cpu    FORMAT-UNIT-CPU of the panel's last UNIT-CPU-PERCENT, "-"
;;;     rss    FORMAT-UNIT-RSS of the last sample, "-"
;;;     last   UNIT-LAST-LINE or ""
;;;   The selected row's runs are inverse. A scope row: 2 × depth spaces +
;;;   "  " + the scope name + "/" (no other column). Header row: the same
;;;   format with mark "  " and +UNIT-PANEL-COLUMNS+, faint.
;;;   Selection: the first unit row when the panel opens and nothing is
;;;   selected (or the selected unit was evicted).
;;;   Keys: Up / Down move over unit rows (scope rows are skipped; the
;;;   selection stays on its unit id when rows move), Home / End, Enter →
;;;   the log view of the selected unit, s / r / i / e → stop / restart /
;;;   input / close_input on it, Esc / q / Ctrl-P → close.
;;;
;;; Log view (UNIT-LOG-LINES, UNIT-LOG-TITLE)
;;;   Opening loads the last +UNIT-LOG-SCROLLBACK+ output lines (SUP:LOG-READ
;;;   from LOG-LAST-LINE − scrollback, both streams, gaps included), then
;;;   follows: a background thread takes SUP:LOG-FOLLOW (:wait 0.25) from the
;;;   next line and sends the records to the UI; past the scrollback the
;;;   oldest lines are dropped. Row 0: UNIT-LOG-TITLE. Then the lines,
;;;   showing the tail while following.
;;;   Line: (format nil "~a~5d  ~a" mark line text): mark ">" on search hit
;;;   lines, else " "; text = the record's text cleaned as UNIT-LAST-LINE but
;;;   TAB expanded to the next multiple of 8 columns of the text, cut to W.
;;;   stderr text is red (foreground 1). Occurrences of the query's terms
;;;   (SS:QUERY-TERMS: terms and phrases, case-insensitive, longest first,
;;;   non-overlapping) in the text of every shown line are inverse. A gap:
;;;   "[gap: lines A-B not in the log (R1, R2)]" (reasons lower case), as
;;;   unit_read shows it. A unit without a log: its SUP:UNIT-OUTPUT, cleaned,
;;;   one line per line, numbered from 1, title suffix " · no log file".
;;;   Keys: Up / Down / PgUp / PgDn / Home scroll (following stops); End →
;;;   the tail, following again; "/" → the search prompt; Enter there runs
;;;   SS:SEARCH-LOGS on the unit tools' index with :units (id) :k 50 (one
;;;   refresh first); the view jumps to hit 1; n / N → the next / previous
;;;   hit (wrapping); a hit outside the loaded lines reloads the window
;;;   around it (SUP:LOG-READ from line − 10, scrollback lines) and stops
;;;   following; s / r / i / e act on this unit; Esc clears the search when
;;;   there is one, else goes back to the list.
;;;   UNIT-LOG-TITLE: "Log <id> (<status word>)" then " · following" or
;;;   " · lines A-B" (the first and last log line shown), then, with a query,
;;;   " · search \"Q\": I of N" or " · search \"Q\": no results".
;;;
;;; Actions (s r i e, list or log view)
;;;   UNIT-ACTION-PERMISSION with the program's agent, its unit tools and its
;;;   current mode: :deny → help row "<action> <id> denied by <rule>" (the
;;;   rule as FORMAT-PERMISSION-RULE writes it) and a transcript :error of the
;;;   same text; :ask → the confirm dialog (title "Unit control", message
;;;   UNIT-ACTION-MESSAGE, +UNIT-ACTION-CHOICES+, Yes selected; Esc = No);
;;;   :allow, or Yes → TOOLS:CALL-UNIT-TOOL "unit_control" on a worker thread
;;;   (stop and restart block), its text on the help row and as a transcript
;;;   :notice "unit_control: <text>"; a TOOL-FAILURE → help row and :error
;;;   with its message. i first opens the "input> " prompt: Enter takes the
;;;   text plus LF as the input (then the decision), Esc cancels.
;;;   Attaching to a pty or tmux unit waits for the H8a-1 executors (no unit
;;;   kind has a terminal yet).
;;;
;;; Live updates
;;;   The program subscribes to its supervisor at TUI-INIT (SUP:SUBSCRIBE,
;;;   from the current seq) and sends each event to the UI with TUI-SEND.
;;;   Each one: the core gets (:units :running N) with the live count
;;;   (status line), and (:unit-failed :notice TEXT) when UNIT-FAILURE-NOTICE
;;;   gives one; an open panel redraws. While open, a timer sends a tick
;;;   every +UNIT-TICK-INTERVAL+ s (uptime, last lines) and the sampler takes
;;;   SAMPLE-UNIT-RESOURCES every +UNIT-STATS-INTERVAL+ s on its own thread.
;;;   Both stop when the panel closes; the subscription ends at
;;;   CLOSE-CODE-PROGRAM.

;;; Given: the panel's state (the program fills it; the readers are the API).

(defclass unit-panel ()
  ((open :initform nil :accessor unit-panel-open-p)
   (mode :initform :list :accessor unit-panel-mode
         :documentation ":list or :log.")
   (selected :initform nil :accessor unit-panel-selected
             :documentation "The selected unit's id in the list view, or NIL.")
   (unit :initform nil :accessor unit-panel-unit
         :documentation "The unit id the log view shows, or NIL.")
   (query :initform nil :accessor unit-panel-query
          :documentation "The log view's search query, or NIL.")
   (hits :initform '() :accessor unit-panel-hits
         :documentation "SS:SEARCH-HITs of the query, in search order.")
   (hit-index :initform nil :accessor unit-panel-hit-index
              :documentation "0-based index of the current hit, or NIL.")
   (state :initform nil :accessor %unit-panel-state
          :documentation "The implementation's: rows, scroll offsets, loaded lines,
follow thread, samples, the prompt, the help text, the pending action."))
  (:documentation "H8d: the interactive mode's unit panel."))

;;; Stubs: the views.

(defun unit-row-text (row width &key header selected stats cpu (now (get-universal-time)))
  "→ the panel text of ROW (a UNIT-TREE row) cut to WIDTH, or of the column
header with HEADER true (ROW ignored). SELECTED: its mark. STATS: its
SAMPLE-UNIT-RESOURCES plist or NIL; CPU: its percent or NIL. See the file
header."
  (declare (ignore row width header selected stats cpu now))
  (%h8d-pending "unit-row-text"))

(defun unit-panel-lines (rows width height &key selected stats cpu (now (get-universal-time)))
  "→ the list view: HEIGHT lines of runs (W:TEXT-RUNs) for the UNIT-TREE ROWS
at WIDTH, the title row first. SELECTED: a unit id. STATS: a
SAMPLE-UNIT-RESOURCES table; CPU: an EQUAL table id → percent. See the file
header."
  (declare (ignore rows width height selected stats cpu now))
  (%h8d-pending "unit-panel-lines"))

(defun unit-log-lines (records gaps width &key hits query)
  "→ lines of runs for SUP:LOG-RECORDs RECORDS and SUP:LOG-GAPs GAPS (in
line order) at WIDTH. HITS: line numbers marked \">\"; QUERY: a search query
whose terms are highlighted. See the file header."
  (declare (ignore records gaps width hits query))
  (%h8d-pending "unit-log-lines"))

(defun unit-log-title (unit &key following first-line last-line query hit-index hit-count)
  "→ the log view's title for UNIT (see the file header). HIT-INDEX is 0-based."
  (declare (ignore unit following first-line last-line query hit-index hit-count))
  (%h8d-pending "unit-log-title"))

;;; Stubs: the core (src/interactive.lisp routes here).

(defun %units-command (state argument)
  "/ps ARGUMENT (idle or busy): no argument → effect (:units-panel); else an
:error \"usage: /ps\". → effects."
  (declare (ignore state argument))
  (%h8d-pending "/ps"))

(defun %units-event (state event)
  "(:units :running N) → STATE-UNITS-RUNNING N, no effect. (:unit-failed
:notice TEXT) → a :notice entry TEXT, no effect. → effects."
  (declare (ignore state event))
  (%h8d-pending "the unit events"))
