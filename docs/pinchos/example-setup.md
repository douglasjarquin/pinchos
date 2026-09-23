# Example setup

The checked-in Codex example, checksums, freshness, and rollback. Moved out of the README.

The canonical configuration is [`example/pinchos.toml`](example/pinchos.toml). The item and menu rows are in [docs/pinchos/configuration.md](docs/pinchos/configuration.md).

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
