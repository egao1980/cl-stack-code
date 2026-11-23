(in-package #:cl-stack-code/tests)

;;; H3e-1: skills (src/skills.lisp): roots, the SKILL.md format, precedence,
;;; the listing, the skill tool and its permission.

(defun skill-names (skills)
  (mapcar #'steer:steer-directive-name skills))

(defun write-skill (dir rel name description &rest keys)
  "SKILL.md at DIR/REL<name>/SKILL.md (REL a root like \".claude/skills/\")."
  (write-file dir (format nil "~a~a/SKILL.md" rel name) (apply #'skill-md name description keys)))

;;; Roots.

(deftest skills-roots-order
  (with-project (project config) '(".cl-stack-code/skills/" ".claude/skills/" ".lisp-workspace/skills/")
    (ensure-directories-exist (subdir config "skills/"))
    (let* ((extra (ensure-directories-exist (subdir config "extra-skills/")))
           (roots (skill-roots project :settings (make-settings :skill-dirs (list extra))
                                       :user-config-dir config)))
      (ok (same-paths (list (subdir project ".cl-stack-code/skills/")
                            (subdir project ".claude/skills/")
                            (subdir project ".lisp-workspace/skills/")
                            (subdir config "skills/")
                            extra)
                      (mapcar #'car roots)))
      (ok (equal +skill-source-names+ (mapcar #'cdr roots)))
      (ok (equal '("project" "claude" "lisp-workspace" "user" "setting") +skill-source-names+)))))

(deftest skills-roots-skip-missing
  (with-project (project config) '(".claude/skills/")
    (let ((roots (skill-roots project :user-config-dir config)))
      (ok (equal '("claude") (mapcar #'cdr roots))
          "no .lisp-workspace/, no user skills/: only the roots that exist"))))

(deftest skills-roots-from-project-root
  (with-project (project config) '(".claude/skills/" "src/deep/")
    (ok (same-paths (list (subdir project ".claude/skills/"))
                    (mapcar #'car (skill-roots (subdir project "src/deep/") :user-config-dir config)))
        "the project root, not the cwd")))

;;; The format.

(deftest skills-parse-folded-description
  (with-project (project config) '()
    (let* ((path (write-skill project ".claude/skills/" "rove"
                              "Rove quick ref (ok / signals). For policy use cl-unit-testing."
                              :body "# Rove

Use ok."))
           (skill (parse-skill-file path)))
      (ok (eq :skill (steer:steer-directive-kind skill)))
      (ok (equal "rove" (steer:steer-directive-name skill)))
      (ok (equal "Rove quick ref (ok / signals). For policy use cl-unit-testing."
                 (steer:steer-directive-description skill))
          "a folded >- scalar is one line (yaml-protocol, not a line parser)")
      (ok (equal (format nil "# Rove~%~%Use ok.") (steer:steer-directive-body skill)))
      (ok (same-path (subdir project ".claude/skills/rove/") (skill-directory skill))))))

(deftest skills-parse-quoted-and-extra-keys
  (with-project (project config) '((".claude/skills/pdf/SKILL.md" "---
name: \"pdf\"
description: 'Read PDFs: text, tables'
license: MIT
metadata:
  author: someone
---
Body.
"))
    (let ((skill (parse-skill-file (merge-pathnames ".claude/skills/pdf/SKILL.md" project))))
      (ok (equal "pdf" (steer:steer-directive-name skill)))
      (ok (equal "Read PDFs: text, tables" (steer:steer-directive-description skill))
          "quotes removed, the colon kept"))))

(deftest-parametrize skills-bad-frontmatter
    ((dir text reason)
     :ids ("none" "bad-yaml" "no-name" "bad-name" "dir-mismatch" "long-name" "no-description" "blank-description")
     ("plain" "Just text.
" "no frontmatter")
     ("broken" "---
name: [broken
description: x
---
" "bad frontmatter")
     ("anon" "---
description: x
---
" "name is missing")
     ("Upper" "---
name: Upper
description: x
---
" "name \"Upper\" is not lowercase letters, digits and hyphens (at most 64)")
     ("there" "---
name: here
description: x
---
" "name \"here\" does not match its directory \"there\"")
     ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "---
name: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
description: x
---
" "is not lowercase letters, digits and hyphens (at most 64)")
     ("quiet" "---
name: quiet
---
" "description is missing")
     ("blank" "---
name: blank
description: \"  \"
---
" "description is missing"))
  (with-project (project config) '()
    (let* ((path (write-file project (format nil ".claude/skills/~a/SKILL.md" dir) text))
           (c (failure (parse-skill-file path))))
      (ok (typep c 'skill-format-error))
      (when (typep c 'skill-format-error)
        (ok (same-path path (skill-format-error-path c)))
        (ok (has reason (skill-format-error-reason c)))
        (ok (uiop:string-prefix-p (format nil "skill at ~a: " (native (truename path)))
                                  (princ-to-string c)))))))

;;; Discovery.

(deftest skills-precedence-first-wins
  (with-project (project config) '()
    (write-skill project ".cl-stack-code/skills/" "lint" "Project lint.")
    (write-skill project ".claude/skills/" "lint" "Claude lint.")
    (write-skill project ".claude/skills/" "build" "Claude build.")
    (write-skill project ".lisp-workspace/skills/" "asdf" "Workspace asdf.")
    (write-skill config "skills/" "build" "User build.")
    (write-skill config "skills/" "notes" "User notes.")
    (let ((extra (subdir config "more/")))
      (write-skill extra "" "notes" "Setting notes.")
      (write-skill extra "" "zeta" "Setting zeta.")
      (multiple-value-bind (skills notes)
          (discover-skills project :settings (make-settings :skill-dirs (list extra))
                                   :user-config-dir config)
        (ok (equal '("lint" "build" "asdf" "notes" "zeta") (skill-names skills))
            "root order, by name inside a root, duplicates dropped")
        (ok (equal "Project lint." (steer:steer-directive-description (first skills))))
        (ok (equal '("project" "claude" "lisp-workspace" "user" "setting")
                   (mapcar #'skill-source skills)))
        (ok (= 3 (length notes)) "one note per shadowed skill")
        (ok (member (format nil "skill lint at ~a is shadowed by ~a"
                            (native (truename (merge-pathnames ".claude/skills/lint/SKILL.md" project)))
                            (native (truename (merge-pathnames ".cl-stack-code/skills/lint/SKILL.md" project))))
                    notes :test #'string=))))))

(deftest skills-bad-ones-are-notes
  (with-project (project config) '((".claude/skills/broken/SKILL.md" "no frontmatter
"))
    (write-skill project ".claude/skills/" "good" "Good one.")
    (multiple-value-bind (skills notes) (discover-skills project :user-config-dir config)
      (ok (equal '("good") (skill-names skills)) "the bad skill is skipped, the rest load")
      (ok (equal (list (format nil "skill at ~a: no frontmatter"
                               (native (truename (merge-pathnames ".claude/skills/broken/SKILL.md" project)))))
                 notes)))))

(deftest skills-missing-skill-dir-is-a-note
  (with-project (project config) '()
    (let ((gone (subdir config "gone/")))
      (multiple-value-bind (skills notes)
          (discover-skills project :settings (make-settings :skill-dirs (list gone)) :user-config-dir config)
        (ok (null skills))
        (ok (equal (list (format nil "skill directory not found: ~a" (native gone))) notes))))))

#-(or windows win32)
(deftest skills-same-file-twice-counts-once
  (with-project (project config) '()
    (write-skill project ".lisp-workspace/skills/" "rove" "Rove ref.")
    (ensure-directories-exist (subdir project ".claude/skills/"))
    ;; lisp-workspace links .claude/skills/<name> into .lisp-workspace/skills/.
    (uiop:run-program (list "ln" "-s" "../../.lisp-workspace/skills/rove"
                            (native (merge-pathnames ".claude/skills/rove" project))))
    (multiple-value-bind (skills notes) (discover-skills project :user-config-dir config)
      (ok (equal '("rove") (skill-names skills)))
      (ok (equal "claude" (skill-source (first skills))) "found first under .claude/skills/")
      (ok (null notes) "no shadow note for the same file"))))

;;; skillDirs: the user file and the flags only.

(deftest skills-skill-dirs-user-not-project
  (with-project (project config) '()
    (let ((user-dir (native (ensure-directories-exist (subdir config "user-skills/"))))
          (project-dir (native (ensure-directories-exist (subdir config "project-skills/")))))
      (write-file config "settings.json" (json:encode (args "skillDirs" (vector user-dir))))
      (write-file project ".cl-stack-code/settings.json"
                  (json:encode (args "skillDirs" (vector project-dir)
                                    "contextFiles" (vector (native (merge-pathnames "x.md" config))))))
      (let ((settings (load-settings project :user-config-dir config
                                             :cli (make-settings :skill-dirs (list (subdir config "flag-skills/"))))))
        (ok (same-paths (list user-dir (subdir config "flag-skills/")) (settings-skill-dirs settings))
            "user, then the flag layer; the project's are dropped")
        (ok (null (settings-context-files settings)))))))

(deftest-parametrize skills-settings-bad-values
    ((json key)
     :ids ("not-array" "relative" "number" "context-relative")
     ("{\"skillDirs\": \"/a\"}" "skillDirs")
     ("{\"skillDirs\": [\"/a\", \"rel/dir\"]}" "skillDirs[1]")
     ("{\"skillDirs\": [3]}" "skillDirs[0]")
     ("{\"contextFiles\": [\"notes.md\"]}" "contextFiles[0]"))
  (let ((c (failure (parse-settings json))))
    (ok (typep c 'settings-error))
    (when (typep c 'settings-error)
      (ok (equal key (settings-error-key c))))))

(deftest skills-settings-home-paths
  (let ((s (parse-settings "{\"skillDirs\": [\"~/sk\"], \"contextFiles\": [\"~/c.md\"]}")))
    (ok (same-path (merge-pathnames "sk/" (user-homedir-pathname)) (first (settings-skill-dirs s))))
    (ok (same-path (merge-pathnames "c.md" (user-homedir-pathname)) (first (settings-context-files s))))))

(deftest skills-flags
  (let* ((tmp (native (uiop:temporary-directory)))
         (inv (parse-arguments (list "-p" "--skill-dir" (concatenate 'string tmp "skills")
                                     "--skill-dir" "~/sk"
                                     "--context-file" (concatenate 'string tmp "ctx.md") "go")))
         (s (invocation-settings inv)))
    (ok (equal 2 (length (settings-skill-dirs s))))
    (ok (uiop:directory-pathname-p (first (settings-skill-dirs s))))
    (ok (equal 1 (length (settings-context-files s)))))
  (ok (signals (parse-arguments '("-p" "--skill-dir" "relative" "go")) 'code-usage-error))
  (ok (signals (parse-arguments '("-p" "--context-file" "c.md" "go")) 'code-usage-error)))

;;; The listing.

(deftest skills-listing-section
  (with-project (project config) '()
    (write-skill project ".claude/skills/" "rove" "Rove quick ref.")
    (write-file project ".claude/skills/asdf/SKILL.md" "---
name: asdf
description: >-
  ASDF 3:   defsystem,
  source registry.
---
Body.
")
    (let ((skills (discover-skills project :user-config-dir config)))
      (ok (equal (format nil "# Skills~%~a~%- asdf: ASDF 3: defsystem, source registry.~%- rove: Rove quick ref."
                         +skill-listing-preamble+)
                 (skill-listing-section skills))
          "whitespace collapsed; by name inside a root")
      (ok (null (skill-listing-section '())) "no skills, no section"))))

(deftest skills-listing-long-description
  (with-project (project config) '()
    (write-skill project ".claude/skills/" "long" (make-string 1500 :initial-element #\d) :folded nil)
    (let ((section (skill-listing-section (discover-skills project :user-config-dir config))))
      (ok (has (format nil "- long: ~a…" (make-string 1023 :initial-element #\d)) section))
      (ok (not (has (make-string 1024 :initial-element #\d) section)))
      (ok (= 1024 +max-skill-description-chars+)))))

(deftest skills-listing-budget
  (with-project (project config) '()
    (dotimes (i 120)
      (write-skill project ".claude/skills/" (format nil "s~3,'0d" i)
                   (make-string 150 :initial-element #\e) :folded nil))
    (let* ((section (skill-listing-section (discover-skills project :user-config-dir config)))
           (lines (rest (rest (lines section))))
           (full (remove-if-not (lambda (l) (search ": " l)) lines))
           (bare (remove-if (lambda (l) (or (search ": " l) (uiop:string-prefix-p "(" l))) lines)))
      (ok (= 8000 +skill-listing-budget+))
      (ok (<= (reduce #'+ full :key (lambda (l) (1+ (length l)))) 8000) "full lines within the budget")
      (ok (= (length full) (floor 8000 (+ 1 (length "- s000: ") 150))) "as many full lines as fit")
      (ok (equal (format nil "- s~3,'0d" (length full)) (first bare)) "then names")
      (ok (= 120 (+ (length full) (length bare)
                    (let ((more (find-if (lambda (l) (uiop:string-prefix-p "(" l)) lines)))
                      (if more (parse-integer more :start 1 :junk-allowed t) 0))))
          "every skill is listed or counted")
      (ok (every (lambda (l) (or (uiop:string-prefix-p "- " l) (uiop:string-prefix-p "(" l))) lines)))))

;;; The tool.

(deftest skills-tool-result
  (with-project (project config) (lisp-workspace-fixture)
    (let* ((skill (first (discover-skills project :user-config-dir config)))
           (dir (native (truename (subdir project ".lisp-workspace/skills/rove/")))))
      (ok (equal (format nil "<skill name=\"rove\" directory=\"~a\">~%# Rove~%~%Use deftest and ok.~%</skill>" dir)
                 (skill-tool-result skill)))
      (ok (equal (format nil "<skill-file name=\"rove\" path=\"~a\">~%More about rove.~%</skill-file>"
                         (native (truename (merge-pathnames ".lisp-workspace/skills/rove/reference.md" project))))
                 (skill-tool-result skill "reference.md")))
      (let ((c (failure (skill-tool-result skill "../../rules/lisp.md"))))
        (ok (typep c 'a:tool-input-error))
        (ok (has "is outside the skill directory" (princ-to-string c))))
      (let ((c (failure (skill-tool-result skill "nope.md"))))
        (ok (typep c 'a:tool-input-error))
        (ok (has "no file nope.md in skill rove" (princ-to-string c)))))))

(deftest skills-tool-source
  (with-project (project config) (lisp-workspace-fixture)
    (let* ((skills (discover-skills project :user-config-dir config))
           (source (make-skill-tools skills))
           (tools (a:list-agent-tools source)))
      (ok (skill-tools-p source))
      (ok (equal skills (skill-tools-skills source)))
      (ok (equal (list +skill-tool-name+) (mapcar #'llm:llm-tool-name tools)))
      (ok (equal "skill" +skill-tool-name+))
      (ok (not (a:tool-needs-approval-p source "skill" (json-args "name" "rove"))) "read-only: no approval")
      (ok (equal '("rove") (a:tool-permission-resources source "skill" (json-args "name" "rove"))))
      (ok (null (a:tool-instruction-paths source "skill" (json-args "name" "rove" "path" "src/a.lisp")))
          "a skill's files never load rules")
      (ok (eq source (code-skill-tools (list :x source)))))))
