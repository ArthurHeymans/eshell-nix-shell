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
```

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
  env -0 > "$PRIVATE_ENV_FILE"
  printf "%s\0" "$PWD" > "$PRIVATE_CWD_FILE"
'
```

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

Investigate whether passing paths through inherited environment variables is
safer than interpolating them into the `--run` payload. Prefer the approach with
the smallest quoting and injection surface.

### 4.5 Eshell asynchronous integration

Use Eshell's existing process lifecycle rather than starting an unrelated
process that Eshell cannot sequence.

Expected mechanism:

1. `eshell/nix-shell` recognizes activation versus pass-through.
2. For activation, it invokes the real executable through Eshell's external
   command machinery.
3. `eshell-exec-hook` attaches capture metadata to the resulting process.
4. The external process is returned to Eshell, causing normal evaluator
   deferral.
5. A buffer-local `eshell-kill-hook` callback runs when the process and its I/O
   are complete.
6. On successful exit, the callback validates and imports the snapshot before
   Eshell resumes the remainder of the command form.
7. On failure, it preserves the old state and reports a useful diagnostic.

Confirm hook ordering against `eshell-resume-command`. The import callback must
run before command evaluation resumes. Avoid replacing Eshell's sentinel.
Chaining or replacing process sentinels is more fragile and should only be used
if the public hooks cannot provide the required ordering.

Support synchronous-process platforms where practical. If that cannot be done
without substantial complexity, document the platform limitation and fail
clearly.

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
8. Refresh the prompt.

If any step fails, roll back every modified value and leave the stack unchanged.

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
  and continuation behavior.
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
eshell-nix-shell-prompt-format-function
eshell-nix-shell-keep-capture-files-on-error
```

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

Use helpers from Emacs's Eshell test suite where practical. Cover:

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
- independent Eshell buffers do not share environments.

### Nix-backed tests

Mark tests requiring Nix so they can be skipped when `nix-shell` is absent.
Use a tiny local Nix expression where possible instead of downloading arbitrary
nixpkgs packages. Test:

- exported variables;
- PATH changes;
- multiline environment values;
- `shellHook` output does not corrupt capture;
- `shellHook` directory changes;
- `--pure` behavior;
- nonzero `shellHook`/activation failure.

Avoid network access in the default test suite.

### Compatibility matrix

Initially test against:

- the oldest supported Emacs release;
- current stable Emacs;
- Emacs master where CI makes that practical;
- representative Nix 2.x releases;
- GNU/Linux and macOS.

Determine the oldest Emacs version from the APIs actually used rather than
choosing an arbitrary compatibility claim.

## 8. Documentation

README sections:

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
- Launch through Eshell's external process machinery.
- Attach process metadata through `eshell-exec-hook`.
- Import through `eshell-kill-hook` before evaluator resumption.
- Implement cleanup and cancellation.

Exit criterion: a fake environment-producing executable activates correctly,
and sequencing tests pass.

### Phase 3: `nix-shell` command

- Implement activation/pass-through classification.
- Add `eshell/nix-shell` and `eshell/nix-shell-exit`.
- Handle failures and unsupported pipeline/background contexts.
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

- Add adapters for `nix develop` and `nix shell`.
- Reuse the same environment stack and process lifecycle.
- Investigate `nix print-dev-env --json` as an optimization while preserving
  shellHook-compatible semantics.

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

## 11. Open questions to resolve during implementation

1. Does `eshell-kill-hook` ordering remain stable across supported Emacs
   versions, or is a command replacement form more robust?
2. Should a `shellHook` directory change affect the entered Eshell directory by
   default, or should that be opt-in?
3. What is the best behavior when disabling the mode with active frames?
4. How should `exit` behave inside compound commands such as `exit; echo done`?
5. Which Eshell syntax reliably forces the external `nix-shell` across all
   supported Emacs versions?
6. Can synchronous-process platforms be supported without duplicating process
   lifecycle logic?
7. Should imported variables such as `INSIDE_EMACS` be preserved from the
   parent Eshell, accepted from Nix verbatim, or regenerated by Eshell's normal
   variable-alias machinery?
8. Should the first release expose a generic adapter API, or wait until the Nix
   implementation demonstrates the correct abstraction?
9. Is `env -0` available in every realistic Nix shell, or should the package
   provide a small helper executable/script with a stronger portability
   guarantee?
10. Can activation payload paths be passed solely through inherited environment
    variables to eliminate generated shell interpolation?

## 12. Initial implementation recommendation

Start as a standalone Nix-focused package, but keep environment-frame code free
of Nix assumptions. Prove the asynchronous lifecycle and rollback behavior
before adding completion or modern Nix commands. Do not begin by patching Emacs:
the current Eshell hooks appear sufficient, and a separate package provides a
faster path to real-world testing. Once the behavior is stable, extract or
upstream only the generic pieces that demonstrably reduce fragility.
