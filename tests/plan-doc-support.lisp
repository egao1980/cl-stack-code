(in-package #:cl-stack-code/tests)

;;; H5c-0 helpers (src/plan-docs.lisp header). Plan documents live under the
;;; test's private data directory (DATA-DIR-OF), never ~/.local/share.

(defparameter +plan-md+
  "# Add a greeting

## Goal
Print a greeting from hello.sh.

## Findings
hello.sh is empty.

## Steps
1. Write the greeting into `hello.sh`
2. Add a test for it

## Files to change
- `hello.sh`: the greeting
- `tests/hello-test.sh`: the test

## Risks
None.

## Test plan
Run `sh tests/hello-test.sh`.
"
  "A complete plan in the :default template: two steps, two files.")

(defparameter +plan-md-2+
  "# Add a greeting

## Goal
Print a greeting from hello.sh, in French.

## Steps
1. Write \"bonjour\" into `hello.sh`
2. Add a test for it
3. Mention it in the README

## Files to change
- `hello.sh`
- `README.md`
"
  "A second revision: three steps.")

(defparameter +spec-md+
  "# Greeting

## Requirements
- WHEN the script runs THE SYSTEM SHALL print hello

## Design
One shell script.

## Files to change
- `hello.sh`

## Tasks
1. Write the script
2. Test it
"
  "A plan in the :spec template.")

(defun propose-step (&optional (markdown +plan-md+))
  "A mock step calling propose_plan with MARKDOWN."
  (list :tool "propose_plan" (json-args "markdown" markdown)))

(defun update-step (step status)
  (list :tool "update_plan" (json-args "step" step "status" status)))

(defun ask-step (question &rest options)
  (list :tool "ask_user" (if options
                             (json-args "question" question "options" (coerce options 'vector))
                             (json-args "question" question))))

(defun project-plan-docs-dir (project config)
  (plan-documents-directory project :data-dir (data-dir-of config)))

(defun project-plan-docs (project config)
  (let ((dir (project-plan-docs-dir project config)))
    (if (uiop:directory-exists-p dir) (list-plan-documents dir) '())))

(defun only-plan-doc (project config)
  "The project's single plan document (a test failure when there are 0 or several)."
  (let ((docs (project-plan-docs project config)))
    (ok (= 1 (length docs)) "exactly one plan document")
    (first docs)))

(defun fresh-plan-doc (project config &rest keys)
  (apply #'open-plan-document project :data-dir (data-dir-of config) keys))

(defun doc-md (doc)
  "plan.md as on disk (independent of the code under test)."
  (uiop:read-file-string (plan-document-path doc)))

(defun doc-file (doc rel)
  (let ((p (merge-pathnames rel (uiop:ensure-directory-pathname (plan-document-directory doc)))))
    (and (probe-file p) (uiop:read-file-string p))))

(defun step-statuses (doc)
  (mapcar #'plan-step-status (plan-document-steps doc)))

(defun plan-doc-run (project config steps &rest argv)
  "A stream-json plan-mode run of PROJECT with prompt \"go\" (argv before it).
→ (values exit out err backend)."
  (code project config (append '("-p" "--output-format" "stream-json" "--permission-mode" "plan")
                               argv '("go"))
        :steps steps))

(defun doc-events (out)
  "The stream-json plan document events of OUT (type \"plan\")."
  (events out "plan"))

(defun doc-event (out subtype)
  (find subtype (doc-events out) :key (lambda (e) (jget e "subtype")) :test #'equal))

(defun doc-events-of (out subtype)
  (remove subtype (doc-events out) :key (lambda (e) (jget e "subtype")) :test-not #'equal))

(defun result-doc (out)
  "The \"plan\" object of the last result line of OUT (:absent when missing)."
  (multiple-value-bind (v present) (gethash "plan" (car (last (events out "result"))))
    (if present v :absent)))

(defun head-record (project config session-id)
  (revision-record (session-head (open-session (project-sessions project config) session-id))))

(defun line-plan-records (project config session-id)
  "The RECORD-PLAN-DOCUMENT of each turn on the head line, oldest first, NILs dropped."
  (let ((store (open-session (project-sessions project config) session-id)))
    (remove nil (mapcar #'record-plan-document (session-records store)))))

(defun request-texts (request)
  "Every :user turn text of REQUEST, joined (the prompt the model saw)."
  (format nil "~{~a~^~%~}" (request-user-texts request)))

(defun doc-tool-result (out name)
  (find name (events out "tool_result") :key (lambda (e) (jget e "name")) :test #'equal))

(defun editor-script (config text)
  "A /bin/sh script that appends TEXT to its argument (the $EDITOR of the
program tests). → its native path."
  (let ((path (merge-pathnames "fake-editor.sh" config)))
    (write-file config "fake-editor.sh"
                (format nil "#!/bin/sh~%printf '%s\\n' '~a' >> \"$1\"~%" text))
    (chmod+x config "fake-editor.sh")
    (native path)))
