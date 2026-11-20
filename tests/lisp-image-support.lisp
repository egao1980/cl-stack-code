(in-package #:cl-stack-code/tests)

;;; H4b helpers (test code, complete). Live images are ros +Q run with
;;; Swank (or Slynk), as lisp-mcp's own tests spawn them. The asynchronous
;;; debugger entry is a background thread in the image (sb-thread).

(defparameter +bg-error+
  "(progn (sb-thread:make-thread (lambda () (restart-case (error \"bg boom\") (retry-later () :report \"Retry later\" 7))) :name \"bg-worker\") (sleep 1) :started)"
  "Starts a thread that enters the debugger at once; returns :STARTED a
second later, so the event arrives while this repl-eval runs.")

(defparameter +late-error+
  "(progn (sb-thread:make-thread (lambda () (sleep 1.5) (restart-case (error \"late boom\") (retry-later () :report \"Retry later\" 7))) :name \"late-worker\") :started)"
  "Starts a thread that enters the debugger 1.5 s later; returns at once.")

(defparameter +seeded-bug+
  "(defun seeded (x) (restart-case (error \"seeded bug ~a\" x) (return-default () :report \"Return 42\" 42)))")

(defparameter +image-tag+ "<lisp-image-event"
  "How an image event's turn starts (lisp-mcp/agent's +IMAGE-EVENT-TAG+).")

(defun wait-until (predicate &key (timeout 20))
  "Poll PREDICATE every 50 ms until it is true (→ its value) or TIMEOUT
seconds pass (→ NIL)."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((value (funcall predicate)))
        (when value (return value)))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.05))))

(defun image-turn-p* (turn)
  "TURN is a user turn whose text starts with +IMAGE-TAG+ (checked here, not
with lisp-mcp/agent's IMAGE-EVENT-TURN-P)."
  (and (eq :user (llm:llm-turn-role turn))
       (uiop:string-prefix-p +image-tag+ (string-left-trim '(#\Space #\Newline) (turn-text* turn)))))

(defun request-image-turns (request)
  (remove-if-not #'image-turn-p* (request-turns request)))

(defun lisp-settings (&rest kv)
  "A settings.json text with a lispImage object from alternating keys and values."
  (json:encode (args "lispImage" (apply #'args kv))))

;;; A Swank server to attach to: a second image, spawned and driven through
;;; lisp-mcp/agent directly (not through the product).

(defun call-with-swank-server (fn)
  (let* ((root (uiop:ensure-directory-pathname (uiop:temporary-directory)))
         (server (lt:make-lisp-tools :root root :image-events nil)))
    (unwind-protect
         (progn
           (lt:call-lisp-tool server "repl-spawn" "{}")
           (let* ((r (lt:call-lisp-tool server "repl-eval"
                                        (json-args "code" "(swank:create-server :port 0 :dont-close t)")))
                  (port (parse-integer r :start (+ 3 (search "=> " r)) :junk-allowed t)))
             (funcall fn port server)))
      (lt:close-lisp-tools server))))

(defmacro with-swank-server ((port server) &body body)
  "PORT: a Swank server port in a fresh image; SERVER: the LISP-TOOLS driving
that image (killed afterwards)."
  `(call-with-swank-server (lambda (,port ,server)
                             (declare (ignorable ,server))
                             ,@body)))

(defun server-eval (server code)
  (lt:call-lisp-tool server "repl-eval" (json-args "code" code)))

(defun tool-result-events (out)
  "The stream-json tool_result events of OUT."
  (events out "tool_result"))

(defun tool-result-named (out name &optional (n 0))
  "The Nth stream-json tool_result of tool NAME in OUT."
  (nth n (remove-if-not (lambda (e) (equal name (jget e "name"))) (tool-result-events out))))
