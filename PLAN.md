# eshell-nix-shell implementation plan

## 1. Purpose

Build a standalone Emacs package that makes interactive Nix environment
commands behave naturally inside Eshell.

The initial target is:

```text
~ $ nix-shell -p hello jq
[nix-shell] ~ $ hello
Hello, world!
[nix-shell] ~ $ exit
~ $
```

The package should enter the environment in the current Eshell buffer, preserve
normal asynchronous Eshell behavior, and restore the previous state when the
user exits the environment. It must not require `nix-mode`, `direnv`, a nested
Bash session, or modifications to Emacs itself.

## 2. Scope

### Initial release

- Support interactive activation through legacy `nix-shell`.
- Support arbitrary `nix-shell` arguments, including `-p`/`--packages`, files,
  attributes, `--pure`, and `--keep`.
- Support bare `nix-shell` with no arguments, which activates the environment
  described by `shell.nix` or `default.nix` in the current directory, and
  `nix-shell FILE.nix`. These are the most common real-world invocations and
  must be classified as activation, not rejected as degenerate.
- Capture the environment after Nix setup and `shellHook` execution.
- Apply the captured environment atomically to the current Eshell buffer.
- Maintain a buffer-local stack so environments can be nested and restored.
- Make `exit` leave the innermost environment before it exits Eshell.
- Preserve Eshell command sequencing, cancellation, status reporting, and
  stdout/stderr behavior.
- Provide completion and discoverability appropriate for an Eshell command.
- Include automated ERT tests and user documentation.

### Follow-up adapters

- `nix develop`
- `nix shell`
- Optional generic environment scopes usable by Guix, Conda, opam, mise, and
  similar tools.

### Explicitly out of scope

- Importing Bash aliases, functions, arrays, traps, shell options, or
  non-exported variables.
- Emulating Bash syntax in Eshell.
- Running a persistent hidden Bash process.
- Replacing project-oriented tools such as `direnv`.
- Automatically activating environments on directory changes in the initial
  release.

## 3. User-facing semantics

### Activation

When entered as a foreground command without an explicit command to execute:

```eshell
nix-shell -p ripgrep jq
```

`nix-shell` becomes an Eshell-aware activation command. It builds and evaluates
the Nix environment asynchronously, then pushes that environment onto the
current Eshell buffer's environment stack.

The prompt should not return until activation has either succeeded or failed.
Consequently, command sequencing must work:

```eshell
nix-shell -p hello; hello
```

`hello` must run inside the activated environment.

### Deactivation

Inside an activated environment:

```eshell
exit
```

pops one environment frame and restores the previous environment and working
directory. At stack depth zero, `exit` retains its normal Eshell behavior.

A dedicated command should also be provided:

```eshell
nix-shell-exit
```

This gives scripts and users a non-overloaded way to leave an environment.

### Nesting

Nested activations are supported:

```eshell
nix-shell -p python312
nix-shell -p nodejs
exit                    # restore the Python environment
exit                    # restore the original Eshell environment
```

### Pass-through behavior

Invocations that already specify a command, or only request information, should
run the real executable without activating the current Eshell:

```eshell
nix-shell -p hello --run hello
nix-shell -p hello --command 'hello; return'
nix-shell --help
nix-shell --version
```

The package must document an explicit way to force the external executable,
using Eshell's external-command syntax where available.

### Unsupported contexts

Activation in pipelines or background jobs should initially fail with a clear
message rather than produce ambiguous state:

```eshell
nix-shell -p hello | cat
nix-shell -p hello &
{ nix-shell -p hello }
```

Subcommands must be rejected as well as pipelines and background jobs. Eshell
rebinds exactly the state an activation mutates when entering a subcommand:

```elisp
;; esh-var.el, `eshell-subcommand-bindings'
(process-environment (eshell-copy-environment))
(eshell-path-env-list eshell-path-env-list)
```

so an activation inside `{ ... }` or `$( ... )` would appear to succeed and
then be silently discarded.

Detect the three contexts with `eshell-in-pipeline-p`, `eshell-current-subjob-p`
(bound by `eshell-do-subjob`), and `eshell-in-subcommand-p`. All three are
internal Eshell variables; record that dependency in the compatibility notes.

Explicit `--run` and `--command` invocations remain valid in those contexts
because they pass through normally.

## 4. Architecture

### 4.1 Package structure

```text
eshell-nix-shell.el          Main package
eshell-nix-shell-tests.el    ERT tests
README.md                    Installation and usage
CHANGELOG.md                 User-visible release history
LICENSE                      GPL-compatible package license
Makefile                     Batch compile, check, and test targets
flake.nix                    Reproducible development/test environment
```

Keep the initial implementation in one Lisp file unless separation materially
improves readability. If the generic environment layer grows, split it into:

```text
eshell-env-scope.el
eshell-nix-shell.el
```

### 4.2 Minor mode

Provide a buffer-local minor mode:

```elisp
eshell-nix-shell-mode
```

The mode installs buffer-local hooks and command integration. It should be safe
to enable with:

```elisp
(add-hook 'eshell-mode-hook #'eshell-nix-shell-mode)
```

Prefer intercepting commands through the buffer-local `eshell-named-command-hook`
rather than defining a global `eshell/nix-shell` function. Eshell itself uses
that hook for `eshell-explicit-command` and `eshell-quoted-file-command`. The
advantages are decisive:

- The interception is genuinely buffer-local, so disabling the mode really does
  remove the behavior. A global `eshell/nix-shell` would apply in every Eshell
  buffer regardless of the mode.
- Returning nil falls through to the normal external command path, making
  pass-through the default rather than something the package must reimplement.
- The same hook scales to `nix develop`/`nix shell`, where defining `eshell/nix`
  would mean intercepting every `nix` subcommand, including `nix build`.

When using the hook, attach an `eshell-which-function` property to the handler
so `which nix-shell` keeps reporting something meaningful.

If a Lisp command function is used instead, do not name the package file
`esh-*.el` or `em-*.el`: `eshell-find-alias-function` treats such files as Eshell
modules and gates the command on module activation. `eshell-nix-shell.el` is
safe, and an `eshell/nix-shell` defined there takes precedence over the external
binary unconditionally.

Optionally provide a globalized mode for convenience, but keep the buffer-local
mode as the fundamental implementation.

Disabling the mode must:

- remove buffer-local hooks;
- remove prompt integration;
- restore the original environment if frames remain, after confirmation or via
  a documented deterministic policy;
- leave no process sentinels, temporary files, or advice-owned state behind.

### 4.3 Environment frame

Represent each active layer with a private structure containing at least:

```elisp
(cl-defstruct eshell-nix-shell--frame
  name
  process-environment
  path
  exec-path
  default-directory
  activation-arguments
  metadata)
```

The stack is buffer-local:

```elisp
(defvar-local eshell-nix-shell--environment-stack nil)
```

The saved state must include:

- a deep-enough copy of `process-environment`;
- Eshell's path representation, obtained through public Eshell accessors;
- buffer-local `exec-path` state, including whether it was previously local;
- `default-directory`;
- adapter metadata needed for prompt display and diagnostics.

Do not rely solely on `$PATH`. Eshell command lookup uses its own path cache,
while other Emacs facilities commonly use `exec-path`.

### 4.4 Capturing the Nix environment

Run the real `nix-shell` asynchronously with an appended `--run` payload that
writes a machine-readable snapshot to private files.

Conceptually:

```sh
nix-shell ARGS --run '
  { for n in $(compgen -e); do printf "%s=%s\0" "$n" "${!n}"; done; } > PRIVATE_ENV_FILE
  printf "%s\0" "$PWD" > PRIVATE_CWD_FILE
'
```

Use the bash builtin `compgen -e` (list exported variable names) plus `printf`
rather than `env -0`. The `--run` payload always executes under bash, so this
depends on no external binary and therefore cannot break under `--pure` if
coreutils is absent from the resulting `PATH`. A local 500-iteration benchmark
measured approximately 1.31 ms per builtin capture versus 2.56 ms for `env -0`.
The builtin implementation is therefore the final choice on both portability
and measured performance grounds.

Implementation requirements:

- Use `make-temp-file` or a private temporary directory.
- Quote all generated paths with a correct shell-quoting function.
- Use NUL-delimited environment output; environment values may contain
  newlines but cannot contain NUL bytes.
- Capture the working directory separately and unambiguously.
- Ensure capture files are mode 0600 where applicable.
- Never parse stdout, because builds and `shellHook` may write arbitrary text.
- Leave normal stdout and stderr connected to Eshell so users can see builds,
  warnings, and hook output.
- Import nothing if the process exits unsuccessfully or capture data is
  incomplete.
- Delete all temporary artifacts in success, failure, cancellation, and buffer
  destruction paths.

Interpolate the capture paths into the payload with `shell-quote-argument`
rather than passing them through inherited environment variables. Inherited
variables do not survive `--pure`, which strips the environment, so that route
would require appending `--keep` arguments for the private variables, i.e. more
package-generated arguments and a `--pure`-conditional code path. The paths come
from `make-temp-file` and are package-generated, so quoting them is the smaller
surface.

### 4.5 Eshell asynchronous integration

Use Eshell's existing process lifecycle rather than starting an unrelated
process that Eshell cannot sequence.

Mechanism:

1. The command handler recognizes activation versus pass-through.
2. Both paths invoke the real executable through `eshell-external-command`.
3. For activation, attach the capture metadata directly to the returned process
   object with `process-put` before handing it back. No `eshell-exec-hook` is
   needed: Emacs is single-threaded, so the sentinel cannot run before the
   handler returns. This also avoids a global hook that fires for every Eshell
   buffer, and avoids `eshell-exec-hook`'s argument asymmetry (it receives a
   command *string*, not a process, on synchronous-process platforms).
4. Hand the process to Eshell by throwing it, not by returning it:

   ```elisp
   (throw 'eshell-external (eshell-external-command command args))
   ```

   This is required. `eshell-lisp-command` always returns nil and *prints* the
   value of the called function, so a returned process would be displayed as
   `#<process nix-shell>` and never deferred. The `eshell-external` catch inside
   `eshell-lisp-command` is the supported escape, and is what `eshell/cat` and
   `eshell/du` use. Only a value reaching `(eshell-deferrable OBJECT)` as a
   process triggers deferral.

   Note that `eshell-external-command` may return `t` rather than a process on
   platforms without `make-process`. Handle both.
5. A buffer-local `eshell-kill-hook` callback runs when the process and its I/O
   are complete. Eshell's own `eshell-resume-command` is installed on the same
   hook buffer-locally at initialization, so ordering is a hook-depth question,
   not an open risk. Install with an explicit negative depth:

   ```elisp
   (add-hook 'eshell-kill-hook #'eshell-nix-shell--kill-hook -90 t)
   ```

   Relying on "added later, therefore prepended" would work only by accident.
6. On successful exit, the callback validates and imports the snapshot before
   Eshell resumes the remainder of the command form.
7. On failure, it preserves the old state and reports a useful diagnostic.

Properties of the hook that the implementation must respect:

- It runs inside `eshell-sentinel`'s `finish-io`, only for the primary handle,
  and only after the process handles have been closed. That is exactly the
  desired ordering; no sentinel replacement is required.
- It fires for every process in the buffer, including background jobs, so the
  callback must gate on its own `process-get` marker.
- Cancellation is signalled by the *status string* matching
  `eshell-reset-signals`, not by the exit code. Refuse to import on a signal
  status even if a complete snapshot exists on disk.
- On synchronous-process platforms the hook is called as
  `(COMMAND-STRING EXIT-NUMBER)` instead of `(PROCESS STATUS-STRING)`. Either
  handle that shape explicitly or detect the platform and fail clearly; do not
  leave it as "where practical".

### 4.6 Applying an environment atomically

Parse and validate the entire snapshot before changing the buffer. Application
must act as one logical transaction:

1. Save the current state into a new frame.
2. Install a fresh buffer-local `process-environment`.
3. Update Eshell's PATH through `eshell-set-path`.
4. Update buffer-local `exec-path` from the imported PATH, preserving
   `exec-directory` as appropriate.
5. Update `default-directory` if a valid captured directory is available.
6. Push the frame only after the new state has been installed successfully.
7. Run `eshell-nix-shell-environment-change-hook`.

Do not refresh the prompt from the import callback. At that point the command
form has not resumed; `eshell-resume-command` will finish the form and Eshell
emits the prompt afterwards. Forcing a refresh risks a duplicate or misplaced
prompt and can break `nix-shell -p hello; hello`.

If any step fails, roll back every modified value and leave the stack unchanged.

Concrete state-handling notes:

- `process-environment` is already buffer-local in Eshell (set by the variable
  module at initialization), so installation is a `setq-local` of a fresh list.
  Never mutate shared list structure.
- Eshell's path is connection-local, not merely buffer-local: `eshell-set-path`
  assigns `eshell-path-env-list` inside
  `with-connection-local-application-variables`. Save with `(eshell-get-path t)`
  and restore with `eshell-set-path`. Use the literal form, so the remote prefix
  and the MS-Windows `"."` element that `eshell-get-path` adds when LITERAL-P is
  nil are not baked into the saved frame.
- Apply the variable filter (see `eshell-nix-shell-excluded-variables`) before
  installing, not after.

Treat these details carefully:

- duplicate environment keys;
- variables without `=` in `process-environment`;
- an unset or empty PATH;
- nonexistent directories in PATH;
- remote `default-directory` values;
- coding systems and non-ASCII environment values;
- environment entries that affect Emacs subprocess behavior.

Initial activation should be limited to local Eshell buffers. TRAMP support can
be designed later because the location of Nix, temporary files, and captured
paths becomes connection-specific.

### 4.7 Exit integration

Prefer an around-advice on `eshell/exit` installed once by the package:

```elisp
(defun eshell-nix-shell--exit-advice (original &rest args)
  (if (and eshell-nix-shell-mode
           eshell-nix-shell--environment-stack)
      (eshell-nix-shell-pop)
    (apply original args)))
```

Requirements:

- Install advice only while the package is loaded.
- Make advice inert outside enabled Eshell buffers.
- Remove advice on package unload.
- Ensure `exit` used in a larger Eshell command form produces sensible status
  and continuation behavior. Vanilla `eshell/exit` is a single
  `(throw 'eshell-terminal t)`, caught outside the command form, so today
  `exit; echo done` never reaches `echo`. A popping `exit` must instead keep
  evaluating the rest of the form. This is a deliberate divergence and must be
  documented, not discovered.
- Provide `eshell/nix-shell-exit` independently of the advice.
- Test repeated activation/deactivation and final Eshell exit.

If advice proves behaviorally awkward, use a named-command hook scoped to
Eshell buffers instead. Do not globally redefine `eshell/exit`.

### 4.8 Prompt integration

Expose, but do not force, a function returning the current environment label:

```elisp
(eshell-nix-shell-prompt-segment)
```

Default label examples:

```text
[nix-shell]
[nix-shell: hello jq]
[nix develop: .#default]
```

Keep prompt modification opt-in or minimally invasive. Users often have custom
Eshell prompts. The package should provide data and a sample integration rather
than replacing `eshell-prompt-function` wholesale.

### 4.9 Completion

Provide completion for:

- `nix-shell` options;
- common option arguments;
- paths for Nix expression files;
- package names where a reliable and sufficiently fast Nix query is available.

Package-name completion must be asynchronous or cached if querying Nix is
expensive. It should not delay the first release if option/path completion is
already useful.

### 4.10 Configuration surface

Keep customization small and stable. Candidate options:

```elisp
eshell-nix-shell-executable
eshell-nix-shell-use-exit-advice
eshell-nix-shell-change-directory
eshell-nix-shell-excluded-variables
eshell-nix-shell-prompt-format-function
eshell-nix-shell-keep-capture-files-on-error
```

`eshell-nix-shell-excluded-variables` is not optional polish. A verbatim import
drags in `PS1`, `PWD`, `OLDPWD`, `SHLVL`, `_`, `IN_NIX_SHELL`, `NIX_BUILD_TOP`,
`NIX_BUILD_CORES`, and `TMPDIR`/`TMP`/`TEMP`/`TEMPDIR`. The temporary-directory
variables are the dangerous ones: they can point at a directory that disappears
when the capture process exits, and they would then persist in a long-lived
Emacs buffer's `process-environment`. Ship a sane default denylist.

`eshell-nix-shell-change-directory` should default to nil: a `shellHook` that
`cd`s the user's Eshell buffer is surprising, and section 4.6 already treats the
captured directory as optional.

Preserve the parent Eshell's `INSIDE_EMACS` and `TERM` rather than importing
Nix's values, which describe the capture bash rather than the Eshell buffer.

Candidate hooks:

```elisp
eshell-nix-shell-before-enter-hook
eshell-nix-shell-after-enter-hook
eshell-nix-shell-before-exit-hook
eshell-nix-shell-after-exit-hook
eshell-nix-shell-environment-change-hook
```

Avoid exposing internal process or temporary-file details as public API until
there is a demonstrated extension use case.

## 5. Command classification

Implement a small parser that distinguishes activation from pass-through
without attempting to fully parse every Nix option.

Activate when:

- there are no arguments at all (Nix discovers `shell.nix`, then `default.nix`,
  relative to `default-directory`);
- arguments select an environment (`-p`, a `.nix` file, `-A`, `-E`, ...) and
  none of the pass-through options below appear.

A scan for pass-through options must skip option *values*, or invocations like
`nix-shell -p x --argstr msg --run` and `-I --run` will be misclassified. This
requires a minimal arity table for the options that consume arguments, at least:
`--arg` (2), `--argstr` (2), `--option` (2), `-I`, `-A`/`--attr`, `-E`/`--expr`,
`--keep`, `--max-jobs`/`-j`, `--cores`.

Pass through when arguments include at least:

- `--run`
- `--command`
- `--help` or `-h`
- `--version`

Investigate additional options whose purpose is non-interactive. Unknown
options should normally remain valid activation options rather than being
rejected by the package; Nix itself remains the authority on argument validity.

Avoid changing the meaning of explicitly qualified executable paths such as:

```eshell
/run/current-system/sw/bin/nix-shell ...
```

Only the unqualified `nix-shell` command should receive package behavior.

Users can force the external binary with Eshell's existing escapes:
`*nix-shell` (`eshell-explicit-command-char`, which bypasses Lisp functions and
aliases) or `/:nix-shell` (which additionally bypasses file name handlers).
Both are long-standing; no new syntax is required.

## 6. Reliability and security

### Temporary data

Environment snapshots may contain secrets. Therefore:

- create them with user-only permissions;
- keep them outside project directories;
- remove them promptly;
- never include their contents in error messages;
- avoid retaining them in process properties after cleanup.

### Input safety

- Never concatenate user arguments into a shell command string.
- Pass user arguments as process argument list elements.
- Only the package-generated capture payload requires shell syntax.
- Shell-quote generated file names and fixed helper arguments.
- Reject embedded NUL values before process creation.

### Atomicity

A failed activation must not partially alter:

- `process-environment`;
- Eshell PATH state;
- `exec-path`;
- `default-directory`;
- environment stack depth.

### Reentrancy

Prevent two simultaneous activation operations in one Eshell buffer. Either:

- queue the second through normal Eshell command sequencing; or
- reject it with a clear "activation already in progress" error.

Operations in different Eshell buffers must remain independent.

## 7. Testing strategy

### Unit tests

Test pure helpers without invoking Nix:

- NUL-delimited environment parsing;
- duplicate and malformed entries;
- PATH-to-`exec-path` conversion;
- frame capture and restoration;
- nested stack behavior;
- command classification;
- shell payload quoting;
- cleanup on synthetic errors.

### Eshell integration tests

Reuse `test/lisp/eshell/eshell-tests-helpers.el` from the Emacs tree; it provides
the buffer setup and command-matching helpers this package needs and is the
difference between a day and a week of scaffolding. Cover:

- successful activation updates `$PATH`;
- an executable introduced by the environment is found by Eshell;
- `executable-find` sees the same executable through buffer-local `exec-path`;
- `nix-shell; next-command` ordering;
- failed activation preserves all prior state;
- `exit` pops one frame;
- nested activation restores frames in LIFO order;
- explicit `--run` passes through;
- stdout and stderr remain visible;
- capture files are removed;
- disabling the mode removes behavior;
- independent Eshell buffers do not share environments;
- `*nix-shell` and `/:nix-shell` pass through to the external binary;
- activation inside `{ ... }`, a pipeline, or a background job is rejected;
- bare `nix-shell` and `nix-shell FILE.nix` are classified as activation.

### Nix-backed tests

Mark tests requiring Nix so they can be skipped when `nix-shell` is absent.
Use a tiny local Nix expression where possible instead of downloading arbitrary
nixpkgs packages. Test:

- exported variables;
- PATH changes;
- multiline environment values;
- `shellHook` output does not corrupt capture;
- `shellHook` directory changes;
- `--pure` behavior, including that the capture payload still works when
  coreutils is absent from the resulting `PATH`;
- a local `shell.nix` activated by bare `nix-shell`;
- nonzero `shellHook`/activation failure.

Avoid network access in the default test suite.

### Compatibility matrix

Set the floor at **Emacs 30.1**. The asynchronous command lifecycle this design
depends on (`eshell-foreground-command`, `eshell-add-command`,
`eshell-resume-command` on `eshell-kill-hook`) was restructured in 30.1, and
`eshell-get-path`/`eshell-set-path` replaced the older `eshell-path-env` string
in 29.1. Supporting 29 would mean maintaining a second, materially different
resumption path for little benefit.

Initially test against:

- Emacs 30.1;
- current stable Emacs;
- Emacs master where CI makes that practical;
- representative Nix 2.x releases;
- GNU/Linux and macOS.

## 8. Documentation

README sections:

0. Fidelity limits up front: exported scalars are imported; bash functions,
   arrays, and aliases are not, so build phases such as `buildPhase` do not
   exist in the activated Eshell.
1. Motivation and the child-shell problem.
2. Installation from source/package archive.
3. Minimal configuration.
4. `nix-shell -p` example.
5. Nesting and `exit` semantics.
6. Pass-through and forcing the real executable.
7. Prompt customization.
8. Fidelity limits: exported environment versus Bash state.
9. Troubleshooting and debug logging.
10. Security note about imported environment variables.
11. Comparison with `nix-mode`, `envrc`, and terminal-based solutions.

Every user-visible command and option should have a complete docstring suitable
for `C-h f` and Customize.

## 9. Development phases

### Phase 0: repository scaffolding

- Add package headers and lexical binding.
- Add README, license, changelog, Makefile, and flake.
- Configure byte compilation, package-lint, checkdoc, and ERT targets.
- Establish supported Emacs/Nix versions.

Exit criterion: an empty package loads and CI/test commands run reproducibly.

### Phase 1: environment stack

- Implement frame capture, apply, push, and pop.
- Correctly synchronize `process-environment`, Eshell PATH, `exec-path`, and
  `default-directory`.
- Add environment-change hooks.
- Add unit tests for rollback and nesting.

Exit criterion: synthetic environments can be entered and exited reliably
without invoking Nix.

### Phase 2: asynchronous capture process

- Generate secure capture files and payload.
- Launch through `eshell-external-command` and hand the process to Eshell with
  `(throw 'eshell-external ...)`.
- Attach process metadata with `process-put` on the returned process.
- Import through a depth-ordered buffer-local `eshell-kill-hook` callback,
  before evaluator resumption.
- Implement cleanup and cancellation, including signal-status detection.

Exit criterion: a fake environment-producing executable activates correctly,
and sequencing tests pass.

### Phase 3: `nix-shell` command

- Implement activation/pass-through classification.
- Register the `nix-shell` handler on the buffer-local
  `eshell-named-command-hook`, with an `eshell-which-function` property; add
  `eshell/nix-shell-exit`.
- Handle bare `nix-shell`, `nix-shell FILE.nix`, and the option arity table.
- Handle failures and unsupported pipeline/background/subcommand contexts.
- Add Nix-backed tests.

Exit criterion: `nix-shell -p hello; hello` works in Eshell and `exit` restores
the original environment.

### Phase 4: usability

- Add prompt segment API.
- Add option/path completion.
- Improve diagnostics and debug logging.
- Finish README examples and troubleshooting.

Exit criterion: package is comfortable for daily interactive use.

### Phase 5: modern Nix commands

- Add adapters for `nix develop` and `nix shell`, reusing the same environment
  stack and process lifecycle.
- Intercept through `eshell-named-command-hook`, dispatching on the first
  subcommand. Do not define `eshell/nix`: that would place every `nix`
  subcommand, including `nix build` and `nix flake update`, behind this package.
- Capture with `nix develop ARGS -c bash -c PAYLOAD`, which is structurally
  identical to `nix-shell --run` and captures post-`shellHook` state.
- The `nix develop` pass-through set is different: `-c`/`--command`,
  `--profile`, and the phase options `--build --check --configure --install
  --unpack --phase`.
- `nix develop` requires the `nix-command` and `flakes` experimental features.
  Detect their absence and fail with a comprehensible message instead of
  surfacing a raw Nix error.
- Treat installables (`.#default`, `nixpkgs#hello`, `-f shell.nix`) as opaque
  strings: record them for the prompt label, never parse them.
- Whether `shellHook` runs under `-c` is inconsistently reported in the wild.
  Do not reason about it; add a Nix-backed test with a devshell whose
  `shellHook` exports a variable, asserted visible in Eshell after activation.
- `nix print-dev-env --json` remains an optimization only. It *describes* the
  environment rather than entering it: `shellHook` is emitted as a variable the
  consumer is expected to evaluate itself (this is what direnv's `use flake`
  does). Adopting it naively would silently change semantics for every devshell
  relying on `shellHook`.
- `nix shell` is the easy third case: no `shellHook`, same `-c bash -c PAYLOAD`
  capture. Do it last, as a check that the adapter interface is not overfit to
  `nix-shell`.
- Document the fidelity limit prominently here. `nix print-dev-env --json` shows
  what a devshell really contains: `bashFunctions` (`buildPhase`, `genericBuild`,
  `runHook`, ...) and array-typed variables (`postUnpackHooks`, ...). Only
  exported scalars are imported, so `nix develop` followed by `buildPhase` -- a
  completely normal workflow -- fails in Eshell with "command not found". Nobody
  notices this with `nix-shell -p`; with `nix develop`, and with `nix-shell` on a
  real derivation, it is the headline limitation.

Exit criterion: modern and legacy Nix environment commands share consistent
Eshell behavior.

### Phase 6: extraction and upstreaming

- Evaluate splitting generic environment scopes into `eshell-env-scope`.
- Stabilize an adapter interface.
- Consider proposing generic environment push/pop primitives to Emacs.
- Keep Nix-specific argument handling in the external package.

Exit criterion: generic functionality has a documented API and no longer
requires Nix-specific assumptions.

## 10. Acceptance criteria for the first usable release

The release is ready when all of the following hold:

- `nix-shell -p PACKAGE` makes PACKAGE immediately available in the current
  Eshell after successful activation.
- Activation is asynchronous from Emacs's perspective but blocks subsequent
  Eshell command evaluation until complete.
- Environment changes include exported variables, PATH, `exec-path`, and the
  captured working directory.
- Failed or cancelled activation leaves the buffer unchanged.
- Nested environments restore correctly in LIFO order.
- `exit` pops an active environment and exits Eshell only at stack depth zero.
- `--run`, `--command`, help, and version invocations retain external-command
  behavior.
- Temporary environment snapshots are private and always cleaned up.
- Two Eshell buffers can hold different active Nix environments concurrently.
- Byte compilation is warning-free on supported Emacs versions.
- Unit and integration tests pass without network access.
- Limitations around Bash-only state are explicitly documented.

## 11. Open questions

### Resolved during review

1. **`eshell-kill-hook` ordering.** Stable and controllable.
   `eshell-resume-command` is itself a buffer-local member of that hook, so an
   explicit negative depth is sufficient. No command replacement form needed.
2. **`shellHook` directory changes.** Opt-in; `eshell-nix-shell-change-directory`
   defaults to nil.
3. **Disabling the mode with active frames.** Pop all frames unconditionally;
   signal an error if a foreground activation is in flight. No confirmation
   prompt, since minor modes are frequently disabled from Lisp.
4. **`exit` in compound commands.** A popping `exit` must continue evaluating
   the rest of the form, unlike vanilla `eshell/exit`. Documented divergence.
5. **Forcing the external binary.** `*nix-shell` or `/:nix-shell`; both already
   exist in Eshell.
6. **`INSIDE_EMACS` and friends.** Preserve the parent Eshell's values; Nix's
   describe the capture bash, not the buffer.
7. **Capture helper portability.** Use the bash builtins `compgen -e` and
   `printf`; no external binary and no helper script required.
8. **Payload paths through inherited environment variables.** Rejected:
    inherited variables do not survive `--pure` without extra `--keep`
    arguments. Interpolate `make-temp-file` paths with `shell-quote-argument`.
9. **Synchronous-process platforms.** Supported through a buffer-local pending
   capture because no process object is available to mark. This is weaker than
   the normal per-process property: an unrelated process finishing in the same
   buffer while activation is pending could trigger the import. Record this as
   a compatibility limitation rather than duplicate Eshell lifecycle logic.

### Still open

1. Should the first release expose a generic adapter API, or wait until the Nix
   implementation demonstrates the correct abstraction?
2. Should re-activation detect an edited `shell.nix`, or is exit-and-reenter
    the documented answer? (Leaning: documented answer; live tracking is what
    `direnv`/`envrc` exist for.)

## 12. Initial implementation recommendation

Start as a standalone Nix-focused package, but keep environment-frame code free
of Nix assumptions. Prove the asynchronous lifecycle and rollback behavior
before adding completion or modern Nix commands. Do not begin by patching Emacs:
the current Eshell hooks appear sufficient, and a separate package provides a
faster path to real-world testing. Once the behavior is stable, extract or
upstream only the generic pieces that demonstrably reduce fragility.
