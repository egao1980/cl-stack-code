(in-package #:cl-stack-code/tests)

;;; R4d-4b: plan mode's sandbox, the API (src/sandbox.lisp header), the
;;; settings and the flag. Portable: the recording backend, plain folders.

(defmacro with-copy-plan ((plan project config) entries &body body)
  `(with-project (,project ,config) ,entries
     (let ((,plan (open-test-plan ,project ,config :copy)))
       (unwind-protect (progn ,@body)
         (when (eq :open (plan-status ,plan))
           (ignore-errors (reject-plan ,plan)))))))

;;; The backend.

(deftest sandbox-default-backend
  (let ((b (default-plan-compute-backend)))
    #+darwin (ok (typep b 'stack-compute-seatbelt:seatbelt-backend) "macOS: Seatbelt")
    #+linux (ok (typep b 'stack-compute-landlock:landlock-backend) "Linux: Landlock")
    #-(or darwin linux) (ok (null b) "no backend (Windows until R4e-1)")
    #+(or darwin linux) (ok (not (eq b (default-plan-compute-backend))) "a fresh backend per call")))

(deftest-parametrize sandbox-plan-compute-backend
    ((value expect) :ids ("default" "nil" "object")
     (:default :default)
     (nil nil)
     (:object :object))
  (let ((object (make-recording-backend)))
    (let ((*plan-compute-backend* (if (eq value :object) object value)))
      (case expect
        (:default
         (let ((b (plan-compute-backend)))
           #+(or darwin linux) (ok (typep b 'sc:confining-backend))
           #-(or darwin linux) (ok (null b))))
        ((nil) (ok (null (plan-compute-backend))))
        (:object (ok (eq object (plan-compute-backend))))))))

(deftest sandbox-plan-compute-backend-type-error
  (let ((*plan-compute-backend* "seatbelt"))
    (ok (signals (plan-compute-backend) 'type-error))))

(deftest sandbox-no-backend-reason
  #+(or windows win32) (ok (has "compute-backend-mxc" +no-sandbox-backend-reason+))
  #-(or windows win32) (ok (has "no confining backend" +no-sandbox-backend-reason+)))

;;; The scratch directory and the confinement.

(deftest sandbox-scratch-directory
  (with-copy-plan (plan project config) '(("a.txt" "alpha"))
    (let ((scratch (plan-scratch-directory plan)))
      (ok (uiop:directory-exists-p scratch) "created")
      (ok (uiop:directory-exists-p (merge-pathnames "cache/" scratch)) "with cache/")
      (ok (equal (dir-key (merge-pathnames "scratch/" (plan-directory plan))) (dir-key scratch))
          "<plan dir>/scratch/")
      (ok (not (uiop:string-prefix-p (dir-key (plan-root plan)) (dir-key scratch)))
          "outside the area")
      (ok (equal (dir-key scratch) (dir-key (plan-scratch-directory plan))) "the same dir again")
      (write-file scratch "build.log" "x")
      (ok (null (plan-changes plan)) "nothing in it is part of the projected change"))))

(deftest sandbox-plan-confinement-shape
  (with-copy-plan (plan project config) '(("a.txt" "alpha"))
    (let ((c (plan-confinement plan (plan-settings)))
          (scratch (plan-scratch-directory plan)))
      (ok (sc:confinement-p c))
      (ok (equal (list (physical-native (plan-root plan)) (physical-native scratch))
                 (mapcar #'uiop:native-namestring (sc:confinement-writable c)))
          "writable: the area, then the scratch dir, physical")
      (ok (eq :all (sc:confinement-read c)))
      (ok (equal (sc:default-deny-read) (sc:confinement-deny-read c)) "the default deny-read")
      (ok (eq :none (sc:confinement-network c)) "network off")
      (ok (eq :scrub (sc:confinement-env-mode c)))
      (ok (equal sc:+default-env-allow+ (sc:confinement-env-allow c)))
      (ok (equal (list (cons "XDG_CACHE_HOME"
                             (uiop:native-namestring (merge-pathnames "cache/" scratch))))
                 (sc:confinement-env c))
          "only XDG_CACHE_HOME; the settings env goes through the shell tools")
      (ok (eq :private (sc:confinement-tmp c)))
      (ok (null (sc:confinement-readable c)))
      (ok (every #'null (list (sc:confinement-cpu-limit c) (sc:confinement-memory-limit c)
                              (sc:confinement-file-size-limit c) (sc:confinement-process-limit c)
                              (sc:confinement-wall-clock c)))
          "no limits"))))

(deftest sandbox-plan-confinement-ignores-settings-env
  (with-copy-plan (plan project config) '()
    (let ((c (plan-confinement plan (merge-settings
                                     (make-settings :permission-mode :plan
                                                    :env '(("FOO" . "bar")))))))
      (ok (null (assoc "FOO" (sc:confinement-env c) :test #'string=))))))

(deftest-parametrize sandbox-plan-confinement-network
    ((sandbox expect) :ids ("unset" "none" "allow")
     (nil :none)
     ('(:network :none) :none)
     ('(:network :allow) :allow))
  (with-copy-plan (plan project config) '()
    (ok (eq expect (sc:confinement-network (plan-confinement plan (apply #'plan-settings sandbox)))))))

(deftest sandbox-plan-confinement-extra-writable
  (with-copy-plan (plan project config) '()
    (let* ((extra (temp-directory-named "csc-extra"))
           (c (plan-confinement plan (plan-settings :extra-writable (list extra)))))
      (unwind-protect
           (ok (equal (list (physical-native (plan-root plan))
                            (physical-native (plan-scratch-directory plan))
                            (physical-native extra))
                      (mapcar #'uiop:native-namestring (sc:confinement-writable c)))
               "after the area and the scratch dir")
        (uiop:delete-directory-tree extra :validate t :if-does-not-exist :ignore)))))

(deftest sandbox-plan-confinement-extra-writable-missing
  (with-copy-plan (plan project config) '()
    (let* ((gone (merge-pathnames "no-such-dir/" (temp-directory-named "csc-gone")))
           (c (handler-case (progn (plan-confinement plan (plan-settings :extra-writable (list gone)))
                                   nil)
                (settings-error (e) e))))
      (ok (typep c 'settings-error))
      (when (typep c 'settings-error)
        (ok (equal "sandbox.extraWritable" (settings-error-key c)))
        (ok (eql 2 (condition-exit-code c)))
        (ok (has "is not a directory" (princ-to-string c)))))))

;;; The probe.

(deftest sandbox-open-confined
  (with-copy-plan (plan project config) '(("a.txt" "alpha"))
    (let* ((b (make-recording-backend))
           (sb (open-plan-sandbox plan (plan-settings) :backend b)))
      (ok (plan-sandbox-p sb))
      (ok (eq :confined (plan-sandbox-status sb)))
      (ok (plan-sandbox-confined-p sb))
      (ok (eq plan (plan-sandbox-plan sb)))
      (ok (eq b (plan-sandbox-backend sb)))
      (ok (null (plan-sandbox-reason sb)))
      (ok (equal (mapcar #'uiop:native-namestring
                         (sc:confinement-writable (plan-confinement plan (plan-settings))))
                 (mapcar #'uiop:native-namestring
                         (sc:confinement-writable (plan-sandbox-confinement sb)))))
      (let ((canary (canary-launches b)))
        (ok (= 1 (length canary)) "one canary")
        (ok (equal (append (at:default-shell) '("exit 0")) (recorded-launch-argv (first canary))))
        (ok (equal (dir-key (plan-root plan)) (dir-key (recorded-launch-directory (first canary))))
            "the canary runs in the area"))
      (ok (null (command-launches b)) "nothing else ran")
      (ok (equal (list :confinement (plan-sandbox-confinement sb) :compute-backend b)
                 (plan-sandbox-tool-keys sb))))))

(deftest sandbox-open-uses-the-variable
  (with-copy-plan (plan project config) '()
    (with-plan-backend (b)
      (let ((sb (open-plan-sandbox plan (plan-settings))))
        (ok (eq b (plan-sandbox-backend sb)))
        (ok (= 1 (length (canary-launches b))))))))

(deftest-parametrize sandbox-open-unavailable
    ((label make expect) :ids ("no-backend" "unavailable" "feature-missing" "canary-fails")
     ("no backend" (lambda () nil) "no confining backend")
     ("backend unavailable" (lambda () (make-recording-backend :available "test: no sandbox here"))
       "test: no sandbox here")
     ("feature missing" (lambda () (make-recording-backend :features '(:filesystem :network-none)))
       "deny-read")
     ("canary fails" (lambda () (make-recording-backend :canary-exit 3))
       "the sandbox canary failed: exit 3"))
  (with-copy-plan (plan project config) '()
    (let* ((b (funcall make))
           (sb (open-plan-sandbox plan (plan-settings) :backend b)))
      (ok (eq :unavailable (plan-sandbox-status sb)) label)
      (ok (not (plan-sandbox-confined-p sb)))
      (ok (has expect (plan-sandbox-reason sb)) (plan-sandbox-reason sb))
      (ok (null (plan-sandbox-tool-keys sb)) "the shell tools are made unconfined")
      (if b
          (ok (sc:confinement-p (plan-sandbox-confinement sb)) "the confinement is kept")
          (ok (null (plan-sandbox-confinement sb))))
      (when (typep b 'recording-backend)
        (ok (null (command-launches b)))))))

(deftest sandbox-open-fail-if-unavailable
  (with-copy-plan (plan project config) '()
    (let* ((b (make-recording-backend :available "test: no sandbox here"))
           (c (handler-case (progn (open-plan-sandbox plan (plan-settings :fail-if-unavailable t)
                                                      :backend b)
                                   nil)
                (plan-sandbox-unavailable (e) e))))
      (ok (typep c 'plan-sandbox-unavailable))
      (when c
        (ok (typep c 'plan-error))
        (ok (eq plan (plan-error-plan c)))
        (ok (eq b (plan-sandbox-unavailable-backend c)))
        (ok (has "test: no sandbox here" (plan-sandbox-unavailable-reason c)))
        (ok (eql 1 (condition-exit-code c)))
        (ok (has "sandbox.failIfUnavailable" (princ-to-string c)))))
    (ok (eq :confined (plan-sandbox-status
                       (open-plan-sandbox plan (plan-settings :fail-if-unavailable t)
                                          :backend (make-recording-backend))))
        "a working sandbox opens as usual")))

(deftest sandbox-refused
  (with-copy-plan (plan project config) '()
    (let ((sb (open-plan-sandbox plan (plan-settings) :backend (make-recording-backend))))
      (ok (eq t (plan-sandbox-refused sb "test: refused on purpose")) "the first refusal → T")
      (ok (eq :refused (plan-sandbox-status sb)))
      (ok (not (plan-sandbox-confined-p sb)))
      (ok (equal "test: refused on purpose" (plan-sandbox-reason sb)))
      (ok (null (plan-sandbox-tool-keys sb)))
      (ok (null (plan-sandbox-refused sb "again")) "later ones → NIL")
      (ok (equal "test: refused on purpose" (plan-sandbox-reason sb)) "the first reason is kept"))
    (let ((sb (open-plan-sandbox plan (plan-settings) :backend nil)))
      (ok (null (plan-sandbox-refused sb "x")))
      (ok (eq :unavailable (plan-sandbox-status sb)) "unavailable stays unavailable"))))

(deftest sandbox-refused-takes-a-condition
  (with-copy-plan (plan project config) '()
    (let* ((b (make-recording-backend))
           (sb (open-plan-sandbox plan (plan-settings) :backend b))
           (cause (make-condition 'sc:confinement-unavailable :backend b :reason "gone")))
      (plan-sandbox-refused sb cause)
      (ok (equal (princ-to-string cause) (plan-sandbox-reason sb))))))

;;; Texts.

(deftest sandbox-notice-texts
  (with-copy-plan (plan project config) '()
    (let ((id8 (subseq (plan-id plan) 0 8)))
      (ok (null (plan-sandbox-notice (open-plan-sandbox plan (plan-settings)
                                                        :backend (make-recording-backend))))
          "confined: no notice")
      (let ((sb (open-plan-sandbox plan (plan-settings)
                                   :backend (make-recording-backend :available "no luck"))))
        (ok (equal (format nil "plan ~a: no sandbox (no luck); bash and job_input ask before each command" id8)
                   (plan-sandbox-notice sb))))
      (let ((sb (open-plan-sandbox plan (plan-settings) :backend (make-recording-backend))))
        (plan-sandbox-refused sb "gone")
        (ok (equal (format nil "plan ~a: the sandbox refused a command (gone); bash and job_input ask before each command from the next turn" id8)
                   (plan-sandbox-notice sb)))))))

(deftest sandbox-prompt-section
  (with-copy-plan (plan project config) '()
    (let* ((sb (open-plan-sandbox plan (plan-settings) :backend (make-recording-backend)))
           (text (plan-sandbox-section sb)))
      (ok (equal (format nil "# Sandbox~%~a" (at:confinement-description (plan-sandbox-confinement sb)))
                 text)))
    (let* ((sb (open-plan-sandbox plan (plan-settings) :backend nil))
           (text (plan-sandbox-section sb)))
      (ok (equal (format nil "# Sandbox~%There is no sandbox: ~a. Each bash and job_input call asks the user first, and a headless run (-p) refuses it. Prefer the file tools; they stay inside the plan area."
                         +no-sandbox-backend-reason+)
                 text)))))

(deftest sandbox-prompt-in-the-system-prompt
  (with-copy-plan (plan project config) '()
    (let* ((sb (open-plan-sandbox plan (plan-settings) :backend (make-recording-backend)))
           (prompt (assemble-system-prompt project :plan plan :sandbox sb
                                                   :settings (plan-settings)
                                                   :user-config-dir config))
           (feedback (search +plan-mode-feedback+ prompt))
           (section (search (plan-sandbox-section sb) prompt)))
      (ok (and feedback section (< feedback section)) "after the plan-mode section")
      (ok (null (search "# Sandbox" (assemble-system-prompt project :plan plan
                                                                    :settings (plan-settings)
                                                                    :user-config-dir config)))
          "no sandbox, no section"))))

(deftest sandbox-object
  (with-copy-plan (plan project config) '()
    (let* ((b (make-recording-backend))
           (sb (open-plan-sandbox plan (plan-settings :network :allow) :backend b))
           (o (plan-sandbox-object sb)))
      (ok (equal "confined" (jget o "status")))
      (ok (equal "recording-backend" (jget o "backend")))
      (ok (equal "allow" (jget o "network")))
      (ok (equal (list (physical-native (plan-root plan)) (physical-native (plan-scratch-directory plan)))
                 (coerce (jget o "writable") 'list)))
      (ok (eq :null (gethash "reason" o))))
    (let ((o (plan-sandbox-object (open-plan-sandbox plan (plan-settings) :backend nil))))
      (ok (equal "unavailable" (jget o "status")))
      (ok (eq :null (gethash "backend" o)))
      (ok (eq :null (gethash "network" o)))
      (ok (eq :null (gethash "writable" o)))
      (ok (equal +no-sandbox-backend-reason+ (jget o "reason"))))
    (let ((sb (open-plan-sandbox plan (plan-settings) :backend (make-recording-backend))))
      (plan-sandbox-refused sb "gone")
      (let ((o (plan-sandbox-object sb)))
        (ok (equal "refused" (jget o "status")))
        (ok (equal "none" (jget o "network")))
        (ok (equal "gone" (jget o "reason")))))))

(deftest sandbox-refusal-result
  (with-copy-plan (plan project config) '()
    (let ((sb (open-plan-sandbox plan (plan-settings) :backend (make-recording-backend))))
      (plan-sandbox-refused sb "gone")
      (ok (equal "Tool bash was not run: the sandbox refused it (gone). Nothing ran. From the next turn, bash and job_input ask the user before each command; until then, continue with the file tools."
                 (plan-sandbox-refusal-result sb "bash"))))))

;;; Given code: the tool keys, the rules, the shell tools (pass on the stubs).

(deftest sandbox-tool-keys-and-rules
  (let ((rules (rule-lists (settings-permission-rules (plan-settings)))))
    (ok (member '("bash" "*" :allow) rules :test #'equal) "confined: bash allowed (0.4.1)")
    (ok (member '("job_input" "*" :allow) rules :test #'equal)))
  (let ((rules (rule-lists (settings-permission-rules (plan-settings) :plan-shell-allowed nil))))
    (ok (not (member "bash" rules :key #'first :test #'equal)) "no sandbox: bash asks")
    (ok (not (member "job_input" rules :key #'first :test #'equal)))
    (ok (member '("write" "*" :allow) rules :test #'equal) "edits stay allowed"))
  (ok (equal (rule-lists (settings-permission-rules (merge-settings (make-settings :permission-mode :default))))
             (rule-lists (settings-permission-rules (merge-settings (make-settings :permission-mode :default))
                                                    :plan-shell-allowed nil)))
      "other modes are unchanged")
  (ok (null (plan-sandbox-tool-keys nil))))

(deftest sandbox-make-code-tools-confined
  (with-project (project config) '()
    (let* ((b (make-recording-backend))
           (c (sc:make-confinement :writable (list (native project))))
           (sources (make-code-tools project :confinement c :compute-backend b)))
      (unwind-protect
           (let* ((shell (second sources))
                  (bash (find "bash" (a:list-agent-tools shell) :key #'llm:llm-tool-name
                                                                 :test #'equal)))
             (ok (eq c (at:shell-tools-confinement shell)))
             (ok (has (at:confinement-description c) (llm:llm-tool-description bash))
                 "the bash description states the policy"))
        (at:close-shell-tools (second sources))))))

;;; Settings and the flag.

(deftest-parametrize sandbox-settings-parse
    ((json expect) :ids ("absent" "empty" "allow" "fail" "fail-false")
     ("{}" '(:none nil nil))
     ("{\"sandbox\": {}}" '(:none nil nil))
     ("{\"sandbox\": {\"network\": \"allow\"}}" '(:allow nil nil))
     ("{\"sandbox\": {\"network\": \"none\", \"failIfUnavailable\": true}}" '(:none nil t))
     ("{\"sandbox\": {\"failIfUnavailable\": false}}" '(:none nil nil)))
  (ok (equal expect (multiple-value-list (sandbox-settings (parse-settings json))))))

(deftest sandbox-settings-extra-writable
  (let ((s (parse-settings (format nil "{\"sandbox\": {\"extraWritable\": [~s, \"~~/cache-dir\"]}}"
                                   (native (uiop:temporary-directory))))))
    (ok (equal (list (dir-key (uiop:temporary-directory))
                     (dir-key (merge-pathnames "cache-dir/" (user-homedir-pathname))))
               (dir-keys (nth-value 1 (sandbox-settings s)))))))

(deftest-parametrize sandbox-settings-errors
    ((json key) :ids ("not-object" "bad-network" "network-bool" "dirs-not-array"
                      "relative-dir" "dir-not-string" "fail-not-bool")
     ("{\"sandbox\": true}" "sandbox")
     ("{\"sandbox\": {\"network\": \"maybe\"}}" "sandbox.network")
     ("{\"sandbox\": {\"network\": false}}" "sandbox.network")
     ("{\"sandbox\": {\"extraWritable\": \"/tmp\"}}" "sandbox.extraWritable")
     ("{\"sandbox\": {\"extraWritable\": [\"relative/dir\"]}}" "sandbox.extraWritable[0]")
     ((format nil "{\"sandbox\": {\"extraWritable\": [~s, 3]}}" (native (uiop:temporary-directory)))
      "sandbox.extraWritable[1]")
     ("{\"sandbox\": {\"failIfUnavailable\": \"yes\"}}" "sandbox.failIfUnavailable"))
  (let ((c (handler-case (progn (parse-settings json) nil)
             (settings-error (e) e))))
    (ok (typep c 'settings-error))
    (when c (ok (equal key (settings-error-key c))))))

(deftest sandbox-settings-user-layer-only
  (with-project (project config) '()
    (project-settings project "{\"sandbox\": {\"network\": \"allow\", \"failIfUnavailable\": true}}")
    (write-file project ".cl-stack-code/settings.local.json"
                "{\"sandbox\": {\"network\": \"allow\"}}")
    (ok (equal '(:none nil nil)
               (multiple-value-list (sandbox-settings (load-settings project :user-config-dir config))))
        "the repository cannot widen its own sandbox")
    (user-settings config "{\"sandbox\": {\"network\": \"allow\"}}")
    (ok (eq :allow (sandbox-settings (load-settings project :user-config-dir config)))
        "the user file can")
    (ok (eq :allow (sandbox-settings
                    (load-settings project :user-config-dir config
                                           :cli (make-settings :sandbox '(:network :allow))))))))

(deftest sandbox-allow-network-flag
  (let ((inv (parse-arguments '("-p" "--permission-mode" "plan" "--allow-network" "go"))))
    (ok (eq :allow (sandbox-settings (invocation-settings inv)))))
  (let ((inv (parse-arguments '("-p" "--permission-mode" "plan" "go"))))
    (ok (null (settings-sandbox (invocation-settings inv))))))
