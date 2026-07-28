# eshell-nix-shell

> **Fidelity limit:** this package imports exported scalar environment
> variables only. Bash functions, arrays, aliases, traps, shell options, and
> non-exported variables cannot be represented in Eshell. In particular,
> commands such as `buildPhase` do **not** exist in an activated Eshell.

`eshell-nix-shell` activates legacy `nix-shell` environments directly in the
current Eshell buffer. It captures the environment after Nix setup and the
`shellHook`, without retaining a nested Bash process.

Emacs 30.1 or newer is required.

## Installation and configuration

Add the source directory to `load-path`, then enable the buffer-local mode in
Eshell buffers:

```elisp
(add-to-list 'load-path "/path/to/eshell-nix-shell")
(require 'eshell-nix-shell)
(add-hook 'eshell-mode-hook #'eshell-nix-shell-mode)
```

## Usage

```text
~ $ nix-shell -p hello jq
❄ nix-shell  hello jq
~ $ hello
Hello, world!
❄ nix-shell  hello jq
~ $ exit
~ $
```

Bare `nix-shell`, Nix expression files, `-p`/`--packages`, `--pure`, attributes,
and other activation options are supported. Environments nest; `exit` restores
one layer in LIFO order. At an empty prompt, `C-d` does the same before it exits
or buries Eshell. `nix-shell-exit` is the explicit equivalent. Unlike vanilla
Eshell `exit`, an `exit` that pops an environment continues the rest of a
compound form.

Activation is deliberately rejected in pipelines, background jobs, and
subcommands. Remote Eshell buffers are supported through TRAMP: `nix-shell`,
the capture files, imported `PATH`, and optional directory changes all remain on
the remote host. Explicit command and informational invocations such as `--run`,
`--command`, `--help`, and `--version` pass through to the external program. Use
`*nix-shell` or `/:nix-shell` to force external execution.
`eshell-nix-shell-executable` selects the executable that is launched, but the
intercepted Eshell command name intentionally remains the unqualified
`nix-shell`.

## Prompt customization

By default the mode prepends a Starship-style Nix indicator on its own line
while preserving the existing `eshell-prompt-function`. Set
`eshell-nix-shell-integrate-prompt` to nil to disable automatic integration.
This option is read when the mode is enabled, so toggle the mode after changing
it in an existing Eshell buffer. Custom prompts can instead call
`(eshell-nix-shell-prompt-segment)` directly.
Customize `eshell-nix-shell-prompt-format-function` or the
`eshell-nix-shell-prompt` face to change its appearance.

By default a `shellHook` directory change is not applied. Set
`eshell-nix-shell-change-directory` non-nil to opt in. Customize
`eshell-nix-shell-excluded-variables` to extend or alter the imported-variable
denylist.

## Troubleshooting and diagnostics

Activation failures are printed in the Eshell buffer next to build and
`shellHook` output, as well as in `*Messages*`. Set `eshell-nix-shell-debug`
non-nil to record lifecycle diagnostics in `*eshell-nix-shell-debug*`; captured
environment values are never logged. For difficult import failures, customize
`eshell-nix-shell-keep-capture-files-on-error` to retain the private mode-0600
capture files. Their paths are printed after failure and they must then be
removed manually.

The capture payload deliberately uses Bash builtins (`compgen -e` and
`printf`) rather than `env -0`. A local 500-iteration benchmark measured
approximately 1.31 ms per builtin capture versus 2.56 ms for `env -0`; more
importantly, the builtin form still works under `--pure` when coreutils is not
on `PATH`. This choice is final for the legacy adapter.

On synchronous-process platforms Eshell supplies no process object to mark.
The compatibility path therefore uses a buffer-local pending capture; unlike
the normal per-process marker, it cannot distinguish an unrelated process
finishing in the same buffer. This is a documented compatibility limitation.

## Reliability and security

Captures use private mode-0600 temporary files on the same host as the Eshell
buffer and are removed after success, failure, cancellation, or buffer
destruction. Destroying a buffer first stops its pending activation process,
preventing it from recreating capture files. Unsafe transient variables are
filtered, while the parent Eshell's `TERM` and `INSIDE_EMACS` are preserved.
Imported variables influence subprocesses launched from the buffer, so activate
only environments you trust.

If activation fails or is interrupted, the previous environment, Eshell path,
`exec-path`, working directory, and nesting depth are restored atomically. Build and `shellHook`
output remains visible in Eshell.

For development, run:

```sh
make clean && make all
```

The `package-lint` step runs when that package is installed and otherwise skips
cleanly; the Nix flake check provides the reproducible full lint environment.
The TRAMP integration test is opt-in because it needs a prepared remote host
with the test fixture's `nix-shell` and `ens-new-command` executables:

```sh
ENS_TRAMP_DIRECTORY=/ssh:host:/tmp/ make test-tramp
```

## Related approaches

- `nix-mode` provides editing support rather than environment activation.
- `envrc`/direnv provide project-oriented automatic activation.
- Terminal `nix-shell` naturally retains Bash state in a child shell; this
  package preserves Eshell but can import only exported scalar variables.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
