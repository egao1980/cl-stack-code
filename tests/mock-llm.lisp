(in-package #:cl-stack-code/tests)

;;; A scripted LLM backend (test code, complete). Each GENERATE /
;;; STREAM-GENERATE answers with the next step of its script:
;;;
;;;   "text"                              a text reply, finish :stop
;;;   (:tool name json-arguments)         one tool call, finish :tool-use
;;;   (:tools (name json) …)              several tool calls
;;;   (:text "…" :tools ((name json) …))  text and tool calls
;;;   (:error "message")                  GENERATE signals an ERROR
;;;   (:gate GATE STEP)                   wait until GATE is open (OPEN-GATE),
;;;                                       then answer with STEP (H3b)
;;;   (:think "thought" STEP)             ACP-2: a thinking part, then STEP: the
;;;                                       thought is streamed first, as word-sized
;;;                                       LLM-THINKING-PART deltas, and is the
;;;                                       response's first part
;;;   H3f:
;;;   (:fail KIND &key status message retry-after)
;;;                                       signal what an llm-protocol 0.7.0
;;;                                       backend signals for KIND: :connect,
;;;                                       :reset, :timeout, :tls (transport),
;;;                                       :rate-limit (429), :overloaded (529),
;;;                                       :auth (401), :not-found (404),
;;;                                       :overflow (400 "prompt is too long"),
;;;                                       :http (STATUS, default 400)
;;;   (:stream-fail "text" KIND …)        stream TEXT's deltas, then :fail
;;;   (:length "text")                    a text reply, finish :length
;;;   (:length-tool name partial-json)    one tool call cut at the output
;;;                                       limit, finish :length
;;;   (:stall SECONDS STEP)               sleep SECONDS, then STEP
;;;   (:usage INPUT STEP)                 STEP, reporting INPUT input tokens
;;;
;;; Tool call ids are "call-<step>-<i>". Every response reports usage
;;; input 10, output 5, cache read 2, cache write 1. STREAM-GENERATE sends
;;; the text as word-sized LLM-TEXT-PART deltas (each word with its trailing
;;; spaces), then each tool call part, through :ON-PART. A request past the
;;; end of the script signals an ERROR. Every request is recorded.

(defclass scripted-request ()
  ((turns :initarg :turns :reader request-turns)
   (model :initarg :model :initform nil :reader request-model
          :documentation "The :MODEL argument GENERATE / STREAM-GENERATE got.")
   (tool-names :initarg :tool-names :reader request-tool-names)
   (settings :initarg :settings :initform nil :reader request-settings
             :documentation "The :SETTINGS argument (an LLM-SETTINGS or NIL).")))

(defclass scripted-backend (llm:llm-backend)
  ((steps :initarg :steps :reader scripted-steps)
   (requests :initform '() :accessor %requests)
   (model :initform :unset :accessor scripted-model
          :documentation "The MODEL its provider factory received.")
   (factory-calls :initform 0 :accessor scripted-factory-calls)
   ;; H3f
   (request-timeout :initform nil :accessor scripted-request-timeout
                    :documentation "Seconds APPLY-REQUEST-TIMEOUT gave it, or NIL.")
   (context-window :initform nil :accessor scripted-context-window
                   :documentation "What LLM:CONTEXT-WINDOW answers (NIL = unknown).")
   (env :initform nil :accessor scripted-env
        :documentation "The ENV function its factory received.")
   (lock :initform (bt:make-lock "scripted-backend") :reader %lock)))

(defun make-scripted-backend (steps)
  (make-instance 'scripted-backend :steps steps))

(defun scripted-requests (backend)
  "Recorded requests, oldest first."
  (bt:with-lock-held ((%lock backend))
    (reverse (%requests backend))))

(defun scripted-provider (backend)
  "A provider factory that records its arguments and returns BACKEND."
  (lambda (model env)
    (setf (scripted-model backend) model
          (scripted-env backend) env)
    (incf (scripted-factory-calls backend))
    backend))

(defmethod llm:backend-supports-p ((backend scripted-backend) feature)
  (and (member feature '(:tools :stream)) t))

(defun %usage (&optional (input 10))
  (llm:make-llm-usage :input-tokens input :output-tokens 5 :total-tokens (+ input 5)
                      :cache-read-tokens 2 :cache-write-tokens 1))

;;; H3f: failures, as llm-protocol 0.7.0 backends signal them. The 0.7.0
;;; types are found by name at run time, so this file also loads against
;;; llm-protocol 0.6 (the contract measures the stubs that way); there the
;;; nearest 0.6 type is signalled.

(defun %llm-type (name fallback)
  (let ((sym (find-symbol name '#:llm-protocol)))
    (if (and sym (find-class sym nil)) sym fallback)))

(defun %fail (kind &key status message retry-after)
  (flet ((http (name status default-message &rest more)
           (apply #'error (%llm-type name 'llm:llm-http-error)
                  :status status :message (or message default-message)
                  :retry-after retry-after
                  (append (and (find-symbol "LLM-ERROR-PROVIDER" '#:llm-protocol)
                               (list :provider "mock" :url "http://mock.invalid/v1"
                                     :model "scripted"))
                          more))))
    (ecase kind
      ((:connect :reset :timeout :tls)
       (let ((type (%llm-type "LLM-TRANSPORT-ERROR" nil)))
         (if type
             (error type :kind kind :provider "mock" :url "http://mock.invalid/v1"
                         :message (or message (format nil "~(~a~) failed" kind)))
             (error 'http-protocol:http-connection-error
                    :message (or message "Connection refused")))))
      (:rate-limit (http "LLM-RATE-LIMITED" 429 "rate limit reached" :retryable-p t))
      (:overloaded (http "LLM-OVERLOADED" 529 "Overloaded" :retryable-p t))
      (:auth (http "LLM-AUTH-ERROR" 401 "invalid x-api-key" :retryable-p nil))
      (:not-found (http "LLM-NOT-FOUND" 404 "model not found" :retryable-p nil))
      (:overflow (error 'llm:llm-context-overflow :status 400
                                                  :message (or message "prompt is too long")))
      (:http (http "LLM-HTTP-ERROR" (or status 400) (format nil "HTTP ~a" (or status 400)))))))

(defun %step-parts (step n)
  "→ (values text tool-call-parts) for script STEP number N."
  (flet ((calls (specs)
           (loop for (name arguments) in specs
                 for i from 1
                 collect (llm:make-llm-tool-call-part
                          :id (format nil "call-~d-~d" n i)
                          :name name :arguments arguments))))
    (etypecase step
      (string (values step nil))
      (cons
       (ecase (first step)
         (:tool (values "" (calls (list (rest step)))))
         (:tools (values "" (calls (rest step))))
         (:text (values (getf step :text "")
                        (calls (getf step :tools))))
         (:error (error "~a" (second step)))
         (:fail (apply #'%fail (rest step)))
         (:length (values (second step) nil))
         (:length-tool (values "" (calls (list (rest step)))))
         ((:stream-fail :stall :usage)
          (error "scripted backend: ~s is handled by %RESPOND" (first step))))))))

(defun %words (text)
  "TEXT cut after each run of spaces: \"a b  c\" → (\"a \" \"b  \" \"c\")."
  (let ((out '()) (start 0) (n (length text)))
    (loop while (< start n)
          do (let* ((sp (or (position #\Space text :start start) n))
                    (end (or (position #\Space text :start sp :test-not #'char=) n)))
               (push (subseq text start end) out)
               (setf start end)))
    (nreverse out)))

(defstruct (gate (:constructor make-gate ()))
  "A one-shot latch for (:gate GATE STEP) script steps."
  (lock (bt:make-lock "gate"))
  (cv (bt:make-condition-variable))
  (open nil)
  (waiting nil))

(defun open-gate (gate)
  (bt:with-lock-held ((gate-lock gate))
    (setf (gate-open gate) t)
    (bt:condition-notify (gate-cv gate)))
  gate)

(defun gate-waiting-p (gate)
  "True once a generate is waiting at GATE (or went through it)."
  (bt:with-lock-held ((gate-lock gate)) (gate-waiting gate)))

(defun %pass-gate (gate)
  (bt:with-lock-held ((gate-lock gate))
    (setf (gate-waiting gate) t)
    (loop until (gate-open gate)
          do (bt:condition-wait (gate-cv gate) (gate-lock gate) :timeout 1))))

(defun %ungated (step)
  "STEP, after waiting at its gate when it is a (:gate GATE STEP) step."
  (if (and (consp step) (eq (first step) :gate))
      (progn (%pass-gate (second step))
             (%ungated (third step)))
      step))

(defun %thought (step)
  "→ (values thought step): a (:think \"thought\" STEP) step's thought and
its STEP (ungated), else \"\" and STEP."
  (if (and (consp step) (eq (first step) :think))
      (values (second step) (%ungated (third step)))
      (values "" step)))

(defun %step-kind (step)
  (and (consp step) (first step)))

(defun %respond (backend turns tools on-part &optional model settings)
  (let ((n (bt:with-lock-held ((%lock backend))
             (push (make-instance 'scripted-request
                                  :turns (copy-list (llm:coerce-turns turns))
                                  :model model
                                  :settings settings
                                  :tool-names (mapcar #'llm:llm-tool-name tools))
                   (%requests backend))
             (length (%requests backend)))))
    (when (> n (length (scripted-steps backend)))
      (error "scripted backend: no step ~d (the script has ~d)"
             n (length (scripted-steps backend))))
    (let ((step (%ungated (nth (1- n) (scripted-steps backend))))
          (input 10))
      ;; H3f wrappers
      (loop
        (case (%step-kind step)
          (:stall (sleep (second step)) (setf step (%ungated (third step))))
          (:usage (setf input (second step)) (setf step (%ungated (third step))))
          (t (return))))
      (when (eq (%step-kind step) :stream-fail)
        (when on-part
          (dolist (w (%words (second step)))
            (funcall on-part (llm:make-llm-text-part :text w))))
        (apply #'%fail (cddr step)))
      (multiple-value-bind (thought step) (%thought step)
        (multiple-value-bind (text calls) (%step-parts step n)
          (when on-part
            (dolist (w (%words thought))
              (funcall on-part (llm:make-llm-thinking-part :text w)))
            (dolist (w (%words text))
              (funcall on-part (llm:make-llm-text-part :text w)))
            (dolist (c calls)
              (funcall on-part c)))
          (llm:make-llm-response
           :parts (append (and (plusp (length thought))
                               (list (llm:make-llm-thinking-part :text thought)))
                          (and (plusp (length text))
                               (list (llm:make-llm-text-part :text text)))
                          calls)
           :model "scripted"
           :finish-reason (cond ((member (%step-kind step) '(:length :length-tool)) :length)
                                (calls :tool-use)
                                (t :stop))
           :usage (%usage input)))))))

;;; H3f: the backend side of requestTimeoutMs and context windows.

(defmethod apply-request-timeout ((backend scripted-backend) seconds)
  (setf (scripted-request-timeout backend) seconds)
  backend)

(defmethod llm:context-window ((backend scripted-backend) model)
  (declare (ignore model))
  (scripted-context-window backend))

(defmethod llm:generate ((backend scripted-backend) turns &key model settings tools
                         tool-choice output)
  (declare (ignore tool-choice output))
  (%respond backend turns tools nil model settings))

(defmethod llm:stream-generate ((backend scripted-backend) turns &key model settings
                                tools tool-choice on-part output)
  (declare (ignore tool-choice output))
  (%respond backend turns tools on-part model settings))

;;; Reading requests.

(defun part-text (part)
  (cond ((llm:llm-text-part-p part) (llm:llm-text-part-text part))
        ((llm:llm-tool-result-part-p part)
         (let ((c (llm:llm-tool-result-part-content part)))
           (if (stringp c) c (princ-to-string c))))
        (t "")))

(defun turn-text* (turn)
  (format nil "~{~a~^~%~}" (mapcar #'part-text (llm:llm-turn-parts turn))))

(defun request-system (request)
  "Text of REQUEST's :system turns."
  (format nil "~{~a~^~%~}"
          (mapcar #'turn-text*
                  (remove :system (request-turns request)
                          :key #'llm:llm-turn-role :test-not #'eq))))

(defun request-text (request)
  "All text of REQUEST's turns: text parts and tool results."
  (format nil "~{~a~^~%~}" (mapcar #'turn-text* (request-turns request))))

(defun request-tool-results (request)
  "Tool result parts in REQUEST's turns, oldest first."
  (loop for turn in (request-turns request)
        append (remove-if-not #'llm:llm-tool-result-part-p (llm:llm-turn-parts turn))))

(defun last-request (backend)
  (car (last (scripted-requests backend))))

(defun result-content (part) (part-text part))
(defun result-error-p (part) (llm:llm-tool-result-part-error-p part))
