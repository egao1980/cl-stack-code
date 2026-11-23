(in-package #:cl-stack-code/tests)

;;; Shared helpers. Every test that touches files works in a fresh temporary
;;; base directory (its truename) holding project/ (the working directory,
;;; with a .git/ directory unless :GIT NIL) and config/ (the private user
;;; config directory). Nothing reads the real ~/.config or the network.

(defun temp-base ()
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-stack-code-~36R" (random (expt 36 8)
                                                                      (make-random-state t)))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (truename dir)))

;;; git writes its object files read-only. POSIX unlinks them anyway (the
;;; directory's mode decides); Windows refuses to delete a file with the
;;; read-only attribute ("Access is denied"), so the attribute is cleared
;;; first there.
(defun delete-temp-base (base)
  "Delete the temp directory BASE and everything under it."
  (when (and (uiop:os-windows-p) (uiop:directory-exists-p base))
    (uiop:run-program (list "attrib" "-R"
                            (concatenate 'string (uiop:native-namestring base) "*")
                            "/S" "/D")
                      :output nil :error-output nil :ignore-error-status t))
  (uiop:delete-directory-tree base :validate t :if-does-not-exist :ignore))

(defun subdir (dir rel)
  "Directory pathname REL (\"a/b/\") under DIR."
  (uiop:ensure-directory-pathname (merge-pathnames rel dir)))

(defun write-file (dir rel content)
  "Write CONTENT (a string, UTF-8) to REL under DIR, creating parents. → the
pathname."
  (let ((path (merge-pathnames rel dir)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :external-format :utf-8)
      (write-string content out))
    path))

(defun read-file (dir rel)
  (let ((path (merge-pathnames rel dir)))
    (and (probe-file path)
         (uiop:read-file-string path :external-format :utf-8))))

(defun make-tree (dir entries)
  "ENTRIES: (rel content), (rel . content), or \"rel/\" alone for an empty directory."
  (dolist (e entries dir)
    (destructuring-bind (rel &optional (content ""))
        (cond ((not (consp e)) (list e))
              ((stringp (cdr e)) (list (car e) (cdr e))) ; dotted (rel . content)
              (t e))
      (if (char= #\/ (char rel (1- (length rel))))
          (ensure-directories-exist (subdir dir rel))
          (write-file dir rel content)))))

(defun call-with-project (git fn)
  (let ((base (temp-base)))
    (unwind-protect
         (let ((project (subdir base "project/"))
               (config (subdir base "config/")))
           (ensure-directories-exist project)
           (ensure-directories-exist config)
           (when git
             (ensure-directories-exist (subdir project ".git/")))
           (funcall fn (truename project) (truename config) base))
      (delete-temp-base base))))

(defmacro with-project ((project config &key (git t) base) entries &body body)
  "PROJECT and CONFIG: fresh directories (truenames) under one temp base;
PROJECT holds ENTRIES (see MAKE-TREE) and a .git/ directory when GIT."
  (let ((b (or base (gensym "BASE"))))
    `(call-with-project ,git
                        (lambda (,project ,config ,b)
                          (declare (ignorable ,b ,config))
                          (make-tree ,project ,entries)
                          ,@body))))

(defun native (pathname)
  (uiop:native-namestring pathname))

(defun env-lookup (&rest kv)
  "A GETENV function over alternating names and values; anything else → NIL."
  (lambda (name)
    (loop for (k v) on kv by #'cddr
          when (string= k name) return v)))

;;; One run-cli call.

(defun data-dir-of (config)
  "The private data directory beside CONFIG (H3c: <base>/data/)."
  (uiop:merge-pathnames* "data/" (uiop:pathname-parent-directory-pathname config)))

(defun code (project config argv &key steps backend (model "mock") (input "")
                                      getenv (cwd t) providers
                                      (data-dir (data-dir-of config)))
  "Run RUN-CLI with ARGV in PROJECT. MODEL (unless NIL) adds --model; CWD T
adds --cwd PROJECT. The scripted BACKEND (or one made from STEPS) is provider
\"mock\". Sessions go to DATA-DIR (default <base>/data/), never the real
data directory. → (values exit-code stdout stderr backend)."
  (let* ((backend (or backend (make-scripted-backend steps)))
         (argv (append (and cwd (list "--cwd" (native project)))
                       (and model (list "--model" model))
                       argv))
         (err (make-string-output-stream))
         (exit nil)
         (out (with-output-to-string (o)
                (setf exit (run-cli argv
                                    :output o
                                    :error-output err
                                    :input (make-string-input-stream input)
                                    :providers (append providers
                                                       (list (cons "mock" (scripted-provider backend))))
                                    :user-config-dir config
                                    :data-dir data-dir
                                    :getenv (or getenv (env-lookup)))))))
    (values exit out (get-output-stream-string err) backend)))

;;; JSON.

(defun lines (string)
  "STRING split at LF; a final LF does not start an empty line."
  (let ((out '()) (start 0))
    (loop for i = (position #\Linefeed string :start start)
          while i
          do (push (subseq string start i) out)
             (setf start (1+ i)))
    (when (< start (length string))
      (push (subseq string start) out))
    (nreverse out)))

(defun json-lines (string)
  "Each line of STRING decoded as JSON."
  (mapcar #'json:decode (lines string)))

(defun jget (object &rest keys)
  "Walk string keys (hash tables) and integer indexes (vectors)."
  (dolist (k keys object)
    (setf object
          (etypecase k
            (string (and (hash-table-p object) (gethash k object)))
            (integer (and (vectorp object) (< k (length object)) (aref object k)))))))

(defun jkeys (object)
  (sort (loop for k being the hash-keys of object collect k) #'string<))

(defun events (out type)
  "Decoded stream-json lines of OUT with \"type\" TYPE."
  (remove-if-not (lambda (e) (equal type (jget e "type"))) (json-lines out)))

(defun args (&rest kv)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on kv by #'cddr do (setf (gethash k h) v))
    h))

(defun json-args (&rest kv)
  "JSON object string from alternating keys and values."
  (json:encode (apply #'args kv)))

;;; Misc.

(defun has (needle haystack)
  (and (stringp haystack) (search needle haystack) t))

(defun nl (&rest lines)
  (format nil "~{~a~%~}" lines))

(defun pick (posix cmd)
  "POSIX on Unix (/bin/sh), CMD on Windows (cmd.exe)."
  #+(or windows win32) (progn posix cmd)
  #-(or windows win32) (progn cmd posix))

(defmacro failure (form)
  "The ERROR FORM signals, or NIL when it returns."
  `(handler-case (progn ,form nil)
     (error (c) c)))

(defun rule-list (rule)
  (list (a:permission-rule-action rule) (a:permission-rule-resource rule)
        (a:permission-rule-effect rule)))

(defun rule-lists (rules)
  (mapcar #'rule-list rules))

(defun same-path (a b)
  "A and B name the same file or directory (native namestrings agree)."
  (and a b (string= (native a) (native b))))

(defun same-paths (as bs)
  (and (= (length as) (length bs)) (every #'same-path as bs)))
