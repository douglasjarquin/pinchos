# Pinchos 0.1 configuration

Pinchos reads one TOML file from `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is set, otherwise `~/.config/pinchos/pinchos.toml`.
The application watches that file and reloads it without rewriting it.

## Item

Each item is declared in file order as `[item.<id>]`.
The supported item keys are:

| Key | Type | Meaning |
| --- | --- | --- |
| `run` | string | Required shell command. |
| `interval` | duration or `manual` | Required refresh cadence. |
| `timeout` | duration | Command timeout. |
| `format` | string | Optional template containing `{output}`. |
| `symbol` | string | Optional macOS SF Symbol. |
| `icon` | path | Optional local icon, mutually exclusive with `symbol`. |
| `menu` | array of tables | Ordered generic submenu rows. |

Example:

```toml
[item.codex]
run = "quota-axi --provider codex --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .percentRemaining'"
interval = "5m"
timeout = "15s"
format = "{output}"
symbol = "terminal"

[[item.codex.menu]]
label = "Usage"
run = "quota-axi --provider codex --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .percentRemaining'"
cache = "5m"

[[item.codex.menu]]
label = "Open Codex"
action = "open https://chatgpt.com/codex"

[[item.codex.menu]]
separator = true
```

## Menu rows

Every non-separator row requires a non-empty `label`.
Use `value` for static text, `run` for a cached dynamic value, and `action` for a clickable shell action.
A row may combine `run` and `action`.
`cache` controls how long a successful dynamic value remains fresh and requires `run`.
`separator = true` is exclusive and cannot be combined with other fields.

Menu construction is synchronous and never executes a command.
Dynamic rows display their cached value and refresh asynchronously when stale or unavailable.
Actions run only after activation.

## Safety boundary

The configuration is declarative and read-only.
Commands and actions are unsandboxed code run with the user's permissions, so inspect commands, paths, network destinations, credentials, and write targets before adding them.
Use `pinchos validate`, `pinchos doctor`, and `pinchos run <item>` against an isolated configuration before changing the live file.

The old development keys and modules are intentionally unsupported.
Do not add `type`, `action`, `info`, groups, triggers, notifications, structured output, visibility flags, scheduler settings, shell/environment overrides, output bounds, error policies, freshness policies, config mutation, or launchd service commands.
