(in-package #:cl-stack-code/tests)

;;; H3d helpers (test code, complete). An SDK client on the scripted mock
;;; backend with its events collected, and an --rpc server (SERVE-RPC) on an
;;; in-memory stdio pair (rpc-backend-stdio 0.2.0) with an RPC-CLIENT on the
;;; other end. Every test uses a temporary project, config and data
;;; directory, as the -p tests do.

;;; A thread-safe list.

(defstruct (collector (:constructor make-collector ()))
  (lock (bt:make-lock "collector"))
  (items '()))

(defun collect (collector item)
  (bt:with-lock-held ((collector-lock collector))
    (push item (collector-items collector)))
  item)

(defun collected (collector)
  "Items so far, oldest first."
  (bt:with-lock-held ((collector-lock collector))
    (reverse (collector-items collector))))

;;; Events.

(defun events-of (events type)
  "The events of TYPE in EVENTS (a list, or a COLLECTOR)."
  (remove-if-not (lambda (e) (equal type (event-type e)))
                 (if (collector-p events) (collected events) events)))

(defun event-types (events)
  (mapcar #'event-type (if (collector-p events) (collected events) events)))

(defun wait-event (events predicate &key (timeout 30))
  "The first event of the COLLECTOR EVENTS satisfying PREDICATE, waiting up to
TIMEOUT seconds. → the event or NIL."
  (wait-until (lambda () (find-if predicate (collected events))) :timeout timeout))

(defun type-is (type &optional session-id)
  (lambda (e)
    (and (equal type (event-type e))
         (or (null session-id) (equal session-id (event-value e "session_id"))))))

(defun normalized (event)
  "A copy of EVENT without \"session_id\" and \"duration_ms\" (for comparing
two runs of one script)."
  (let ((copy (make-hash-table :test #'equal)))
    (maphash (lambda (k v)
               (unless (member k '("session_id" "duration_ms") :test #'string=)
                 (setf (gethash k copy) v)))
             event)
    copy))

(defun same-events-p (as bs)
  (and (= (length as) (length bs))
       (every (lambda (a b) (equalp (normalized a) (normalized b))) as bs)))

;;; The SDK client.

(defun call-with-test-client (project config fn &key steps backend settings on-approval
                                                     providers (plan-area :auto) cwd)
  "FN gets (client backend events): a client on PROJECT with the scripted
BACKEND (or one made from STEPS) as provider \"mock\", the default model
\"mock\" under SETTINGS (a flag layer), and every event in the COLLECTOR."
  (let* ((backend (or backend (make-scripted-backend steps)))
         (events (make-collector)))
    (with-client (client :cwd (or cwd project)
                         :settings (merge-settings (make-settings :model "mock") settings)
                         :providers (append providers
                                            (list (cons "mock" (scripted-provider backend))))
                         :user-config-dir config
                         :data-dir (data-dir-of config)
                         :getenv (env-lookup)
                         :plan-area plan-area
                         :on-event (lambda (session event)
                                     (declare (ignore session))
                                     (collect events event))
                         :on-approval on-approval)
      (funcall fn client backend events))))

(defmacro with-test-client ((client backend events project config &rest keys) &body body)
  `(call-with-test-client ,project ,config
                          (lambda (,client ,backend ,events)
                            (declare (ignorable ,client ,backend ,events))
                            ,@body)
                          ,@keys))

(defun session-dir-records (project config id)
  "The turn records of session ID as they are on disk (a fresh store)."
  (session-records (open-session (project-sessions project config) id)))

(defun request-user-texts (request)
  "The text of each :user turn of REQUEST, oldest first."
  (mapcar #'turn-text*
          (remove :user (request-turns request) :key #'llm:llm-turn-role :test-not #'eq)))

;;; An --rpc server on a pair.

(defun call-with-rpc (project config fn &key steps backend settings providers (plan-area :auto))
  "FN gets (rpc backend server-thread result-cell): SERVE-RPC on the server
half of a MAKE-STDIO-RPC-PAIR in a thread (the same client arguments as
CALL-WITH-TEST-CLIENT), an RPC-CLIENT on the other half. Afterwards the
client is closed, which ends the server (EOF). RESULT-CELL's car is
SERVE-RPC's value once it returned."
  (let ((backend (or backend (make-scripted-backend steps)))
        (cell (list :running)))
    (multiple-value-bind (server-tx client-tx) (stdio:make-stdio-rpc-pair)
      (let* ((thread (bt:make-thread
                      (lambda ()
                        (setf (car cell)
                              (handler-case
                                  (serve-rpc server-tx
                                             :cwd project
                                             :settings (merge-settings (make-settings :model "mock") settings)
                                             :providers (append providers
                                                                (list (cons "mock" (scripted-provider backend))))
                                             :user-config-dir config
                                             :data-dir (data-dir-of config)
                                             :getenv (env-lookup)
                                             :plan-area plan-area)
                                (error (e) (list :error (princ-to-string e))))))
                      :name "rpc server"))
             (rpc (connect-rpc-client :transport client-tx)))
        (unwind-protect (funcall fn rpc backend thread cell)
          (ignore-errors (close-rpc-client rpc))
          (wait-until (lambda () (not (bt:thread-alive-p thread))) :timeout 30))))))

(defmacro with-rpc ((rpc backend project config &rest keys) &body body)
  `(call-with-rpc ,project ,config
                  (lambda (,rpc ,backend %thread %cell)
                    (declare (ignorable ,rpc ,backend %thread %cell))
                    ,@body)
                  ,@keys))

(defun call (rpc method &rest kv)
  "RPC-CLIENT-CALL with params from alternating keys and values."
  (rpc-client-call rpc method (apply #'args kv) :timeout 30))

(defun fault (rpc method &rest kv)
  "The error response of METHOD: (values code data message), or NIL when it
succeeded."
  (handler-case (progn (rpc-client-call rpc method (apply #'args kv) :timeout 30) nil)
    (rpc:rpc-error (e)
      (values (rpc:rpc-error-code e) (rpc:rpc-error-data e) (rpc:rpc-error-message e)))))

(defun rpc-result (rpc session-id &key (n 0) (timeout 30))
  "The Nth \"result\" event of SESSION-ID received by RPC (waiting for it)."
  (wait-until (lambda ()
                (nth n (rpc-client-events rpc :type "result" :session-id session-id)))
              :timeout timeout))

(defun new-session (rpc &rest kv)
  "session/new → the session id."
  (event-value (apply #'call rpc "session/new" kv) "session_id"))
