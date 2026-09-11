# Contributing

Thanks for contributing to pinchos.

Human pull requests target `main` through ordinary GitHub PRs: fork, branch, commit, push, and open the PR. There is no extra git remote, proxy, or required push helper.

## Workflow

1. Fork [douglasjarquin/pinchos](https://github.com/douglasjarquin/pinchos).
2. Clone your fork (optionally add this repository as `upstream`).
3. Branch from current `main`.
4. Commit your changes.
5. Push the branch to your fork.
6. Open a pull request against `main`.

## Verification

Follow [VERIFY.md](VERIFY.md) before you open a pull request or ask for review. CI's **Verify changes** workflow repeats the Swift build and test steps on `macos-14`; local runs should match those commands.

If you change `site/` or `recipes/`, also run the site steps in VERIFY.md.

## Repo conventions

Pinchos is a Swift Package Manager macOS menu-bar app. There is no Xcode project and no `package.json` at the repository root. The stack is SwiftPM plus optional [mise](https://mise.jdx.dev) tasks; the Astro site under `site/` is separate.

- `Package.swift` uses `swift-tools-version: 5.10` and macOS 14.
- `Sources/PinchosCore` is UI-free. `Sources/pinchos` is AppKit wiring and the CLI.
- `swift test` covers `Tests/PinchosCoreTests` and `Tests/pinchosTests`.
- `swift build` and `swift build -c release` are the debug and release builds. The release executable is `.build/release/pinchos`.
- `mise.toml` wraps the same Swift commands (`mise run test`, `mise run build`) and the site tasks (`site:install`, `site:dev`, `site:build`, `site:preview`).
- Item TOML keys, CLI subcommands, and architecture notes live in [README.md](README.md). Keep public `ItemConfig` fields aligned with that list.
- Manual QA writeups belong under `docs/manual-qa/`.

## Questions

Open a [GitHub issue](https://github.com/douglasjarquin/pinchos/issues).
