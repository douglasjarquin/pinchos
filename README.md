# pinchos

## What it is

Pinchos runs shell commands and pins their latest values to the macOS menu bar.

The 0.1 product is deliberately small: one command-backed item and an ordered native submenu of static values, cached values, actions, and separators.

Release tags, signing, and the first release are in [docs/pinchos/install.md](docs/pinchos/install.md).

## Features

* **Menu bar item.** One command-backed item shows the latest value. Keys, order, and the submenu model are in [docs/pinchos/configuration.md](docs/pinchos/configuration.md).

* **Native submenu.** Static values, cached values, actions, and separators, in declaration order. Row rules are in [docs/pinchos/configuration.md](docs/pinchos/configuration.md).

* **Checked-in example.** The example item shells out for one Codex reading. Download, checksum, freshness, and rollback are in [docs/pinchos/example-setup.md](docs/pinchos/example-setup.md).

* **CLI.** `init`, `validate`, `doctor`, `run`, `config-path`, and `open-config`. What each one does is in [docs/pinchos/cli.md](docs/pinchos/cli.md).

* **Live reload.** Valid edits apply incrementally. A malformed file leaves the last known-good items running. Recovery and the removed 0.1 syntax are in [docs/pinchos/runtime.md](docs/pinchos/runtime.md).

* **Bounded execution.** Output tails share one process-wide memory budget, and sessions share one scheduler. Commands use one internal PATH (`/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`), HOME, and cwd policy whether Pinchos is launched from Finder or Terminal. `SSH_AUTH_SOCK` is not inherited. Safety rules are in [docs/pinchos/runtime.md](docs/pinchos/runtime.md).

## Quick Start

### Requirements

Pinchos targets Apple Silicon (arm64) Macs on macOS 14+.

The project is pure Swift Package Manager and has no Xcode project.
Until `v0.1.0` is published, the install script and Homebrew cask fail closed on a missing artifact or checksum.
Build from source in the meantime.

### Build from source

```sh
swift build -c release
```

The release executable is `.build/release/pinchos`.
`PINCHOS_VERSION`, `PINCHOS_INSTALL_DIR`, Homebrew, the unpublished install script, and the Gatekeeper check are in [docs/pinchos/install.md](docs/pinchos/install.md).

### First run

The config path is `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is non-empty, otherwise `~/.config/pinchos/pinchos.toml`.

```sh
.build/release/pinchos config-path
.build/release/pinchos init
.build/release/pinchos validate
.build/release/pinchos open-config
```

`config-path` prints the resolved file and creates nothing.
`init` writes the checked-in [example](example/pinchos.toml) only when that file does not exist.
`validate` parses without running commands and without rewriting the file.
`open-config` opens the same path in the default application.
It creates an empty file only when the path is missing.

If the file is malformed, `validate` prints the error and exits non-zero.
`init` still refuses to overwrite.
Edit the existing file, then `validate` again.
The running app keeps last known-good items until the file parses.
The other commands are in [docs/pinchos/cli.md](docs/pinchos/cli.md).

Run `.build/release/pinchos` with no arguments to launch the menu-bar app; any argument goes to the CLI.
That no-argument launch runs in the foreground and keeps the terminal busy until the app quits, so it has not hung.
Stop it with Quit Pinchos from its menu (Quit in the recovery menu), or Ctrl-C in the launching terminal.

```sh
.build/release/pinchos
```

`pinchos doctor` inspects executables against the fixed PATH without running them.
`pinchos run <item>` executes one item.
The example item needs Remainder on that PATH or an absolute path; see [docs/pinchos/example-setup.md](docs/pinchos/example-setup.md).

Commands and actions are unsandboxed code executed with the user's permissions.

## How it works

```
pinchos.toml
 │  declaration order
 ▼
scheduler and source cache
 │
 └─ menu bar item and native submenu
```

Opening a menu is synchronous and never waits on a command. Never-attempted rows refresh in the background immediately. Stale or failed cached rows may request a background retry only after a fixed 30-second cadence from when the last attempt settled. Refresh Now updates every distinct value source, including manual submenu rows, and never runs actions. Actions execute only when selected.

The last successful value stays visible while a refresh is queued or running and after a failed command. Age uses the shared command-success timestamp against each consumer's `interval` or `cache`. Age-stale and scheduler-delayed share the ⌛︎ marker; VoiceOver says "stale, scheduler delayed" when the scheduler has not attempted since the value aged out, "stale" when it aged out without that delay, and "stale, refreshing" when an aged value is already refreshing. A failed command uses a warning marker. Scalar age starts at command success, not an invented provider timestamp. Option-click the item for diagnostics: last attempt, last success, queued or active refresh, and `Delay: scheduler` for both the primary value and dynamic menu rows. `pinchos doctor` is a separate CLI inspection and does not read that live cache. Details are in [docs/pinchos/runtime.md](docs/pinchos/runtime.md).

Commands and actions are unsandboxed code executed with the user's permissions. Review executables, arguments, paths, network destinations, credentials, and write targets before placing them in TOML.

Bounds, reload, recovery, and the rejected development syntax are in [docs/pinchos/runtime.md](docs/pinchos/runtime.md).

## Documentation

* [docs/pinchos/install.md](docs/pinchos/install.md) — release install, Homebrew, and building from source.

* [docs/pinchos/cli.md](docs/pinchos/cli.md) — `init`, `validate`, `doctor`, `run`, `config-path`, and `open-config`.

* [docs/pinchos/configuration.md](docs/pinchos/configuration.md) — config path, item keys, and menu rows.

* [docs/pinchos/example-setup.md](docs/pinchos/example-setup.md) — the checked-in Codex example, checksums, freshness, and rollback.

* [docs/pinchos/runtime.md](docs/pinchos/runtime.md) — output bounds, reload, recovery, and removed syntax.

* [docs/pinchos/architecture.md](docs/pinchos/architecture.md) — modules, tests, and manual QA.

* [example/pinchos.toml](example/pinchos.toml) — canonical configuration.

* [recipes/README.md](recipes/README.md) — the nine-recipe catalog and named-path validation.

* [docs/performance.md](docs/performance.md) — P1 three-item/60s idle `phys_footprint` under 15 MB, sampled at commit `44bb2b3`.

* [CHANGELOG.md](CHANGELOG.md) — unreleased notes; there are no migrations for unreleased experiments.

* [docs/manual-qa](docs/manual-qa) — manual QA evidence.

## Contributing

Human-authored pull requests target `main`. The workflow and checks are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Pinchos is licensed under the [MIT License](LICENSE).
