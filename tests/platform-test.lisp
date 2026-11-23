(in-package #:cl-stack-code/tests)

;;; RESET-INHERITED-EXCEPTION-PORTS (platform.lisp): a Mach exception port the
;;; parent installed (Zed's crash reporter) must not take the traps SBCL needs
;;; as signals.

(deftest signal-mapped-exception-mask
  (testing "BAD_ACCESS, BAD_INSTRUCTION, ARITHMETIC and BREAKPOINT are cleared"
    (dolist (bit '(#x02 #x04 #x08 #x40))
      (ok (logtest bit cl-stack-code::+signal-mapped-exception-mask+))))
  (testing "CRASH, RESOURCE, GUARD and CORPSE_NOTIFY stay with the crash reporter"
    (dolist (bit '(#x400 #x800 #x1000 #x2000))
      (ok (not (logtest bit cl-stack-code::+signal-mapped-exception-mask+))))))

#+darwin
(progn
  (cffi:defcfun ("mach_port_allocate" %mach-port-allocate) :int
    (task :uint32) (right :uint32) (name :pointer))
  (cffi:defcfun ("mach_port_insert_right" %mach-port-insert-right) :int
    (task :uint32) (name :uint32) (poly :uint32) (type :uint32))
  (cffi:defcfun ("mach_port_destroy" %mach-port-destroy) :int
    (task :uint32) (name :uint32))
  (defun %make-exception-port (task)
    "A new port with receive and send rights (MACH_PORT_RIGHT_RECEIVE,
MACH_MSG_TYPE_MAKE_SEND)."
    (cffi:with-foreign-object (name :uint32)
      (assert (zerop (%mach-port-allocate task 1 name)))
      (let ((port (cffi:mem-ref name :uint32)))
        (assert (zerop (%mach-port-insert-right task port port 20)))
        port))))

#+darwin
(deftest reset-clears-an-inherited-port
  ;; A port for EXC_SOFTWARE (#x20), which SBCL never raises, stands in for
  ;; the parent's: one for EXC_BREAKPOINT would hang this image on its next
  ;; trap, as it hung the agent under Zed.
  (let* ((task (cl-stack-code::%mach-task-self))
         (port (%make-exception-port task))
         (none cl-stack-code::+thread-state-none+))
    (unwind-protect
         (progn
           (ok (zerop (cl-stack-code::%task-set-exception-ports task #x20 port 1 none)))
           (ok (find port (cl-stack-code::inherited-exception-ports) :key #'second))
           (ok (cl-stack-code::reset-inherited-exception-ports))
           (ok (null (cl-stack-code::inherited-exception-ports))))
      (cl-stack-code::%task-set-exception-ports task #x20 0 1 none)
      (%mach-port-destroy task port))))
