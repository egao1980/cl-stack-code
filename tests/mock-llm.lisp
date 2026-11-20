(in-package #:cl-stack-code/tests)

;;; A scripted LLM backend (test code, complete). Each GENERATE /
;;; STREAM-GENERATE answers with the next step of its script:
;;;
;;;   "text"                              a text reply, finish :stop
;;;   (:tool name json-arguments)         one tool call, finish :tool-use
;;;   (:tools (name json) …)              several tool calls
;;;   (:text "…" :tools ((name json) …))  text and tool calls
;;;   (:error "message")                  GENERATE signals an ERROR
;;;
;;; Tool call ids are "call-<step>-<i>". Every response reports usage
;;; input 10, output 5, cache read 2, cache write 1. STREAM-GENERATE sends
;;; the text as word-sized LLM-TEXT-PART deltas (each word with its trailing
;;; spaces), then each tool call part, through :ON-PART. A request past the
;;; end of the script signals an ERROR. Every request is recorded.

(defclass scripted-request ()
  ((turns :initarg :turns :reader request-turns)
   (tool-names :initarg :tool-names :reader request-tool-names)))

(defclass scripted-backend (llm:llm-backend)
  ((steps :initarg :steps :reader scripted-steps)
   (requests :initform '() :accessor %requests)
   (model :initform :unset :accessor scripted-model
          :documentation "The MODEL its provider factory received.")
   (factory-calls :initform 0 :accessor scripted-factory-calls)
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

(defun %usage ()
  (llm:make-llm-usage :input-tokens 10 :output-tokens 5 :total-tokens 15
                      :cache-read-tokens 2 :cache-write-tokens 1))

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
         (:error (error "~a" (second step))))))))

(defun %words (text)
  "TEXT cut after each run of spaces: \"a b  c\" → (\"a \" \"b  \" \"c\")."
  (let ((out '()) (start 0) (n (length text)))
    (loop while (< start n)
          do (let* ((sp (or (position #\Space text :start start) n))
                    (end (or (position #\Space text :start sp :test-not #'char=) n)))
               (push (subseq text start end) out)
               (setf start end)))
    (nreverse out)))

(defun %respond (backend turns tools on-part)
  (let ((n (bt:with-lock-held ((%lock backend))
             (push (make-instance 'scripted-request
                                  :turns (copy-list (llm:coerce-turns turns))
                                  :tool-names (mapcar #'llm:llm-tool-name tools))
                   (%requests backend))
             (length (%requests backend)))))
    (when (> n (length (scripted-steps backend)))
      (error "scripted backend: no step ~d (the script has ~d)"
             n (length (scripted-steps backend))))
    (multiple-value-bind (text calls) (%step-parts (nth (1- n) (scripted-steps backend)) n)
      (when on-part
        (dolist (w (%words text))
          (funcall on-part (llm:make-llm-text-part :text w)))
        (dolist (c calls)
          (funcall on-part c)))
      (llm:make-llm-response
       :parts (append (and (plusp (length text))
                           (list (llm:make-llm-text-part :text text)))
                      calls)
       :model "scripted"
       :finish-reason (if calls :tool-use :stop)
       :usage (%usage)))))

(defmethod llm:generate ((backend scripted-backend) turns &key model settings tools
                         tool-choice output)
  (declare (ignore model settings tool-choice output))
  (%respond backend turns tools nil))

(defmethod llm:stream-generate ((backend scripted-backend) turns &key model settings
                                tools tool-choice on-part output)
  (declare (ignore model settings tool-choice output))
  (%respond backend turns tools on-part))

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
