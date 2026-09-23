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

* **Bounded execution.** Output tails share one process-wide memory budget, and sessions share one scheduler. Safety rules are in [docs/pinchos/runtime.md](docs/pinchos/runtime.md).

## Quick Start

### Requirements

Pinchos releases target Apple Silicon (arm64) Macs on macOS 14+.

The project is pure Swift Package Manager and has no Xcode project. Until `v0.1.0` is published, the install script and Homebrew cask fail closed on a missing artifact or checksum; build from source in the meantime.

### Install

```sh
curl -fsSL https://douglasjarquin.github.io/pinchos/install.sh | bash
```

The script refuses non-macOS, non-arm64, and pre-macOS 14 hosts, downloads the release zip, and verifies the published SHA-256 sidecar.

`PINCHOS_VERSION`, `PINCHOS_INSTALL_DIR`, Homebrew, the local build, and the Gatekeeper check are in [docs/pinchos/install.md](docs/pinchos/install.md).

### First run

```sh
.build/release/pinchos init
.build/release/pinchos validate
.build/release/pinchos doctor
.build/release/pinchos run codex
```

`init` writes the checked-in example only when no configuration exists. The other commands are in [docs/pinchos/cli.md](docs/pinchos/cli.md).

## How it works

```
pinchos.toml
 │  declaration order
 ▼
scheduler and source cache
 │
 └─ menu bar item and native submenu
```

Opening a menu is synchronous and never executes a command. Actions execute only when selected.

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

* [docs/manual-qa](docs/manual-qa) — manual QA evidence.

## Contributing

Human-authored pull requests target `main`. The workflow and checks are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Pinchos is licensed under the [MIT License](LICENSE).
