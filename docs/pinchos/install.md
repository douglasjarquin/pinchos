# Install

Release install, Homebrew, and building from source. Moved out of the README.

Pinchos releases are signed, notarized `Pinchos.app` builds for Apple Silicon (arm64) Macs on macOS 14+.
Release tags are `vMAJOR.MINOR.PATCH`; `v0.1.0` is the first release and its signing/notarization pipeline is tracked in issue [#15](https://github.com/douglasjarquin/pinchos/issues/15).
Until that release is published both install methods below fail closed on a missing artifact or checksum; build from source in the meantime.

## Install script

```sh
curl -fsSL https://douglasjarquin.github.io/pinchos/install.sh | bash
```

The script refuses non-macOS, non-arm64, and pre-macOS 14 hosts, downloads `Pinchos-<version>-macos-arm64.zip` from GitHub Releases, and verifies the published SHA-256 sidecar.
Before anything is installed it runs a real Gatekeeper assessment (`spctl --assess`) plus a Developer ID authority check, so an unsigned, ad hoc-signed, or non-notarized artifact fails closed - `codesign --verify` alone would accept ad hoc signatures.
It then installs `Pinchos.app` into `/Applications` (or `~/Applications` when `/Applications` is not writable; override with `PINCHOS_INSTALL_DIR`), staging the new bundle beside the target and swapping so a failed copy never leaves a partial install.
Pin a release with `PINCHOS_VERSION=0.1.0`.
Re-running the script upgrades in place.
The script source is [`site/public/install.sh`](site/public/install.sh), served by the project site.

## Homebrew

This repository is the Homebrew tap.
Because it is not named `homebrew-pinchos`, tap it with an explicit URL rather than the `user/repo` shortcut:

```sh
brew tap douglasjarquin/pinchos https://github.com/douglasjarquin/pinchos
brew trust douglasjarquin/pinchos
brew install --cask pinchos
```

Current Homebrew refuses casks from untrusted third-party taps; `brew trust` records your decision to run this tap's cask code.

The cask ([`Casks/pinchos.rb`](Casks/pinchos.rb)) installs `Pinchos.app` into `/Applications` and links its `pinchos` CLI onto your `PATH`.
It pins an exact version and SHA-256 per release and refuses non-arm64 Macs.

- **Upgrade:** `brew update && brew upgrade --cask pinchos`.
- **Uninstall:** `brew uninstall --cask pinchos` removes the app and CLI link only; your config is left in place.

## Build from source

Pinchos is a pure Swift Package Manager project with no Xcode project.

```sh
swift build -c release
swift test
```

The release executable is `.build/release/pinchos`.
`scripts/package-app.sh` assembles an unsigned `Pinchos.app` from it for local bundle smoke testing (`scripts/smoke-app-bundle.sh`).
That unsigned bundle is not a distributable artifact: Gatekeeper will block it on other Macs, and the release pipeline in issue [#15](https://github.com/douglasjarquin/pinchos/issues/15) fails closed rather than publish one.
