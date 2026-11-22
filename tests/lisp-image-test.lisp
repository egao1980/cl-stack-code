(in-package #:cl-stack-code/tests)

;;; H4b without an image: designators, settings, flags, checks, the source,
;;; the system prompt, the status line, the core and its views.

(defun image-layer (&rest plist)
  "A settings layer with the lispImage PLIST."
  (make-settings :lisp-image plist))

(deftest-parametrize lisp-image-designators
    ((text expected)
     :ids ("off" "spawn" "attach-port" "attach-host" "attach-name" "attach-empty" "attach-word"
           "attach-three" "attach-zero" "attach-big" "spawn-arg" "empty" "not-a-string")
     ("off" '(:off))
     ("spawn" '(:spawn))
     ("attach:4005" '(:attach "127.0.0.1" 4005))
     ("attach:10.0.0.2:4006" '(:attach "10.0.0.2" 4006))
     ("attach:localhost:1" '(:attach "localhost" 1))
     ("attach:" nil)
     ("attach:x" nil)
     ("attach:a:b:4005" nil)
     ("attach:0" nil)
     ("attach:65536" nil)
     ("spawn:1" nil)
     ("" nil)
     (4005 nil))
  (ok (equal expected (parse-lisp-image-designator text))))

(deftest lisp-image-settings-object
  (multiple-value-bind (image backend observe policy) (lisp-image-settings (make-settings))
    (ok (equal '(:off) image))
    (ok (equal "swank" backend))
    (ok (null observe))
    (ok (eq :turn policy)))
  (ok (not (lisp-image-enabled-p (make-settings))))
  (let ((s (parse-settings (lisp-settings "image" "attach:4005" "backend" "slynk"
                                          "observe" t "onDebugger" "notice"))))
    (multiple-value-bind (image backend observe policy) (lisp-image-settings s)
      (ok (equal '(:attach "127.0.0.1" 4005) image))
      (ok (equal "slynk" backend))
      (ok (eq t observe))
      (ok (eq :notice policy)))
    (ok (lisp-image-enabled-p s)))
  (let ((merged (merge-settings (parse-settings (lisp-settings "image" "spawn" "backend" "slynk"))
                                (parse-settings (lisp-settings "onDebugger" "notice"))
                                (image-layer :image '(:attach "127.0.0.1" 4005)))))
    (multiple-value-bind (image backend observe policy) (lisp-image-settings merged)
      (ok (equal '(:attach "127.0.0.1" 4005) image) "the flag layer's image wins")
      (ok (equal "slynk" backend) "keys merge one by one")
      (ok (null observe))
      (ok (eq :notice policy))))
  (ok (not (lisp-image-enabled-p (parse-settings (lisp-settings "image" "off"))))))

(deftest-parametrize lisp-image-settings-errors
    ((json key)
     :ids ("not-object" "image" "backend" "observe" "policy")
     ("{\"lispImage\": true}" "lispImage")
     ("{\"lispImage\": {\"image\": \"attach:x\"}}" "lispImage.image")
     ("{\"lispImage\": {\"backend\": \"cmucl\"}}" "lispImage.backend")
     ("{\"lispImage\": {\"observe\": \"yes\"}}" "lispImage.observe")
     ("{\"lispImage\": {\"onDebugger\": \"ignore\"}}" "lispImage.onDebugger"))
  (let ((c (failure (parse-settings json))))
    (ok (typep c 'settings-error))
    (ok (and c (equal key (settings-error-key c))))))

(deftest lisp-image-flags
  (let ((layer (invocation-settings (parse-arguments '("-p" "--lisp-image" "spawn" "hi")))))
    (ok (equal '(:spawn) (getf (settings-lisp-image layer) :image)))
    (ok (null (getf (settings-lisp-image layer) :observe))))
  (let ((layer (invocation-settings
                (parse-arguments '("-p" "--lisp-image" "attach:example.org:4005" "--lisp-observe" "hi")))))
    (ok (equal '(:attach "example.org" 4005) (getf (settings-lisp-image layer) :image)))
    (ok (eq t (getf (settings-lisp-image layer) :observe))))
  (ok (null (settings-lisp-image (invocation-settings (parse-arguments '("-p" "hi")))))
      "no flag, no layer keys")
  (let ((c (failure (parse-arguments '("-p" "--lisp-image" "fork" "hi")))))
    (ok (typep c 'code-usage-error))
    (ok (has "unknown --lisp-image \"fork\": use spawn, attach:[HOST:]PORT or off" (princ-to-string c))))
  (with-project (project config) '()
    (multiple-value-bind (exit out err) (code project config '("-p" "--lisp-image" "fork" "hi"))
      (ok (= 2 exit))
      (ok (equal "" out))
      (ok (has "--lisp-image" err)))))

(deftest-parametrize lisp-image-checks
    ((plist mode error)
     :ids ("off" "spawn" "attach" "observe-attach" "observe-spawn" "observe-off" "plan" "plan-off" "preview" "preview-off")
     ('() :default nil)
     ('(:image (:spawn)) :default nil)
     ('(:image (:attach "127.0.0.1" 4005)) :accept-edits nil)
     ('(:image (:attach "127.0.0.1" 4005) :observe t) :bypass-permissions nil)
     ('(:image (:spawn) :observe t) :default
      "--lisp-observe needs --lisp-image attach:[HOST:]PORT (an observer attaches; it does not spawn)")
     ('(:observe t) :default
      "--lisp-observe needs --lisp-image attach:[HOST:]PORT (an observer attaches; it does not spawn)")
     ('(:image (:spawn)) :plan
      "--lisp-image is not available in plan mode yet (the image would not see the plan area)")
     ('() :plan nil)
     ('(:image (:spawn)) :preview
      "--lisp-image is not available in preview mode yet (the image would not see the preview area)")
     ('() :preview nil))
  (let ((c (failure (check-lisp-image-settings (apply #'image-layer plist) mode))))
    (if error
        (ok (and (typep c 'code-usage-error) (equal error (princ-to-string c))) error)
        (ok (null c) "accepted"))))

(deftest-parametrize lisp-image-descriptions
    ((plist text)
     :ids ("spawn" "spawn-slynk" "attach" "attach-observe")
     ('(:image (:spawn)) "image (spawned, swank)")
     ('(:image (:spawn) :backend "slynk") "image (spawned, slynk)")
     ('(:image (:attach "127.0.0.1" 4005)) "image (attached 127.0.0.1:4005, swank)")
     ('(:image (:attach "10.0.0.2" 4006) :backend "slynk" :observe t)
      "image (attached 10.0.0.2:4006, slynk, observe)"))
  (ok (equal text (lisp-image-description (apply #'image-layer plist)))))

(deftest lisp-image-sources
  (with-project (project config) '()
    (let ((plain (make-code-tools project :settings (make-settings))))
      (unwind-protect (ok (= 2 (length plain)) "no image, no lisp tools (H3a)")
        (at:close-shell-tools (second plain))))
    (let ((sources (make-code-tools project :settings (image-layer :image '(:spawn)))))
      (unwind-protect
           (progn
             (ok (= 3 (length sources)))
             (ok (lt:lisp-tools-p (third sources)) "file, shell, then lisp tools")
             (ok (eq :full (lt:lisp-tools-mode (third sources))))
             (ok (same-path project (lt:lisp-tools-root (third sources))))
             (ok (member "repl-eval" (lt:lisp-tools-names (third sources)) :test #'string=))
             (ok (lt:lisp-tools-image-events-p (third sources))))
        (at:close-shell-tools (second sources))
        (when (third sources) (lt:close-lisp-tools (third sources)))))
    (let ((sources (make-code-tools project
                                    :settings (make-settings
                                               :lisp-image '(:image (:attach "127.0.0.1" 4005) :observe t)
                                               :deny (list (a:make-permission-rule "repl-eval" "*" :deny))))))
      (unwind-protect
           (progn
             (ok (eq :observe (lt:lisp-tools-mode (third sources))))
             (ok (not (member "repl-eval" (lt:lisp-tools-names (third sources)) :test #'string=))
                 "a resource-* deny hides a lisp tool")
             (ok (member "debug-state" (lt:lisp-tools-names (third sources)) :test #'string=)))
        (at:close-shell-tools (second sources))
        (when (third sources) (lt:close-lisp-tools (third sources)))))))

(deftest lisp-image-system-prompt
  (with-project (project config) '(("AGENTS.md" "Project rule."))
    (let* ((settings (image-layer :image '(:spawn)))
           (tools (lt:make-lisp-tools :root project)))
      (unwind-protect
           (let ((prompt (assemble-system-prompt project :settings settings :user-config-dir config
                                                         :lisp-image tools)))
             (ok (has (format nil "# Lisp image~%- Image: image (spawned, swank)~%") prompt))
             (ok (has (lt:lisp-tools-instructions tools) prompt))
             (ok (< (search "# Environment" prompt) (search "# Lisp image" prompt)
                    (search "Project rule." prompt))
                 "after the environment, before AGENTS.md"))
        (lt:close-lisp-tools tools)))
    (ok (not (has "# Lisp image" (assemble-system-prompt project :user-config-dir config)))
        "no image, no section")))

(defun image-state (&rest keys &key (description "image (spawned, swank)") observe
                                    (on-debugger :turn) debuggers &allow-other-keys)
  (apply #'fresh-state :cwd #p"/srv/app/"
                       :image (list :name "image" :description description :observe observe
                                    :on-debugger on-debugger :debuggers debuggers)
         (alexandria:remove-from-plist keys :description :observe :on-debugger :debuggers)))

(deftest-parametrize lisp-image-status-markers
    ((observe debuggers marker)
     :ids ("plain" "observe" "debugger" "both")
     (nil nil "λ image")
     (t nil "λ image (observe)")
     (nil '((:connection "image" :thread 7 :level 1 :condition "boom")) "λ image (debugger)")
     (t '((:connection "image" :thread 7 :level 1 :condition "boom")) "λ image (observe, debugger)"))
  (let ((left (status-line-text (image-state :observe observe :debuggers debuggers))))
    (ok (equal (format nil " mock · default · ~a · ~a" marker (native #p"/srv/app/")) left))))

(deftest lisp-image-status-without-image
  (ok (equal (format nil " mock · default · ~a" (native #p"/srv/app/"))
             (status-line-text (fresh-state :cwd #p"/srv/app/")))
      "H3b's status line is unchanged"))

(defun debugger-event (&key (thread 7) (level 1) (condition (format nil "bg boom~%more")))
  (list :image-event :kind :debugger :connection "image" :thread thread :level level
                     :condition condition :job nil
                     :notice (format nil "λ image entered the debugger (thread ~a, level ~a): bg boom"
                                     thread level)))

(deftest lisp-image-core-idle-turn
  (let ((state (image-state)))
    (multiple-value-bind (s fx) (feed state (debugger-event))
      (ok (equal '((:image-turn)) fx) "idle with onDebugger turn: an image turn starts")
      (ok (state-busy-p s))
      (ok (equal '(:notice) (kinds s)))
      (ok (equal "λ image entered the debugger (thread 7, level 1): bg boom" (entry-text (last-entry s))))
      (ok (equal '((:connection "image" :thread 7 :level 1 :condition "bg boom
more"))
                 (getf (state-image s) :debuggers))))))

(deftest lisp-image-core-busy-posts
  (let ((state (feed (image-state) '(:submit "first"))))
    (multiple-value-bind (s fx) (feed state (debugger-event))
      (ok (equal '((:post-image-events)) fx) "busy: post into the running turn")
      (ok (state-busy-p s))
      (ok (equal '(:user :notice) (kinds s))))))

(deftest lisp-image-core-notice-policy
  (let ((state (image-state :on-debugger :notice)))
    (multiple-value-bind (s fx) (feed state (debugger-event))
      (ok (null fx) "idle with onDebugger notice: nothing starts")
      (ok (not (state-busy-p s)))
      (ok (equal '(:notice) (kinds s)))
      (ok (= 1 (length (getf (state-image s) :debuggers)))))
    (multiple-value-bind (s fx) (feed (image-state :on-debugger :notice) '(:image-pending 2))
      (ok (null fx))
      (ok (not (state-busy-p s))))))

(deftest lisp-image-core-debuggers
  (let ((state (image-state :on-debugger :notice)))
    (feed state (debugger-event :thread 7) (debugger-event :thread 9) (debugger-event :thread 7))
    (ok (equal '(7 9) (mapcar (lambda (d) (getf d :thread)) (getf (state-image state) :debuggers)))
        "newest first; the same thread and level replaces")
    (feed state (debugger-event :thread 9 :level 2))
    (multiple-value-bind (s fx) (feed state '(:image-return :connection "image" :thread 9 :level 1))
      (ok (null fx))
      (ok (equal '(7) (mapcar (lambda (d) (getf d :thread)) (getf (state-image s) :debuggers)))
          "levels 1 and 2 of thread 9 are left"))
    (feed state '(:image-return :connection "other" :thread 7 :level 1))
    (ok (= 1 (length (getf (state-image state) :debuggers))) "another connection's thread 7 is not ours")
    (let ((n (length (state-transcript state))))
      (feed state '(:image-return :connection "image" :thread 7 :level 1))
      (ok (null (getf (state-image state) :debuggers)))
      (ok (= n (length (state-transcript state))) "a return adds no entry"))))

(deftest lisp-image-core-jobs-and-pending
  (let ((state (image-state)))
    (multiple-value-bind (s fx)
        (feed state '(:image-event :kind :job :connection "image" :thread nil :level nil
                      :condition nil :job "j3" :notice "λ image: job j3 done"))
      (ok (equal '((:image-turn)) fx))
      (ok (null (getf (state-image s) :debuggers)) "a job is not a debugger")
      (ok (equal "λ image: job j3 done" (entry-text (last-entry s))))))
  (multiple-value-bind (s fx) (feed (image-state) '(:image-pending 1))
    (ok (equal '((:image-turn)) fx) "events left after a turn start the next one")
    (ok (state-busy-p s)))
  (multiple-value-bind (s fx) (feed (image-state) '(:image-pending 0))
    (ok (null fx))
    (ok (not (state-busy-p s))))
  (multiple-value-bind (s fx) (feed (fresh-state) (debugger-event))
    (ok (null fx) "no image: the events change nothing")
    (ok (null (state-transcript s)))))

(deftest lisp-image-banner
  (ok (null (image-banner-text (image-state))))
  (ok (null (image-banner-text (fresh-state))))
  (ok (equal "λ image is in the debugger: bg boom (thread 7)"
             (image-banner-text
              (image-state :debuggers '((:connection "image" :thread 7 :level 1
                                         :condition "bg boom
second line"))))))
  (ok (equal "λ image is in the debugger: late boom (thread 9) (+1 more)"
             (image-banner-text
              (image-state :debuggers '((:connection "image" :thread 9 :level 1 :condition "late boom")
                                        (:connection "image" :thread 7 :level 1 :condition "bg boom")))))))

(deftest lisp-image-program-state
  (ok (null (lisp-image-state (make-settings))))
  (ok (equal '(:name "image" :description "image (attached 127.0.0.1:4005, swank, observe)"
               :observe t :on-debugger :notice :debuggers ())
             (lisp-image-state (image-layer :image '(:attach "127.0.0.1" 4005) :observe t
                                            :on-debugger :notice)))))

(deftest lisp-image-event-views
  (let ((dbg (make-instance 'lt:image-event :kind :debugger :connection "image" :thread 42 :level 1
                                            :condition (format nil "bg boom~%second")
                                            :text "<lisp-image-event …>"))
        (job (make-instance 'lt:image-event :kind :job :connection "image" :job "j2" :job-state :failed
                                            :text "<lisp-image-event …>"))
        (back (make-instance 'lt:image-event :kind :debugger-return :connection "image" :thread 42 :level 1)))
    (ok (equal "λ image entered the debugger (thread 42, level 1): bg boom" (image-event-notice dbg)))
    (ok (equal "λ image: job j2 failed" (image-event-notice job)))
    (ok (equal (list :image-event :kind :debugger :connection "image" :thread 42 :level 1
                     :condition (format nil "bg boom~%second") :job nil
                     :notice "λ image entered the debugger (thread 42, level 1): bg boom")
               (image-event-message dbg)))
    (ok (equal (list :image-event :kind :job :connection "image" :thread nil :level nil
                     :condition nil :job "j2" :notice "λ image: job j2 failed")
               (image-event-message job)))
    (ok (equal '(:image-return :connection "image" :thread 42 :level 1) (image-event-message back)))))
