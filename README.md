# pinchos

Pinchos runs shell commands and pins their latest values to the macOS menu bar.
The 0.1 product is deliberately small: one command-backed item and an ordered native submenu of static values, cached values, actions, and separators.

## Install and build

Pinchos is a pure Swift Package Manager project with no Xcode project.

```sh
swift build -c release
swift test
```

The release executable is `.build/release/pinchos`.
The unsigned packaged application is owned by this project; signed distribution and Homebrew publication remain downstream work in issue [#15](https://github.com/douglasjarquin/pinchos/issues/15).

## Quick start

```sh
.build/release/pinchos init
.build/release/pinchos validate
.build/release/pinchos doctor
.build/release/pinchos run codex
```

`init` creates the resolved configuration directory and writes the checked-in example only when no configuration exists.
`validate` parses the file without running commands.
`doctor` checks the configured command and icon prerequisites without running the command.
`run <item>` executes one item for scriptable verification.
`config-path` prints the resolved path and `open-config` opens it in the default application.

## Configuration

Pinchos reads `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is non-empty.
Otherwise it reads `~/.config/pinchos/pinchos.toml`.
The config watcher reloads this file after changes, but normal operation never rewrites it.

The canonical source is [`example/pinchos.toml`](example/pinchos.toml).

```toml
[item.codex]
run = "remainder value --provider codex --profile default --window weekly --scope account --field remaining --cache auto --max-age 5s --freshness fresh"
interval = "5m"
timeout = "15s"
format = "{output}"
symbol = "terminal"

[[item.codex.menu]]
label = "Usage"
run = "remainder value --provider codex --profile default --window weekly --scope account --field remaining --cache auto --max-age 5s --freshness fresh"
cache = "5m"

[[item.codex.menu]]
label = "Pace"
run = "remainder value --provider codex --profile default --window weekly --scope account --field pace --cache auto --max-age 5s --freshness fresh"
cache = "5m"

[[item.codex.menu]]
label = "Refresh"
run = "remainder value --provider codex --profile default --window weekly --scope account --field remaining --cache auto --max-age 5s --freshness fresh"
cache = "5m"
action = "open https://chatgpt.com/codex"

[[item.codex.menu]]
label = "Open Codex"
action = "open https://chatgpt.com/codex"

[[item.codex.menu]]
separator = true
```

This example calls [`remainder`](https://github.com/douglasjarquin/remainder) directly for the Codex `default` profile's account-scoped `weekly` remaining percentage and pace.
It was verified against immutable Remainder `v0.2.1` for macOS Apple Silicon (`darwin_arm64`).
Use Remainder `v0.2.1`'s immutable-tagged [standalone release recipe](https://github.com/douglasjarquin/remainder/blob/v0.2.1/docs/release.md) for the one-time download, selected-archive checksum verification, and extraction into a versioned directory you choose.
The exact [macOS Apple Silicon archive](https://github.com/douglasjarquin/remainder/releases/download/v0.2.1/remainder_v0.2.1_darwin_arm64.tar.gz) has SHA-256 `84f3b21f3a0a30068644e4c6f229af1ec7b183744be30f10c379fe514921af95`.
Download the archive and `SHA256SUMS`, select exactly one matching archive entry, verify it, and then extract it:

```sh
asset=remainder_v0.2.1_darwin_arm64.tar.gz
release=https://github.com/douglasjarquin/remainder/releases/download/v0.2.1
curl --fail --location --output "$asset" "$release/$asset"
curl --fail --location --output SHA256SUMS "$release/SHA256SUMS"
awk -v name="$asset" '$2 == name { print; count++ } END { if (count != 1) exit 1 }' SHA256SUMS > "$asset.sha256"
shasum -a 256 -c "$asset.sha256"
tar -xzf "$asset"
```

After the extracted binary passes `--version` and `--help`, copy it to a versioned directory such as `~/.local/opt/remainder/v0.2.1/remainder`.
The extracted executable SHA-256 is `8f1a4fd0ce7e1466055e733512b41cbd0bcd25ccba0ac125b4f13b58d578d886`.
Keep that chosen versioned directory in the `PATH` Pinchos inherits, and record its absolute executable path before activating the configuration.
Keep the versioned executable available while restoring the previous configuration or `PATH` for rollback.
Record the resolved path and release version before activating the configuration:

```sh
command -v remainder
remainder --version
```

Pinchos does not install Remainder during a refresh or menu opening.
This path does not require Sum, Herdr, `jq`, or a Go toolchain.
It does not embed credentials, select another account, prompt for authentication from a menu opening, or enable a paid provider route.

Each scalar read asks Remainder for fresh evidence and permits reuse of an original provider observation for at most five seconds.
Pinchos refreshes the primary display every five minutes and keeps the dynamic rows for five minutes, while Remainder's process-safe cache can coalesce the nearby remaining and pace reads.
The nominal original-observation age bound is therefore five minutes plus Remainder's five-second reuse window plus command execution and scheduler delay.
An explicit zero remains a successful exhausted value; unknown, expired, wrong-account, missing-auth, nonzero-exit, and timeout outcomes remain failures rather than becoming numeric zero or empty success.

Pinchos preserves the last successful primary value with a warning marker after a failed attempt, and its diagnostics expose the last attempt, last success, exit status, and error.
Pinchos does not currently carry Remainder's original observation timestamp through the scalar output or age a successful primary value solely because sleep or a missed timer delayed the next attempt.
Dynamic and manual-only submenu rows likewise do not expose the provider observation age.
Those are explicit freshness-affordance follow-ups in [issue #123](https://github.com/douglasjarquin/pinchos/issues/123); the nominal bound must not be presented as a hard maximum until they are resolved.

To roll back, restore the previously reviewed [`quota-axi`](https://github.com/kunchenguid/quota-axi) commands in the four `run` entries while keeping the item, labels, order, symbol, cache durations, and actions unchanged.
Pinchos will live-reload that edit and will not uninstall either executable.
`quota-axi` remains an independent, attributed quota tool and is still used by the separate optional recipe catalog.

Items appear in declaration order.
The supported item keys are `run`, `interval`, `timeout`, `format`, `symbol`, `icon`, and `menu`.
`symbol` is a macOS SF Symbol name.
`icon` is a local image path.
The two icon keys are mutually exclusive.

Every non-separator menu row needs a non-empty `label`.
Use `value` for static text, `run` for a cached command value, and `action` for a clickable command.
A row may combine `run` and `action`.
`cache` is optional for a dynamic row; when present, it controls the row's freshness interval, while an omitted value makes the row manual-only.
`separator = true` cannot be combined with any other row key.

Opening a menu is synchronous and never executes a command.
Unavailable cached rows request a background refresh while keeping menu construction immediate.
Actions execute only when selected.
Equivalent primary and menu commands share one source and cache within a controller.

## Runtime safety

All command output is retained in bounded tails with one process-wide memory budget.
Command sessions use one process-wide scheduler and cannot overlap on the same source.
Timeout, reload, removal, quit, SIGTERM, and SIGINT settle owned process groups through the shared lifecycle deadline.
Menu and diagnostics previews sanitize control characters and are bounded independently from retained output.
Command diagnostics remain bounded and available for troubleshooting.

Commands and actions are unsandboxed code executed with the user's permissions.
Review executables, arguments, paths, network destinations, credentials, and write targets before placing them in TOML.

## Live reload and recovery

Valid changes apply incrementally while preserving unchanged source/cache identity.
Added, removed, changed, and reordered items are reconciled under one concurrent lifecycle deadline.
Malformed configuration leaves the last known-good items running and exposes recovery actions for creating, opening, reloading, or quitting.

## Removed development syntax

The 0.1 release is intentionally breaking because the earlier development schema never shipped.
`type`, legacy `action` and `info` tables, groups, item triggers, notifications, structured output, visibility flags, scheduler settings, shell/environment overrides, output bounds, error policies, freshness policies, config mutation, and launchd service commands are rejected.
There are no compatibility aliases or migration writers.

## Architecture

- `Sources/PinchosCore` contains TOML parsing, the config diff, bounded command execution, the scheduler, source/cache actors, formatting, and diagnostics.
- `Sources/pinchos` contains AppKit ownership, menu projection, live reload coordination, recovery, signals, and shutdown.
- `Tests/PinchosCoreTests` covers parser, source/cache, scheduler, process, output, and formatting contracts.
- `Tests/pinchosTests` covers AppKit-headless lifecycle, menus, reload, recovery, signals, and CLI behavior.

Manual QA evidence belongs under [`docs/manual-qa`](docs/manual-qa).
The current headless environment cannot grant the one-time macOS Screen Recording and Accessibility permissions required for real screenshots.
