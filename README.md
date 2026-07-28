# eshell-nix-shell

<p align="center">
  <img src="assets/eshell-nix-shell.jpg" alt="Eshell and Nix logo" width="400">
</p>

Activate legacy `nix-shell` environments directly in the current Eshell buffer,
without keeping a nested Bash process.

Requires Emacs 30.1 or newer.

## Installation

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

The package supports bare `nix-shell`, expression files, packages, attributes,
`--pure`, and other activation options.

Environments can be nested. Run `exit`, `nix-shell-exit`, or press `C-d` at an
empty prompt to restore the previous environment.

Explicit command and informational invocations are passed to the external
program, including:

- `--run` and `--command`
- `--help` and `--version`

Use `*nix-shell` or `/:nix-shell` to force external execution.

Activation is not supported inside pipelines, background jobs, or subcommands.

## What gets imported

`eshell-nix-shell` imports exported scalar environment variables produced by
Nix setup and `shellHook`.

It cannot import shell-specific state such as:

- Bash functions, arrays, aliases, or traps
- Shell options
- Non-exported variables

Consequently, shell functions such as `buildPhase` are not available in the
activated Eshell.

A failed or interrupted activation restores the previous environment, Eshell
path, `exec-path`, working directory, and nesting state.

## Configuration

### Prompt

By default, active environments add a Nix indicator above the existing Eshell
prompt.

```elisp
(setq eshell-nix-shell-integrate-prompt nil)
```

This option is read when the mode is enabled. Toggle the mode after changing it
in an existing buffer.

Custom prompts can call:

```elisp
(eshell-nix-shell-prompt-segment)
```

The appearance can be changed through:

- `eshell-nix-shell-prompt-format-function`
- The `eshell-nix-shell-prompt` face

### Directory changes

Directory changes made by `shellHook` are ignored by default. To apply them:

```elisp
(setq eshell-nix-shell-change-directory t)
```

### Other options

- `eshell-nix-shell-executable` selects the executable to launch.
- `eshell-nix-shell-excluded-variables` controls which variables are not
  imported.
- `eshell-nix-shell-process-kill-timeout` bounds the wait for a cancelled
  activation process that refuses to die, for instance one blocked on an
  unresponsive remote connection.

The intercepted Eshell command remains named `nix-shell`, regardless of the
configured executable.

Loading the library has no effect on its own: the advice this package needs on
`eshell/exit`, Eshell's path and variable accessors, and TRAMP is installed
when the first buffer enables `eshell-nix-shell-mode` and removed when the last
one disables it.

## TRAMP

Remote Eshell buffers are supported for TRAMP methods that implement remote
process execution, such as SSH-based methods and containers. The `nix-shell`
process, capture files, imported paths, and optional directory changes remain
on the remote host. File-only methods such as GVFS, archive, rclone, and
sudoedit do not provide remote process execution and cannot activate a shell.

## FHS and mount-namespace environments

Environments created with `buildFHSEnv` and similar `bubblewrap`-based tools
cannot be imported into Eshell.

These environments depend on a private mount namespace containing paths such as
`/usr/bin` and `/lib`. A namespace belongs to a process and cannot be transferred
to Emacs through environment variables.

Possible alternatives are:

1. Expose the required tools in the outer `mkShell` as well as the FHS
   environment.
2. Start Emacs inside the FHS environment.
3. Run affected commands explicitly through the FHS wrapper.

For example:

```sh
fhs-env -c 'make -j4'
```

## Troubleshooting

Activation errors and `shellHook` output appear in the Eshell buffer and in
`*Messages*`.

Enable lifecycle diagnostics with:

```elisp
(setq eshell-nix-shell-debug t)
```

Diagnostics are written to `*eshell-nix-shell-debug*`. Captured environment
values are not logged.

For difficult failures, enable
`eshell-nix-shell-keep-capture-files-on-error`. Retained files have mode `0600`;
their paths are reported after failure and they must be removed manually.

Only activate environments you trust: imported variables affect subprocesses
launched from the Eshell buffer.

## Development

Run the test and lint suite with:

```sh
make clean && make all
```

The reproducible full lint environment is also available through the Nix flake
check.

The TRAMP integration test requires a prepared remote host:

```sh
ENS_TRAMP_DIRECTORY=/ssh:host:/tmp/ make test-tramp
```

## Related projects

- [`nix-mode`](https://github.com/NixOS/nix-mode) provides Nix editing support.
- [`envrc`](https://github.com/purcell/envrc) and direnv provide automatic,
  project-oriented environment activation.
- A terminal `nix-shell` retains complete Bash state, while this package keeps
  Eshell and imports only exported scalar variables.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
