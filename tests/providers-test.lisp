(in-package #:cl-stack-code/tests)

;;; Model designators, provider factories and the built-in providers. No
;;; request is sent: the tests only build backends.

(deftest providers-default-list
  (ok (equal '("anthropic" "openai") (mapcar #'car (default-providers))))
  (ok (every #'functionp (mapcar #'cdr (default-providers))))
  (ok (equal "anthropic" +default-model+)))

(deftest providers-anthropic-from-env
  (multiple-value-bind (backend provider model)
      (resolve-model "anthropic:claude-x"
                     :env (env-lookup "ANTHROPIC_API_KEY" "k-1"
                                      "ANTHROPIC_BASE_URL" "http://127.0.0.1:9/v1"
                                      "ANTHROPIC_MODEL" "from-env"))
    (ok (typep backend 'llm-protocol-anthropic:anthropic-backend))
    (ok (equal "anthropic" provider))
    (ok (equal "claude-x" model))
    (ok (equal "claude-x" (llm:backend-model backend)) "the designator's model wins")
    (ok (equal "k-1" (llm-protocol-anthropic:anthropic-api-key backend)))
    (ok (equal "http://127.0.0.1:9/v1" (llm-protocol-anthropic:anthropic-base-url backend))))
  (testing "provider only → *_MODEL from env"
    (multiple-value-bind (backend provider model)
        (resolve-model "anthropic" :env (env-lookup "ANTHROPIC_MODEL" "from-env"
                                                    "ANTHROPIC_AUTH_TOKEN" "tok"))
      (ok (equal "anthropic" provider))
      (ok (null model))
      (ok (equal "from-env" (llm:backend-model backend)))
      (ok (equal "tok" (llm-protocol-anthropic:anthropic-api-key backend))))))

(deftest providers-openai-from-env
  (let ((backend (resolve-model "openai:gpt-x"
                                :env (env-lookup "OPENAI_API_KEY" "k-2"
                                                 "OPENAI_BASE_URL" "http://127.0.0.1:9/v1"))))
    (ok (typep backend 'llm-protocol-openai:openai-compat-backend))
    (ok (equal "gpt-x" (llm:backend-model backend)))
    (ok (equal "k-2" (llm-protocol-openai:openai-api-key backend)))
    (ok (equal "http://127.0.0.1:9/v1" (llm-protocol-openai:openai-base-url backend)))))

(deftest providers-custom-factory
  (let* ((b (make-scripted-backend '()))
         (env (env-lookup "X" "y")))
    (multiple-value-bind (backend provider model)
        (resolve-model "mock:big" :providers (list (cons "mock" (scripted-provider b))) :env env)
      (ok (eq b backend))
      (ok (equal "mock" provider))
      (ok (equal "big" model))
      (ok (equal "big" (scripted-model b)))
      (ok (equal "y" (funcall (scripted-env b) "X")) "the factory gets the env lookup"))
    (resolve-model "mock" :providers (list (cons "mock" (scripted-provider b))))
    (ok (null (scripted-model b)) "no model → NIL")))

(deftest providers-custom-overrides-built-in
  (let ((b (make-scripted-backend '())))
    (ok (eq b (resolve-model "anthropic:x" :providers (list (cons "anthropic" (scripted-provider b))))))))

(deftest providers-unknown
  (let ((c (failure (resolve-model "nope:x"))))
    (ok (typep c 'model-not-found))
    (ok (and (typep c 'model-not-found) (equal "nope:x" (model-not-found-designator c))))
    (ok (has "nope" (princ-to-string c)))
    (ok (and (typep c 'model-not-found) (= 2 (condition-exit-code c)))))
  (testing "USE-VALUE supplies a backend"
    (let ((b (make-scripted-backend '())))
      (ok (eq b (handler-bind ((model-not-found
                                 (lambda (c)
                                   (declare (ignore c))
                                   (invoke-restart (find-restart 'use-value) b))))
                  (resolve-model "nope:x")))))))

(deftest condition-exit-codes
  (ok (= 2 (condition-exit-code (make-condition 'code-usage-error :message "x"))))
  (ok (= 2 (condition-exit-code (make-condition 'permission-rule-error :text "x("))))
  (ok (= 2 (condition-exit-code (make-condition 'settings-error :message "x"))))
  (ok (= 2 (condition-exit-code (make-condition 'model-not-found :designator "x"))))
  (ok (= 1 (condition-exit-code (make-condition 'run-failed :message "x"))))
  (ok (= 1 (condition-exit-code (make-condition 'simple-error :format-control "x")))))
