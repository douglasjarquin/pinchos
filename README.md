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
run = "quota-axi --provider codex --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .percentRemaining'"
interval = "5m"
timeout = "15s"
format = "{output}"
symbol = "terminal"

[[item.codex.menu]]
label = "Usage"
run = "quota-axi --provider codex --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .percentRemaining'"
cache = "5m"

[[item.codex.menu]]
label = "Pace"
run = "quota-axi --provider codex --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .pace.status'"
cache = "5m"

[[item.codex.menu]]
label = "Refresh"
run = "quota-axi --provider codex --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .percentRemaining'"
cache = "5m"
action = "open https://chatgpt.com/codex"

[[item.codex.menu]]
label = "Open Codex"
action = "open https://chatgpt.com/codex"

[[item.codex.menu]]
separator = true
```

Items appear in declaration order.
The supported item keys are `run`, `interval`, `timeout`, `format`, `symbol`, `icon`, and `menu`.
`symbol` is a macOS SF Symbol name.
`icon` is a local image path.
The two icon keys are mutually exclusive.

Every non-separator menu row needs a non-empty `label`.
Use `value` for static text, `run` for a cached command value, and `action` for a clickable command.
A row may combine `run` and `action`.
`cache` is required only for a dynamic row and controls its freshness interval.
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
