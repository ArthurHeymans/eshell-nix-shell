;;; eshell-nix-shell-tests.el --- Tests for eshell-nix-shell  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Arthur Heymans
;; Author: Arthur Heymans <arthur@aheymans.xyz>
;; Assisted-by: OpenAI Codex:gpt-5.6-sol
;; Package-Requires: ((emacs "30.1"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Unit and integration tests for `eshell-nix-shell'.  The small Eshell
;; fixtures below are adapted from Emacs's
;; test/lisp/eshell/resources/eshell-tests-helpers.el; keeping them here makes
;; the package tests independent of an Emacs source checkout.

;;; Code:

(require 'ert)
(require 'ert-x)
(require 'eshell)
(require 'esh-mode)
(require 'eshell-nix-shell)

(defvar eshell-aliases-file nil)
(defvar eshell-command-aliases-list nil)
(defvar eshell-history-file-name nil)
(defvar eshell-last-dir-ring-file-name nil)

(defconst eshell-nix-shell-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

(defmacro eshell-nix-shell-tests--with-eshell (&rest body)
  "Run BODY in a fresh, disposable Eshell buffer."
  (declare (indent 0) (debug t))
  `(ert-with-temp-directory eshell-directory-name
     (let ((eshell-aliases-file nil)
           (eshell-command-aliases-list nil)
           (eshell-history-file-name nil)
           (eshell-last-dir-ring-file-name nil)
           (eshell-module-loading-messages nil))
       (let ((buffer (eshell t)))
         (unwind-protect
             (with-current-buffer buffer ,@body)
           (when (buffer-live-p buffer)
             (let (kill-buffer-query-functions) (kill-buffer buffer))))))))

(defun eshell-nix-shell-tests--wait ()
  "Wait for the current Eshell's foreground process to finish."
  (let ((deadline (+ (float-time)
                     (if (file-remote-p default-directory) 30 10))))
    (while (and (or (eshell-interactive-process-p)
                    (seq-some #'eshell-process-active-p eshell-process-list)
                    eshell-nix-shell--pending-capture)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (when (or (eshell-interactive-process-p)
              (seq-some #'eshell-process-active-p eshell-process-list)
              eshell-nix-shell--pending-capture)
      (error "Timed out waiting for Eshell"))))

(defun eshell-nix-shell-tests--command (command)
  "Submit COMMAND in the current Eshell and return its output."
  (goto-char eshell-last-output-end)
  (insert-and-inherit command)
  (eshell-send-input)
  (eshell-nix-shell-tests--wait)
  (buffer-substring-no-properties (eshell-beginning-of-output)
                                  (eshell-end-of-output)))

(defun eshell-nix-shell-tests--write-nul (records)
  "Write RECORDS, NUL terminated, and return the temporary file name."
  (let ((file (make-temp-file "ens-test-")))
    (with-temp-file file
      (set-buffer-multibyte t)
      (dolist (record records) (insert record "\0")))
    file))

(ert-deftest eshell-nix-shell-parse-nul-environment ()
  "NUL parsing supports unusual values and deterministic duplicates."
  (let ((file (eshell-nix-shell-tests--write-nul
               '("A=first" "A=second" "MALFORMED" "EMPTY="
                 "UNICODE=λ" "LINES=one\ntwo"))))
    (unwind-protect
        (should (equal (eshell-nix-shell--parse-environment file)
                       '("A=first" "MALFORMED" "EMPTY="
                         "UNICODE=λ" "LINES=one\ntwo")))
      (delete-file file))))

(ert-deftest eshell-nix-shell-parse-rejects-incomplete-data ()
  "A capture without its final NUL is incomplete."
  (let ((file (make-temp-file "ens-test-" nil nil "A=x")))
    (unwind-protect
        (should-error (eshell-nix-shell--parse-environment file))
      (delete-file file))))

(ert-deftest eshell-nix-shell-path-conversion ()
  "PATH conversion preserves empty elements and Emacs's exec directory."
  (let ((exec-directory "/emacs/libexec/"))
    (dolist (separator '(?: ":"))
      (let ((path-separator separator))
        (should (equal (eshell-nix-shell--path-list "/one::/two")
                       '("/one" "" "/two")))))
    (should (equal (eshell-nix-shell--exec-path nil)
                   '("/emacs/libexec/")))))

(ert-deftest eshell-nix-shell-variable-filter ()
  "Dangerous variables are denied and parent terminal values survive."
  (let ((eshell-nix-shell-excluded-variables '("PS1" "TMPDIR")))
    (should (equal (eshell-nix-shell--filter-environment
                    '("OK=yes" "PS1=bad" "TMPDIR=/gone" "TERM=bad"
                      "INSIDE_EMACS=bad")
                    '("TERM=parent" "INSIDE_EMACS=30.2"))
                   '("OK=yes" "TERM=parent" "INSIDE_EMACS=30.2")))))

(ert-deftest eshell-nix-shell-frame-restore-and-locality ()
  "A frame restores all values, including non-local `exec-path'."
  (eshell-nix-shell-tests--with-eshell
    (kill-local-variable 'exec-path)
    (let ((original-exec exec-path)
          (process-environment '("PATH=/old" "X=old"))
          (default-directory temporary-file-directory))
      (eshell-set-path '("/old"))
      (let ((frame (eshell-nix-shell--capture-frame '("old"))))
        (setq-local process-environment '("PATH=/new"))
        (setq-local exec-path '("/new"))
        (eshell-set-path '("/new"))
        (eshell-nix-shell--restore-frame frame)
        (should (equal process-environment '("PATH=/old" "X=old")))
        (should (equal (eshell-get-path t) '("/old")))
        (should-not (local-variable-p 'exec-path))
        (should (equal exec-path original-exec))))))

(ert-deftest eshell-nix-shell-nested-lifo ()
  "Synthetic activations pop in last-in, first-out order."
  (eshell-nix-shell-tests--with-eshell
    (setq-local path-separator ?:)
    (setq-local process-environment '("PATH=/zero" "L=zero"))
    (eshell-set-path '("/zero"))
    (eshell-nix-shell--apply '("PATH=/one" "L=one") nil '("one"))
    (eshell-nix-shell--apply '("PATH=/two" "L=two") nil '("two"))
    (should (= (length eshell-nix-shell--environment-stack) 2))
    (eshell-nix-shell-pop)
    (should (equal (getenv "L") "one"))
    (eshell-nix-shell-pop)
    (should (equal (getenv "L") "zero"))))

(ert-deftest eshell-nix-shell-does-not-advise-generic-eshell-disposal ()
  "The generic Eshell kill-or-bury entry point remains unmodified."
  (should-not
   (advice--p (advice--symbol-function 'eshell-life-is-too-much))))

(ert-deftest eshell-nix-shell-ctrl-d-key-pops-at-empty-prompt ()
  "The minor-mode keymap handles `C-d' before custom Eshell bindings."
  (eshell-nix-shell-tests--with-eshell
    (setq-local process-environment '("PATH=/zero" "L=zero"))
    (eshell-set-path '("/zero"))
    (eshell-nix-shell-mode 1)
    (should (eq (key-binding (kbd "C-d")) #'eshell-nix-shell--ctrl-d))
    (eshell-nix-shell--apply '("PATH=/one" "L=one") nil '("one"))
    (goto-char (point-max))
    (should (= (point) eshell-last-output-end))
    (eshell-nix-shell--ctrl-d)
    (should-not eshell-nix-shell--environment-stack)
    (should (equal (getenv "L") "zero"))))

(ert-deftest eshell-nix-shell-apply-is-atomic ()
  "An error during activation restores state and stack depth."
  (eshell-nix-shell-tests--with-eshell
    (setq-local process-environment '("PATH=/before" "X=before"))
    (setq-local exec-path '("/before"))
    (eshell-set-path '("/before"))
    (let ((eshell-nix-shell-after-enter-hook
           (list (lambda () (error "synthetic failure")))))
      (should-error (eshell-nix-shell--apply
                     '("PATH=/after" "X=after") nil nil)))
    (should-not eshell-nix-shell--environment-stack)
    (should (equal (getenv "X") "before"))
    (should (equal exec-path '("/before")))
    (should (equal (eshell-get-path t) '("/before")))))

(ert-deftest eshell-nix-shell-apply-rolls-back-on-quit ()
  "A quit from an installation hook rolls back every mutation."
  (eshell-nix-shell-tests--with-eshell
    (setq-local process-environment '("PATH=/before" "X=before"))
    (setq-local exec-path '("/before"))
    (eshell-set-path '("/before"))
    (let ((eshell-nix-shell-after-enter-hook
           (list (lambda () (signal 'quit nil))))
          caught)
      (condition-case nil
          (eshell-nix-shell--apply '("PATH=/after" "X=after") nil nil)
        (quit (setq caught t)))
      (should caught))
    (should-not eshell-nix-shell--environment-stack)
    (should (equal (getenv "X") "before"))
    (should (equal exec-path '("/before")))))

(ert-deftest eshell-nix-shell-command-classification ()
  "Activation classification observes option arities."
  (dolist (args '(() ("thing.nix") ("-p" "hello")
                     ("--argstr" "msg" "--run")
                     ("-I" "--run") ("--unknown")))
    (should (eshell-nix-shell--activation-p args)))
  (dolist (args '(("--run" "echo x") ("--command" "echo x")
                  ("--help") ("-h") ("--version")))
    (should-not (eshell-nix-shell--activation-p args))))

(ert-deftest eshell-nix-shell-payload-quotes-files ()
  "Generated payload quotes local path names and uses Bash builtins."
  (let* ((capture '(:environment-file "/ssh:host:/tmp/a b'c"
                    :directory-file "/ssh:host:/tmp/d e"))
         (payload (eshell-nix-shell--payload capture)))
    (should (string-match-p
             (regexp-quote (shell-quote-argument "/tmp/a b'c")) payload))
    (should (string-match-p
             (regexp-quote (shell-quote-argument "/tmp/d e")) payload))
    (should-not (string-match-p "/ssh:host:" payload))
    (should (string-match-p "compgen -e" payload))
    (should-not (string-match-p "env -0" payload))))

(ert-deftest eshell-nix-shell-import-restores-remote-directory-prefix ()
  "A remote capture turns the shell's local PWD into a Tramp name."
  (let ((environment-file
         (eshell-nix-shell-tests--write-nul '("PATH=/remote/bin")))
        (directory-file
         (eshell-nix-shell-tests--write-nul '("/remote/project")))
        applied)
    (unwind-protect
        (cl-letf (((symbol-function 'eshell-nix-shell--apply)
                   (lambda (environment directory arguments)
                     (setq applied (list environment directory arguments)))))
          (eshell-nix-shell--import-capture
           (list :environment-file environment-file
                 :directory-file directory-file
                 :remote-prefix "/ssh:host:"
                 :arguments '("shell.nix")))
          (should (equal applied
                         '(("PATH=/remote/bin")
                           "/ssh:host:/remote/project"
                           ("shell.nix")))))
      (delete-file environment-file)
      (delete-file directory-file))))

(ert-deftest eshell-nix-shell-apply-allows-valid-remote-directory ()
  "Opt-in directory changes retain a valid Tramp directory."
  (eshell-nix-shell-tests--with-eshell
    (let* ((eshell-nix-shell-change-directory t)
           (remote "/ssh:host:/remote/project/")
           (default-directory "/ssh:host:/remote/start/")
           (original-exec-path exec-path))
      (cl-letf (((symbol-function 'file-directory-p)
                 (lambda (directory) (equal directory remote)))
                ((symbol-function 'eshell-get-path)
                 (lambda (&optional _literal) '("/remote/old")))
                ((symbol-function 'eshell-set-path) #'ignore))
        (eshell-nix-shell--apply '("PATH=/remote/bin") remote nil))
      (should (equal default-directory remote))
      (should (equal exec-path original-exec-path))
      (should-not (local-variable-p 'exec-path))
      (should (equal (getenv "PATH")
                     (getenv-internal
                      "PATH" (default-toplevel-value
                              'process-environment))))
      (should (member "PATH=/remote/bin" process-environment))
      (eshell-nix-shell-pop))))

(ert-deftest eshell-nix-shell-default-prompt-omits-package-option ()
  "The default package prompt emphasizes package names, not `-p'."
  (should (equal (substring-no-properties
                  (eshell-nix-shell--default-prompt-format
                   '("-p" "hello" "jq")))
                 "❄ nix-shell  hello jq")))

(ert-deftest eshell-nix-shell-prompt-wraps-and-restores-custom-prompt ()
  "Prompt integration preserves and restores an existing custom prompt."
  (eshell-nix-shell-tests--with-eshell
    (let ((custom-prompt (lambda () "\nproject λ ")))
      (setq-local eshell-prompt-function custom-prompt)
      (eshell-nix-shell-mode 1)
      (should (eq eshell-prompt-function
                  #'eshell-nix-shell--prompt-function))
      (should (equal (eshell-nix-shell--prompt-function) "\nproject λ "))
      (eshell-nix-shell--apply '("PATH=/one") nil '("-p" "hello"))
      (should (equal (substring-no-properties
                      (eshell-nix-shell--prompt-function))
                     "\n❄ nix-shell  hello\nproject λ "))
      (eshell-nix-shell-mode -1)
      (should (eq eshell-prompt-function custom-prompt)))))

(ert-deftest eshell-nix-shell-prompt-leaves-nil-configuration-alone ()
  "Prompt integration does not replace a nil `eshell-prompt-function'."
  (eshell-nix-shell-tests--with-eshell
    (setq-local eshell-prompt-function nil)
    (eshell-nix-shell-mode 1)
    (should-not eshell-prompt-function)
    (should-not eshell-nix-shell--prompt-installed-p)
    (eshell-nix-shell-mode -1)
    (should-not eshell-prompt-function)))

(defmacro eshell-nix-shell-tests--with-fake (&rest body)
  "Run BODY in Eshell with a fake `nix-shell' and introduced command."
  (declare (indent 0) (debug t))
  `(ert-with-temp-directory root
     (let* ((bash (or (executable-find "bash")
                      (error "Bash is required for integration tests")))
            (bindir (expand-file-name "bin" root))
            (shell (expand-file-name "nix-shell" root))
            (tool (expand-file-name "ens-new-command" bindir)))
       (make-directory bindir)
       (with-temp-file tool
         (insert "#!/bin/sh\nprintf 'introduced:%s\\n' \"$FAKE_LAYER\"\n"))
       (set-file-modes tool #o700)
       (with-temp-file shell
         (insert (format "#!%s\n" bash)
                 "payload=; layer=default; fail=\n"
                 "while (($#)); do\n"
                 " case $1 in\n"
                 "  --run|--command) payload=$2; shift 2;;\n"
                 "  --argstr) [[ $2 == layer ]] && layer=$3; shift 3;;\n"
                 "  --fail) fail=1; shift;;\n"
                 "  --emit-output) echo fake-stdout; echo fake-stderr >&2; shift;;\n"
                 "  --help) echo fake-help; exit 0;;\n"
                 "  *) shift;;\n"
                 " esac\n"
                 "done\n"
                 "[[ $fail ]] && { echo fake-failure >&2; exit 9; }\n"
                 "export FAKE_LAYER=$layer\n"
                 "export PATH=$FAKE_TOOL_DIR:$PATH\n"
                 (format "[[ $payload ]] && %s -c \"$payload\"\n"
                         (shell-quote-argument bash))))
       (set-file-modes shell #o700)
       (eshell-nix-shell-tests--with-eshell
         (setq-local process-environment
                     (cons (concat "FAKE_TOOL_DIR=" bindir)
                           (cons (concat "PATH=" root ":" (getenv "PATH"))
                                 process-environment)))
         (eshell-set-path (eshell-nix-shell--path-list (getenv "PATH")))
         (setq-local exec-path (eshell-nix-shell--exec-path (getenv "PATH")))
         (let ((eshell-nix-shell-executable shell))
           (eshell-nix-shell-mode 1)
           ,@body)))))

(ert-deftest eshell-nix-shell-integration-activation-and-lookup ()
  "Activation updates PATH and both Eshell and Emacs command lookup."
  (eshell-nix-shell-tests--with-fake
    (eshell-nix-shell-tests--command "nix-shell --argstr layer one")
    (should (equal (getenv "FAKE_LAYER") "one"))
    (should (executable-find "ens-new-command"))
    (should (string-match-p "introduced:one"
                            (eshell-nix-shell-tests--command "ens-new-command")))))

(ert-deftest eshell-nix-shell-integration-preserves-numeric-arguments ()
  "Eshell leaves numeric-looking activation arguments as strings."
  (eshell-nix-shell-tests--with-fake
    (eshell-nix-shell-tests--command "nix-shell --cores 4")
    (let ((arguments (eshell-nix-shell--frame-activation-arguments
                      (car eshell-nix-shell--environment-stack))))
      (should (equal arguments '("--cores" "4")))
      (should (seq-every-p #'stringp arguments)))))

(ert-deftest eshell-nix-shell-integration-sequencing ()
  "The command following activation sees the imported environment."
  (eshell-nix-shell-tests--with-fake
    (should (string-match-p
             "introduced:ordered"
             (eshell-nix-shell-tests--command
              "nix-shell --argstr layer ordered; ens-new-command")))))

(ert-deftest eshell-nix-shell-integration-failure-is-atomic ()
  "A failed fake activation changes no prior state."
  (eshell-nix-shell-tests--with-fake
    (let ((before-env (copy-sequence process-environment))
          (before-path (copy-sequence (eshell-get-path t)))
          (before-exec (copy-sequence exec-path)))
      (should (string-match-p
               "Nix shell activation failed"
               (eshell-nix-shell-tests--command "nix-shell --fail")))
      (should (equal process-environment before-env))
      (should (equal (eshell-get-path t) before-path))
      (should (equal exec-path before-exec))
      (should-not eshell-nix-shell--environment-stack))))

(ert-deftest eshell-nix-shell-integration-exit-and-nesting ()
  "Exit pops exactly one fake environment and nesting is LIFO."
  (eshell-nix-shell-tests--with-fake
    (eshell-nix-shell-tests--command "nix-shell --argstr layer one")
    (eshell-nix-shell-tests--command "nix-shell --argstr layer two")
    (eshell-nix-shell-tests--command "exit")
    (should (equal (getenv "FAKE_LAYER") "one"))
    (should (= (length eshell-nix-shell--environment-stack) 1))
    (eshell-nix-shell-tests--command "nix-shell-exit")
    (should-not (getenv "FAKE_LAYER"))
    (should-not eshell-nix-shell--environment-stack)))

(ert-deftest eshell-nix-shell-integration-which-reports-external-path ()
  "`which nix-shell' reports the configured executable and annotation."
  (eshell-nix-shell-tests--with-fake
    (let ((output (eshell-nix-shell-tests--command "which nix-shell")))
      (should (string-match-p (regexp-quote shell) output))
      (should (string-match-p "activation managed" output)))))

(ert-deftest eshell-nix-shell-integration-pass-through ()
  "An explicit --run invocation executes externally without activation."
  (eshell-nix-shell-tests--with-fake
    (should (string-match-p "passthrough"
                            (eshell-nix-shell-tests--command
                             "nix-shell --run 'printf passthrough'")))
    (should-not eshell-nix-shell--environment-stack)))

(ert-deftest eshell-nix-shell-integration-forced-external-pass-through ()
  "Eshell's two explicit external syntaxes bypass activation."
  (eshell-nix-shell-tests--with-fake
    (dolist (command '("*nix-shell --run 'printf star-pass'"
                       "/:nix-shell --run 'printf slash-pass'"))
      (should (string-match-p "pass"
                              (eshell-nix-shell-tests--command command)))
      (should-not eshell-nix-shell--environment-stack))))

(ert-deftest eshell-nix-shell-integration-keeps-process-output-visible ()
  "Activation stdout and stderr remain in the Eshell output."
  (eshell-nix-shell-tests--with-fake
    (let ((output (eshell-nix-shell-tests--command
                   "nix-shell --emit-output")))
      (should (string-match-p "fake-stdout" output))
      (should (string-match-p "fake-stderr" output)))))

(ert-deftest eshell-nix-shell-debug-records-lifecycle-only ()
  "Debug logging writes lifecycle text to its dedicated buffer."
  (let ((eshell-nix-shell-debug t))
    (when-let ((buffer (get-buffer "*eshell-nix-shell-debug*")))
      (kill-buffer buffer))
    (eshell-nix-shell--debug "synthetic lifecycle event")
    (with-current-buffer "*eshell-nix-shell-debug*"
      (should (string-match-p "synthetic lifecycle event" (buffer-string))))
    (kill-buffer "*eshell-nix-shell-debug*")))

(ert-deftest eshell-nix-shell-failure-and-signal-clean-captures ()
  "Failed and cancelled synchronous activations remove their captures."
  (eshell-nix-shell-tests--with-eshell
    (dolist (status '(9 "interrupt"))
      (let* ((capture (eshell-nix-shell--make-capture))
             (files (list (plist-get capture :environment-file)
                          (plist-get capture :directory-file))))
        (setq eshell-nix-shell--pending-capture capture)
        (eshell-nix-shell--kill-hook "nix-shell" status)
        (should-not eshell-nix-shell--pending-capture)
        (should-not (seq-some #'file-exists-p files))))))

(ert-deftest eshell-nix-shell-failure-can-retain-captures ()
  "Failed captures can be retained and are no longer buffer-owned."
  (eshell-nix-shell-tests--with-eshell
    (let* ((eshell-nix-shell-keep-capture-files-on-error t)
           (capture (eshell-nix-shell--make-capture))
           (files (list (plist-get capture :environment-file)
                        (plist-get capture :directory-file))))
      (unwind-protect
          (progn
            (setq eshell-nix-shell--pending-capture capture)
            (eshell-nix-shell--kill-hook "nix-shell" 9)
            (should (seq-every-p #'file-exists-p files))
            (should-not (seq-intersection files
                                          eshell-nix-shell--capture-files)))
        (mapc (lambda (file) (ignore-errors (delete-file file))) files)))))

(ert-deftest eshell-nix-shell-integration-cleans-captures ()
  "Capture files are deleted after successful import."
  (eshell-nix-shell-tests--with-fake
    (let ((original (symbol-function 'eshell-nix-shell--make-capture))
          files)
      (cl-letf (((symbol-function 'eshell-nix-shell--make-capture)
                 (lambda ()
                   (let ((capture (funcall original)))
                     (setq files (list (plist-get capture :environment-file)
                                       (plist-get capture :directory-file)))
                     capture))))
        (eshell-nix-shell-tests--command "nix-shell"))
      (should (= (length files) 2))
      (should-not (seq-some #'file-exists-p files)))))

(ert-deftest eshell-nix-shell-pending-disable-keeps-mode-enabled ()
  "Rejected disable leaves the mode and its integration intact."
  (eshell-nix-shell-tests--with-eshell
    (eshell-nix-shell-mode 1)
    (setq eshell-nix-shell--pending-capture '(:synthetic t))
    (should-error (eshell-nix-shell-mode -1) :type 'user-error)
    (should eshell-nix-shell-mode)
    (should (memq #'eshell-nix-shell--command-handler
                  eshell-named-command-hook))
    (setq eshell-nix-shell--pending-capture nil)))

(ert-deftest eshell-nix-shell-disable-cleans-after-hook-error ()
  "Disable restores frames and removes hooks despite an exit-hook error."
  (eshell-nix-shell-tests--with-eshell
    (setq-local process-environment '("PATH=/before" "X=before"))
    (eshell-set-path '("/before"))
    (eshell-nix-shell-mode 1)
    (eshell-nix-shell--apply '("PATH=/after" "X=after") nil nil)
    (let ((eshell-nix-shell-before-exit-hook
           (list (lambda () (error "exit hook failed")))))
      (should-error (eshell-nix-shell-mode -1)))
    (should-not eshell-nix-shell--environment-stack)
    (should (equal (getenv "X") "before"))
    (should-not (memq #'eshell-nix-shell--command-handler
                      eshell-named-command-hook))))

(ert-deftest eshell-nix-shell-buffer-cleanup-terminates-process ()
  "Buffer cleanup terminates a pending writer before deleting captures."
  (eshell-nix-shell-tests--with-eshell
    (let* ((capture (eshell-nix-shell--make-capture))
           (environment-file (plist-get capture :environment-file))
           (directory-file (plist-get capture :directory-file))
           (process (make-process
                     :name "ens-pending-test" :buffer nil
                     :command (list "/bin/sh" "-c"
                                    (format "sleep 2; echo late > %s"
                                            (shell-quote-argument environment-file))))))
      (process-put process 'eshell-nix-shell--capture capture)
      (setq eshell-nix-shell--pending-capture capture
            eshell-nix-shell--pending-process process)
      (eshell-nix-shell--cleanup-all)
      (should-not (process-live-p process))
      (should-not (file-exists-p environment-file))
      (should-not (file-exists-p directory-file)))))

(ert-deftest eshell-nix-shell-integration-disable-removes-behavior ()
  "Disabling restores active state and stops command interception."
  (eshell-nix-shell-tests--with-fake
    (eshell-nix-shell-tests--command "nix-shell --argstr layer active")
    (eshell-nix-shell-mode -1)
    (should-not eshell-nix-shell--environment-stack)
    (should-not (memq #'eshell-nix-shell--command-handler
                      eshell-named-command-hook))
    (eshell-nix-shell-tests--command "nix-shell")
    (should-not (getenv "FAKE_LAYER"))))

(ert-deftest eshell-nix-shell-integration-buffer-independence ()
  "Two Eshell buffers own independent stacks and environments."
  (eshell-nix-shell-tests--with-fake
    (eshell-nix-shell-tests--command "nix-shell --argstr layer outer")
    (let ((outer (current-buffer)))
      (eshell-nix-shell-tests--with-eshell
        (should-not (getenv "FAKE_LAYER"))
        (should-not eshell-nix-shell--environment-stack))
      (with-current-buffer outer
        (should (equal (getenv "FAKE_LAYER") "outer"))
        (should (= (length eshell-nix-shell--environment-stack) 1))))))

(ert-deftest eshell-nix-shell-rejects-unsupported-contexts ()
  "Activation is rejected in pipeline, background, and subcommand contexts."
  (dolist (bindings '((t nil nil) (nil t nil) (nil nil t)))
    (let ((eshell-in-pipeline-p (nth 0 bindings))
          (eshell-current-subjob-p (nth 1 bindings))
          (eshell-in-subcommand-p (nth 2 bindings))
          (default-directory temporary-file-directory)
          eshell-nix-shell--pending-capture)
      (should-error (eshell-nix-shell--command-handler "nix-shell" nil)
                    :type 'user-error))))

(defun eshell-nix-shell-tests--offline-nixpkgs ()
  "Return an already-cached nixpkgs path, or nil without network access."
  (when (executable-find "nix")
    (with-temp-buffer
      (when (= 0 (call-process "nix" nil t nil
                               "eval" "--offline" "--raw" "nixpkgs#path"))
        (string-trim (buffer-string))))))

(defun eshell-nix-shell-tests--write-expression (directory contents)
  "Write CONTENTS as shell.nix below DIRECTORY and return its path."
  (let ((file (expand-file-name "shell.nix" directory)))
    (with-temp-file file (insert contents))
    file))

(ert-deftest eshell-nix-shell-nix-explicit-local-expression ()
  "An explicit local expression imports exported and multiline values."
  (skip-unless (executable-find "nix-shell"))
  (let ((expression (expand-file-name "test-resources/shell.nix"
                                      eshell-nix-shell-tests--directory)))
    (skip-unless (file-readable-p expression))
    (eshell-nix-shell-tests--with-eshell
      (eshell-nix-shell-mode 1)
      (eshell-nix-shell-tests--command
       (format "nix-shell %s" (shell-quote-argument expression)))
      (should (equal (getenv "ENS_NIX_TEST") "from-local-nix"))
      (should (equal (getenv "ENS_NIX_MULTILINE") "first\nsecond"))
      (should (= (length eshell-nix-shell--environment-stack) 1)))))

(ert-deftest eshell-nix-shell-nix-bare-discovers-shell-nix ()
  "Bare `nix-shell' discovers shell.nix in `default-directory'."
  (skip-unless (executable-find "nix-shell"))
  (ert-with-temp-directory root
    (copy-file (expand-file-name "test-resources/shell.nix"
                                 eshell-nix-shell-tests--directory)
               (expand-file-name "shell.nix" root))
    (eshell-nix-shell-tests--with-eshell
      (setq default-directory (file-name-as-directory root))
      (eshell-nix-shell-mode 1)
      (eshell-nix-shell-tests--command "nix-shell")
      (should (equal (getenv "ENS_NIX_TEST") "from-local-nix")))))

(ert-deftest eshell-nix-shell-nix-pure-needs-no-coreutils-capture ()
  "The Bash-builtin capture works under `--pure' without coreutils in PATH."
  (skip-unless (executable-find "nix-shell"))
  (ert-with-temp-directory root
    (let ((expression
           (eshell-nix-shell-tests--write-expression
            root
            (concat
             "builtins.derivation { name = \"ens-pure\"; "
             "system = builtins.currentSystem; builder = \"/bin/sh\"; "
             "args = [ \"-c\" \"printf fixture > $out\" ]; "
             "ENS_NIX_PURE = \"yes\"; }\n"))))
      (eshell-nix-shell-tests--with-eshell
        (eshell-nix-shell-mode 1)
        (eshell-nix-shell-tests--command
         (format "nix-shell --pure %s" (shell-quote-argument expression)))
        (should (equal (getenv "ENS_NIX_PURE") "yes"))
        (should-not
         (seq-some (lambda (directory)
                     (file-exists-p (expand-file-name "env" directory)))
                   (eshell-nix-shell--path-list (getenv "PATH"))))))))

(ert-deftest eshell-nix-shell-nix-shell-hook-output-and-directory ()
  "shellHook output is visible and its directory capture is uncorrupted."
  (skip-unless (executable-find "nix-shell"))
  (let ((nixpkgs (eshell-nix-shell-tests--offline-nixpkgs)))
    (skip-unless (and nixpkgs (file-directory-p nixpkgs)))
    (ert-with-temp-directory root
      (let* ((target (expand-file-name "hook-target" root))
             (expression
              (eshell-nix-shell-tests--write-expression
               root
               (format
                (concat "with import <nixpkgs> {}; mkShell { shellHook = ''\n"
                        "echo hook-stdout\n"
                        "echo hook-stderr >&2\n"
                        "cd %s\n"
                        "export ENS_HOOK_RAN=yes\n"
                        "''; }\n")
                (shell-quote-argument target)))))
        (make-directory target)
        (eshell-nix-shell-tests--with-eshell
          (setq-local process-environment
                      (cons (concat "NIX_PATH=nixpkgs=" nixpkgs)
                            process-environment))
          (let ((eshell-nix-shell-change-directory t))
            (eshell-nix-shell-mode 1)
            (let ((output (eshell-nix-shell-tests--command
                           (format "nix-shell %s"
                                   (shell-quote-argument expression)))))
              (should (string-match-p "hook-stdout" output))
              (should (string-match-p "hook-stderr" output))
              (should (equal (getenv "ENS_HOOK_RAN") "yes"))
              (should (equal default-directory
                             (file-name-as-directory target))))))))))

(ert-deftest eshell-nix-shell-nix-shell-hook-exit-fails-atomically ()
  "A shellHook that exits nonzero does not import an environment."
  (skip-unless (executable-find "nix-shell"))
  (let ((nixpkgs (eshell-nix-shell-tests--offline-nixpkgs)))
    (skip-unless (and nixpkgs (file-directory-p nixpkgs)))
    (ert-with-temp-directory root
      (let ((expression
             (eshell-nix-shell-tests--write-expression
              root
              (concat "with import <nixpkgs> {}; mkShell { shellHook = ''\n"
                      "export ENS_HOOK_MUST_NOT_IMPORT=yes\n"
                      "echo hook-failed >&2\n"
                      "exit 17\n"
                      "''; }\n"))))
        (eshell-nix-shell-tests--with-eshell
          (setq-local process-environment
                      (cons (concat "NIX_PATH=nixpkgs=" nixpkgs)
                            process-environment))
          (let ((before (copy-sequence process-environment)))
            (eshell-nix-shell-mode 1)
            (let ((output (eshell-nix-shell-tests--command
                           (format "nix-shell %s"
                                   (shell-quote-argument expression)))))
              (should (string-match-p "hook-failed" output)))
            (should (equal process-environment before))
            (should-not eshell-nix-shell--environment-stack)))))))

(ert-deftest eshell-nix-shell-tramp-integration ()
  "Activation and command lookup work in a configured remote fixture."
  (let ((remote-directory (getenv "ENS_TRAMP_DIRECTORY")))
    (skip-unless remote-directory)
    (let ((default-directory
           (file-name-as-directory remote-directory)))
      (skip-unless (file-directory-p default-directory))
      (eshell-nix-shell-tests--with-eshell
        (let ((original (symbol-function 'eshell-nix-shell--make-capture))
              capture-files)
          (cl-letf (((symbol-function 'eshell-nix-shell--make-capture)
                     (lambda ()
                       (let ((capture (funcall original)))
                         (setq capture-files
                               (list (plist-get capture :environment-file)
                                     (plist-get capture :directory-file)))
                         capture))))
            (eshell-nix-shell-mode 1)
            (eshell-nix-shell-tests--command
             "nix-shell --argstr layer tramp")
            (should (equal (getenv "FAKE_LAYER") "tramp"))
            (should (seq-every-p #'file-remote-p capture-files))
            (should-not (seq-some #'file-exists-p capture-files))
            (should (string-match-p
                     "introduced:tramp"
                     (eshell-nix-shell-tests--command "ens-new-command")))
            (eshell-nix-shell-pop)
            (should-not eshell-nix-shell--environment-stack)))))))

(provide 'eshell-nix-shell-tests)
;;; eshell-nix-shell-tests.el ends here
