(in-package #:cl-stack-code/tests)

;;; #67: the system compiles without a full WARNING. 0.16.0 used
;;; +TOOL-SEARCH-TOOL-NAME+ in src/mcp.lisp before src/mcp-context.lisp
;;; defined it: an undefined-variable WARNING that worked at run time but
;;; failed every build treating warnings as errors. A warning only shows on
;;; a fresh compile in an image that has not loaded the system, so the
;;; check is a child SBCL that loads the dependencies as they are (ASDF
;;; PREPARE-OP), then recompiles the named systems, counting the full
;;; WARNINGs signalled meanwhile. SBCL signals an undefined variable at the
;;; end of the compilation unit, not in its file, so the count is by time,
;;; not by file. A style-warning counts through ASDF's
;;; COMPILE-WARNED-WARNING, which is what fails a build with
;;; ASDF:*COMPILE-FILE-WARNINGS-BEHAVIOUR* :ERROR.

(defun compile-warnings-form (system forced)
  "The child's form: load the core's dependencies (cl-stack-code/acp's own
ones are cached fasls and load without compiling), then load SYSTEM with
the systems FORCED recompiled; print each full WARNING signalled meanwhile
and quit 1 if any."
  (format nil "(let ((n 0))
  (asdf:operate 'asdf:prepare-op \"cl-stack-code\")
  (handler-bind ((warning (lambda (c)
                            (unless (typep c 'style-warning)
                              (incf n)
                              (format t \"~~&FULL WARNING: ~~a~~%\" c)))))
    (asdf:load-system ~s :force '~s))
  (format t \"~~&~~d full warning(s)~~%\" n)
  (finish-output)
  (uiop:quit (if (zerop n) 0 1)))"
          system forced))

(defun compile-warnings (system forced)
  "→ the exit code of a child that recompiles FORCED (and loads SYSTEM),
and its output."
  #-sbcl (declare (ignore system forced))
  #-sbcl (error "the compile check's child is SBCL only")
  #+sbcl
  (with-project (project config) '()
    (multiple-value-bind (out err exit)
        (uiop:run-program
         (append (list (uiop:native-namestring sb-ext:*runtime-pathname*)
                       "--core" (uiop:native-namestring sb-ext:*core-pathname*) "--noinform"
                       "--dynamic-space-size" (%child-dynamic-space-size)
                       "--non-interactive" "--no-sysinit" "--no-userinit")
                 (loop for form in (append (%child-asdf-forms config)
                                           (list (compile-warnings-form system forced)))
                       append (list "--eval" form)))
         :output :string :error-output :output :ignore-error-status t)
      (declare (ignore err))
      (values exit out))))

(defun compile-warnings-summary (out)
  "→ the FULL WARNING lines and the count line of the child's OUT."
  (format nil "~{~a~^~%~}"
          (remove-if-not (lambda (line)
                           (or (search "FULL WARNING" line) (search "full warning(s)" line)))
                         (uiop:split-string out :separator '(#\Newline)))))

(deftest core-compiles-without-full-warnings
  #-sbcl (skip "the compile check's child is SBCL")
  #+sbcl
  (multiple-value-bind (exit out) (compile-warnings "cl-stack-code" '("cl-stack-code"))
    (ok (eql 0 exit) (compile-warnings-summary out))
    (ok (search "0 full warning(s)" out) "the child compiled and counted")))
