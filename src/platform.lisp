(in-package #:cl-stack-code)

;;; Inherited Mach exception ports (macOS).
;;;
;;; SBCL's runtime gets hardware traps as BSD signals: brk → SIGTRAP (pending
;;; interrupts at the end of pseudo-atomic sections, internal errors,
;;; breakpoints), SIGSEGV / SIGBUS, SIGILL and SIGFPE. The kernel makes those
;;; signals only when no Mach exception port takes the exception, and task
;;; exception ports survive fork and exec. A parent with an in-process crash
;;; reporter hands its port to the processes it spawns: Zed 1.29 does, for ACP
;;; agents. That handler swallows the child's EXC_BREAKPOINT, the thread
;;; resumes at the same brk, and the image spins at full CPU without
;;; answering.
;;;
;;; RESET-INHERITED-EXCEPTION-PORTS, called first by MAIN, clears the ports for
;;; the exception types the kernel maps to those signals. EXC_CRASH,
;;; EXC_RESOURCE, EXC_GUARD and EXC_CORPSE_NOTIFY stay with the system crash
;;; reporter. Children (the Lisp image, shell jobs, MCP servers) inherit the
;;; cleared ports.

(defparameter +signal-mapped-exception-mask+
  (logior #x02 #x04 #x08 #x10 #x20 #x40)
  "EXC_MASK_BAD_ACCESS, _BAD_INSTRUCTION, _ARITHMETIC, _EMULATION, _SOFTWARE and
_BREAKPOINT: the Mach exceptions the kernel turns into the signals SBCL handles.")

(defparameter +exception-default+ 1
  "EXCEPTION_DEFAULT, the behavior passed with MACH_PORT_NULL.")

(defparameter +thread-state-none+ #+arm64 5 #-arm64 13
  "THREAD_STATE_NONE for this architecture.")

#+darwin
(progn
  (cffi:defcfun ("task_set_exception_ports" %task-set-exception-ports) :int
    (task :uint32) (mask :uint32) (new-port :uint32) (behavior :int) (flavor :int))
  (cffi:defcfun ("task_get_exception_ports" %task-get-exception-ports) :int
    (task :uint32) (mask :uint32) (masks :pointer) (count :pointer)
    (ports :pointer) (behaviors :pointer) (flavors :pointer))
  (defun %mach-task-self ()
    (cffi:mem-ref (cffi:foreign-symbol-pointer "mach_task_self_") :uint32)))

(defun exception-ports (&optional (mask +signal-mapped-exception-mask+))
  "This task's Mach exception ports for MASK: a list of (MASK PORT BEHAVIOR), one
per distinct handler, PORT 0 for none. NIL on other systems or when the call
fails."
  (declare (ignorable mask))
  #+darwin
  (cffi:with-foreign-objects ((masks :uint32 32) (count :uint32) (ports :uint32 32)
                              (behaviors :uint32 32) (flavors :int 32))
    (setf (cffi:mem-ref count :uint32) 32)
    (when (zerop (%task-get-exception-ports (%mach-task-self) mask masks count
                                            ports behaviors flavors))
      (loop for i below (cffi:mem-ref count :uint32)
            collect (list (cffi:mem-aref masks :uint32 i)
                          (cffi:mem-aref ports :uint32 i)
                          (cffi:mem-aref behaviors :uint32 i)))))
  #-darwin nil)

(defun inherited-exception-ports ()
  "The handlers installed for +SIGNAL-MAPPED-EXCEPTION-MASK+: the entries of
EXCEPTION-PORTS that have a port."
  (remove 0 (exception-ports) :key #'second))

(defun reset-inherited-exception-ports ()
  "Clear this task's Mach exception ports for +SIGNAL-MAPPED-EXCEPTION-MASK+, so
those traps reach SBCL as signals whatever the parent installed. → T when the
ports were cleared; NIL on other systems or when the call fails."
  #+darwin
  (zerop (%task-set-exception-ports (%mach-task-self) +signal-mapped-exception-mask+
                                    0 +exception-default+ +thread-state-none+))
  #-darwin nil)
