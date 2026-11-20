(in-package #:cl-stack-code/tests)

;;; H3b helpers. The core is driven with hand-built events; the program runs
;;; on tui-backend-terminal's headless driver over the pure-Lisp emulator
;;; with the scripted mock LLM (provider "mock").

;;; The core.

(defun proposed (id name &optional (arguments "{}"))
  "A fresh :proposed AGENT-INVOCATION."
  (a:make-agent-invocation :id id :name name :arguments arguments :status :proposed))

(defun fresh-state (&rest keys)
  (apply #'make-interactive-state :model "mock" keys))

(defun feed (state &rest events)
  "Apply EVENTS in order. → (values state effects-of-the-last-event)."
  (let ((effects nil))
    (dolist (e events)
      (multiple-value-bind (s fx) (interactive-update state e)
        (setf state s effects fx)))
    (values state effects)))

(defun effects (state event)
  (nth-value 1 (interactive-update state event)))

(defun kinds (state)
  (mapcar #'entry-kind (state-transcript state)))

(defun texts (state)
  (mapcar #'entry-text (state-transcript state)))

(defun last-entry (state)
  (car (last (state-transcript state))))

(defun busy-state (&rest keys)
  "A state with one turn running (\"first\" submitted)."
  (feed (apply #'fresh-state keys) '(:submit "first")))

;;; Lines.

(defun line-strings (lines)
  (mapcar #'w:runs-string lines))

(defun indent-lines (prefix lines)
  (mapcar (lambda (line) (concatenate 'string prefix (w:runs-string line))) lines))

;;; The headless program.

(defun emulator ()
  (make-instance 'tl:lisp-backend))

(defun program-argv (project argv model)
  (append (list "--cwd" (native project))
          (and model (list "--model" model))
          argv))

(defun make-program (project config &key steps backend argv providers (model "mock") getenv)
  "→ (values program backend): MAKE-CODE-PROGRAM with the scripted BACKEND (or
one made from STEPS) as provider \"mock\"."
  (let ((backend (or backend (make-scripted-backend steps))))
    (values (make-code-program (parse-arguments (program-argv project argv model))
                               :providers (append providers
                                                  (list (cons "mock" (scripted-provider backend))))
                               :user-config-dir config
                               :getenv (or getenv (env-lookup)))
            backend)))

(defun call-with-code-tui (project config fn &key steps backend argv providers (model "mock")
                                                  getenv gates (cols 80) (rows 24))
  (multiple-value-bind (program backend)
      (make-program project config :steps steps :backend backend :argv argv
                                   :providers providers :model model :getenv getenv)
    (let ((tui nil))
      (unwind-protect
           (progn
             (setf tui (h:make-headless-tui program :cols cols :rows rows
                                                    :terminal-backend (emulator)))
             (funcall fn tui program backend))
        (dolist (g gates) (open-gate g))
        (when tui (ignore-errors (h:tui-stop tui)))
        (close-code-program program)))))

(defmacro with-code-tui ((tui program backend &rest keys) (project config) &body body)
  "Run BODY with TUI (a headless TUI) on PROGRAM (MAKE-CODE-PROGRAM in
PROJECT) and its scripted BACKEND. KEYS: :steps :backend :argv :providers
:model :getenv :gates (opened on exit) :cols :rows."
  `(call-with-code-tui ,project ,config
                       (lambda (,tui ,program ,backend)
                         (declare (ignorable ,tui ,program ,backend))
                         ,@body)
                       ,@keys))

(defparameter *ui-timeout* 20
  "Seconds a UI wait may take (the first turn loads natives and the loop).")

(defun screen (tui) (h:tui-screen tui))

(defun screen-text (tui)
  (format nil "~{~a~^~%~}" (screen tui)))

(defun on-screen (tui needle)
  (and (search needle (screen-text tui)) t))

(defun wait-screen (tui needle &key (timeout *ui-timeout*))
  "True once NEEDLE shows on screen."
  (h:tui-wait-for tui needle :timeout timeout))

(defun wait-gone (tui needle &key (timeout *ui-timeout*))
  "True once NEEDLE is no longer on screen."
  (and (h:tui-wait-until tui (lambda () (not (on-screen tui needle))) :timeout timeout) t))

(defun wait-for* (tui predicate &key (timeout *ui-timeout*))
  (and (h:tui-wait-until tui predicate :timeout timeout) t))

(defun wait-idle (tui program &key (timeout *ui-timeout*))
  "True once no turn runs (and no approval waits)."
  (wait-for* tui (lambda () (not (state-busy-p (code-program-state program))))
             :timeout timeout))

(defun wait-requests (tui backend n &key (timeout *ui-timeout*))
  "True once BACKEND has seen N requests."
  (wait-for* tui (lambda () (>= (length (scripted-requests backend)) n)) :timeout timeout))

(defun send-line (tui text)
  "Type TEXT and press Enter."
  (h:tui-type tui text)
  (h:tui-press tui :enter))

(defun ctrl (tui key)
  (h:tui-press tui key :modifiers '(:ctrl)))

(defun last-row (tui)
  (car (last (screen tui))))

(defun row-index (tui needle)
  "Index of the first screen row containing NEEDLE, or NIL."
  (position-if (lambda (row) (search needle row)) (screen tui)))

(defun rule-row-p (row)
  (and (plusp (length (string-right-trim " " row)))
       (every (lambda (c) (char= c #\─)) (string-right-trim " " row))))

(defun local-settings (config project)
  "The local settings file of PROJECT."
  (third (settings-file-paths project :user-config-dir config)))

(defun write-bytes (dir rel octets)
  "Write OCTETS to REL under DIR. → the pathname."
  (let ((path (merge-pathnames rel dir)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :element-type '(unsigned-byte 8))
      (write-sequence (coerce octets '(vector (unsigned-byte 8))) out))
    path))
