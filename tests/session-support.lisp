(in-package #:cl-stack-code/tests)

;;; H3c helpers. Store tests work in a fresh temporary sessions directory;
;;; end-to-end tests use the project's private data directory (DATA-DIR-OF,
;;; <base>/data/), so nothing touches the real ~/.local/share.

(defun call-with-sessions-dir (fn)
  (let ((base (temp-base)))
    (unwind-protect (funcall fn (subdir base "sessions/project/") base)
      (uiop:delete-directory-tree base :validate t :if-does-not-exist :ignore))))

(defmacro with-sessions-dir ((dir &optional (base (gensym "BASE"))) &body body)
  "DIR: a fresh, not yet existing sessions directory under a temp BASE."
  `(call-with-sessions-dir (lambda (,dir ,base)
                             (declare (ignorable ,base))
                             ,@body)))

(defun project-sessions (project config)
  "SESSIONS-DIRECTORY of PROJECT under its private data directory."
  (sessions-directory project :data-dir (data-dir-of config)))

;;; Turns and records.

(defun call-part (id name arguments)
  (llm:make-llm-tool-call-part :id id :name name :arguments arguments))

(defun simple-record (prompt answer &rest keys)
  "A TURN-RECORD whose turns are PROMPT and one assistant ANSWER."
  (apply #'make-turn-record :prompt prompt
                            :turns (list (llm:user-turn prompt) (llm:assistant-turn answer))
                            :model "mock"
                            keys))

(defun tool-record (prompt)
  "A record with a tool call, its result and a final answer."
  (make-turn-record
   :prompt prompt
   :turns (list (llm:user-turn prompt)
                (llm:assistant-turn "Let me look." :tool-calls (list (call-part "c1" "read" "{\"file_path\":\"a.txt\"}")))
                (llm:tool-turn "c1" "alpha" :name "read")
                (llm:assistant-turn "It says alpha."))
   :model "mock:alpha"
   :permission-mode :accept-edits
   :usage (list 20 10 4 2)))

(defun turn-summary (turn)
  "(role text) of an LLM-TURN, for comparisons: TEXT joins its text parts and
tool result contents."
  (list (llm:llm-turn-role turn)
        (format nil "~{~a~}" (remove "" (mapcar #'part-text (llm:llm-turn-parts turn))
                                     :test #'equal))))

(defun turn-summaries (turns) (mapcar #'turn-summary turns))

(defun commit (store prompt &optional (answer (format nil "re: ~a" prompt)) &rest keys)
  "COMMIT-TURN a SIMPLE-RECORD. → the revision."
  (values (apply #'commit-turn store (simple-record prompt answer) keys)))

(defun line-prompts (store)
  (mapcar #'record-prompt (session-records store)))

(defun id8 (revision) (subseq (rev:revision-id revision) 0 8))

(defun hex-n (char n) (make-string n :initial-element char))

(defun rev-id (char) (hex-n char 40))

(defun session-file (store &rest parts)
  "A file under STORE's directory, e.g. (session-file s \"refs/\" \"head\")."
  (let ((path (session-directory store)))
    (dolist (p parts path)
      (setf path (merge-pathnames p path)))))

(defun file-string (path)
  (and (probe-file path) (uiop:read-file-string path :external-format :utf-8)))

(defun directory-names (dir)
  "Names of the subdirectories of DIR, sorted."
  (sort (mapcar (lambda (d) (car (last (pathname-directory d))))
                (uiop:subdirectories dir))
        #'string<))

(defun fixed-clock-at (seconds)
  (dt:make-instant seconds))

(defmacro at-time ((seconds) &body body)
  `(dt:with-fixed-clock ((fixed-clock-at ,seconds)) ,@body))

(defun one-session (sessions-dir)
  "The only session directory's store in SESSIONS-DIR (OPEN-SESSION)."
  (let ((names (directory-names sessions-dir)))
    (and (= 1 (length names))
         (open-session sessions-dir (first names)))))

(defun entry-summary (entry)
  "(kind text-or-name) of an ENTRY; NIL for NIL."
  (and entry
       (list (entry-kind entry)
             (if (eq :tool (entry-kind entry)) (entry-name entry) (entry-text entry)))))

(defun request-chat (request)
  "Text of REQUEST's turns other than :system ones (the system prompt holds
ordinary words like \"follow\" that must not count)."
  (format nil "~{~a~^~%~}"
          (mapcar #'turn-text*
                  (remove :system (request-turns request) :key #'llm:llm-turn-role))))
