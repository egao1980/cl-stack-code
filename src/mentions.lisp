(in-package #:cl-stack-code)

;;; H3b: @path mentions.
;;;
;;; PROJECT-FILES: every file and directory under ROOT as a root-relative
;;; string with "/" separators, directories ending in "/", sorted STRING<.
;;; .gitignore / .ignore files apply (cl-stack-pathlib's :IGNORE :AUTO); a
;;; directory named ".git" and everything under it is left out; other dot
;;; files are kept. Directory symlinks are listed, not descended. At most
;;; LIMIT entries: the first LIMIT of the sorted list.
;;;
;;; MENTION-CANDIDATES: TOKEN is text-input's completion token. It must start
;;; with "@"; the query Q is the rest. An entry of FILES matches when Q occurs
;;; in it ignoring case (CHAR-EQUAL). Matches come in three groups, each in
;;; FILES order: (1) the entry starts with Q; (2) a segment after a "/"
;;; starts with Q; (3) the rest. Each candidate is "@" + the entry, at most
;;; LIMIT of them. An empty Q gives the first LIMIT entries. A token without
;;; "@" gives NIL.
;;;
;;; EXPAND-MENTIONS: a mention is "@" at the start of TEXT or after
;;; whitespace, followed by non-whitespace; trailing characters from
;;; . , ; : ! ? ) ] } " ' are not part of the path. The path is relative to
;;; ROOT. A mention naming a regular file under ROOT (no "..", no absolute
;;; path, no symlink leaving ROOT) whose content is UTF-8 is attached once, in
;;; order of first mention; anything else stays plain text. The prompt is
;;; TEXT, then for each attached file:
;;;
;;;   LF LF <file path="REL"> LF content LF </file>
;;;
;;; where REL is the mention's path as written (without the "@") and content
;;; has its trailing whitespace trimmed. Content over +MAX-MENTION-CHARS+
;;; characters is cut to that many and followed by LF
;;; "[truncated: REL is over 32000 characters]". → (values prompt rels).

(defparameter +max-mention-chars+ 32000
  "Characters of one @-mentioned file the prompt carries.")

(defun %relative-entry (root pathname)
  "PATHNAME under ROOT as a root-relative string with \"/\" separators
(directories end in \"/\"), or NIL when it is not under ROOT."
  (let ((rel (uiop:enough-pathname pathname root)))
    (unless (uiop:absolute-pathname-p rel)
      (let ((text (uiop:unix-namestring rel)))
        (and (plusp (length text)) text)))))

(defun %dot-git-entry-p (rel)
  (or (string= rel ".git/") (uiop:string-prefix-p ".git/" rel)))

(defun project-files (root &key (limit 10000))
  "→ root-relative entries under ROOT (see the file header), sorted."
  (let* ((root (uiop:ensure-directory-pathname (or (probe-file root) root)))
         (entries '()))
    (dolist (triple (p:walk root :ignore :auto))
      (destructuring-bind (dir files dirs) triple
        (declare (ignore dir))
        (dolist (entry (append files dirs))
          (let ((rel (%relative-entry root (p:path-pathname entry))))
            (when (and rel (not (%dot-git-entry-p rel)))
              (push rel entries))))))
    (let ((sorted (sort (remove-duplicates entries :test #'string=) #'string<)))
      (if (> (length sorted) limit) (subseq sorted 0 limit) sorted))))

(defun %segment-prefix-p (query entry)
  "True when a segment of ENTRY after a \"/\" starts with QUERY (ignoring case)."
  (loop for slash = (position #\/ entry) then (position #\/ entry :start (1+ slash))
        while slash
        thereis (let ((start (1+ slash)))
                  (and (<= (+ start (length query)) (length entry))
                       (string-equal query entry :start2 start
                                                 :end2 (+ start (length query)))))))

(defun mention-candidates (files token &key (limit 20))
  "→ completion candidates (\"@path\" strings) of TOKEN over FILES."
  (when (and (stringp token) (plusp (length token)) (char= #\@ (char token 0)))
    (let* ((query (subseq token 1))
           (matches (remove-if-not (lambda (entry) (search query entry :test #'char-equal))
                                   files))
           (first (remove-if-not (lambda (entry)
                                   (and (<= (length query) (length entry))
                                        (string-equal query entry :end2 (length query))))
                                 matches))
           (second (remove-if-not (lambda (entry)
                                    (and (not (member entry first :test #'eq))
                                         (%segment-prefix-p query entry)))
                                  matches))
           (rest (remove-if (lambda (entry)
                              (or (member entry first :test #'eq)
                                  (member entry second :test #'eq)))
                            matches))
           (ordered (append first second rest)))
      (mapcar (lambda (entry) (concatenate 'string "@" entry))
              (if (> (length ordered) limit) (subseq ordered 0 limit) ordered)))))

(defun %mention-whitespace-p (char)
  (member char '(#\Space #\Tab #\Newline #\Return #\Page)))

(defparameter +mention-trailing-chars+ ".,;:!?)]}\"'"
  "Characters that end a sentence after a mention; not part of its path.")

(defun %mention-rels (text)
  "The paths (without \"@\") of the mentions in TEXT, in order, with repeats."
  (let ((rels '()) (n (length text)))
    (loop for i from 0 below n
          when (and (char= #\@ (char text i))
                    (or (zerop i) (%mention-whitespace-p (char text (1- i))))
                    (< (1+ i) n)
                    (not (%mention-whitespace-p (char text (1+ i)))))
            do (let* ((end (or (position-if #'%mention-whitespace-p text :start (1+ i)) n))
                      (rel (string-right-trim +mention-trailing-chars+
                                              (subseq text (1+ i) end))))
                 (when (plusp (length rel))
                   (push rel rels))))
    (nreverse rels)))

(defun %read-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (subseq octets 0 (read-sequence octets in)))))

(defun %project-file (root rel)
  "The truename of the regular file REL names under ROOT, or NIL: no absolute
path, no \"..\", nothing whose truename leaves ROOT."
  (unless (or (zerop (length rel))
              (char= #\/ (char rel 0))
              (char= #\\ (char rel 0))
              (char= #\~ (char rel 0))
              (find #\: rel)
              (member ".." (uiop:split-string rel :separator "/\\") :test #'string=))
    (let* ((root (uiop:ensure-directory-pathname (or (probe-file root) root)))
           (path (probe-file (merge-pathnames (uiop:parse-unix-namestring rel) root))))
      (and path
           (pathname-name path)
           (uiop:subpathp path root)
           (not (uiop:directory-pathname-p path))
           path))))

(defun %file-text (path)
  "PATH's content decoded as strict UTF-8, or NIL."
  (handler-case (p:utf8-decode-strict (%read-octets path))
    (p:utf8-decoding-error () nil)))

(defun %attachment (rel content)
  (let* ((content (string-right-trim '(#\Space #\Tab #\Newline #\Return #\Page) content))
         (cut (> (length content) +max-mention-chars+)))
    (format nil "~%~%<file path=\"~a\">~%~a~:[~;~%[truncated: ~a is over ~d characters]~]~%</file>"
            rel
            (if cut (subseq content 0 +max-mention-chars+) content)
            cut rel +max-mention-chars+)))

(defun expand-mentions (text root)
  "→ (values prompt attached-rels): TEXT with the @-mentioned files of ROOT
appended (see the file header)."
  (let ((attached '()) (parts '()))
    (dolist (rel (%mention-rels text))
      (unless (member rel attached :test #'string=)
        (let* ((path (%project-file root rel))
               (content (and path (%file-text path))))
          (when content
            (push rel attached)
            (push (%attachment rel content) parts)))))
    (values (apply #'concatenate 'string text (nreverse parts))
            (nreverse attached))))
