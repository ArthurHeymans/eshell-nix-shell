;;; eshell-nix-shell.el --- Activate Nix shells in Eshell  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Arthur Heymans
;;
;; Author: Arthur Heymans <arthur@aheymans.xyz>
;; Maintainer: Arthur Heymans <arthur@aheymans.xyz>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: processes, unix
;; URL: https://github.com/aheymans/eshell-nix-shell

;;; Commentary:

;; Activate a legacy nix-shell environment in the current Eshell buffer.
;; Exported scalar variables, but not Bash aliases, functions, or arrays, are
;; imported.  Add `eshell-nix-shell-mode' to `eshell-mode-hook' to enable it.

;;; Code:

(require 'cl-lib)
(require 'esh-cmd)
(require 'esh-ext)
(require 'esh-mode)
(require 'esh-proc)
(require 'esh-util)
(require 'pcomplete)
(require 'seq)
(require 'subr-x)

(defgroup eshell-nix-shell nil
  "Activate Nix shell environments in Eshell."
  :group 'eshell)

(defcustom eshell-nix-shell-executable "nix-shell"
  "Executable used to create Nix shell environments.
This may be an absolute path.  Command interception intentionally remains
attached to the unqualified Eshell command name `nix-shell'."
  :type 'string)

(defcustom eshell-nix-shell-debug nil
  "Whether to record activation lifecycle details in a debug buffer.
Diagnostics are written to `*eshell-nix-shell-debug*'.  Environment contents
are never logged."
  :type 'boolean)

(defcustom eshell-nix-shell-use-exit-advice t
  "Whether `exit' and end-of-file should pop an active Nix shell.
At an empty prompt, this makes `C-d' behave like it does in a regular nested
shell.  When `exit' pops an environment, evaluation of a compound Eshell form
continues."
  :type 'boolean)

(defcustom eshell-nix-shell-change-directory nil
  "Whether activation should adopt the directory selected by the shell hook."
  :type 'boolean)

(defcustom eshell-nix-shell-excluded-variables
  '("PS1" "PWD" "OLDPWD" "SHLVL" "_" "IN_NIX_SHELL" "NIX_BUILD_TOP"
    "NIX_BUILD_CORES" "TMPDIR" "TMP" "TEMP" "TEMPDIR")
  "Environment variable names that must not be imported from Nix.
The parent values of `INSIDE_EMACS' and `TERM' are always preserved too."
  :type '(repeat string))

(defcustom eshell-nix-shell-prompt-format-function
  #'eshell-nix-shell--default-prompt-format
  "Function used to format the current environment's prompt segment.
It receives the activation arguments and returns a string."
  :type 'function)

(defcustom eshell-nix-shell-keep-capture-files-on-error nil
  "Whether failed activation captures should be retained for debugging.
The private environment and directory files remain mode 0600 and their paths
are reported in Eshell.  Successful captures are always deleted."
  :type 'boolean)

(defcustom eshell-nix-shell-before-enter-hook nil
  "Hook run immediately before an imported environment is installed."
  :type 'hook)
(defcustom eshell-nix-shell-after-enter-hook nil
  "Hook run after an imported environment has been installed."
  :type 'hook)
(defcustom eshell-nix-shell-before-exit-hook nil
  "Hook run immediately before the innermost environment is restored."
  :type 'hook)
(defcustom eshell-nix-shell-after-exit-hook nil
  "Hook run after the innermost environment has been restored."
  :type 'hook)
(defcustom eshell-nix-shell-environment-change-hook nil
  "Hook run after either entering or leaving an environment."
  :type 'hook)

(defvar eshell-nix-shell-mode nil)

(cl-defstruct (eshell-nix-shell--frame
               (:constructor eshell-nix-shell--make-frame))
  name process-environment path exec-path exec-path-local-p default-directory
  activation-arguments metadata)

(defvar-local eshell-nix-shell--environment-stack nil)
(defvar-local eshell-nix-shell--pending-capture nil)
(defvar-local eshell-nix-shell--pending-process nil)
(defvar-local eshell-nix-shell--capture-files nil)

(defun eshell-nix-shell--debug (format-string &rest arguments)
  "Record FORMAT-STRING with ARGUMENTS when debugging is enabled."
  (when eshell-nix-shell-debug
    (with-current-buffer (get-buffer-create "*eshell-nix-shell-debug*")
      (goto-char (point-max))
      (insert (format-time-string "%Y-%m-%d %H:%M:%S ")
              (apply #'format format-string arguments) "\n"))))

(defun eshell-nix-shell--diagnose (format-string &rest arguments)
  "Report FORMAT-STRING with ARGUMENTS to Eshell and the message log."
  (let ((text (apply #'format format-string arguments)))
    (eshell-nix-shell--debug "%s" text)
    (message "%s" text)
    (when (derived-mode-p 'eshell-mode)
      (eshell-interactive-print (concat text "\n")))))

(defun eshell-nix-shell--env-value (name environment)
  "Return NAME's value in ENVIRONMENT, respecting its first occurrence."
  (let ((prefix (concat name "=")))
    (catch 'value
      (dolist (entry environment)
        (when (and (stringp entry) (string-prefix-p prefix entry))
          (throw 'value (substring entry (length prefix))))))))

(defun eshell-nix-shell--restore-frame (frame)
  "Restore all buffer state saved in FRAME."
  (with-suppressed-warnings ((lexical process-environment))
    (setq-local process-environment
                (copy-sequence
                 (eshell-nix-shell--frame-process-environment frame))))
  (eshell-set-path (copy-sequence (eshell-nix-shell--frame-path frame)))
  (if (eshell-nix-shell--frame-exec-path-local-p frame)
      (with-suppressed-warnings ((lexical exec-path))
        (setq-local exec-path
                    (copy-sequence
                     (eshell-nix-shell--frame-exec-path frame))))
    (kill-local-variable 'exec-path))
  (setq default-directory (eshell-nix-shell--frame-default-directory frame)))

(defun eshell-nix-shell--capture-frame (arguments)
  "Capture current buffer state in a frame labelled by ARGUMENTS."
  (eshell-nix-shell--make-frame
   :name "nix-shell"
   :process-environment (copy-sequence process-environment)
   :path (copy-sequence (eshell-get-path t))
   :exec-path (copy-sequence exec-path)
   :exec-path-local-p (local-variable-p 'exec-path)
   :default-directory default-directory
   :activation-arguments (copy-sequence arguments)))

(defun eshell-nix-shell--path-list (path)
  "Turn the possibly empty PATH string into an Eshell path list."
  (if (or (null path) (string-empty-p path))
      nil
    (split-string path
                  (regexp-quote (if (characterp path-separator)
                                    (char-to-string path-separator)
                                  path-separator))
                  nil)))

(defun eshell-nix-shell--exec-path (path)
  "Construct variable `exec-path' from PATH, preserving `exec-directory'."
  (append (eshell-nix-shell--path-list path)
          (and exec-directory (list exec-directory))))

(defun eshell-nix-shell--parse-nul-file (file)
  "Read FILE literally and return its NUL-delimited records."
  (with-temp-buffer
    (set-buffer-multibyte t)
    (let ((coding-system-for-read 'utf-8-emacs))
      (insert-file-contents file))
    (let ((text (buffer-string)))
      (unless (and (> (length text) 0)
                   (= (aref text (1- (length text))) 0))
        (error "Incomplete Nix shell capture"))
      (split-string text "\0" t))))

(defun eshell-nix-shell--parse-environment (file)
  "Parse NUL-delimited environment records from FILE.
Malformed entries are retained, and duplicate names use the first record."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (entry (eshell-nix-shell--parse-nul-file file) (nreverse result))
      (let ((equals (string-search "=" entry)))
        (if (not equals)
            (push entry result)
          (let ((name (substring entry 0 equals)))
            (unless (gethash name seen)
              (puthash name t seen)
              (push entry result))))))))

(defun eshell-nix-shell--filter-environment (environment old-environment)
  "Filter ENVIRONMENT and preserve special values from OLD-ENVIRONMENT."
  (let ((excluded (append eshell-nix-shell-excluded-variables
                          '("INSIDE_EMACS" "TERM")))
        result)
    (dolist (entry environment)
      (let ((equals (and (stringp entry) (string-search "=" entry))))
        (unless (and equals (member (substring entry 0 equals) excluded))
          (push entry result))))
    (dolist (name '("TERM" "INSIDE_EMACS"))
      (let ((value (eshell-nix-shell--env-value name old-environment)))
        (when value (push (concat name "=" value) result))))
    (nreverse result)))

(defun eshell-nix-shell--apply (environment directory arguments)
  "Atomically install ENVIRONMENT and DIRECTORY, recording ARGUMENTS."
  (let ((frame (eshell-nix-shell--capture-frame arguments))
        (old-stack eshell-nix-shell--environment-stack)
        committed)
    (unwind-protect
        (progn
          (run-hooks 'eshell-nix-shell-before-enter-hook)
          (with-suppressed-warnings ((lexical process-environment))
            (setq-local process-environment
                        (eshell-nix-shell--filter-environment
                         environment
                         (eshell-nix-shell--frame-process-environment frame))))
          (let ((path (eshell-nix-shell--env-value "PATH" process-environment)))
            (eshell-set-path (eshell-nix-shell--path-list path))
            (with-suppressed-warnings ((lexical exec-path))
              (setq-local exec-path (eshell-nix-shell--exec-path path))))
          (when eshell-nix-shell-change-directory
            (unless (and directory (file-directory-p directory)
                         (not (file-remote-p directory)))
              (error "Nix shell returned an invalid local directory"))
            (setq default-directory (file-name-as-directory directory)))
          (push frame eshell-nix-shell--environment-stack)
          (run-hooks 'eshell-nix-shell-after-enter-hook
                     'eshell-nix-shell-environment-change-hook)
          (setq committed t))
      (unless committed
        (setq eshell-nix-shell--environment-stack old-stack)
        (eshell-nix-shell--restore-frame frame)))
    t))

;;;###autoload
(defun eshell-nix-shell-pop ()
  "Leave the innermost Nix shell environment in the current Eshell buffer."
  (interactive)
  (unless eshell-nix-shell--environment-stack
    (user-error "No active Nix shell environment"))
  (run-hooks 'eshell-nix-shell-before-exit-hook)
  (let ((frame (pop eshell-nix-shell--environment-stack)))
    (eshell-nix-shell--restore-frame frame))
  (run-hooks 'eshell-nix-shell-after-exit-hook
             'eshell-nix-shell-environment-change-hook)
  t)

(defun eshell/nix-shell-exit ()
  "Leave the innermost Nix shell environment without exiting Eshell."
  (eshell-nix-shell-pop))

(defun eshell-nix-shell--make-capture ()
  "Create private environment and directory capture files."
  (let ((env (make-temp-file "eshell-nix-shell-env-")) cwd)
    (unwind-protect
        (progn
          (setq cwd (make-temp-file "eshell-nix-shell-cwd-"))
          (set-file-modes env #o600)
          (set-file-modes cwd #o600)
          (push env eshell-nix-shell--capture-files)
          (push cwd eshell-nix-shell--capture-files)
          (prog1 (list :environment-file env :directory-file cwd)
            (setq env nil cwd nil)))
      (when env (ignore-errors (delete-file env)))
      (when cwd (ignore-errors (delete-file cwd))))))

(defun eshell-nix-shell--payload (capture)
  "Return the Bash capture payload for CAPTURE."
  (format "{ for n in $(compgen -e); do printf \"%%s=%%s\\0\" \"$n\" \"${!n}\"; done; } > %s\nprintf \"%%s\\0\" \"$PWD\" > %s"
          (shell-quote-argument (plist-get capture :environment-file))
          (shell-quote-argument (plist-get capture :directory-file))))

(defun eshell-nix-shell--cleanup-capture (capture)
  "Delete all files belonging to CAPTURE and forget their names."
  (dolist (key '(:environment-file :directory-file))
    (let ((file (plist-get capture key)))
      (when file
        (ignore-errors (delete-file file))
        (setq eshell-nix-shell--capture-files
              (delete file eshell-nix-shell--capture-files)))))
  (setf (plist-get capture :environment-file) nil
        (plist-get capture :directory-file) nil))

(defun eshell-nix-shell--finish-capture (capture success)
  "Finish CAPTURE after SUCCESS, retaining failed files when requested."
  (if (or success (not eshell-nix-shell-keep-capture-files-on-error))
      (eshell-nix-shell--cleanup-capture capture)
    (let ((files (delq nil
                       (list (plist-get capture :environment-file)
                             (plist-get capture :directory-file)))))
      (dolist (file files)
        (setq eshell-nix-shell--capture-files
              (delete file eshell-nix-shell--capture-files)))
      (eshell-nix-shell--diagnose
       "Nix shell debug captures retained: %s"
       (string-join files ", ")))))

(defun eshell-nix-shell--cancel-pending ()
  "Cancel the current activation process without importing its capture."
  (when (processp eshell-nix-shell--pending-process)
    (process-put eshell-nix-shell--pending-process
                 'eshell-nix-shell--capture nil)
    (when (process-live-p eshell-nix-shell--pending-process)
      (delete-process eshell-nix-shell--pending-process)
      (while (process-live-p eshell-nix-shell--pending-process)
        (accept-process-output eshell-nix-shell--pending-process 0.01))))
  (setq eshell-nix-shell--pending-process nil
        eshell-nix-shell--pending-capture nil))

(defun eshell-nix-shell--cleanup-all ()
  "Cancel activation and delete all captures owned by the current buffer."
  (eshell-nix-shell--cancel-pending)
  (dolist (file eshell-nix-shell--capture-files)
    (ignore-errors (delete-file file)))
  (setq eshell-nix-shell--capture-files nil))

(defun eshell-nix-shell--import-capture (capture)
  "Validate and import CAPTURE into the current buffer."
  (let* ((environment (eshell-nix-shell--parse-environment
                       (plist-get capture :environment-file)))
         (directories (eshell-nix-shell--parse-nul-file
                       (plist-get capture :directory-file))))
    (unless (= (length directories) 1)
      (error "Invalid Nix shell directory capture"))
    (eshell-nix-shell--apply environment (car directories)
                             (plist-get capture :arguments))))

(defun eshell-nix-shell--kill-hook (process status)
  "Import a marked PROCESS capture after successful STATUS.
PROCESS may instead be a command string on synchronous platforms."
  (let ((capture (if (processp process)
                     (process-get process 'eshell-nix-shell--capture)
                   eshell-nix-shell--pending-capture)))
    (when capture
      ;; On platforms where `eshell-external-command' is synchronous there is
      ;; no process object to mark.  The buffer-local pending capture is the
      ;; compatibility fallback.  It assumes Eshell invokes this hook for the
      ;; command that has just returned; unlike the process property, it cannot
      ;; distinguish an unrelated process completing in the same buffer.
      (eshell-nix-shell--debug "Activation completed with status %S" status)
      (let (success)
        (unwind-protect
            (cond
             ((and (stringp status)
                   (string-match-p eshell-reset-signals status))
              (eshell-nix-shell--diagnose
               "Nix shell activation cancelled: %s" status))
             ((not (if (processp process)
                       (and (memq (process-status process) '(exit closed))
                            (= (process-exit-status process) 0))
                     (and (integerp status) (= status 0))))
              (eshell-nix-shell--diagnose "Nix shell activation failed"))
             (t
              (condition-case error-data
                  (progn
                    (eshell-nix-shell--import-capture capture)
                    (setq success t)
                    (eshell-nix-shell--debug
                     "Activation imported successfully"))
                (error
                 (eshell-nix-shell--diagnose
                  "Could not import Nix shell: %s"
                  (error-message-string error-data))))))
          (when (processp process)
            (process-put process 'eshell-nix-shell--capture nil))
          (setq eshell-nix-shell--pending-process nil
                eshell-nix-shell--pending-capture nil)
          (eshell-nix-shell--finish-capture capture success))))))

(defconst eshell-nix-shell--option-arities
  '(("--arg" . 2) ("--argstr" . 2) ("--option" . 2) ("-I" . 1)
    ("-A" . 1) ("--attr" . 1) ("-E" . 1) ("--expr" . 1)
    ("--keep" . 1) ("-j" . 1) ("--max-jobs" . 1) ("--cores" . 1)))

(defun eshell-nix-shell--activation-p (arguments)
  "Return non-nil when ARGUMENTS describe interactive activation."
  (let ((args arguments) activation)
    (setq activation t)
    (while args
      (let* ((argument (pop args))
             (arity (cdr (assoc argument eshell-nix-shell--option-arities))))
        (when (member argument '("--run" "--command" "--help" "-h" "--version"))
          (setq activation nil args nil))
        (dotimes (_ (or arity 0)) (when args (pop args)))))
    activation))

(defun eshell-nix-shell--unsupported-context-p ()
  "Return a description of the current unsupported Eshell context."
  (cond (eshell-in-pipeline-p "a pipeline")
        (eshell-current-subjob-p "a background job")
        (eshell-in-subcommand-p "a subcommand")))

(defun eshell-nix-shell--activate (&rest arguments)
  "Start an activation using ARGUMENTS as a deferrable Lisp command."
  (when (file-remote-p default-directory)
    (user-error "Nix shell activation is not supported in remote directories"))
  (when eshell-nix-shell--pending-capture
    (user-error "A Nix shell activation is already in progress"))
  (when-let ((context (eshell-nix-shell--unsupported-context-p)))
    (user-error "Nix shell activation is not supported in %s" context))
  (dolist (argument arguments)
    (when (and (stringp argument) (string-search "\0" argument))
      (user-error "Nix shell arguments may not contain NUL bytes")))
  (let* ((capture (eshell-nix-shell--make-capture))
         (payload (eshell-nix-shell--payload capture))
         (args (append arguments (list "--run" payload)))
         result)
    (setf (plist-get capture :arguments) (copy-sequence arguments))
    (setq eshell-nix-shell--pending-capture capture)
    (eshell-nix-shell--debug "Starting activation with %d argument(s)"
                             (length arguments))
    (condition-case error-data
        (progn
          (setq result (eshell-external-command
                        eshell-nix-shell-executable args))
          (when (processp result)
            (process-put result 'eshell-nix-shell--capture capture)
            (setq eshell-nix-shell--pending-process result))
          (throw 'eshell-external result))
      (error
       (setq eshell-nix-shell--pending-process nil
             eshell-nix-shell--pending-capture nil)
       (eshell-nix-shell--cleanup-capture capture)
       (signal (car error-data) (cdr error-data))))))

(put 'eshell-nix-shell--activate 'eshell-no-numeric-conversions t)

(defun eshell-nix-shell--command-handler (command arguments)
  "Handle unqualified COMMAND with ARGUMENTS when it is an activation."
  (when (and (string= command "nix-shell")
             (eshell-nix-shell--activation-p arguments))
    (when-let ((context (eshell-nix-shell--unsupported-context-p)))
      (user-error "Nix shell activation is not supported in %s" context))
    (eshell-lisp-command #'eshell-nix-shell--activate arguments)))

(defun eshell-nix-shell--which (command)
  "Describe interception of COMMAND for Eshell's `which' command."
  (when (string= command "nix-shell")
    (let ((external (eshell-external-command--which
                     eshell-nix-shell-executable)))
      (format "%s (activation managed by eshell-nix-shell-mode)"
              (or external eshell-nix-shell-executable)))))

(put 'eshell-nix-shell--command-handler 'eshell-which-function
     #'eshell-nix-shell--which)

(defun eshell-nix-shell--default-prompt-format (arguments)
  "Format a default prompt label from activation ARGUMENTS."
  (if arguments
      (let* ((package-tail
              (cdr (cl-member-if (lambda (argument)
                                (member argument '("-p" "--packages")))
                              arguments)))
             (packages
              (and package-tail
                   (seq-take-while
                    (lambda (argument)
                      (not (string-prefix-p "-" argument)))
                    package-tail))))
        (format "[nix-shell: %s]"
                (string-join (or packages arguments) " ")))
    "[nix-shell]"))

;;;###autoload
(defun eshell-nix-shell-prompt-segment ()
  "Return a prompt segment describing the innermost active Nix shell.
Return the empty string when no environment is active."
  (if-let ((frame (car eshell-nix-shell--environment-stack)))
      (funcall eshell-nix-shell-prompt-format-function
               (eshell-nix-shell--frame-activation-arguments frame))
    ""))

(defun eshell-nix-shell--exit-advice (original &rest arguments)
  "Call ORIGINAL with ARGUMENTS, or pop the active environment."
  (if (and eshell-nix-shell-use-exit-advice
           (bound-and-true-p eshell-nix-shell-mode)
           eshell-nix-shell--environment-stack)
      (eshell-nix-shell-pop)
    (apply original arguments)))

(defun eshell-nix-shell--eof-advice (original &rest arguments)
  "Call ORIGINAL with ARGUMENTS, or pop the active environment.
This advises `eshell-life-is-too-much', which is reached by Eshell's standard
end-of-file command and by common Eshell configurations that bind `C-d'."
  (if (and eshell-nix-shell-use-exit-advice
           (bound-and-true-p eshell-nix-shell-mode)
           eshell-nix-shell--environment-stack)
      (eshell-nix-shell-pop)
    (apply original arguments)))

(defun eshell-nix-shell--ctrl-d ()
  "Pop an active environment at an empty prompt, otherwise handle `C-d'.
The fallback command is resolved with this minor mode temporarily disabled, so
user configurations such as Doom Eshell retain their normal delete-or-exit
behavior."
  (interactive)
  (if (and eshell-nix-shell--environment-stack
           (eobp)
           (= (point) eshell-last-output-end)
           (not (eshell-head-process)))
      (eshell-nix-shell-pop)
    (let* ((eshell-nix-shell-mode nil)
           (fallback (key-binding (kbd "C-d"))))
      (unless (commandp fallback)
        (user-error "No underlying Eshell C-d command"))
      (call-interactively fallback))))

(defvar eshell-nix-shell-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-d") #'eshell-nix-shell--ctrl-d)
    map)
  "Keymap for `eshell-nix-shell-mode'.")

(defun eshell-nix-shell--disable (&optional force)
  "Remove local integration and restore frames; FORCE cancels activation."
  (when (and eshell-nix-shell--pending-capture (not force))
    (setq eshell-nix-shell-mode t)
    (user-error "Cannot disable mode while Nix shell activation is in progress"))
  (let (first-error)
    (unwind-protect
        (while eshell-nix-shell--environment-stack
          (let ((stack eshell-nix-shell--environment-stack))
            (condition-case error-data
                (eshell-nix-shell-pop)
              (t
               (unless first-error (setq first-error error-data))
               (when (eq stack eshell-nix-shell--environment-stack)
                 (eshell-nix-shell--restore-frame (pop eshell-nix-shell--environment-stack)))))))
      (remove-hook 'eshell-named-command-hook
                   #'eshell-nix-shell--command-handler t)
      (remove-hook 'eshell-kill-hook #'eshell-nix-shell--kill-hook t)
      (remove-hook 'kill-buffer-hook #'eshell-nix-shell--cleanup-all t)
      (eshell-nix-shell--cleanup-all))
    (when (and first-error (not force))
      (signal (car first-error) (cdr first-error)))))

;;;###autoload
(define-minor-mode eshell-nix-shell-mode
  "Manage interactive legacy Nix shell environments in this Eshell buffer.
Disabling the mode restores all active environments in last-in, first-out
order.  It refuses to disable while activation is in progress."
  :lighter " NixSh"
  (if eshell-nix-shell-mode
      (progn
        (unless (derived-mode-p 'eshell-mode)
          (setq eshell-nix-shell-mode nil)
          (user-error "Eshell Nix Shell mode only works in Eshell buffers"))
        (add-hook 'eshell-named-command-hook
                  #'eshell-nix-shell--command-handler nil t)
        (add-hook 'eshell-kill-hook #'eshell-nix-shell--kill-hook -90 t)
        (add-hook 'kill-buffer-hook #'eshell-nix-shell--cleanup-all nil t))
    (eshell-nix-shell--disable)))

(defconst eshell-nix-shell--completion-options
  '("-p" "--packages" "--pure" "--keep" "-I" "-A" "--attr" "-E"
    "--expr" "--arg" "--argstr" "--option" "-j" "--max-jobs" "--cores"
    "--run" "--command" "--help" "--version"))

(defun pcomplete/eshell-mode/nix-shell ()
  "Complete legacy `nix-shell' options and Nix expression file names.
Package-name completion is an intentionally reserved extension point."
  (while (pcomplete-here* eshell-nix-shell--completion-options)
    (let ((previous (pcomplete-arg -1)))
      (cond
       ((member previous '("-A" "--attr" "-E" "--expr" "--keep" "-j"
                           "--max-jobs" "--cores"))
        (pcomplete-here))
       ((member previous '("-I"))
        (pcomplete-here (pcomplete-entries)))
       ;; Extension point: cached/asynchronous package completion after -p.
       (t (pcomplete-here (pcomplete-entries nil (lambda (file)
                                                   (string-suffix-p ".nix" file)))))))))

(advice-add 'eshell/exit :around #'eshell-nix-shell--exit-advice)
(advice-add 'eshell-life-is-too-much :around #'eshell-nix-shell--eof-advice)

(defun eshell-nix-shell-unload-function ()
  "Restore managed Eshell buffers and remove global integration."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (or (bound-and-true-p eshell-nix-shell-mode)
                eshell-nix-shell--environment-stack
                eshell-nix-shell--pending-capture)
        (setq eshell-nix-shell-mode nil)
        (eshell-nix-shell--disable t))))
  (advice-remove 'eshell/exit #'eshell-nix-shell--exit-advice)
  (advice-remove 'eshell-life-is-too-much #'eshell-nix-shell--eof-advice)
  nil)

(provide 'eshell-nix-shell)

;;; eshell-nix-shell.el ends here
