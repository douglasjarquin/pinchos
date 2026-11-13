# Example setup

The checked-in Codex example, checksums, freshness, and rollback.

The canonical configuration is [`example/pinchos.toml`](../../example/pinchos.toml).
The item and menu rows are in [configuration.md](configuration.md).

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
That versioned path is not on Pinchos's PATH.
Symlink the executable onto the fixed PATH (for example `/opt/homebrew/bin/remainder` or `/usr/local/bin/remainder`), or put its absolute path in the TOML `run` lines.
Pinchos does not inherit the process `PATH`.
Commands run with the fixed PATH `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` documented in [runtime.md](runtime.md).
Keep the versioned executable available while restoring the previous configuration for rollback.
Confirm Remainder on that same PATH before activating the configuration.
`command -v remainder` in an interactive shell checks a different PATH.

```sh
env -i PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c 'command -v remainder && remainder --version'
.build/release/pinchos doctor
```

Pinchos does not install Remainder during a refresh or menu opening.
This path does not require Sum, Herdr, `jq`, or a Go toolchain.
It does not embed credentials, select another account, prompt for authentication from a menu opening, or enable a paid provider route.

Each scalar read asks Remainder for fresh evidence and permits reuse of an original provider observation for at most five seconds.
Pinchos refreshes the primary display every five minutes and keeps the dynamic rows for five minutes, while Remainder's process-safe cache can coalesce the nearby remaining and pace reads.
The nominal original-observation age bound is five minutes plus Remainder's five-second reuse window plus command execution and scheduler delay, including the case where Remainder reused an almost-expired upstream observation.
That bound is not a hard five-minute maximum.
An explicit zero remains a successful exhausted value; unknown, expired, wrong-account, missing-auth, nonzero-exit, and timeout outcomes remain failures rather than becoming numeric zero or empty success.

Pinchos preserves the last successful value while a refresh is queued or running and after a failed attempt, and it marks age expiry separately from a failed command.
Age starts at command success in Pinchos.
Remainder's original observation time is not in the scalar stdout, and Pinchos does not invent one; a provider `observed_at` needs the separately planned structured-source contract.
A sleep or missed timer that skips several intervals still ages the last-good value from that shared success timestamp; the next render shows stale/scheduler-delayed state until a new success lands.

To roll back, restore the previously reviewed [`quota-axi`](https://github.com/kunchenguid/quota-axi) commands in the four `run` entries while keeping the item, labels, order, symbol, cache durations, and actions unchanged.
Pinchos will live-reload that edit and will not uninstall either executable.
`quota-axi` remains an independent, attributed quota tool and is still used by the separate optional recipe catalog.
