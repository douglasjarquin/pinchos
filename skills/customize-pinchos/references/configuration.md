# Pinchos configuration reference

This reference covers the current Pinchos TOML schema and the workflow for changing it safely.
Use it with the `customize-pinchos` skill when you add, review, or troubleshoot a menu-bar item.

Pinchos does not load skills or recipes at runtime.
This skill only guides an AI agent while the agent edits your configuration.
Pinchos runs configured shell commands with the user's permissions, and those commands are not sandboxed.
`validate` checks configuration syntax and schema values, while `doctor` checks known prerequisites.
Neither command can decide whether a command is trustworthy.

## Start with one item

Use a small read-only command to confirm the complete workflow before adding a dependency.

```toml
[item.clock]
type = "command"
run = "date '+%H:%M'"
interval = "manual"
format = "{output}"
timeout = "5s"
max_output = "1KiB"
```

The sample uses the stock macOS `date` command.
It does not need an account, a network connection, a secret, or a working-directory assumption.

## Change a configuration safely

Follow this order for every customization.

1. Run `pinchos config-path` to find the file Pinchos actually reads.
2. Read the existing file before editing it.
3. Preserve unrelated item tables and their declaration order.
4. Create an isolated staging root and copy the resolved file before editing it:

   ```sh
   config_path="$(pinchos config-path)"
   staging_root="$(mktemp -d)"
   mkdir -p "$staging_root/pinchos"
   baseline_path="$staging_root/pinchos/pinchos.toml.baseline"
   cp "$config_path" "$baseline_path"
   cp "$baseline_path" "$staging_root/pinchos/pinchos.toml"
   ```

5. Start with one item and one read-only command in the staged file.
6. Show the exact diff and every executable, argument, path, environment name, network destination, and write target before adding a risky command.
7. Run the checks against the staged file, not the live file:

   ```sh
   XDG_CONFIG_HOME="$staging_root" pinchos validate
   XDG_CONFIG_HOME="$staging_root" pinchos doctor
   XDG_CONFIG_HOME="$staging_root" pinchos run <item>
   ```

The staging copy changes the base directory for relative `shell[0]`, `working_directory`, `watch`, and `icon` paths.
Create safe staging fixtures or use absolute equivalents for any such path before relying on `doctor` or `run` results.
Do not claim that a staged check exercised an original relative path when it did not.

8. After the staged checks pass and the user authorizes promotion, confirm that the live file still matches the copied baseline with `cmp -s "$config_path" "$baseline_path"`.
   Stop if it changed, and ask the user to reconcile the new live changes instead of overwriting them.
9. Apply only the reviewed diff to the live file, then repeat `pinchos validate`, `pinchos doctor`, and `pinchos run <item>` without `XDG_CONFIG_HOME`.
10. Save the file and let a running Pinchos process reload it.
11. Open the item menu and confirm its displayed value, actions, and error behavior.

Use the same Pinchos binary for `config-path`, `validate`, `doctor`, and `run <item>` that you use to run the menu-bar app.
An installed binary may be available as `pinchos`.
A source checkout may use `.build/release/pinchos`.
Do not mix an old installed binary with a newly built configuration contract.

If the file does not exist, run `pinchos init` first.
`init` creates the example only when the target file does not already exist.
Use `pinchos open-config` when you want Pinchos to open the resolved file in its default application.

## Resolve the configuration file

Pinchos reads `$XDG_CONFIG_HOME/pinchos/pinchos.toml` when `XDG_CONFIG_HOME` is set and non-empty.
Otherwise it reads `~/.config/pinchos/pinchos.toml`.
Relative `shell[0]`, `working_directory`, `watch`, and `icon` paths resolve relative to the configuration file.
A leading `~` resolves to the launching user's home directory.

## Schema

Pinchos validates unknown keys, value types, required fields, and semantic constraints at load time.
Unknown keys are errors with the item or group path and source-line context when available.
The schema accepts ordinary TOML tables and top-level dotted keys.
Inline-table item and group declarations are rejected because Pinchos cannot recover their declaration order reliably.

### Root tables

The supported root keys are `item`, `group`, and `scheduler`.

Use `[scheduler]` to set the process-wide command-session limit.
The only scheduler key is `max_active_sessions`.
It is an integer from 1 through 32, and the default is `min(4, CPU cores)`.
This limit applies to scheduled refreshes, manual refreshes, clicks, and actions across the application.

Declare command modules with `[item.<name>]`.
Declare group modules with `[group.<name>]`.
Item and group names share one flat namespace.
Each name must be declared once.

Tables appear in menu-bar order from left to right.
Keep the table order intentional when you add or move items.
Pinchos rebuilds native status items when a live change cannot preserve that order through native insertion.

### Command items

Every command item requires `type = "command"` and a non-empty `run` string.
The parser supports these item keys.

| Key | Type | Default | Use |
| --- | --- | --- | --- |
| `type` | string | required | Set this to `"command"`. |
| `run` | string | required | Shell command that produces the displayed value. |
| `shell` | array of strings | `["/bin/sh", "-c"]` | Executable path and arguments. Pinchos appends `run` as the final argument. |
| `working_directory` | string | inherited process directory | Directory in which Pinchos starts the command. |
| `env` | table of strings | inherited environment | Values that override inherited variables for this item. |
| `interval` | string | `"60s"` | Use seconds, minutes, hours, or `"manual"`. |
| `output` | string | plain stdout | Set to `"json-v1"` to use structured output. |
| `triggers` | array of strings | empty | Refresh on `"startup"`, `"wake"`, or `"network-change"`. |
| `watch` | array of strings | empty | Refresh when one of these paths changes. |
| `timeout` | string | `"15s"` | Stop the command process group after this duration. The minimum is one second. |
| `max_output` | string | `"64KiB"` | Retained stdout and stderr tail per stream. Use `B`, `KiB`, or `MiB`, up to 4MiB per stream. |
| `format` | string | raw output | Display `{output}` or a formatted version of the trimmed last stdout line. |
| `click` | string | absent | Shell command for a left click. It runs independently of the primary command. |
| `refresh_on_click` | boolean | `false` | Refresh `run` on a left click when `click` is absent. |
| `error_text` | string | `"–"` | Text shown when the command fails under the default error policy. |
| `on_error` | string | `"replace"` | Use `"replace"` or `"keep_last"` when a command fails. |
| `stale_after` | string | absent | Mark the last successful value stale after this duration. |
| `action` | array of tables | empty | Add menu actions in declaration order. |
| `icon` | string | absent | Local image path. It cannot appear with `symbol`. |
| `symbol` | string | absent | macOS SF Symbol name. It cannot appear with `icon`. |
| `max_length` | integer | absent | Limit the rendered title by grapheme clusters. |
| `hide_when_empty` | boolean | `false` | Hide the item after a completed successful run with empty trimmed output. |
| `hide_on_error` | boolean | `false` | Hide the item after a completed failed run. |
| `hidden` | boolean | `false` | Keep the item out of the menu bar until this key becomes `false` or is removed. |
| `icon_only` | boolean | `false` | Show only a loaded icon while keeping the full title in the diagnostics menu. |
| `disabled` | boolean | `false` | Keep the item visible but stop scheduled, click, refresh, and action execution. |
| `notify_on` | array of strings | empty | Notify on `"failure"`, `"recovery"`, or both. |
| `notify_cooldown` | string | absent | Suppress repeated failure notifications for this duration. |

Use `[item.<name>.env]` for environment values.
Environment names must start with a letter or underscore and contain only letters, digits, and underscores.
Environment values must be strings without NUL bytes.
Configured values override inherited values immediately before the command starts.

Use `interval = "manual"` for an item that should not poll.
The item runs once when it activates.
Use **Refresh Now** or `refresh_on_click = true` for later refreshes.

The `triggers` and `watch` arrays add event-driven refreshes without changing the polling interval.
Repeated equivalent events are debounced.
Paths in `watch` are normalized and duplicate paths are removed.

`icon` and `symbol` are mutually exclusive.
An unavailable SF Symbol keeps the item valid and falls back to text.
A missing or unreadable file icon also falls back to text.

`hidden`, `hide_when_empty`, and `hide_on_error` control display only.
They do not stop the command unless `disabled` is also true.
An item never hides before its first completed attempt.

### Actions

Use one or more `[[item.<name>.action]]` tables.
Each action requires a non-empty `title` and exactly one of `run` or `refresh`.
`run` is a shell command that uses the item's shell, working directory, environment, timeout, and output bound.
`refresh = true` invokes the item's normal refresh without starting a second action shell.

```toml
[[item.clock.action]]
title = "Open calendar"
run = "open -a Calendar"

[[item.clock.action]]
title = "Refresh now"
refresh = true
```

Do not set both `run` and `refresh` in one action.
Actions are not a security boundary.
An action command can change files, open applications, access a network, or expose credentials if you configure it to do so.

### Groups

Use `[group.<name>]` to place several declared items behind one native menu-bar item.
Groups do not run commands of their own.

| Key | Type | Default | Use |
| --- | --- | --- | --- |
| `title` | string | required | Static text on the group status item. |
| `members` | array of strings | required | Non-empty names of declared items or groups. |
| `icon` | string | absent | Local image path. It cannot appear with `symbol`. |
| `symbol` | string | absent | macOS SF Symbol name. It cannot appear with `icon`. |
| `hidden` | boolean | `false` | Keep the group out of the menu bar until this key becomes `false` or is removed. |

Members must be unique and must name declared items or groups.
Nested groups are allowed.
Membership cycles are errors.
A member appears inside its parent group and does not receive a second top-level status item.
The member keeps its own schedule, actions, diagnostics, and refresh behavior.

## Structured output

Set `output = "json-v1"` when a command needs to provide display state, an icon, or declarative actions.
The command must write one JSON object with integer `version = 1`.

```json
{
  "version": 1,
  "text": "81%",
  "state": "warning",
  "hidden": false,
  "symbol": "chart.bar.fill",
  "actions": [
    { "title": "Refresh", "refresh": true }
  ]
}
```

The optional `text` field becomes the displayed title.
The optional `state` is `"normal"`, `"warning"`, or `"error"`.
The optional `hidden` field controls visibility for that successful run.
The optional `icon` and `symbol` fields override the configured icon source and remain mutually exclusive.
The optional `actions` array replaces the configured actions for that successful run.
Unknown top-level JSON fields are ignored.

Malformed JSON, unsupported versions, invalid field types, conflicting icon sources, invalid actions, and truncated retained output are command failures.
Use `on_error = "keep_last"` when retaining a known-good value is safer for your display.

## Display and diagnostics

`max_length` limits only the menu-bar title.
The diagnostics menu retains the full title.
`max_output` limits retained stdout and stderr without stopping the command from draining its streams.
Every collector also draws from one shared 8MiB output-memory budget.

The default `on_error = "replace"` displays `error_text` after a failed command.
`on_error = "keep_last"` retains the last successful value and marks the failure in diagnostics.
A failed command does not crash Pinchos.

## Command safety

Treat every `run`, `click`, action `run`, `shell`, `working_directory`, and `env` value as executable configuration.
Pinchos launches the configured shell vector and appends the command as its final argument.
The command inherits the user's environment, with configured environment values overriding matching names.
The command runs with the user's permissions and is not sandboxed.

Before adding a command, show the exact command, executable, arguments, working directory, environment names, network destinations, and write targets.
Ask for explicit user authorization before adding or running a command that changes state, uses credentials, sends data, contacts a private service, or invokes a privileged tool.
Do not treat a request to customize a display item as permission to alter unrelated files, services, accounts, or repositories.

Prefer commands that read one known local value and print one bounded result.
Use a fixed executable and fixed arguments when possible.
Quote shell values instead of concatenating untrusted text into a command.
Do not interpolate command output, downloaded text, issue text, or user-provided text into a later shell command.

Do not recommend `curl | sh`, `wget | sh`, `eval`, remote script execution, `sudo`, `rm -rf`, broad file globs, recursive permission changes, or commands that write credentials to disk.
Do not copy a command from an untrusted page without inspecting every argument and destination.
Do not put API keys, passwords, cookies, access tokens, private keys, or other secrets in TOML.
Use an existing CLI login, keychain integration, or environment mechanism that keeps secrets outside the configuration file.
Use the least privilege account and credential scope that the tool supports.

For network commands, name the fixed host or endpoint and set the tool's own network timeout when it supports one.
Also set Pinchos `timeout` so a hung tool cannot occupy a command session forever.
Set `max_output` to a small value that covers the expected result.
Do not use a network command when a local source provides the same signal.

`validate` proves only that the TOML matches the schema.
`doctor` proves only that Pinchos can resolve selected prerequisites.
Neither command approves command intent, network trust, credentials, or data handling.
Run a new command explicitly with `pinchos run <item>` only after reviewing it.

## Troubleshoot a failed customization

Run `pinchos validate` first when Pinchos rejects a file.
Correct the reported item, key, type, or source line before investigating runtime output.

Run `pinchos doctor` when validation succeeds but a command does not start.
Check the shell executable, simple command resolution, working directory, icon path, SF Symbol availability, and environment prerequisites.

Run `pinchos run <item>` to separate command output from menu-bar presentation.
Check the command's exit status and stderr before changing `format`, `error_text`, or `on_error`.

If a live reload does not change the menu, confirm that you edited the path printed by `pinchos config-path` and that the running process uses the same binary you validated.
If the file has a syntax error, Pinchos keeps the last good configuration active until the next successful reload.
