# Pinchos 0.1 configuration

Pinchos reads one TOML file from `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is non-empty, otherwise `~/.config/pinchos/pinchos.toml`.
The application watches that file and reloads it without rewriting it.
Commands below use `.build/release/pinchos` from a source checkout.
After a release install, the same subcommands are the `pinchos` executable on `PATH`.

## Item

Each item is declared in file order as `[item.<id>]`.
Item ids may contain only `[A-Za-z0-9_-]`.
Durations are a whole number plus `s`, `m`, or `h`, with a minimum of `1s`.
Compound values, decimals, and `ms` are rejected.
The supported item keys are:

| Key | Type | Meaning |
| --- | --- | --- |
| `run` | string | Required shell command. |
| `interval` | duration or `manual` | Refresh cadence. Omit for `60s`. |
| `timeout` | duration | Command timeout. Omit for `15s`. |
| `format` | string | Optional template containing `{output}`. Omit to show the last non-empty stdout line, trimmed. |
| `symbol` | string | Optional macOS SF Symbol. |
| `icon` | path | Optional local icon, mutually exclusive with `symbol`. |
| `menu` | array of tables | Ordered generic submenu rows. |

Example:

```toml
[item.clock]
run = "date '+%H:%M'"
interval = "30s"
format = "{output}"
```

`init` writes that clock item.
The previous Codex Remainder default, with cached menu rows and `symbol = "terminal"`, is the opt-in snippet in `docs/pinchos/example-setup.md`.
It needs Remainder on the fixed PATH and a Codex CLI login, and fails on a fresh Mac without those.

## Menu rows

Every non-separator row requires a non-empty `label`.
Use `value` for static text, `run` for a cached dynamic value, and `action` for a clickable shell action.
A row may combine `run` and `action`.
`cache` is the freshness window for a dynamic row against the shared command-success timestamp and requires `run`.
Omit `cache` to make the row manual-only.
`separator = true` is exclusive and cannot be combined with other fields.

Menu construction is synchronous and never executes a command.
Dynamic rows display their cached value and refresh asynchronously when stale or unavailable.
Refresh Now requests every distinct value source, including manual rows, and never runs actions.
Actions run only after activation.

## Safety boundary

The configuration is declarative and read-only.
Commands and actions are unsandboxed code run with the user's permissions, so inspect commands, paths, network destinations, credentials, and write targets before adding them.
Use `.build/release/pinchos validate`, `.build/release/pinchos doctor`, and `.build/release/pinchos run <item>` against an isolated configuration before changing the live file.

Copy the current file into one named temporary `XDG_CONFIG_HOME` root, then validate with the same path:

```sh
config_root="$(mktemp -d)"
mkdir -p "$config_root/pinchos"
cp "$(.build/release/pinchos config-path)" "$config_root/pinchos/pinchos.toml"
XDG_CONFIG_HOME="$config_root" .build/release/pinchos validate
```

The old development keys and modules are intentionally unsupported.
Commands run under the internal execution policy in `docs/pinchos/runtime.md` (PATH `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, HOME as the working directory, a small inherited-key set; `SSH_AUTH_SOCK` is not inherited).
Do not add `type`, `action`, `info`, groups, triggers, notifications, structured output, visibility flags, scheduler settings, shell/environment overrides, output bounds, error policies, freshness policies, config mutation, or launchd service commands.
