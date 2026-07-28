# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Buffer-local `nix-shell` activation with asynchronous Eshell sequencing.
- Atomic nested environment restoration and `exit` integration.
- Secure NUL-delimited capture, variable filtering, prompt segment, completion,
  and unit/integration tests.
- Eshell-visible failure diagnostics, optional debug logging, and opt-in
  retention of failed capture files.
- End-of-file (`C-d`) deactivation matching `exit` at an empty Eshell prompt.
- Starship-style prompt integration that preserves existing custom prompts.
- A `package-lint` development target and expanded pass-through, output,
  discovery, `--pure`, `shellHook`, and opt-in TRAMP integration tests.
- TRAMP activation with host-local private captures, remote command lookup, and
  remote directory restoration.
- Documentation of the `buildFHSEnv` mount-namespace limitation and its
  workarounds.
- `eshell-nix-shell-process-kill-timeout`, bounding the wait for a cancelled
  activation process that cannot be reaped.
- Tests for completion, `which` interception, remote path advice, unloading,
  invalid directory changes, and retained captures from a real failed
  activation.

### Changed

- Install the global advice on the first buffer that enables the mode and
  remove it when the last one is disabled, so loading the library alone no
  longer changes Eshell or TRAMP behavior.
- Degrade gracefully when Eshell internals are unavailable: `which` falls back
  to a public resolver, activation survives a missing `eshell-external` catch,
  and missing integration points are reported once as a warning.

### Fixed

- Complete option values after `-I`, `-A`, and friends; the previous argument
  was looked up with a negative `pcomplete-arg' index, which looks ahead.
- Create capture files with mode 0600 instead of tightening them afterwards.
- Read captures literally so that CRLF and non-UTF-8 environment values are
  imported unchanged.
- Deny excluded variables that appear as bare unset markers.
- Classify activations correctly after `--timeout`, `--builders`,
  `--max-silent-time`, `--out-link`/`-o`, `--include`, and related options.
- Make the `checkdoc` target fail on documentation warnings.

- Clean up a partially created capture if temporary-file setup fails.
- Exercise native Emacs 30 PATH separator handling in integration tests.
- Preserve numeric-looking `nix-shell` arguments as strings.
- Roll back activation on quits as well as errors.
- Terminate pending activations before capture cleanup on buffer destruction.
- Make disabling and unloading restore buffers reliably despite hook errors.
- Report the actual external path from `which nix-shell` and simplify package
  prompts to emphasize names after `-p`/`--packages`.
- Leave a nil `eshell-prompt-function` untouched instead of installing a
  wrapper that would fail on every prompt.
- Keep `eshell-life-is-too-much` as Eshell's unmodified generic kill-or-bury
  entry point; interactive `C-d` deactivation remains in the minor-mode keymap.
- Let `make all` skip `package-lint` cleanly when it is not installed.
- Redraw the prompt after `C-d` pops an environment, and suppress the stray
  `t` output from managed `exit` so the restored package indicator starts on
  the next line.
