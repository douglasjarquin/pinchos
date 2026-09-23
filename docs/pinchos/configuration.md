# Configuration

Config path, item keys, and menu rows. Moved out of the README.

Pinchos reads `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is non-empty.
Otherwise it reads `~/.config/pinchos/pinchos.toml`.
The config watcher reloads this file after changes, but normal operation never rewrites it.

The canonical source is [`example/pinchos.toml`](example/pinchos.toml).

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

Download, checksum, freshness, and rollback for this example are in [docs/pinchos/example-setup.md](docs/pinchos/example-setup.md).

Items appear in declaration order.
The supported item keys are `run`, `interval`, `timeout`, `format`, `symbol`, `icon`, and `menu`.
`symbol` is a macOS SF Symbol name.
`icon` is a local image path.
The two icon keys are mutually exclusive.

Every non-separator menu row needs a non-empty `label`.
Use `value` for static text, `run` for a cached command value, and `action` for a clickable command.
A row may combine `run` and `action`.
`cache` is optional for a dynamic row; when present, it controls the row's freshness interval, while an omitted value makes the row manual-only.
`separator = true` cannot be combined with any other row key.

Opening a menu is synchronous and never executes a command.
Unavailable cached rows request a background refresh while keeping menu construction immediate.
Actions execute only when selected.
Equivalent primary and menu commands share one source and cache within a controller.
