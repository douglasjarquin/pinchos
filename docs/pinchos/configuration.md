# Configuration

Config path, item keys, and menu rows.

Pinchos reads `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is non-empty.
Otherwise it reads `~/.config/pinchos/pinchos.toml`.
The config watcher reloads this file after changes, but normal operation never rewrites it.

The canonical source is [`example/pinchos.toml`](../../example/pinchos.toml).
`init` writes this clock item when no configuration exists.

```toml
[item.clock]
run = "date '+%H:%M'"
interval = "30s"
format = "{output}"
```

Setup for this example is in [example-setup.md](example-setup.md).
The previous Codex Remainder default, with cached menu rows and `symbol = "terminal"`, is the opt-in snippet in [example-setup.md](example-setup.md#opt-in-codex-example).
It needs Remainder on the fixed PATH and a Codex CLI login, and fails on a fresh Mac without those.

Items appear in declaration order.
Item ids in `[item.<id>]` and `[[item.<id>.menu]]` may contain only `[A-Za-z0-9_-]`.

Durations are a whole number plus `s`, `m`, or `h`, with a minimum of `1s`.
Compound values, decimals, and `ms` are rejected (`5m30s`, `1.5s`, and `500ms` are invalid).

| Key | Type | Meaning |
| --- | --- | --- |
| `run` | string | Required shell command. |
| `interval` | duration or `manual` | Refresh cadence for the primary value. Omit for `60s`. |
| `timeout` | duration | Command timeout. Omit for `15s`. |
| `format` | string | Optional template that may contain only `{output}`. Omit to show the last non-empty stdout line, trimmed. |
| `symbol` | string | Optional macOS SF Symbol name. |
| `icon` | path | Optional local image path, mutually exclusive with `symbol`. |
| `menu` | `[[item.<id>.menu]]` rows | Ordered generic submenu rows. |

There are no per-item `shell`, `env`, or `cwd` keys.
Commands run under the internal execution policy in [runtime.md](runtime.md).
PATH is `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
`SSH_AUTH_SOCK` is not inherited.
`symbol` is a macOS SF Symbol name.
`icon` is a local image path.
The two icon keys are mutually exclusive.

Every non-separator menu row needs a non-empty `label`.

| Key | Type | Meaning |
| --- | --- | --- |
| `label` | string | Required on non-separator rows. |
| `value` | string | Static text. Cannot combine with `run`. |
| `run` | string | Cached command value. |
| `action` | string | Clickable command. May combine with `run`. |
| `cache` | duration | Freshness window for a `run` row against the shared command-success timestamp. Omit to make the row manual-only (not age-stale). |
| `separator` | `true` | Exclusive; cannot combine with any other row key. |

Use `value` for static text, `run` for a cached command value, and `action` for a clickable command.
A row may combine `run` and `action`.
The item `interval` is the same kind of window for the primary value.
Shared primary and menu commands keep one success timestamp; consumers with different windows can disagree on freshness without depending on who registered first.

Opening a menu is synchronous and never waits on a command.
Never-attempted (unavailable) rows may start a background refresh immediately.
Stale or failed cached rows may request a background retry after a fixed 30-second cadence from when the last attempt settled, documented in [runtime.md](runtime.md).
Fresh values do not refresh on open.
Refresh Now requests every distinct value source for the selected item, including manual rows with no `cache` interval, and never runs action commands.
Actions execute only when selected.
Equivalent primary and menu commands share one source and cache within a controller.

Commands and actions are unsandboxed code executed with the user's permissions.
Review executables, arguments, paths, network destinations, credentials, and write targets before placing them in TOML.
