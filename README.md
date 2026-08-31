# pinchos

<img width="2172" height="724" alt="Pinchos header: menu-bar snacks pinned with a skewer" src="https://github.com/user-attachments/assets/072cb6ab-6570-4dd4-9a41-b83602d1da21" />

Pinchos pins the latest output of ordinary shell commands to native macOS menu-bar items.
It uses one declarative TOML file, native `NSStatusItem`s, and no web runtime.

`pinchos.toml` is to the menu bar what `starship.toml` is to the terminal prompt.

> **Pre-release:** `0.1.0` deliberately replaces the earlier development schema with a much smaller contract. Old unreleased configs are expected to break rather than become permanent compatibility baggage.

## What `0.1.0` does

- Runs bounded shell commands on an interval or only when manually refreshed.
- Displays each command's latest useful stdout in its own native menu-bar item.
- Reloads the config live while preserving unchanged items and their current output.
- Keeps the last good config running when a new edit is invalid.
- Provides compact menus, Option-click diagnostics, and exact output copying.
- Cleans up owned process groups on timeout, reload, removal, Quit, SIGTERM, and SIGINT.

It does **not** yet provide groups, collapse mode, dynamic actions, structured JSON output, event triggers, notifications, per-item shell/environment controls, or a settings window. Those features belong on the roadmap only after the core contract proves itself.

## Requirements

- macOS 14 or newer
- Xcode 15 or a standalone Swift 5.10 toolchain

## Build from source

```sh
git clone https://github.com/douglasjarquin/pinchos.git
cd pinchos
swift build -c release
```

The binary is written to `.build/release/pinchos`.
Running it without a CLI command starts the menu-bar app:

```sh
.build/release/pinchos
```

Signed, notarized app and Homebrew installation are tracked in [#15](https://github.com/douglasjarquin/pinchos/issues/15) for the `0.1.0` release.

## Quick start

Create the canonical example:

```sh
.build/release/pinchos init
.build/release/pinchos validate
.build/release/pinchos
```

Pinchos reads:

- `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is set;
- otherwise `~/.config/pinchos/pinchos.toml`.

The canonical example is also checked in at [`example/pinchos.toml`](example/pinchos.toml):

```toml
[item.clock]
run = "date '+%H:%M'"
interval = "30s"
symbol = "clock"

[item.battery]
run = "pmset -g batt | awk -F';' 'NR==2 { gsub(/^[ \\t]+/, \"\", $1); print $1 }'"
format = "{output}"
```

Declaration order is menu-bar order.

## Configuration

Every item uses one canonical table form:

```toml
[item.<id>]
run = "<shell command>" # required
interval = "60s"        # optional: 30s, 5m, 1h, or manual
timeout = "15s"         # optional; minimum 1s
format = "{output}"      # optional; {output} is the trimmed final stdout line
symbol = "clock"         # optional SF Symbol
# icon = "./clock.pdf"   # optional local image path; mutually exclusive with symbol
```

The supported public keys are exactly:

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `run` | yes | — | Non-empty command executed by `/bin/sh -c`. |
| `interval` | no | `60s` | Refresh interval or `manual`. |
| `timeout` | no | `15s` | Command timeout; minimum `1s`. |
| `format` | no | raw output | Text containing the optional `{output}` placeholder. |
| `symbol` | no | none | SF Symbol rendered as a native template image. |
| `icon` | no | none | Local SVG, PNG, or PDF path, relative to the config file when not absolute. |

Item IDs may contain ASCII letters, digits, `_`, and `-`.
Unknown root tables, alternate item declaration syntax, nested item tables, and unknown keys are rejected with source-line context.
`symbol` and `icon` cannot be used together.

### Fixed runtime policy

The first release intentionally keeps operational policy out of the config:

- shell: `/bin/sh -c`;
- working directory: the user's home directory;
- timeout: 15 seconds unless the item overrides it;
- output bound: 64 KiB for stdout and 64 KiB for stderr;
- scheduler: one application-scoped bounded scheduler;
- failures: preserve the last successful title, mark the item as failed, and show `–` before the first success;
- environment: preserve the current process environment, set `HOME`, and replace `PATH` with predictable mise, local, Homebrew, and system locations.

This gives normal command-line credentials and macOS session values to commands without making Pinchos a second shell-profile language.

## Menus and diagnostics

Click an item to open its compact menu:

- **Refresh Now**
- **Open Config**
- **Reload Config**
- **Quit Pinchos**

Option-click reveals cached diagnostics such as runtime state, timestamps, exit information, byte counts, and full-output copy commands.
Opening a menu never starts another command or network request.

## Live reload and recovery

Pinchos watches the config with a file-system event source and coalesces in-place writes.
A valid edit is diffed against the running configuration:

- unchanged items retain their status item, scheduler state, runner, and displayed value;
- changed items update in place;
- removed items are cancelled and torn down;
- added items are created;
- status items are rebuilt only when native placement cannot preserve a changed declaration order.

Malformed edits leave the last good configuration running and expose recovery actions instead of destroying a working menu bar.
Pinchos never rewrites the user's TOML file.

## CLI

```text
pinchos init
pinchos validate
pinchos doctor
pinchos config-path
pinchos open-config
pinchos run <item>
```

`init` writes the canonical example without overwriting an existing config.
`validate` performs strict syntax and semantic validation.
`doctor` checks config access, the fixed command environment, executable availability, and icons without running configured commands.
`run <item>` uses the same execution, timeout, output, cancellation, and environment policy as the menu-bar app.

CLI exit codes are scriptable: `2` is usage failure, `3` is config/open failure, `4` is a failed diagnostic, `124` is timeout, `125` is internal execution/cancellation failure, and `127` is launch failure. A completed item otherwise preserves its command's exit code.

## Process safety

Each execution owns a process session and drains stdout and stderr concurrently into bounded tail buffers.
Timeout, config replacement, item removal, app shutdown, and CLI interruption all use the same SIGTERM-then-SIGKILL cleanup policy.
Shutdown is single-flight and deadline-bounded; repeated Quit or signal requests do not start overlapping cleanup sequences.

## Recipes

[`recipes/`](recipes/) contains a deliberately small catalog of eight examples that are validated against the same public schema in CI:

- clock
- battery
- disk free
- memory pressure
- load average
- local IP
- HTTP health
- Git branch

Recipes are ordinary shell commands, not provider-specific Pinchos integrations.

## Customize with an agent

[`skills/customize-pinchos`](skills/customize-pinchos/SKILL.md) is an optional Agent Skill for reviewing and safely editing a Pinchos config. Pinchos does not load it at runtime.
The full six-key reference is in [`configuration.md`](skills/customize-pinchos/references/configuration.md).

Configured commands run with the user's permissions and are not sandboxed. Review commands before adding them, especially commands copied from the internet or commands that use credentials.

## Development

```sh
swift test
swift build -c release
```

The static Astro site lives in `site/` and uses the versions pinned by `mise.toml`:

```sh
mise install
mise run site:install
mise run site:dev
mise run site:build
```

The `0.1.0` product freeze is tracked in [#99](https://github.com/douglasjarquin/pinchos/issues/99), and the staged path to `1.0` is tracked in [#100](https://github.com/douglasjarquin/pinchos/issues/100).

## License

See [`LICENSE`](LICENSE).
