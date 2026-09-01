# Recipes

These recipes are small copyable examples for the Pinchos 0.1 schema.
Each file contains one or more `[item.<id>]` tables and documents its command dependency, expected output, and network or account assumptions.

| Recipe | Signal | Dependency |
| --- | --- | --- |
| [`clock.toml`](clock.toml) | Local time | macOS `/bin/date` |
| [`battery.toml`](battery.toml) | Battery percentage | macOS `/usr/bin/pmset` |
| [`disk-free.toml`](disk-free.toml) | Root-volume free space | macOS `/bin/df` and `awk` |
| [`github-open-prs.toml`](github-open-prs.toml) | Open pull requests | GitHub CLI and an existing login |
| [`vpn-network.toml`](vpn-network.toml) | Default interface and likely VPN activity | macOS `route` and `ifconfig` |
| [`ai-quota.toml`](ai-quota.toml) | Provider quota | `quota-axi` and `jq` |
| [`http-health.toml`](http-health.toml) | HTTP status | macOS `curl` |
| [`aws-profile.toml`](aws-profile.toml) | AWS account identity | AWS CLI and an existing profile |
| [`load-average.toml`](load-average.toml) | One-minute load | macOS `sysctl` and `awk` |

The Codex quota example in [`example/pinchos.toml`](../example/pinchos.toml) demonstrates several cached menu rows, one action, and a separator.
Its menu opens from cache without running commands during construction.

Validate a recipe before copying it into the live configuration:

```sh
XDG_CONFIG_HOME="$(mktemp -d)" .build/release/pinchos validate
```

The command must be run after placing the selected recipe at `pinchos/pinchos.toml` in the temporary root.
Never place credentials or tokens in a recipe.
