# Pinchos recipes

These recipes are deliberately small examples for the stable `0.1.0` configuration contract. Copy one `[item.<name>]` table into `~/.config/pinchos/pinchos.toml`, review the command, then run:

```sh
pinchos validate
pinchos doctor
pinchos run <item-name>
```

| Recipe | Purpose |
| --- | --- |
| [`clock.toml`](clock.toml) | Current local time |
| [`battery.toml`](battery.toml) | Battery percentage |
| [`disk-free.toml`](disk-free.toml) | Free space on `/` |
| [`memory-pressure.toml`](memory-pressure.toml) | Approximate memory use |
| [`load-average.toml`](load-average.toml) | One-minute load average |
| [`local-ip.toml`](local-ip.toml) | Address for `en0` |
| [`http-health.toml`](http-health.toml) | HTTP status from a bounded request |
| [`git-branch.toml`](git-branch.toml) | Current branch for one repository |

Recipes use only the public keys `run`, `interval`, `timeout`, `format`, `symbol`, and `icon`. Network and path placeholders must be replaced before use. Pinchos commands run with your user permissions; read every command before adding it.
