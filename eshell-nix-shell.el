;;; eshell-nix-shell.el --- Activate Nix shells in Eshell  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Arthur Heymans
;;
;; Author: Arthur Heymans <arthur@aheymans.xyz>
;; Assisted-by: OpenAI Codex:gpt-5.6-sol
;; Maintainer: Arthur Heymans <arthur@aheymans.xyz>
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: processes, unix
;; URL: https://github.com/aheymans/eshell-nix-shell

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

;; Activate `nix-shell', `nix shell', and `nix develop' environments in the
;; current Eshell buffer.  Exported scalar variables, but not Bash aliases,
;; functions, or arrays, are imported.  Add `eshell-nix-shell-mode' to
;; `eshell-mode-hook' to enable it.

;;; Code:

(require 'cl-lib)
(require 'esh-cmd)
(require 'esh-ext)
(require 'esh-mode)
(require 'esh-proc)
(require 'esh-util)
(require 'esh-var)
(require 'pcomplete)
(require 'seq)
(require 'subr-x)

(defgroup eshell-nix-shell nil
  "Activate Nix shell environments in Eshell."
  :group 'eshell)

(defface eshell-nix-shell-prompt
  '((t :inherit font-lock-keyword-face))
  "Face used for the Nix shell prompt indicator."
  :group 'eshell-nix-shell)

(defcustom eshell-nix-shell-executable "nix-shell"
  "Executable used to create legacy Nix shell environments.
This may be an absolute path.  Command interception intentionally remains
attached to the unqualified Eshell command name `nix-shell'."
  :type 'string)

(defcustom eshell-nix-executable "nix"
  "Executable used for `nix shell' and `nix develop' environments.
This may be an absolute path.  Command interception intentionally remains
attached to the unqualified Eshell command name `nix'."
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

(defcustom eshell-nix-shell-integrate-prompt t
  "Whether the mode should prepend its segment to the existing prompt.
The existing `eshell-prompt-function' remains responsible for the main prompt;
the Nix indicator is added on a separate line and disappears at stack depth
zero.  This option is consulted when the mode is enabled; toggle the mode after
changing it in an existing Eshell buffer."
  :type 'boolean)

(defcustom eshell-nix-shell-keep-capture-files-on-error nil
  "Whether failed activation captures should be retained for debugging.
The private environment and directory files remain mode 0600 and their paths
are reported in Eshell.  Successful captures are always deleted."
  :type 'boolean)

(defcustom eshell-nix-shell-process-kill-timeout 5.0
  "Seconds to wait for a cancelled activation process to terminate.
A process blocked in an uninterruptible system call, such as one waiting on an
unresponsive remote connection, cannot be reaped.  Waiting forever would hang
Emacs, so the wait is abandoned after this many seconds and reported instead."
  :type 'number)

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
  process-environment path exec-path exec-path-local-p default-directory
  remote-environment remote-path-active-p activation-arguments)

(defvar-local eshell-nix-shell--environment-stack nil)
(defvar-local eshell-nix-shell--pending-capture nil)
(defvar-local eshell-nix-shell--pending-process nil)
(defvar-local eshell-nix-shell--capture-files nil)
(defvar-local eshell-nix-shell--saved-prompt-function nil)
(defvar-local eshell-nix-shell--remote-environment nil)
(defvar-local eshell-nix-shell--remote-path nil)
(defvar-local eshell-nix-shell--remote-path-active-p nil)
(defvar-local eshell-nix-shell--prompt-function-was-local-p nil)
(defvar-local eshell-nix-shell--prompt-installed-p nil)
(defvar-local eshell-nix-shell--advice-claimed-p nil)

(defmacro eshell-nix-shell--setq-local-env (variable value)
  "Set buffer-local VARIABLE to VALUE without a `lexical-binding' warning.
VARIABLE must be a symbol naming one of the dynamic environment variables
that Eshell rebinds, such as `process-environment' or variable `exec-path'."
  (declare (indent 1) (debug (symbolp form)))
  `(with-suppressed-warnings ((lexical ,variable))
     (setq-local ,variable ,value)))

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
  ;; `getenv-internal' falls back to `process-environment' for a nil
  ;; ENVIRONMENT; an empty environment must define nothing here.
  (and environment (getenv-internal name environment)))

(defun eshell-nix-shell--env-entry (name environment)
  "Return NAME's entry in ENVIRONMENT, including an unset marker."
  (let ((prefix (concat name "=")))
    (seq-find (lambda (entry)
                (and (stringp entry)
                     (or (string= entry name)
                         (string-prefix-p prefix entry))))
              environment)))

(defun eshell-nix-shell--get-path-advice (original &optional literal-p)
  "Use the buffer's managed remote path, or call ORIGINAL.
When LITERAL-P is non-nil, do not add the remote file-name prefix."
  (if (and eshell-nix-shell--remote-path-active-p
           (file-remote-p default-directory))
      (let ((path (copy-sequence eshell-nix-shell--remote-path)))
        (if literal-p
            path
          (let ((remote (file-remote-p default-directory)))
            (mapcar (lambda (directory) (concat remote directory)) path))))
    (funcall original literal-p)))

(defun eshell-nix-shell--set-path-advice (original path)
  "Set the managed per-buffer remote PATH, or call ORIGINAL with PATH."
  (if (and eshell-nix-shell--remote-path-active-p
           (file-remote-p default-directory))
      (setq eshell-nix-shell--remote-path
            (if (listp path)
                (copy-sequence path)
              (eshell-nix-shell--path-list path)))
    (funcall original path)))

(defun eshell-nix-shell--get-variable-advice
    (original name &optional indices quoted)
  "Read imported remote NAME before calling ORIGINAL.
INDICES and QUOTED have the meaning used by `eshell-get-variable'."
  (let ((entry (and (stringp name)
                    (file-remote-p default-directory)
                    (not (assoc name eshell-variable-aliases-list))
                    (eshell-nix-shell--env-entry
                     name eshell-nix-shell--remote-environment))))
    (if entry
        (eshell-apply-indices
         (and (string-search "=" entry)
              (substring entry (1+ (string-search "=" entry))))
         indices quoted)
      (funcall original name indices quoted))))

(defun eshell-nix-shell--tramp-local-environment-variable-advice
    (original argument)
  "Keep imported remote ARGUMENT eligible for propagation by Tramp.
Call ORIGINAL for variables not managed by the active Nix environment."
  (if (and (file-remote-p default-directory)
           (member argument eshell-nix-shell--remote-environment))
      nil
    (funcall original argument)))

(defun eshell-nix-shell--restore-frame (frame)
  "Restore all buffer state saved in FRAME."
  (eshell-nix-shell--setq-local-env process-environment
    (copy-sequence
     (eshell-nix-shell--frame-process-environment frame)))
  (setq eshell-nix-shell--remote-environment
        (copy-sequence
         (eshell-nix-shell--frame-remote-environment frame)))
  (if (eshell-nix-shell--frame-remote-path-active-p frame)
      (setq eshell-nix-shell--remote-path
            (copy-sequence (eshell-nix-shell--frame-path frame))
            eshell-nix-shell--remote-path-active-p t)
    (setq eshell-nix-shell--remote-path nil
          eshell-nix-shell--remote-path-active-p nil)
    (unless (file-remote-p
             (eshell-nix-shell--frame-default-directory frame))
      (eshell-set-path
       (copy-sequence (eshell-nix-shell--frame-path frame)))))
  (if (eshell-nix-shell--frame-exec-path-local-p frame)
      (eshell-nix-shell--setq-local-env exec-path
        (copy-sequence (eshell-nix-shell--frame-exec-path frame)))
    (kill-local-variable 'exec-path))
  (setq default-directory (eshell-nix-shell--frame-default-directory frame)))

(defun eshell-nix-shell--capture-frame (arguments)
  "Capture current buffer state in a frame labelled by ARGUMENTS."
  (eshell-nix-shell--make-frame
   :process-environment (copy-sequence process-environment)
   :path (copy-sequence (eshell-get-path t))
   :exec-path (copy-sequence exec-path)
   :exec-path-local-p (local-variable-p 'exec-path)
   :default-directory default-directory
   :remote-environment (copy-sequence eshell-nix-shell--remote-environment)
   :remote-path-active-p eshell-nix-shell--remote-path-active-p
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
  "Read FILE literally and return its NUL-delimited records.
Environment values are arbitrary byte strings, so the file is read without any
decoding or end-of-line conversion and each record is decoded afterwards.
Bytes that are not valid UTF-8 survive as raw bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (let ((text (buffer-string)))
      (unless (and (> (length text) 0)
                   (= (aref text (1- (length text))) 0))
        (error "Incomplete Nix shell capture"))
      (mapcar (lambda (record)
                (decode-coding-string record 'utf-8-emacs-unix))
              (split-string text "\0" t)))))

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
      ;; An entry without "=" is an unset marker naming the variable itself.
      (let ((name (and (stringp entry)
                       (if-let* ((equals (string-search "=" entry)))
                           (substring entry 0 equals)
                         entry))))
        (unless (and name (member name excluded))
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
          (let* ((filtered
                  (eshell-nix-shell--filter-environment
                   environment
                   (eshell-nix-shell--frame-process-environment frame)))
                 (path (eshell-nix-shell--env-value "PATH" filtered)))
            (eshell-nix-shell--setq-local-env process-environment
              (if (file-remote-p default-directory)
                  ;; Tramp launches its local transport with this variable,
                  ;; then forwards entries that differ from the top-level
                  ;; environment.  Keep the local entries first so commands
                  ;; such as ssh, podman, and kubectl remain launchable.
                  (append (copy-sequence
                           (default-toplevel-value 'process-environment))
                          filtered)
                filtered))
            (if (file-remote-p default-directory)
                (setq eshell-nix-shell--remote-environment
                      (seq-remove
                       (lambda (entry)
                         (member (substring entry 0 (string-search "=" entry))
                                 '("TERM" "INSIDE_EMACS")))
                       filtered)
                      eshell-nix-shell--remote-path
                      (eshell-nix-shell--path-list path)
                      eshell-nix-shell--remote-path-active-p t)
              (setq eshell-nix-shell--remote-environment nil
                    eshell-nix-shell--remote-path nil
                    eshell-nix-shell--remote-path-active-p nil)
              (eshell-set-path (eshell-nix-shell--path-list path))
              (eshell-nix-shell--setq-local-env exec-path
                (eshell-nix-shell--exec-path path))))
          (when eshell-nix-shell-change-directory
            (unless (and directory (file-directory-p directory))
              (error "Nix shell returned an invalid directory"))
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
  "Create private environment and directory capture files.
On a remote Eshell, create the files on the same host as the shell."
  (let ((remote-prefix (file-remote-p default-directory))
        ;; Create the files with restrictive modes rather than tightening them
        ;; afterwards: a umask-dependent creation mode would leave a window in
        ;; which the environment dump is readable by other users.
        (env (with-file-modes #o600
               (make-nearby-temp-file "eshell-nix-shell-env-")))
        cwd)
    (unwind-protect
        (progn
          (setq cwd (with-file-modes #o600
                      (make-nearby-temp-file "eshell-nix-shell-cwd-")))
          ;; Belt and braces for back ends that ignore `with-file-modes'.
          (set-file-modes env #o600)
          (set-file-modes cwd #o600)
          (push env eshell-nix-shell--capture-files)
          (push cwd eshell-nix-shell--capture-files)
          (prog1 (list :environment-file env
                       :directory-file cwd
                       :remote-prefix remote-prefix)
            (setq env nil cwd nil)))
      (when env (ignore-errors (delete-file env)))
      (when cwd (ignore-errors (delete-file cwd))))))

(defun eshell-nix-shell--payload (capture)
  "Return the Bash capture payload for CAPTURE."
  (format "{ for n in $(compgen -e); do printf \"%%s=%%s\\0\" \"$n\" \"${!n}\"; done; } > %s\nprintf \"%%s\\0\" \"$PWD\" > %s"
          (shell-quote-argument
           (file-local-name (plist-get capture :environment-file)))
          (shell-quote-argument
           (file-local-name (plist-get capture :directory-file)))))

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
      ;; A process wedged in an uninterruptible system call, for instance one
      ;; waiting on a dead remote connection, never becomes reapable.  Give up
      ;; after the configured deadline instead of hanging Emacs.
      (let ((process eshell-nix-shell--pending-process)
            (deadline (+ (float-time)
                         (max 0 eshell-nix-shell-process-kill-timeout))))
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.01))
        (when (process-live-p process)
          (eshell-nix-shell--diagnose
           "Nix shell activation process %s did not terminate within %ss"
           (process-name process)
           eshell-nix-shell-process-kill-timeout)))))
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
                       (plist-get capture :directory-file)))
         (directory (car directories))
         (remote-prefix (plist-get capture :remote-prefix)))
    (unless (= (length directories) 1)
      (error "Invalid Nix shell directory capture"))
    (when remote-prefix
      (setq directory (concat remote-prefix directory)))
    (eshell-nix-shell--apply environment directory
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
  '(("--arg" . 2) ("--argstr" . 2) ("--option" . 2)
    ("-I" . 1) ("--include" . 1)
    ("-A" . 1) ("--attr" . 1) ("-E" . 1) ("--expr" . 1)
    ("--keep" . 1) ("-j" . 1) ("--max-jobs" . 1) ("--cores" . 1)
    ("--timeout" . 1) ("--max-silent-time" . 1) ("--builders" . 1)
    ("--substituters" . 1) ("--log-format" . 1)
    ("-o" . 1) ("--out-link" . 1) ("--add-root" . 1))
  "Number of values consumed by each legacy `nix-shell' option.
Options absent from this table are assumed to take no value; a missing entry
can only misclassify an invocation whose option value happens to be one of the
pass-through flags, such as a literal --run.")

(defun eshell-nix-shell--activation-p (arguments)
  "Return non-nil when ARGUMENTS describe interactive activation."
  (let ((args arguments) (activation t))
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

(defun eshell-nix-shell--check-context ()
  "Signal a `user-error' when the current Eshell context is unsupported.
This is the single choke point for the check; both the command handler and the
deferred Lisp command call it, because the handler must reject the invocation
before Eshell commits to a Lisp command, while the Lisp command can also be
called directly."
  (when-let* ((context (eshell-nix-shell--unsupported-context-p)))
    (user-error "Nix shell activation is not supported in %s" context)))

(defun eshell-nix-shell--activate (kind &rest arguments)
  "Start a KIND activation using ARGUMENTS as a deferrable Lisp command."
  (when eshell-nix-shell--pending-capture
    (user-error "A Nix shell activation is already in progress"))
  (eshell-nix-shell--check-context)
  (dolist (argument (cons kind arguments))
    (when (and (stringp argument) (string-search "\0" argument))
      (user-error "Nix shell arguments may not contain NUL bytes")))
  (let* ((legacy-p (string= kind "nix-shell"))
         (executable (if legacy-p
                         eshell-nix-shell-executable
                       eshell-nix-executable))
         (capture-shell
          (unless legacy-p
            (or (eshell-nix-shell--external-file-name "bash")
                (user-error "Bash is required for Nix environment capture"))))
         (capture (eshell-nix-shell--make-capture))
         (payload (eshell-nix-shell--payload capture))
         (activation-arguments (if legacy-p
                                   arguments
                                 (cons kind arguments)))
         (args (if legacy-p
                   (append arguments (list "--run" payload))
                 (append activation-arguments
                         (list "--command" capture-shell "-c" payload))))
         result)
    (setf (plist-get capture :arguments)
          (copy-sequence activation-arguments))
    (setq eshell-nix-shell--pending-capture capture)
    (eshell-nix-shell--debug "Starting activation with %d argument(s)"
                             (length arguments))
    (condition-case error-data
        (progn
          (setq result (eshell-external-command executable args))
          (when (processp result)
            (process-put result 'eshell-nix-shell--capture capture)
            (setq eshell-nix-shell--pending-process result))
          ;; `eshell-lisp-command' catches this tag to hand its caller the
          ;; external command's result unchanged.  The tag is an Eshell
          ;; internal, so a release that drops it must not break activation:
          ;; without a catch the throw signals `no-catch' and the result is
          ;; simply returned instead.
          (condition-case nil
              (throw 'eshell-external result)
            (no-catch
             (eshell-nix-shell--debug
              "No `eshell-external' catch in this Emacs; returning result")
             result)))
      (error
       (setq eshell-nix-shell--pending-process nil
             eshell-nix-shell--pending-capture nil)
       (eshell-nix-shell--cleanup-capture capture)
       (signal (car error-data) (cdr error-data))))))

(put 'eshell-nix-shell--activate 'eshell-no-numeric-conversions t)

(defconst eshell-nix-shell--modern-pass-through-options
  '("--command" "-c" "--help" "-h" "--version")
  "Modern Nix options that make an invocation non-interactive.")

(defconst eshell-nix-shell--develop-phase-options
  '("--unpack" "--configure" "--build" "--check" "--install"
    "--installcheck" "--phase")
  "`nix develop' options that run a build phase instead of a shell.")

(defconst eshell-nix-shell--modern-option-arities
  '(("--arg-from-file" . 2) ("--arg-from-stdin" . 1)
    ("--eval-store" . 1) ("--experimental-features" . 1)
    ("--extra-experimental-features" . 1) ("--file" . 1) ("-f" . 1)
    ("--inputs-from" . 1) ("--keep-env-var" . 1) ("-k" . 1)
    ("--output-lock-file" . 1) ("--override-flake" . 2)
    ("--override-input" . 2) ("--profile" . 1)
    ("--redirect" . 2) ("--reference-lock-file" . 1)
    ("--set-env-var" . 2) ("-s" . 2) ("--store" . 1)
    ("--unset-env-var" . 1) ("-u" . 1) ("--update-input" . 1))
  "Number of values consumed by modern Nix options not in the legacy table.")

(defun eshell-nix-shell--modern-invocation (arguments)
  "Normalize supported modern Nix ARGUMENTS, or return nil.
Global options preceding the subcommand are moved after it because the
activation function receives the subcommand separately."
  (let ((args arguments) prefix)
    (while (and args (string-prefix-p "-" (car args)))
      (let* ((option (pop args))
             (arity (or (cdr (assoc option
                                    eshell-nix-shell--modern-option-arities))
                        (cdr (assoc option
                                    eshell-nix-shell--option-arities))
                        0)))
        (push option prefix)
        (dotimes (_ arity)
          (when args (push (pop args) prefix)))))
    (when (member (car args) '("shell" "develop"))
      (cons (car args) (append (nreverse prefix) (cdr args))))))

(defun eshell-nix-shell--modern-activation-p (kind arguments)
  "Return non-nil when `nix' KIND with ARGUMENTS should be activated."
  (when (member kind '("shell" "develop"))
    (let ((args arguments) (activation t))
      (while args
        (let* ((argument (pop args))
               (arity (or (cdr (assoc argument
                                      eshell-nix-shell--modern-option-arities))
                          (cdr (assoc argument
                                      eshell-nix-shell--option-arities)))))
          (when (or (member argument
                            eshell-nix-shell--modern-pass-through-options)
                    (and (string= kind "develop")
                         (member argument
                                 eshell-nix-shell--develop-phase-options)))
            (setq activation nil args nil))
          (dotimes (_ (or arity 0)) (when args (pop args)))))
      activation)))

(defun eshell-nix-shell--command-handler (command arguments)
  "Handle unqualified COMMAND with ARGUMENTS when it is an activation."
  (cond
   ((and (string= command "nix-shell")
         (eshell-nix-shell--activation-p arguments))
    (eshell-nix-shell--check-context)
    (eshell-lisp-command #'eshell-nix-shell--activate
                         (cons "nix-shell" arguments)))
   ((string= command "nix")
    (when-let* ((invocation (eshell-nix-shell--modern-invocation arguments))
                (kind (car invocation))
                (modern-arguments (cdr invocation))
                ((eshell-nix-shell--modern-activation-p
                  kind modern-arguments)))
      (eshell-nix-shell--check-context)
      (eshell-lisp-command #'eshell-nix-shell--activate invocation)))))

(defun eshell-nix-shell--external-file-name (command)
  "Return the file name Eshell would run for external COMMAND, or nil.
Eshell's own resolver is preferred, with a public fallback for Emacs versions
that do not provide it."
  (cond
   ((fboundp 'eshell-external-command--which)
    (eshell-external-command--which command))
   ((file-name-directory command)
    (and (file-executable-p command) command))
   (t (eshell-search-path command))))

(defun eshell-nix-shell--which (command)
  "Describe interception of COMMAND for Eshell's `which' command."
  (when (member command '("nix-shell" "nix"))
    (let* ((configured (if (string= command "nix-shell")
                           eshell-nix-shell-executable
                         eshell-nix-executable))
           (external (eshell-nix-shell--external-file-name configured)))
      (format "%s (activation managed by eshell-nix-shell-mode)"
              (or external configured)))))

(put 'eshell-nix-shell--command-handler 'eshell-which-function
     #'eshell-nix-shell--which)

(defun eshell-nix-shell--default-prompt-format (arguments)
  "Format a default prompt label from activation ARGUMENTS."
  (let* ((modern-kind (and (member (car arguments) '("shell" "develop"))
                           (car arguments)))
         (display-arguments (if modern-kind (cdr arguments) arguments))
         (package-tail
          (cdr (cl-member-if (lambda (argument)
                               (member argument '("-p" "--packages")))
                             display-arguments)))
         (packages
          (and package-tail
               (seq-take-while
                (lambda (argument)
                  (not (string-prefix-p "-" argument)))
                package-tail)))
         (command-label (if modern-kind
                            (concat "nix " modern-kind)
                          "nix-shell"))
         (label (if display-arguments
                    (format "❄ %s  %s" command-label
                            (string-join (or packages display-arguments) " "))
                  (format "❄ %s" command-label))))
    (propertize label 'face 'eshell-nix-shell-prompt)))

;;;###autoload
(defun eshell-nix-shell-prompt-segment ()
  "Return a prompt segment describing the innermost active Nix shell.
Return the empty string when no environment is active."
  (if-let* ((frame (car eshell-nix-shell--environment-stack)))
      (funcall eshell-nix-shell-prompt-format-function
               (eshell-nix-shell--frame-activation-arguments frame))
    ""))

(defun eshell-nix-shell--prompt-function ()
  "Return the existing Eshell prompt with a Nix shell indicator prepended."
  (let ((prompt (funcall eshell-nix-shell--saved-prompt-function))
        (segment (eshell-nix-shell-prompt-segment)))
    (if (string-empty-p segment)
        prompt
      (if (string-prefix-p "\n" prompt)
          (concat "\n" segment "\n" (substring prompt 1))
        (concat segment "\n" prompt)))))

(defun eshell-nix-shell--install-prompt ()
  "Install buffer-local prompt integration when requested."
  (with-suppressed-warnings ((free-vars eshell-prompt-function)
                             (lexical eshell-prompt-function))
    (when (and eshell-nix-shell-integrate-prompt
               eshell-prompt-function
               (not eshell-nix-shell--prompt-installed-p))
      (setq eshell-nix-shell--saved-prompt-function eshell-prompt-function
            eshell-nix-shell--prompt-function-was-local-p
            (local-variable-p 'eshell-prompt-function)
            eshell-nix-shell--prompt-installed-p t)
      (setq-local eshell-prompt-function
                  #'eshell-nix-shell--prompt-function))))

(defun eshell-nix-shell--remove-prompt ()
  "Remove prompt integration and restore the previous prompt function."
  (with-suppressed-warnings ((free-vars eshell-prompt-function)
                             (lexical eshell-prompt-function))
    (when eshell-nix-shell--prompt-installed-p
      (if (eq eshell-prompt-function #'eshell-nix-shell--prompt-function)
          (if eshell-nix-shell--prompt-function-was-local-p
              (setq-local eshell-prompt-function
                          eshell-nix-shell--saved-prompt-function)
            (kill-local-variable 'eshell-prompt-function))
        (eshell-nix-shell--debug
         "Prompt wrapper changed by another package; not restoring saved prompt"))
      (setq eshell-nix-shell--saved-prompt-function nil
            eshell-nix-shell--prompt-function-was-local-p nil
            eshell-nix-shell--prompt-installed-p nil))))

(defun eshell-nix-shell--exit-advice (original &rest arguments)
  "Call ORIGINAL with ARGUMENTS, or pop the active environment."
  (if (and eshell-nix-shell-use-exit-advice
           (bound-and-true-p eshell-nix-shell-mode)
           eshell-nix-shell--environment-stack)
      (progn
        (eshell-nix-shell-pop)
        nil)
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
      (progn
        (eshell-nix-shell-pop)
        ;; Submit the empty input so Eshell emits a fresh prompt using the
        ;; restored outer environment instead of leaving the old indicator.
        (eshell-send-input))
    ;; `minor-mode-map-alist' consults the mode variable's current value.
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

(defconst eshell-nix-shell--required-internals
  '(eshell-external-command eshell-lisp-command eshell-get-path
    eshell-set-path eshell-get-variable eshell-external-command--which)
  "Eshell functions this package builds on.
Some of them, notably `eshell-external-command--which' and the
`eshell-external' catch used by `eshell-lisp-command', are internal to Eshell
and may change between Emacs releases.  Missing pieces degrade gracefully, and
`eshell-nix-shell--verify-internals' reports them once.")

(defvar eshell-nix-shell--internals-verified-p nil
  "Non-nil once the Eshell integration points have been checked.")

(defun eshell-nix-shell--verify-internals ()
  "Warn once about Eshell integration points missing from this Emacs."
  (unless eshell-nix-shell--internals-verified-p
    (setq eshell-nix-shell--internals-verified-p t)
    (when-let* ((missing (seq-remove #'fboundp
                                     eshell-nix-shell--required-internals)))
      (display-warning
       'eshell-nix-shell
       (format (concat "This Emacs (%s) lacks the Eshell function(s) %s; "
                       "eshell-nix-shell may behave unexpectedly")
               emacs-version
               (mapconcat #'symbol-name missing ", "))
       :warning))))

(defvar eshell-nix-shell--advice-users 0
  "Number of buffers that currently require the global advice.")

(defconst eshell-nix-shell--advice
  '((eshell/exit . eshell-nix-shell--exit-advice)
    (eshell-get-path . eshell-nix-shell--get-path-advice)
    (eshell-set-path . eshell-nix-shell--set-path-advice)
    (eshell-get-variable . eshell-nix-shell--get-variable-advice)
    (tramp-local-environment-variable-p
     . eshell-nix-shell--tramp-local-environment-variable-advice))
  "Alist of globally advised functions and their `:around' advice.")

(defun eshell-nix-shell--install-advice ()
  "Install the global advice this package needs.
Installation is deferred to the first buffer that enables the mode so that
merely loading the library changes no behavior."
  (eshell-nix-shell--verify-internals)
  (pcase-dolist (`(,symbol . ,function) eshell-nix-shell--advice)
    (advice-add symbol :around function)))

(defun eshell-nix-shell--remove-advice ()
  "Remove the global advice installed by this package."
  (pcase-dolist (`(,symbol . ,function) eshell-nix-shell--advice)
    (advice-remove symbol function)))

(defun eshell-nix-shell--claim-advice ()
  "Register the current buffer as a user of the global advice."
  (unless eshell-nix-shell--advice-claimed-p
    (setq eshell-nix-shell--advice-claimed-p t)
    (when (<= (cl-incf eshell-nix-shell--advice-users) 1)
      (setq eshell-nix-shell--advice-users 1)
      (eshell-nix-shell--install-advice))))

(defun eshell-nix-shell--release-advice (&optional force)
  "Unregister the current buffer from the global advice.
With FORCE, remove the advice regardless of the remaining users."
  (when eshell-nix-shell--advice-claimed-p
    (setq eshell-nix-shell--advice-claimed-p nil)
    (cl-decf eshell-nix-shell--advice-users))
  (when (or force (<= eshell-nix-shell--advice-users 0))
    (setq eshell-nix-shell--advice-users 0)
    (eshell-nix-shell--remove-advice)))

(defun eshell-nix-shell--kill-buffer-hook ()
  "Release global integration and captures owned by a dying buffer."
  (eshell-nix-shell--cleanup-all)
  (eshell-nix-shell--release-advice))

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
      (remove-hook 'kill-buffer-hook #'eshell-nix-shell--kill-buffer-hook t)
      (eshell-nix-shell--remove-prompt)
      (eshell-nix-shell--cleanup-all)
      (eshell-nix-shell--release-advice))
    (when (and first-error (not force))
      (signal (car first-error) (cdr first-error)))))

;;;###autoload
(define-minor-mode eshell-nix-shell-mode
  "Manage interactive Nix shell environments in this Eshell buffer.
Disabling the mode restores all active environments in last-in, first-out
order.  It refuses to disable while activation is in progress."
  :lighter " NixSh"
  (if eshell-nix-shell-mode
      (progn
        (unless (derived-mode-p 'eshell-mode)
          (setq eshell-nix-shell-mode nil)
          (user-error "Eshell Nix Shell mode only works in Eshell buffers"))
        (eshell-nix-shell--claim-advice)
        (add-hook 'eshell-named-command-hook
                  #'eshell-nix-shell--command-handler nil t)
        ;; Depth -90 keeps the import ahead of user hooks that inspect the
        ;; environment after a command, while still leaving room for a hook
        ;; that must observe the pre-import state at a lower depth.
        (add-hook 'eshell-kill-hook #'eshell-nix-shell--kill-hook -90 t)
        (add-hook 'kill-buffer-hook #'eshell-nix-shell--kill-buffer-hook nil t)
        (eshell-nix-shell--install-prompt))
    (eshell-nix-shell--disable)))

(defconst eshell-nix-shell--completion-options
  '("-p" "--packages" "--pure" "--keep" "-I" "-A" "--attr" "-E"
    "--expr" "--arg" "--argstr" "--option" "-j" "--max-jobs" "--cores"
    "--run" "--command" "--help" "--version"))

(defun pcomplete/eshell-mode/nix-shell ()
  "Complete legacy `nix-shell' options and Nix expression file names.
Package-name completion is an intentionally reserved extension point."
  (while (pcomplete-here* eshell-nix-shell--completion-options)
    ;; `pcomplete-arg' subtracts its index, so the option just consumed is at
    ;; index 1; a negative index would look ahead instead.
    (let ((previous (pcomplete-arg 1)))
      (cond
       ((member previous '("-A" "--attr" "-E" "--expr" "--keep" "-j"
                           "--max-jobs" "--cores"))
        (pcomplete-here))
       ((member previous '("-I"))
        (pcomplete-here (pcomplete-entries)))
       ;; Extension point: cached/asynchronous package completion after -p.
       (t (pcomplete-here (pcomplete-entries nil (lambda (file)
                                                   (string-suffix-p ".nix" file)))))))))

(defun pcomplete/eshell-mode/nix ()
  "Complete supported modern Nix shell subcommands.
Completion after the subcommand is deliberately left to Nix-aware completion
packages, which can provide installable and flake-reference candidates."
  (pcomplete-here* '("shell" "develop")))

(autoload 'tramp-local-environment-variable-p "tramp")

(defun eshell-nix-shell-unload-function ()
  "Restore managed Eshell buffers and remove global integration."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (or (bound-and-true-p eshell-nix-shell-mode)
                eshell-nix-shell--environment-stack
                eshell-nix-shell--pending-capture)
        (setq eshell-nix-shell-mode nil)
        (eshell-nix-shell--disable t))))
  (eshell-nix-shell--release-advice t)
  nil)

(provide 'eshell-nix-shell)

;;; eshell-nix-shell.el ends here
