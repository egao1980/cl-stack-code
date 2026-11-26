(in-package #:cl-stack-code/acp/tests)

;;; #67: cl-stack-code/acp (and the core under it) compiles without a full
;;; WARNING (the child is the core suite's COMPILE-WARNINGS).

(deftest acp-compiles-without-full-warnings
  #-sbcl (skip "the compile check's child is SBCL")
  #+sbcl
  (multiple-value-bind (exit out)
      (cl-stack-code/tests::compile-warnings "cl-stack-code/acp"
                                             '("cl-stack-code" "cl-stack-code/acp"))
    (ok (eql 0 exit) (cl-stack-code/tests::compile-warnings-summary out))
    (ok (search "0 full warning(s)" out) "the child compiled and counted")))
