# pinchos

<img width="2172" height="724" alt="pinchos-github-header" src="https://github.com/user-attachments/assets/072cb6ab-6570-4dd4-9a41-b83602d1da21" />

Pinchos are the little snacks pinned to a Basque bar top with a skewer.
This app pins your own snacks to the macOS menu bar: one declarative TOML file, native `NSStatusItem`s, no runtime bloat.

`pinchos.toml` is to your menu bar what `starship.toml` is to your terminal prompt.

## Why

SwiftBar and xbar host a folder of one-script-per-plugin.
Pinchos is one config file with a module system: declare items, pick an interval, point at a shell command.

The other reason pinchos exists: a popular provider-quota menu bar app was measured burning **1GB of RSS** to show a single percentage that updates once a minute.
Pinchos exists to make that class of widget cost two orders of magnitude less.
No Electron, no webview, no Dock icon.
Idle RSS with 3 items at 60s intervals stays under 15MB, and idle CPU is effectively zero between ticks.

## Install / build

Requires macOS 14+ and Xcode 15+ (or a standalone Swift 5.10+ toolchain).

```sh
git clone https://github.com/douglasjarquin/pinchos.git
cd pinchos
swift build -c release
```

The binary lands at `.build/release/pinchos`. Run it directly:

```sh
.build/release/pinchos
```

It has no Dock icon and no main window (`NSApp.setActivationPolicy(.accessory)`) — it lives entirely in the menu bar.
Quit it from any item's right-click menu, or `killall pinchos`.
`killall pinchos` sends SIGTERM to each matching Pinchos process, and each process runs the same bounded cleanup used by the native Quit action.

### Shutdown and interruption

Pinchos uses one single-flight shutdown coordinator for native Quit, SIGTERM, SIGINT, and CLI completion.
The first termination request wins, and repeated or mixed requests do not start a second cleanup sequence.

SIGTERM is handled in both GUI and CLI modes.
SIGINT is handled by `pinchos run <item>` and by a GUI process launched directly from a terminal; pressing Control-C in that terminal requests the same graceful GUI cleanup as SIGTERM.
A GUI process launched with `open` has no controlling terminal, so Control-C in the launching shell does not target it.

For `pinchos run <item>`, Control-C returns 130 and SIGTERM returns 143 after the active runner and every owned same-group descendant have been cleaned up.
Without a termination signal, ordinary command exit codes remain unchanged.
Managed process groups apply the existing SIGTERM-then-SIGKILL cancellation policy, so a command that ignores SIGTERM cannot outlive its Pinchos owner.

Cleanup has a finite five-second bound.
If cleanup cannot settle within that bound, Pinchos uses its deliberate forced-exit escape hatch with status 125; this escape hatch is owned by the coordinator and cannot overlap another shutdown sequence.

The signal integration uses `DispatchSourceSignal` for safe handoff.
The raw POSIX signal disposition does no async work, actor calls, locking, or allocation; the DispatchSource event handler only posts the signal number to the main actor, where the bounded cleanup state machine runs.

### Launch at login

Pinchos doesn't manage login items for you (that's out of scope for v1). Two options, pick whichever fits:

```sh
# One-off, from Terminal or a script:
open /path/to/pinchos/.build/release/pinchos

# Or add it under System Settings -> General -> Login Items,
# pointing at the same release binary.
```

## Config

Pinchos reads `$XDG_CONFIG_HOME/pinchos/pinchos.toml` if `XDG_CONFIG_HOME` is set, otherwise `~/.config/pinchos/pinchos.toml`.

The file is edited live: pinchos watches it with a `DispatchSource` file-system-object source and applies configuration diffs without relaunching.
Unchanged items keep their existing status item, timer, runner, and displayed output.
Added items are appended when native status-item placement can preserve declaration order, removed items are torn down, and changed items update in place.
If a declaration-order change cannot be represented by native insertion, pinchos rebuilds the configured status items to restore the requested order.
Reload notifications are coalesced so in-place writes are applied after the file settles, and a malformed file leaves the last good configuration running.

### CLI

The release binary also provides setup, validation, diagnostics, and one-shot execution commands.

```sh
.build/release/pinchos --help
.build/release/pinchos init
.build/release/pinchos validate
.build/release/pinchos doctor
.build/release/pinchos config-path
.build/release/pinchos open-config
.build/release/pinchos run codex
```

Use `pinchos <command> --help` for command-specific help.
`init` creates the config directory and writes the documented example only when the config does not already exist.
`validate` rejects missing, empty, malformed, and semantically invalid configurations with item, key, and source-line context when available.
`doctor` reports config accessibility, shell and command availability, working directories, icons, environment prerequisites, and launch-at-login state when the app bundle exposes it.
`config-path` prints the resolved path without creating files, while `open-config` opens that path in its default application and creates an empty file only when necessary.
`run <item>` uses the same configured shell vector, working directory, merged environment, timeout, and output bounds as the menu-bar app.

CLI exit codes are suitable for scripts.
`0` means success, `2` means invalid command usage, `3` means config or open failure, and `4` means `doctor` found a problem.
`run` preserves a configured command's exit code, uses `124` for timeouts, and uses `127` for launch failures.

### Strict schema compatibility

Pinchos validates the current TOML schema strictly at every entry point.
Unknown keys under `item.*`, including action keys, are configuration errors with the item path and source line.
Present values must use the documented TOML type; integers, booleans, arrays, and tables are not silently coerced to strings or treated as absent.
`run`, `click`, and action `run` commands must contain non-whitespace text.
Environment variable names remain an explicitly dynamic set, but each name must be valid for the configured shell and each value must be a string without NUL bytes.
This strict behavior applies to `pinchos validate`, `doctor`, `run`, and live GUI reloads.
Configurations that relied on ignored typos or wrong types must be corrected before upgrading to this schema behavior.
When a new model field is added, its supported-key enumeration and parser validation must be updated together.

### Schema (v1)

Every item is a `[item.<name>]` table. Items render left-to-right in the order their tables appear in the file.

Items may also be declared with top-level dotted keys (`item.<name>.<key> = value`), which is standard TOML and produces the same result; declaration order is still left-to-right, but dotted-key items must come before the first `[item.*]` header in the file (TOML has no syntax to return to root scope once a header has opened a table). Inline-table item declarations (`item = { <name> = { ... } }` or `item.<name> = { ... }`) parse under the TOML spec but are not a supported Pinchos declaration form and are rejected with an explicit configuration error; use `[item.<name>]` or dotted keys instead.

```toml
[item.<name>]
type = "command"        # required, the only v1 module type
run = "<shell command>" # required, executed with `shell` on its interval
shell = ["/bin/zsh", "-lc"] # optional, default ["/bin/sh", "-c"]
working_directory = "~/src/project" # optional, tilde-expanded; relative paths are relative to this config file
interval = "60s"        # optional, default "60s". Formats: "30s", "5m", "1h", or "manual"
timeout = "15s"         # optional, default "15s", minimum "1s". Terminates the command process group when it expires
max_output = "64KiB"    # optional, default "64KiB" per stdout/stderr stream. Formats: "B", "KiB", "MiB". Maximum 4MiB per stream.
format = "{output}%"    # optional. {output} is the trimmed last stdout line of `run`. Absent = raw output.
click = "<shell command>" # optional, run (fire-and-forget) on left-click
refresh_on_click = true  # optional, refresh `run` on left-click when `click` is absent
error_text = "–"   # optional, default "–". Shown when `run` fails, instead of the item disappearing.
on_error = "keep_last" # optional, default "replace". Keep the last successful value when `run` fails.
stale_after = "15m"    # optional. Mark the last successful value stale at or after this age.
tooltip = "Updated {updated_at} ({status})" # optional. Native tooltip template.
icon = "/path/to/icon.svg" # optional, a local image file (SVG/PNG/PDF) rendered as a template icon left of the text
max_length = 24        # optional. Truncates the rendered title to this many grapheme clusters, appending "…"
hide_when_empty = false # optional, default false. Hide the item when the last successful run's trimmed output is empty
hide_on_error = false   # optional, default false. Hide the item while its last completed run is a failure
icon_only = false       # optional, default false. Suppress the text title once `icon` has loaded; the full title stays available in the tooltip and diagnostics
disabled = false        # optional, default false. Stop scheduling and block manual/click/action execution while keeping the item visible for diagnostics

[item.<name>.env]
PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
AWS_PROFILE = "production"

[[item.<name>.action]]
title = "Open usage"
run = "open https://example.com/usage"

[[item.<name>.action]]
title = "Refresh now"
refresh = true
```

- `tooltip` is rendered by the native status-item tooltip. Supported placeholders are `{output}` (the retained stdout, including newlines, as a bounded preview — see "Diagnostics previews vs. retained output" below), `{updated_at}` (the last successful completion time), `{attempted_at}` (the last command start time), `{duration}` (the last run duration with three decimal places and an `s` suffix), `{exit_status}` (the last exit code or terminal result), `{error}` (the latest bounded stderr line or terminal error), `{stale}` (`yes` or `no`), and `{status}` (`running`, `fresh`, `stale`, `error`, or `unavailable`).
- Timestamps use UTC ISO-8601 format.
- Before the first successful run, `{output}` and `{updated_at}` are empty, while `{attempted_at}` and diagnostic placeholders become available after an attempt.
- `{{` and `}}` escape literal braces.
- An unknown placeholder or unmatched brace is a configuration error, so raw placeholder braces never leak into a native tooltip.
- The full output is the command runner's retained output subject to `max_output`; a truncation flag and byte counts remain visible in the right-click diagnostics menu, and the exact retained bytes stay available via **Copy Full Output**/**Copy Full Error**.
- `shell` is an executable path followed by the arguments used to invoke it; `run` is appended as the final argument. The default is `[/bin/sh, -c]`, preserving the original behavior.
- `shell` and `working_directory` are resolved when the config loads. A leading `~` expands to the launching user's home directory, and relative filesystem paths are resolved relative to the config file, including `icon` paths.
- `working_directory` is optional. When omitted, the command inherits Pinchos's process working directory.
- `[item.<name>.env]` values merge with the inherited Pinchos environment. Configured values override inherited variables with the same name immediately before `run` starts, while variables not listed remain available to the command. This keeps configured values stable even when the selected shell runs login startup files.
- Environment variable names must use letters, digits, and underscores, and must start with a letter or underscore.
- `timeout` accepts whole seconds, minutes, or hours and terminates the command's process group after the configured duration.
- `interval = "manual"` runs the item once when it is first activated, then disables its periodic timer. Use **Refresh Now** from the item's right-click menu, or set `refresh_on_click = true`, for later runs.
- `refresh_on_click` only applies when `click` is absent. A configured `click` command keeps ownership of the normal left-click action.
- An item may declare zero or more `action` tables.
- Actions appear in declaration order at the top of the item's right-click menu.
- A `run` action uses the item's shell, working directory, environment, timeout, and output bound.
- A `refresh = true` action invokes the native item refresh without starting a second shell command.
- Repeated command-action invocations are skipped while that action is running, and the skipped count is retained in the item's diagnostics.
- Timeout and cancellation terminate the process group with `SIGTERM` followed immediately by `SIGKILL`, so managed descendants cannot outlive an item or the app.
- A command that exits while leaving same-group background work running remains owned by its item until that work exits or the item is removed.
- `max_output` is an independent retained-tail limit for stdout and stderr, so `64KiB` can retain up to 64KiB from each stream while both streams continue draining. Values above 4MiB are rejected at config load with the item, key, and source line.
- Retaining the tail keeps the final output line and the most recent stderr diagnostic available even when a command emits more than the configured limit. Retention is a circular byte buffer, so appending new output costs work proportional to the new bytes read, not to `max_output` or to total bytes read so far.
- When a retained tail happens to start mid-way through a multi-byte UTF-8 scalar (because the cut landed inside it), the orphaned byte(s) render as the U+FFFD replacement character rather than corrupting or merging with neighboring text — standard `String(decoding:as:)` behavior, not something pinchos special-cases.
- **Output memory budget:** every stdout/stderr collector in the process (primary, click, and action runners) draws from one shared 8MiB aggregate budget. Configuring several noisy items or actions with large `max_output` values cannot together reserve more than that shared budget — collectors that would exceed it simply retain less than their configured `max_output`, with their `truncated` diagnostic reflecting the shortfall. This decouples "sum of every item's configured `max_output`" from actual retained memory, which is what keeps the default idle-footprint target meaningful even for adversarial configs.
- `icon` is a plain filesystem path, not a built-in icon library — pinchos ships with no bundled icon catalog. Point it at any image file you like; it's drawn as a template image (tinted automatically for light/dark menu bars) at 16x16, to the left of the item's text. A missing or unreadable file just falls back to text-only — it never crashes the app.
- `max_length` truncates only the rendered menu-bar title, counting grapheme clusters (so multi-scalar emoji and combining marks are never split) and appending a single `…`; the full untruncated title remains available in the native tooltip and the right-click diagnostics menu. Omitted or non-positive values apply no cap. It must be a positive integer — zero, negative, or non-integer values are a configuration error.
- `hide_when_empty` and `hide_on_error` are display-only policies evaluated after each completed run; they never skip execution, and an item is never hidden before its first completed attempt (so a slow-starting item stays visible instead of vanishing). `hide_on_error` takes effect on the very first run if that run fails. When both apply, a failing run defers to `hide_on_error`.
- `icon_only` clears the rendered title from the status bar button once `icon` has successfully loaded, showing only the icon; if `icon` is absent or unreadable, `icon_only` has no visible effect and the text title is shown as usual. The tooltip and diagnostics menu always retain the full title regardless of `icon_only`.
- `disabled` stops the item's scheduled timer and blocks left-click, `refresh_on_click`, and declarative `action` execution (each is a no-op while disabled; already-running work is cancelled the moment `disabled` becomes true through a live reload). The item stays visible with a "Disabled: yes" line in its right-click diagnostics menu, and the menu's action entries and **Refresh Now** fallback are shown but disabled, so a disabled item remains inspectable without being actionable. Right-click still opens normally. Flipping `disabled` back to `false` through a live reload resumes scheduling and re-enables actions.
- A failing command never crashes pinchos. With the default `on_error = "replace"`, it renders `error_text`; with `on_error = "keep_last"`, it retains the last successful title and full output while marking the item with a compact warning indicator.
- `stale_after` uses the last successful completion as its clock origin and becomes stale when the age is greater than or equal to the configured threshold. A first-run failure is `error`/`unavailable` rather than a fabricated stale value.
- Command runs for a given item never overlap: if the previous run for that item hasn't finished when the next tick fires, the tick is skipped.
- Manual refreshes use the same per-item execution gate as scheduled ticks, so repeated Refresh Now actions are skipped while a run is active.
- While a refresh is running, the last good value stays visible and the item's native tooltip reports the running state. The right-click diagnostics menu reports a bounded preview of the retained value (see below), state, last attempt, last success, stale flag, duration, exit/error details, and the hardened runner's per-stream diagnostics.
- Skipped ticks are counted in the item's right-click diagnostics menu without replacing the last completed result.
- The same timeout and output bounds apply to an optional click command, which is cancelled when its item is removed or Pinchos quits.
- The diagnostics menu reports the last exit code or signal, duration, skipped ticks, per-stream truncation, and the latest bounded stderr line.
- `click` is fire-and-forget only in the sense that the left-click never blocks the UI and never replaces the item's primary displayed value — it is not silent. A configured `click` command gets its own **Click Action** section in the right-click menu, independent of the primary refresh diagnostics: current state (never run, running, completed, error, timed out, or cancelled), last attempt/completion time, duration, exit/signal/timeout/cancellation/launch-failure detail, skipped-invocation count (while the click runner is already busy), per-stream byte counts and truncation, a bounded stderr preview, and **Copy Click Output**/**Copy Click Error** actions for the complete retained streams. A click failure never overwrites the menu-bar title, tooltip output, or the primary runner's last-good value. Diagnostics for the click runner are retained across presentation-only reloads and reset only when the click command or its execution settings (shell, environment, working directory, timeout, or `max_output`) change or `click` is removed.
- A command action's diagnostics offer their own **Copy "&lt;title&gt;" Output**/**Copy "&lt;title&gt;" Error** entries once that action has produced non-empty output/error, mirroring the click and primary sections.
- An unresolvable shell or working directory is reported in the config warning; a launch failure during execution is retained in the item's diagnostics menu with the resolved path.

### Diagnostics previews vs. retained output

Every command-derived `NSMenuItem` title and tooltip expansion is a **bounded preview**, not the raw retained string, produced by `DiagnosticPreviewFormatter` (`Sources/PinchosCore/DiagnosticPreviewFormatter.swift`). This decouples the cost of opening a right-click menu or rendering a tooltip from `max_output` (up to 4MiB per stream): the primary "Value:" line, stderr/error lines, and per-action diagnostics are capped independently in grapheme clusters, UTF-8 bytes, and line count, so a pathologically large or control-character-heavy command output can never inflate a menu's layout or hide the global **Open Config**/**Reload Config**/**Quit Pinchos** actions beneath it.

- Menu titles render as one visual line: embedded line breaks are visibly escaped (joined with `␊`) rather than becoming real newlines, since AppKit renders an `NSMenuItem.title` as a single row.
- Tooltips are a native multi-line surface and keep real line breaks, but still cap total size and line count for the same reason.
- NUL, other C0/C1 control characters, DEL, and bidi format controls are replaced with a visible placeholder (mostly the Unicode Control Pictures block, e.g. tab becomes `␉`, escape becomes `␛`) so they can neither disappear nor visually distort surrounding text; ordinary Unicode, including multi-scalar emoji and combining marks, passes through unchanged. Truncation never splits an extended grapheme cluster.
- Whenever a preview is actually shortened, it ends with an explicit marker naming the original byte and line counts, e.g. `… (truncated, 65536 bytes / 1 line total)`, and the corresponding menu item's accessibility label/help calls out the truncation for VoiceOver.
- The preview never replaces the retained data: **Copy Full Output**, **Copy Full Error**, **Copy Click Output**/**Copy Click Error**, and each action's **Copy "&lt;title&gt;" Output**/**Copy "&lt;title&gt;" Error** place the exact retained stdout/stderr on the clipboard, unabridged, and are omitted whenever the corresponding stream is empty.
- A malformed config keeps the last good config running untouched, and pinchos additionally shows a single `pinchos ⚠︎` item; click it to see the parse error (with line number when available), reload, or quit. Fix the file and it clears automatically on the next successful reload.
- Right-click any item for its configured actions, **Refresh Now** when no built-in refresh action is configured, item diagnostics, then the global **Open Config**, **Reload Config**, and **Quit Pinchos** actions.
- Right-click the warning item for its recovery actions.
- The app is fully usable without ever touching the config file.

### Example: the flagship "quota" preset

```toml
[item.claude]
type = "command"
run = "quota-axi --provider claude --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .percentRemaining'"
interval = "5m"
timeout = "15s"
max_output = "64KiB"
format = "{output}%"
icon = "/path/to/pinchos/example/icons/claude.svg"
click = "open https://claude.ai/settings/usage"

[item.codex]
type = "command"
run = "quota-axi --provider codex --json | jq -r '.providers[0].windows[] | select(.label==\"week\") | .percentRemaining'"
interval = "5m"
format = "{output}%"
icon = "/path/to/pinchos/example/icons/codex.svg"
click = "open https://chatgpt.com/codex/settings/usage"
```

This composes [`quota-axi`](https://github.com/douglasjarquin) (a CLI that reports local provider quota windows) with `jq` to pull the weekly window's remaining percentage out of its JSON (each provider labels its 7-day window `"week"`, though the `id` differs by provider), one item per provider, each with its own brand icon.
`quota-axi` is one option here, not a dependency — `run` is any shell command, so this same pattern works for a stock price, a CI status, a battery reading (`pmset -g batt`), or a clock (`date '+%H:%M'`).

The two icon files under [`example/icons/`](example/icons/) are MIT-licensed brand marks vendored from [steipete/CodexBar](https://github.com/steipete/CodexBar) - see [`example/icons/NOTICE.md`](example/icons/NOTICE.md) for attribution. Swap in whatever icon you like for your own items; pinchos has no opinion on where it comes from.

See [`example/pinchos.toml`](example/pinchos.toml) for a full working config with four items (claude, codex, clock, battery).

### Recipes

[`recipes/`](recipes/README.md) is a curated catalog of standalone, copy-pasteable configs for common menu-bar signals — clock, battery, disk/memory/load, VPN/network state, network latency, HTTP health, and optional third-party integrations (`quota-axi`, `gh`, `aws`). It's documentation and example configuration, not a runtime plugin system; see [`recipes/README.md`](recipes/README.md) for the full index and how to copy, validate, diagnose, and run each one.

## Architecture

- `Sources/PinchosCore` — UI-free library: TOML parsing (via TOMLKit), duration and byte-size parsing, `{output}` templating, bounded/sanitized diagnostics previews (`DiagnosticPreviewFormatter`), the config-diff engine, and bounded process-group command execution with concurrent stdout/stderr draining.
- Each command session has a supervisor process as its process-group leader.
  The supervisor remains alive until its descendants have exited or cancellation terminates the group, so every signal is made through the live session owner rather than a reusable numeric process-group ID.
- `Sources/pinchos` — the AppKit executable: one `NSStatusItem` and one per-item scheduled `DispatchSourceTimer` when configured, plus manual refresh actions, declarative per-item menu actions, menu and lifecycle projection of `PinchosCore` runner snapshots, a shared `ShutdownCoordinator` for GUI and CLI lifecycle convergence, and a `ConfigWatcher` (`DispatchSourceFileSystemObject`) for live reload.
- Config file reads and TOML parsing run off the AppKit main actor through `ConfigLoadCoordinator`, which tags each reload with a generation number so a superseded parse — success or failure — is never applied over a newer one, and coalesces reload bursts into a single pending load instead of an unbounded backlog.

### Why TOMLKit

[TOMLKit](https://github.com/LebJe/TOMLKit) is a maintained Swift wrapper around `toml++`, a mature C++17 TOML parser — full spec compliance (escaping, nested tables, arrays, dotted keys) without hand-rolling a parser, which is exactly the kind of correctness-critical, already-solved problem worth depending on rather than reimplementing.

One wrinkle: TOMLKit's underlying store is a `std::map`, so iterating a `TOMLTable` returns keys in **alphabetical**, not declaration, order — a known, currently-unresolved limitation upstream ([marzer/tomlplusplus#62](https://github.com/marzer/tomlplusplus/issues/62)). Since v1's left-to-right item ordering is a hard requirement, `ConfigParser` does a small line-scan over the raw text to record the order `[item.*]` headers and top-level `item.<name>.<key>` dotted-key declarations appear in, then uses TOMLKit purely for spec-compliant parsing and per-item value access. This isn't a second TOML parser — it's a thin, separately-tested pass that only recognizes those two item-declaring forms.

TOMLKit's parsed tree is authoritative for whether an item exists at all: `ConfigParser` cross-checks the line-scanned name set against TOMLKit's parsed `item` table and fails explicitly on any mismatch, rather than silently returning a config with fewer items than the file actually declares. This matters because TOMLKit/toml++ accepts strictly more syntax than the line scanner recognizes (for example, single-line inline-table item declarations); those forms are rejected with a clear configuration error rather than parsed and then dropped.

Everything else in the app has no third-party dependency.

## Manual QA

See `docs/manual-qa/` for the evidence captured for v1: the example config running in the bar, a live-reload edit applied without relaunch, and a deliberately broken config recovering via the `pinchos ⚠︎` item.

## CI

`.github/workflows/ci.yml` runs `swift build`, `swift test`, and `swift build -c release` on a macOS runner for every PR and every push to `main`.
See [`docs/performance.md`](docs/performance.md) for the performance budgets and benchmark profiles behind the claims above, including the deterministic timer/output-budget invariant tests `swift test` enforces and how to run a controlled release-binary measurement locally.

## Out of scope for v1

No additional module types beyond `command`, no nested/JSON-path format placeholders, no preferences UI, no login-item management, no code signing/notarization/distribution pipeline, no Homebrew formula, no multi-bar layout engine. See the project brief for the full list.
