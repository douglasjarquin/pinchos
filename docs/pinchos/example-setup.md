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
The value is locale- and timezone-dependent.
`pinchos run clock` executes it.
`pinchos doctor` should pass on a fresh Mac.

```sh
.build/release/pinchos doctor
.build/release/pinchos run clock
```

The Codex Remainder example, including download and checksums, is the opt-in recipe [`recipes/codex.toml`](../../recipes/codex.toml).
