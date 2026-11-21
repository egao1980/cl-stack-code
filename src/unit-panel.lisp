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

;;; The views.

(defparameter +unit-panel-empty-text+
  "  no units yet: shell jobs, servers and subagents show up here"
  "Row 1 of the list view without units.")

(defun %fit (text n)
  "TEXT, or its first N − 1 characters and \"…\" when longer than N."
  (if (<= (length text) n)
      text
      (concatenate 'string (subseq text 0 (max 0 (1- n))) "…")))

(defun %cut-row (text width)
  "TEXT cut to WIDTH characters, trailing blanks trimmed."
  (string-right-trim " " (if (> (length text) width) (subseq text 0 (max 0 width)) text)))

(defun %indent (depth)
  (make-string (* 2 depth) :initial-element #\Space))

(defvar *%unit-last-lines* nil
  "An EQUAL table unit id → UNIT-LAST-LINE the program binds while it draws the
list view (one log read per unit per refresh), or NIL.")

(defun %row-last-line (unit)
  (let ((cache *%unit-last-lines*)
        (id (sup:unit-id unit)))
    (if cache
        (multiple-value-bind (line found) (gethash id cache)
          (if found line (setf (gethash id cache) (unit-last-line unit))))
        (unit-last-line unit))))

(defun %row-columns (mark name status kind pid up cpu rss last)
  (string-right-trim
   " " (%text "~a~20a ~9a ~9a ~6@a ~6@a ~5@a ~6@a  ~a"
               mark (%fit name 20) (%fit status 9) (%fit kind 9) pid up cpu rss last)))

(defun unit-row-text (row width &key header selected stats cpu (now (get-universal-time)))
  "→ the panel text of ROW (a UNIT-TREE row) cut to WIDTH, or of the column
header with HEADER true (ROW ignored). SELECTED: its mark. STATS: its
SAMPLE-UNIT-RESOURCES plist or NIL; CPU: its percent or NIL. See the file
header."
  (%cut-row
   (cond (header (apply #'%row-columns "  " +unit-panel-columns+))
         ((getf row :scope)
          (%text "~a  ~a/" (%indent (getf row :depth)) (sup:scope-name (getf row :scope))))
         (t (let* ((u (getf row :unit))
                   (pid (sup:unit-pid u))
                   (start (sup:unit-start-time u)))
              (%row-columns (if selected "> " "  ")
                            (concatenate 'string (%indent (getf row :depth)) (sup:unit-id u))
                            (unit-status-word u)
                            (%lower (sup:unit-kind u))
                            (if pid (princ-to-string pid) "-")
                            (if (and start (sup:unit-live-p u))
                                (format-unit-uptime (max 0 (- now start)))
                                "-")
                            (format-unit-cpu cpu)
                            (format-unit-rss (getf stats :rss))
                            (or (%row-last-line u) "")))))
   width))

(defun %row-unit-id (row)
  (let ((u (getf row :unit)))
    (and u (sup:unit-id u))))

(defun unit-panel-lines (rows width height &key selected stats cpu (now (get-universal-time)))
  "→ the list view: HEIGHT lines of runs (W:TEXT-RUNs) for the UNIT-TREE ROWS
at WIDTH, the title row first. SELECTED: a unit id. STATS: a
SAMPLE-UNIT-RESOURCES table; CPU: an EQUAL table id → percent. See the file
header."
  (let* ((units (remove-if-not (lambda (row) (getf row :unit)) rows))
         (running (count-if (lambda (row) (sup:unit-live-p (getf row :unit))) units))
         (lines (list (list (w:text-run (%cut-row (format nil "Units · ~d running · ~d total"
                                                          running (length units))
                                                  width))))))
    (if (null units)
        (push (list (w:text-run (%cut-row +unit-panel-empty-text+ width))) lines)
        (let* ((body (max 0 (- height 2)))
               (index (and selected (position selected rows :key #'%row-unit-id :test #'equal)))
               (offset (if (and index (plusp body))
                           (max 0 (min (- index (1- body)) (- (length rows) body)))
                           0)))
          (push (list (w:text-run (unit-row-text nil width :header t) :dim t)) lines)
          (loop for row in (nthcdr offset rows)
                repeat body
                do (let* ((id (%row-unit-id row))
                          (mine (and id (equal id selected)))
                          (text (unit-row-text row width
                                               :selected mine
                                               :stats (and id stats (gethash id stats))
                                               :cpu (and id cpu (gethash id cpu))
                                               :now now)))
                     (push (list (if mine (w:text-run text :inverse t) (w:text-run text))) lines)))))
    (setf lines (nreverse lines))
    (if (< (length lines) height)
        (append lines (make-list (- height (length lines)) :initial-element '()))
        (subseq lines 0 (max 0 height)))))

(defun %query-needles (query)
  "The terms and phrases of QUERY (SS:QUERY-TERMS), longest first."
  (when (and (stringp query) (plusp (length query)))
    (multiple-value-bind (terms phrases) (ss:query-terms query)
      (stable-sort (remove-duplicates (remove "" (append phrases terms) :test #'string=)
                                      :test #'string= :from-end t)
                   #'> :key #'length))))

(defun %highlight-ranges (text needles)
  "Non-overlapping (start . end) ranges of NEEDLES in TEXT (case-insensitive;
at each position the first, i.e. longest, needle that matches)."
  (let ((ranges '()) (i 0) (n (length text)))
    (loop while (< i n)
          do (let ((hit (find-if (lambda (needle)
                                   (let ((e (+ i (length needle))))
                                     (and (<= e n) (string-equal needle text :start2 i :end2 e))))
                                 needles)))
               (if hit
                   (progn (push (cons i (+ i (length hit))) ranges)
                          (incf i (length hit)))
                   (incf i))))
    (nreverse ranges)))

(defun %text-runs (text ranges foreground)
  "Runs of TEXT: RANGES inverse, the rest plain, all in FOREGROUND (or the
default color)."
  (let ((runs '()) (pos 0))
    (flet ((emit (start end inverse)
             (when (< start end)
               (push (w:text-run (subseq text start end) :inverse inverse :foreground foreground)
                     runs))))
      (dolist (r ranges)
        (emit pos (car r) nil)
        (emit (car r) (cdr r) t)
        (setf pos (cdr r)))
      (emit pos (length text) nil))
    (nreverse runs)))

(defun %log-text-line (mark line text width &key needles foreground)
  "One log view line: (format nil \"~a~5d  ~a\" MARK LINE TEXT) cut to WIDTH,
NEEDLES highlighted in TEXT."
  (let* ((prefix (format nil "~a~5d  " mark line))
         (room (max 0 (- width (length prefix))))
         (text (if (> (length text) room) (subseq text 0 room) text)))
    (cons (w:text-run (if (> (length prefix) width) (subseq prefix 0 (max 0 width)) prefix))
          (%text-runs text (%highlight-ranges text needles) foreground))))

(defun %gap-line (gap width)
  (list (w:text-run (%cut-row (%text "[gap: lines ~d-~d not in the log (~{~a~^, ~})]"
                                      (sup:log-gap-first-line gap) (sup:log-gap-last-line gap)
                                      (mapcar #'%lower (sup:log-gap-reasons gap)))
                              width))))

(defun %log-item-line (item)
  (if (typep item 'sup:log-gap) (sup:log-gap-first-line item) (sup:log-record-line item)))

(defun %log-items (records gaps)
  "RECORDS and GAPS merged in line order."
  (stable-sort (append (copy-list gaps) (copy-list records)) #'< :key #'%log-item-line))

(defun unit-log-lines (records gaps width &key hits query)
  "→ lines of runs for SUP:LOG-RECORDs RECORDS and SUP:LOG-GAPs GAPS (in
line order) at WIDTH. HITS: line numbers marked \">\"; QUERY: a search query
whose terms are highlighted. See the file header."
  (let ((needles (%query-needles query)))
    (mapcar (lambda (item)
              (if (typep item 'sup:log-gap)
                  (%gap-line item width)
                  (let ((line (sup:log-record-line item)))
                    (%log-text-line (if (member line hits) ">" " ") line
                                    (%clean-text (sup:log-record-text item) :tab :expand)
                                    width
                                    :needles needles
                                    :foreground (and (eq :stderr (sup:log-record-stream item)) 1)))))
            (%log-items records gaps))))

(defun %unit-memory-lines (text width &key (start 1) hits query)
  "The log view's lines of a unit without a log file: TEXT (SUP:UNIT-OUTPUT)
one line per line, cleaned, numbered from 1; from line START."
  (let* ((needles (%query-needles query))
         (lines (uiop:split-string (string-right-trim '(#\Newline) text) :separator '(#\Newline))))
    (when (equal lines '("")) (setf lines '()))
    (loop for raw in (nthcdr (max 0 (1- start)) lines)
          for n from start
          collect (%log-text-line (if (member n hits) ">" " ") n
                                  (%clean-text raw :tab :expand) width :needles needles))))

(defun unit-log-title (unit &key following first-line last-line query hit-index hit-count)
  "→ the log view's title for UNIT (see the file header). HIT-INDEX is 0-based."
  (format nil "Log ~a (~a)~a~a"
          (sup:unit-id unit) (unit-status-word unit)
          (cond (following " · following")
                ((and first-line last-line) (format nil " · lines ~d-~d" first-line last-line))
                (t ""))
          (cond ((null query) "")
                ((and hit-count (plusp hit-count))
                 (format nil " · search \"~a\": ~d of ~d" query (1+ (or hit-index 0)) hit-count))
                (t (format nil " · search \"~a\": no results" query)))))

;;; The core (src/interactive.lisp routes here).

(defun %units-command (state argument)
  "/ps ARGUMENT (idle or busy): no argument → effect (:units-panel); else an
:error \"usage: /ps\". → effects."
  (if (or (null argument) (%blank-text-p argument))
      (list (list :units-panel))
      (progn (%add-entry state :kind :error :text "usage: /ps")
             '())))

(defun %units-event (state event)
  "(:units :running N) → STATE-UNITS-RUNNING N, no effect. (:unit-failed
:notice TEXT) → a :notice entry TEXT, no effect. → effects."
  (destructuring-bind (kind &key running notice &allow-other-keys) event
    (ecase kind
      (:units (setf (state-units-running state) (or running 0)))
      (:unit-failed (when notice
                      (%add-entry state :kind :notice :text notice))))
    '()))
