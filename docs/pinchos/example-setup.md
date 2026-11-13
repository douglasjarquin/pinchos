# Example setup

The checked-in clock example.

The canonical configuration is [`example/pinchos.toml`](../../example/pinchos.toml).
`init` writes that file when no configuration exists.
The item and menu rows are in [configuration.md](configuration.md).

```toml
[item.clock]
run = "date '+%H:%M'"
interval = "30s"
format = "{output}"
```

This item calls macOS `/bin/date`.
It needs no extra tools, logins, or PATH changes.
`date` is on Pinchos's fixed PATH `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` documented in [runtime.md](runtime.md).
Pinchos does not inherit the process `PATH`.

Expected output is 24-hour `HH:MM` in the machine's current timezone, for example `14:07`.
The value is timezone-dependent.
`pinchos run clock` executes it.
`pinchos doctor` should pass on a fresh Mac.

```sh
.build/release/pinchos doctor
.build/release/pinchos run clock
```

## Opt-in Codex example

The previous default used Remainder to read Codex weekly remaining and pace.
It needs Remainder on the fixed PATH and an existing Codex CLI login.
It fails on a fresh Mac without those.
This is an opt-in snippet, not what `init` writes.

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

This snippet calls [`remainder`](https://github.com/douglasjarquin/remainder) for the Codex `default` profile's account-scoped `weekly` remaining percentage and pace.
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
Confirm Remainder on that same PATH before activating the configuration.
`command -v remainder` in an interactive shell checks a different PATH.

```sh
env -i PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c 'command -v remainder && remainder --version'
.build/release/pinchos doctor
```
