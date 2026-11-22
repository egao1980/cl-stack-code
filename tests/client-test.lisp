(in-package #:cl-stack-code/tests)

;;; H3d: the in-process SDK (src/client.lisp): the client, sessions, turns,
;;; events with stream-json's shapes, steering, interrupts, threads, the
;;; image. Every LLM call goes to the scripted mock backend.

(defun read-step (file)
  (list :tool "read" (json-args "file_path" file)))

;;; The client.

(deftest client-make-and-close
  (with-project (project config) '()
    (let ((client (make-client :cwd project :user-config-dir config
                               :data-dir (data-dir-of config) :getenv (env-lookup))))
      (ok (typep client 'code-client))
      (ok (same-path project (client-cwd client)))
      (ok (null (client-sessions client)))
      (ok (not (client-closed-p client)))
      (close-client client)
      (close-client client)
      (ok (client-closed-p client) "idempotent")
      (ok (signals (client-new-session client) 'client-closed)))))

(deftest client-bad-cwd
  (with-project (project config) '()
    (ok (signals (make-client :cwd (native (merge-pathnames "missing/" project))
                              :user-config-dir config :data-dir (data-dir-of config))
                 'code-usage-error))))

;;; Sessions.

(deftest client-new-session-init
  (with-project (project config) '(("AGENTS.md" "Rules."))
    (with-test-client (client backend events project config)
      (let* ((s (client-new-session client))
             (init (code-session-init s)))
        (ok (typep s 'code-session))
        (ok (hex-id-p (code-session-id s)))
        (ok (equal "system" (event-type init)))
        (ok (equal "init" (event-value init "subtype")))
        (ok (equal "0.15.0" (event-value init "version")))
        (ok (equal (code-session-id s) (event-value init "session_id")))
        (ok (equal (native project) (event-value init "cwd")))
        (ok (equal (native project) (event-value init "project_root")))
        (ok (equal "mock" (event-value init "model")))
        (ok (equal "default" (event-value init "permission_mode")))
        (ok (equal (append at:+file-tool-names+ at:+shell-tool-names+ at:+unit-tool-names+)
                   (coerce (event-value init "tools") 'list)))
        (ok (= 1 (length (event-value init "instructions"))) "AGENTS.md")
        (ok (eq init (first (collected events))) "the init object is the first event")
        (ok (equal (list s) (client-sessions client)))
        (ok (eq s (client-find-session client (code-session-id s))))
        (ok (null (list-sessions (project-sessions project config)))
            "nothing on disk before the first turn")))))

(deftest client-new-session-overrides
  (with-project (project config) '()
    (with-test-client (client backend events project config)
      (let ((init (code-session-init (client-new-session client :model "mock:big"
                                                                 :permission-mode :accept-edits))))
        (ok (equal "mock:big" (event-value init "model")))
        (ok (equal "acceptEdits" (event-value init "permission_mode")))
        (ok (equal "big" (scripted-model backend)) "the model reaches the provider")))))

(deftest client-new-session-errors
  (with-project (project config) '((".cl-stack-code/settings.json" "{\"maxTurns\": \"many\"}"))
    (with-test-client (client backend events project config)
      (ok (signals (client-new-session client) 'settings-error) "a bad project settings file")
      (write-file project ".cl-stack-code/settings.json" "{}")
      (ok (signals (client-new-session client :model "nope:x") 'model-not-found))
      (ok (signals (client-new-session client :session-id "zz") 'code-usage-error))
      (ok (signals (client-new-session client :cwd "missing/") 'code-usage-error))
      (ok (null (client-sessions client)) "nothing stays open")
      (ok (null (collected events)) "no init event"))))

(deftest client-session-id-exists
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("one"))
      (let* ((id "0123456789abcdef0123456789abcdef")
             (s (client-new-session client :session-id id)))
        (ok (equal id (code-session-id s)))
        (client-query s "first" :timeout 30)
        (client-close-session s)
        (let ((c (failure (client-new-session client :session-id id))))
          (ok (typep c 'code-usage-error))
          (ok (has "already exists" (princ-to-string c))))))))

;;; Turns.

(deftest client-query-result
  (with-project (project config) '(("a.txt" "alpha
"))
    (with-test-client (client backend events project config
                       :steps (list (read-step "a.txt") "It says alpha."))
      (let ((s (client-new-session client)))
        (multiple-value-bind (result turn-events) (client-query s "read it" :timeout 30)
          (ok (equal "result" (event-type result)))
          (ok (equal "success" (event-value result "subtype")))
          (ok (null (event-value result "is_error")))
          (ok (equal "It says alpha." (event-value result "result")))
          (ok (eq :null (event-value result "error")))
          (ok (eql 2 (event-value result "num_turns")))
          (ok (equal '(20 10 4 2) (usage-of result)))
          (ok (equal (code-session-id s) (event-value result "session_id")))
          (ok (equal '("duration_ms" "error" "is_error" "num_turns" "permission_denials"
                       "result" "session_id" "subtype" "type" "usage")
                     (jkeys result))
              "-p's result keys")
          (ok (eq result (car (last turn-events))) "the result comes last")
          (ok (equal '("assistant" "tool_use" "tool_result" "assistant" "result")
                     (remove "text_delta" (event-types turn-events) :test #'string=)))
          (ok (equal "It says alpha."
                     (format nil "~{~a~}" (mapcar (lambda (e) (event-value e "text"))
                                                  (remove-if-not (lambda (e) (and (equal "text_delta" (event-type e))
                                                                                  (eql 2 (event-value e "step"))))
                                                                 turn-events))))
              "the deltas of step 2")
          (ok (every (lambda (e) (equal (code-session-id s) (event-value e "session_id"))) turn-events))
          (ok (= 2 (length (scripted-requests backend)))))))))

(deftest client-events-are-stream-json
  (let ((steps (list (read-step "a.txt") (list :tool "ls" "{}") "Done reading.")))
    (with-project (project config) '(("a.txt" "alpha
"))
      (let ((lines (rest (json-lines (nth-value 1 (code project config
                                                       '("-p" "--output-format" "stream-json" "go")
                                                       :steps steps))))))
        (with-project (project2 config2) '(("a.txt" "alpha
"))
          (with-test-client (client backend events project2 config2 :steps steps)
            (let ((sdk (nth-value 1 (client-query (client-new-session client) "go" :timeout 30))))
              (ok (same-events-p lines sdk)
                  "the same objects as -p's stream-json lines after init (session_id and duration_ms aside)"))))))))

(deftest client-turn-committed-before-result
  (with-project (project config) '()
    (let ((seen :none))
      (with-test-client (client backend events project config :steps '("Hello."))
        (let ((s (client-new-session client)))
          (client-query s "hi" :timeout 30
                               :on-event (lambda (session event)
                                           (when (equal "result" (event-type event))
                                             (setf seen (mapcar #'record-prompt
                                                                (session-dir-records project config
                                                                                     (code-session-id session)))))))
          (ok (equal '("hi") seen) "the record is on disk when the result is delivered"))))))

(deftest client-conversation-continues
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("One." "Two."))
      (let ((s (client-new-session client)))
        (client-query s "first" :timeout 30)
        (client-query s "second" :timeout 30)
        (let ((texts (request-user-texts (second (scripted-requests backend)))))
          (ok (equal '("first" "second") texts) "the history goes with the second turn"))
        (ok (has "One." (request-text (second (scripted-requests backend)))))
        (ok (equal '("first" "second")
                   (mapcar #'record-prompt (session-dir-records project config (code-session-id s)))))))))

(deftest client-two-sessions
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("A." "B."))
      (let* ((a (client-new-session client))
             (b (client-new-session client)))
        (ok (not (equal (code-session-id a) (code-session-id b))))
        (ok (equal (list a b) (client-sessions client)) "oldest first")
        (ok (equal "A." (event-value (client-query a "to a" :timeout 30) "result")))
        (ok (equal "B." (event-value (client-query b "to b" :timeout 30) "result")))
        (ok (equal '("to b") (request-user-texts (second (scripted-requests backend))))
            "b's turn does not carry a's conversation")
        (ok (= 2 (length (events-of events "result"))))
        (ok (equal (list (code-session-id a) (code-session-id b))
                   (mapcar (lambda (e) (event-value e "session_id")) (events-of events "result"))))))))

(deftest client-resume
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("One." "Two."))
      (let* ((s (client-new-session client))
             (id (code-session-id s)))
        (client-query s "first" :timeout 30)
        (client-close-session s)
        (ok (null (client-find-session client id)))
        (let* ((r (client-resume-session client (subseq id 0 6)))
               (init (code-session-init r)))
          (ok (equal id (code-session-id r)) "a prefix resumes")
          (ok (eql 1 (event-value init "turns")))
          (ok (eq r (client-resume-session client id)) "already open: the same session")
          (ok (= 2 (length (events-of events "system"))) "no init event for that")
          (client-query r "second" :timeout 30)
          (ok (equal '("first" "second") (request-user-texts (second (scripted-requests backend))))))
        (ok (signals (client-resume-session client "ffffffff") 'session-not-found))))))

(deftest client-resume-last-and-fork
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("One." "Two."))
      (let* ((s (client-new-session client))
             (id (code-session-id s)))
        (client-query s "first" :timeout 30)
        (client-close-session s)
        (ok (equal id (code-session-id (client-resume-session client :last))) ":last is --continue")
        (client-close-session (client-find-session client id))
        (let* ((f (client-resume-session client id :fork t))
               (init (code-session-init f)))
          (ok (not (equal id (code-session-id f))))
          (ok (equal id (event-value init "forked_from")))
          (ok (eql 1 (event-value init "turns")))
          (client-query f "in the fork" :timeout 30)
          (ok (equal '("first") (mapcar #'record-prompt (session-dir-records project config id)))
              "the source is unchanged")
          (ok (equal '("first" "in the fork")
                     (mapcar #'record-prompt (session-dir-records project config (code-session-id f))))))))))

(deftest client-fork-session-at
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("One." "Two." "Three."))
      (let ((s (client-new-session client)))
        (client-query s "first" :timeout 30)
        (client-query s "second" :timeout 30)
        (let* ((f (client-fork-session s :at 1))
               (init (code-session-init f)))
          (ok (equal (code-session-id s) (event-value init "forked_from")))
          (ok (eql 1 (event-value init "turns")))
          (ok (equal (list s f) (client-sessions client)))
          (client-query f "other second" :timeout 30)
          (ok (equal '("first" "other second") (request-user-texts (third (scripted-requests backend))))
              "the fork's conversation stops at turn 1")
          (ok (= 2 (length (session-dir-records project config (code-session-id s))))))
        (ok (signals (client-fork-session s :at "ffffffff") 'session-turn-not-found))))))

(deftest client-list-sessions-objects
  (with-project (project config) '()
    (with-test-client (client backend events project config :steps '("One." "Two."))
      (let ((a (client-new-session client))
            (b (client-new-session client)))
        (client-query a "alpha prompt
second line" :timeout 30)
        (sleep 1.1)
        (client-query b "beta prompt" :timeout 30)
        (client-close-session a)
        (let ((list (client-list-sessions client)))
          (ok (= 2 (length list)))
          (ok (equal (list (code-session-id b) (code-session-id a))
                     (mapcar (lambda (o) (event-value o "session_id")) list))
              "newest first")
          (let ((ob (first list)) (oa (second list)))
            (ok (equal '("head" "open" "prompt" "session_id" "turns" "updated_at") (jkeys ob)))
            (ok (eql 1 (event-value ob "turns")))
            (ok (equal "beta prompt" (event-value ob "prompt")))
            (ok (eq t (event-value ob "open")))
            (ok (null (event-value oa "open")))
            (ok (equal "alpha prompt" (event-value oa "prompt")) "the first line")
            (ok (integerp (event-value oa "updated_at")))
            (ok (stringp (event-value oa "head")))))))))

(deftest client-close-session-refuses-later-calls
  (with-project (project config) '()
    (with-test-client (client backend events project config)
      (let ((s (client-new-session client)))
        (ok (eq t (client-close-session s)))
        (ok (eq t (client-close-session s)) "idempotent")
        (ok (signals (client-turn s "hi") 'session-not-open))
        (ok (null (client-sessions client)))))))

(deftest client-turn-busy
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-test-client (client backend events project config
                         :steps (list (list :gate gate "First.") "Second."))
        (let* ((s (client-new-session client))
               (turn (client-turn s "one")))
          (ok (typep turn 'code-turn))
          (ok (wait-until (lambda () (gate-waiting-p gate))))
          (ok (client-busy-p s))
          (let ((c (failure (client-turn s "two"))))
            (ok (typep c 'turn-busy) "one turn at a time")
            (ok (equal (code-session-id s) (and c (turn-busy-session-id c)))))
          (open-gate gate)
          (ok (equal "First." (event-value (client-wait turn :timeout 30) "result")))
          (ok (code-turn-done-p turn))
          (ok (not (client-busy-p s)))
          (ok (equal "Second." (event-value (client-query s "two" :timeout 30) "result"))))))))

(deftest client-interrupt
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-test-client (client backend events project config
                         :steps (list (list :gate gate "Never seen.")))
        (let* ((s (client-new-session client))
               (turn (client-turn s "slow")))
          (ok (null (client-interrupt (client-new-session client))) "idle: NIL")
          (ok (wait-until (lambda () (gate-waiting-p gate))))
          (ok (eq t (client-interrupt s)))
          (open-gate gate)
          (let ((result (client-wait turn :timeout 30)))
            (ok (equal "error_during_execution" (event-value result "subtype")))
            (ok (has "interrupted" (event-value result "error"))))
          (ok (eq :canceled (record-finish (first (session-dir-records project config (code-session-id s))))))
          (ok (not (client-busy-p s))))))))

(deftest client-steer-taken
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-test-client (client backend events project config
                         :steps (list (list :gate gate (list :tool "ls" "{}")) "Saw both."))
        (let* ((s (client-new-session client))
               (turn (client-turn s "list files")))
          (ok (wait-until (lambda () (gate-waiting-p gate))))
          (ok (eq t (client-steer s "also check b")))
          (open-gate gate)
          (let ((result (client-wait turn :timeout 30)))
            (ok (equal "success" (event-value result "subtype"))))
          (let ((steering (events-of (code-turn-events turn) "steering")))
            (ok (= 1 (length steering)))
            (ok (equal "taken" (event-value (first steering) "subtype")))
            (ok (equalp #("also check b") (event-value (first steering) "texts"))))
          (ok (= 2 (length (scripted-requests backend))) "no extra request")
          (ok (has "also check b" (request-text (second (scripted-requests backend)))))
          (ok (equal '("also check b")
                     (record-steering (first (session-dir-records project config (code-session-id s)))))))))))

(deftest client-steer-without-a-turn
  (with-project (project config) '()
    (with-test-client (client backend events project config)
      (let* ((s (client-new-session client))
             (c (failure (client-steer s "hello"))))
        (ok (typep c 'turn-not-running))
        (ok (equal (code-session-id s) (and c (turn-not-running-session-id c))))))))

(deftest client-steer-dropped-on-interrupt
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-test-client (client backend events project config
                         :steps (list (list :gate gate "Never seen.")))
        (let* ((s (client-new-session client))
               (turn (client-turn s "slow")))
          (ok (wait-until (lambda () (gate-waiting-p gate))))
          (client-steer s "late thought")
          (client-interrupt s)
          (open-gate gate)
          (client-wait turn :timeout 30)
          (let ((types (event-types (code-turn-events turn))))
            (ok (equal '("steering" "result") (last types 2)) "dropped steering, then the result"))
          (let ((dropped (first (events-of (code-turn-events turn) "steering"))))
            (ok (equal "dropped" (event-value dropped "subtype")))
            (ok (equalp #("late thought") (event-value dropped "texts")))))))))

(deftest client-mentions
  (with-project (project config) '(("a.txt" "alpha
") ("b.txt" "beta
"))
    (with-test-client (client backend events project config :steps '("Seen."))
      (let ((s (client-new-session client)))
        (ok (signals (client-turn s "look" :mentions '("missing.txt")) 'code-usage-error))
        (ok (signals (client-turn s "look" :mentions '("../outside.txt")) 'code-usage-error))
        (ok (null (scripted-requests backend)) "nothing ran")
        (client-query s "look @a.txt" :mentions '("b.txt" "a.txt") :timeout 30)
        (let ((text (first (request-user-texts (first (scripted-requests backend))))))
          (ok (has "<file path=\"a.txt\">" text))
          (ok (has "<file path=\"b.txt\">" text))
          (ok (< (search "a.txt\">" text) (search "b.txt\">" text)) "the text's own first")
          (ok (= 1 (count-matches "<file path=\"a.txt\">" text)) "a.txt once"))
        (ok (equal '("look @a.txt")
                   (mapcar #'record-prompt (session-dir-records project config (code-session-id s))))
            "the record keeps the prompt as given")))))

(defun count-matches (needle text)
  (loop with start = 0
        for i = (search needle text :start2 start)
        while i count t do (setf start (1+ i))))

(deftest client-blank-prompt
  (with-project (project config) '()
    (with-test-client (client backend events project config)
      (let ((s (client-new-session client)))
        (ok (signals (client-turn s "   ") 'code-usage-error))
        (ok (not (client-busy-p s)))))))

(deftest client-wait-timeout
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-test-client (client backend events project config
                         :steps (list (list :gate gate "Late.")))
        (let ((turn (client-turn (client-new-session client) "slow")))
          (ok (null (client-wait turn :timeout 0.3)))
          (ok (not (code-turn-done-p turn)))
          (open-gate gate)
          (ok (equal "Late." (event-value (client-wait turn :timeout 30) "result")))
          (ok (eq (client-wait turn) (code-turn-result turn)) "a finished turn answers at once"))))))

(deftest client-query-timeout-interrupts
  (with-project (project config) '()
    (let* ((gate (make-gate))
           (opener (bt:make-thread (lambda () (sleep 1.5) (open-gate gate)))))
      (with-test-client (client backend events project config
                         :steps (list (list :gate gate "Too late.")))
        (let ((result (client-query (client-new-session client) "slow" :timeout 0.5)))
          (ok (equal "error_during_execution" (event-value result "subtype")))
          (ok (has "interrupted" (event-value result "error")))))
      (bt:join-thread opener))))

(deftest client-max-turns-and-failures
  (with-project (project config) '()
    (with-test-client (client backend events project config
                       :settings (make-settings :max-turns 1)
                       :steps (list (list :tool "ls" "{}") '(:error "backend exploded") "Fine."))
      (let ((s (client-new-session client)))
        (let ((r (client-query s "go" :timeout 30)))
          (ok (equal "error_max_turns" (event-value r "subtype")))
          (ok (has "max turns (1)" (event-value r "error"))))
        (let ((r (client-query s "again" :timeout 30)))
          (ok (equal "error_during_execution" (event-value r "subtype")))
          (ok (has "backend exploded" (event-value r "error"))))
        (ok (equal "Fine." (event-value (client-query s "once more" :timeout 30) "result"))
            "the session goes on")
        (ok (equal '(:max-steps :failed :stop)
                   (mapcar #'record-finish (session-dir-records project config (code-session-id s)))))))))

(deftest client-conflict-forks-the-session
  (with-project (project config) '()
    (let ((gate (make-gate)))
      (with-test-client (client backend events project config
                         :steps (list "One." (list :gate gate "Two.")))
        (let* ((s (client-new-session client))
               (old (code-session-id s)))
          (client-query s "first" :timeout 30)
          (let ((turn (client-turn s "mine")))
            (ok (wait-until (lambda () (gate-waiting-p gate))))
            ;; Another process commits to the same session meanwhile.
            (commit (open-session (project-sessions project config) old) "from another process")
            (open-gate gate)
            (let* ((result (client-wait turn :timeout 30))
                   (new (event-value result "session_id"))
                   (forked (first (events-of (code-turn-events turn) "session"))))
              (ok (not (equal old new)))
              (ok (equal new (code-session-id s)))
              (ok (equal "forked" (event-value forked "subtype")))
              (ok (equal old (event-value forked "from")))
              (ok (equal new (event-value forked "session_id")))
              (ok (equal '("first" "from another process")
                         (line-prompts (open-session (project-sessions project config) old))))
              (ok (equal '("first" "mine")
                         (line-prompts (open-session (project-sessions project config) new)))))))))))

;;; Threads and callbacks.

(deftest client-callbacks-on-the-loop-thread
  (with-project (project config) '()
    (let ((threads (make-collector))
          (inline :none)
          (wait-refused :none))
      (with-test-client (client backend events project config :steps '("Hi."))
        (let ((s (client-new-session client)))
          (client-query s "hi" :timeout 30
                               :on-event (lambda (session event)
                                           (collect threads (bt:current-thread))
                                           (when (equal "result" (event-type event))
                                             ;; A client call inside a callback runs at once.
                                             (setf inline (client-find-session client (code-session-id session)))
                                             (setf wait-refused
                                                   (handler-case (progn (client-wait (client-turn session "x")) nil)
                                                     (code-usage-error () :refused)
                                                     (turn-busy () :busy)
                                                     (error (e) e))))))
          (ok (plusp (length (collected threads))))
          (ok (= 1 (length (remove-duplicates (collected threads)))) "one thread")
          (ok (not (eq (bt:current-thread) (first (collected threads)))) "not the caller's")
          (ok (eq s inline) "no deadlock")
          (ok (member wait-refused '(:refused :busy)) (format nil "got ~s" wait-refused)))))))

(deftest client-callback-errors-are-dropped
  (with-project (project config) '()
    (let ((backend (make-scripted-backend '("Fine."))))
      (with-client (client :cwd project :settings (make-settings :model "mock")
                           :providers (list (cons "mock" (scripted-provider backend)))
                           :user-config-dir config :data-dir (data-dir-of config)
                           :getenv (env-lookup)
                           :on-event (lambda (s e) (declare (ignore s e)) (error "callback bug")))
        (ok (equal "success" (event-value (client-query (client-new-session client) "hi" :timeout 30)
                                          "subtype")))))))

;;; Introspection.

(deftest client-settings-object
  (with-project (project config)
      '((".cl-stack-code/settings.json"
         "{\"permissions\": {\"allow\": [\"read\"], \"deny\": [\"bash(rm *)\"]}, \"env\": {\"SECRET_KEY\": \"s3cr3t\", \"A\": \"1\"}}"))
    (with-test-client (client backend events project config :settings (make-settings :max-turns 7))
      (let* ((s (client-new-session client :permission-mode :accept-edits))
             (o (client-settings s))
             (settings (event-value o "settings")))
        (ok (equal '("files" "settings") (jkeys o)))
        (ok (equal "mock" (event-value settings "model")))
        (ok (eql 7 (event-value settings "maxTurns")))
        (ok (equal "acceptEdits" (event-value settings "permissionMode")) "the session's override")
        (ok (equalp #("read") (event-value settings "permissions" "allow")))
        (ok (equalp #("bash(rm *)") (event-value settings "permissions" "deny")))
        (ok (equalp #("A" "SECRET_KEY") (event-value settings "env")) "names only, sorted")
        (ok (not (has "s3cr3t" (json:encode o))) "never a value")
        (ok (eq t (event-value settings "checkpoints" "enabled")))
        (ok (equal "off" (event-value settings "lispImage" "image")))
        (ok (member (native (merge-pathnames ".cl-stack-code/settings.json" project))
                    (coerce (event-value o "files") 'list) :test #'equal))
        (ok (eq :null (event-value (event-value (client-settings client) "settings") "permissionMode"))
            "the client's: no override")))))

(deftest client-tools-list
  (with-project (project config) '()
    (with-test-client (client backend events project config)
      (let* ((s (client-new-session client))
             (tools (client-tools s)))
        (ok (equal (coerce (event-value (code-session-init s) "tools") 'list)
                   (mapcar (lambda (o) (event-value o "name")) tools)))
        (ok (every (lambda (o) (equal '("description" "input_schema" "name") (jkeys o))) tools))
        (ok (every (lambda (o) (and (stringp (event-value o "description"))
                                    (hash-table-p (event-value o "input_schema"))))
                   tools))))))

;;; The image (H4b): real ros +Q run images with Swank.

(deftest client-image-event-during-a-turn
  (with-project (project config) '()
    (with-test-client (client backend events project config
                       :settings (make-settings :lisp-image '(:image (:spawn))
                                                :allow (list (parse-permission-rule "repl-eval" :allow)))
                       :steps (list (list :tool "repl-eval" (json-args "code" +bg-error+)) "Seen it."))
      (let ((s (client-new-session client)))
        (ok (event-value (code-session-init s) "lisp_image") "the init object has the image")
        (multiple-value-bind (result turn-events) (client-query s "watch" :timeout 120)
          (ok (equal "success" (event-value result "subtype")))
          (let ((event (first (events-of turn-events "image_event"))))
            (ok event "an image_event in the turn")
            (ok (equal "debugger" (event-value event "kind")))
            (ok (uiop:string-prefix-p +image-tag+ (event-value event "text"))))
          (ok (= 1 (length (request-image-turns (second (scripted-requests backend)))))
              "posted into the run before its next generate"))))))

(deftest client-image-event-while-idle-waits-for-the-next-turn
  (with-project (project config) '()
    (with-test-client (client backend events project config
                       :settings (make-settings :lisp-image '(:image (:spawn))
                                                :allow (list (parse-permission-rule "repl-eval" :allow)))
                       :steps (list (list :tool "repl-eval" (json-args "code" +late-error+)) "Started."
                                    "Handled."))
      (let ((s (client-new-session client)))
        (client-query s "start it" :timeout 120)
        (ok (wait-event events (type-is "image_event") :timeout 30) "delivered while idle")
        (sleep 1)
        (ok (= 2 (length (scripted-requests backend))) "no turn starts by itself")
        (ok (not (client-busy-p s)))
        (client-query s "what happened?" :timeout 60)
        (let* ((request (third (scripted-requests backend)))
               (users (remove :user (request-turns request) :key #'llm:llm-turn-role :test-not #'eq)))
          (ok (= 1 (length (request-image-turns request))) "the next turn carries it")
          (ok (has "what happened?" (turn-text* (car (last users 2)))) "right after the prompt")
          (ok (image-turn-p* (car (last users)))))))))
