# Verification

The canonical entrypoint is `mise run verify`; the fenced `verify` block below is the machine-readable contract.
The Swift checks it runs are the ones [`.github/workflows/verify.yml`](.github/workflows/verify.yml) runs on `macos-14`.
Site steps apply only when `site/` or `recipes/` changed.

```verify
entrypoint = "mise run verify"
feature_maps = "docs/features/README.md"
artifacts = ".artifacts/verification"
evidence = ".artifacts/evidence"
task_owner = "."
timeout_seconds = 3600

[requires]
commands = ["git", "mise", "swift"]

[freshness]
inputs = ["Package.swift", "Sources"]
outputs = [".build/release/pinchos"]
```

## Setup

macOS 14+ with a Swift toolchain that can build this package (`swift-tools-version: 5.10`).

Optional: install [mise](https://mise.jdx.dev) and run `mise install` if you want the tasks in `mise.toml` (Node 24 and Aube 2.1 are pinned there for the site only).

Swift work does not use a root package.json file. Do not add one.

## Readiness

`swift --version` should succeed. Pinchos is a menu-bar process, not a network service, so there is no readiness endpoint to poll.

## Automated checks

From the repository root, matching **Verify changes**:

```sh
swift build
swift test
swift build -c release
```

Equivalent mise tasks (these are not a superset of CI):

```sh
mise run test    # swift test
mise run build   # swift build -c release
```

`mise run build` does not run the debug `swift build` CI also performs. `swift test` rebuilds the debug target only. Some integration tests prefer `.build/release/pinchos` when that file already exists, so rebuild release if a leftover binary is present.

## Scenarios

`swift test` is the automated suite: parser, command, scheduler, and AppKit-headless lifecycle coverage.

After a release build, these CLI commands are useful local probes and are not part of CI:

```sh
.build/release/pinchos validate
.build/release/pinchos doctor
```

GUI and screenshot evidence is not required for ordinary PRs. Notes for manual runs live in [`docs/manual-qa`](docs/manual-qa).

### Site (only if `site/` or `recipes/` changed)

Local, from the repository root:

```sh
mise install
mise run site:install
mise run site:build
```

`mise run site:dev` and `mise run site:preview` are for interactive work. The **Site** workflow (`.github/workflows/site.yml`) installs and builds with `pnpm --dir site` on `ubuntu-latest` when those paths change.

## Isolation

Checks run in this checkout. SwiftPM writes to `.build/` (gitignored). Tests do not need a logged-in GUI session, Screen Recording permission, or a user's ~/.config/pinchos file.

## Artifacts

- Swift debug/release output: `.build/`
- Release binary: `.build/release/pinchos`
- Site production output: `site/dist/` after `mise run site:build`

There is no separate verification-run directory. Leave these gitignored outputs in place for review; do not commit them.

## Teardown

Nothing to stop. No daemon or bound port is part of the automated checks.

## Policy

This file lists tools that already exist (SwiftPM, `mise.toml`, the Verify and Site workflows). Do not treat `scripts/package-app.sh`, bundle smoke, or footprint measurement as required PR verification unless that is the change under review.
