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

The file is edited live: pinchos watches it with a `DispatchSource` file-system-object source and reapplies your changes — including adding, removing, or reordering items — without a relaunch.

### Schema (v1)

Every item is a `[item.<name>]` table. Items render left-to-right in the order their tables appear in the file.

```toml
[item.<name>]
type = "command"        # required, the only v1 module type
run = "<shell command>" # required, executed via `/bin/sh -c` on its interval
interval = "60s"        # optional, default "60s", minimum "1s". Formats: "30s", "5m", "1h"
timeout = "15s"         # optional, default "15s", minimum "1s". Terminates the command process group when it expires
max_output = "64KiB"    # optional, default "64KiB" per stdout/stderr stream. Formats: "B", "KiB", "MiB"
format = "{output}%"    # optional. {output} is the trimmed last stdout line of `run`. Absent = raw output.
click = "<shell command>" # optional, run (fire-and-forget) on left-click
error_text = "–"   # optional, default "–". Shown when `run` fails, instead of the item disappearing.
icon = "/path/to/icon.svg" # optional, a local image file (SVG/PNG/PDF) rendered as a template icon left of the text
```

- `{output}` is the **only** placeholder. There's no JSON-path or nested-field extraction — pipe your command through `jq` (or anything else) to shape the value before it reaches pinchos.
- `timeout` accepts whole seconds, minutes, or hours and terminates the command's process group after the configured duration.
- Timeout and cancellation terminate the process group with `SIGTERM` followed immediately by `SIGKILL`, so managed descendants cannot outlive an item or the app.
- A command that exits while leaving same-group background work running remains owned by its item until that work exits or the item is removed.
- `max_output` is an independent retained-tail limit for stdout and stderr, so `64KiB` can retain up to 64KiB from each stream while both streams continue draining.
- Retaining the tail keeps the final output line and the most recent stderr diagnostic available even when a command emits more than the configured limit.
- `icon` is a plain filesystem path, not a built-in icon library — pinchos ships with no bundled icon catalog. Point it at any image file you like; it's drawn as a template image (tinted automatically for light/dark menu bars) at 16x16, to the left of the item's text. A missing or unreadable file just falls back to text-only — it never crashes the app.
- A failing command never crashes pinchos and never blanks the item — it renders `error_text`.
- Command runs for a given item never overlap: if the previous run for that item hasn't finished when the next tick fires, the tick is skipped.
- Skipped ticks are counted in the item's right-click diagnostics menu without replacing the last completed result.
- The same timeout and output bounds apply to an optional click command, which is cancelled when its item is removed or Pinchos quits.
- The diagnostics menu reports the last exit code or signal, duration, skipped ticks, per-stream truncation, and the latest bounded stderr line.
- A malformed config keeps the last good config running untouched, and pinchos additionally shows a single `pinchos ⚠︎` item; click it to see the parse error (with line number when available), reload, or quit. Fix the file and it clears automatically on the next successful reload.
- Right-click any item (or the warning item) for **Reload Config** and **Quit** — the app is fully usable without ever touching the config file.

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

## Architecture

- `Sources/PinchosCore` — UI-free library: TOML parsing (via TOMLKit), duration and byte-size parsing, `{output}` templating, the config-diff engine, and bounded process-group command execution with concurrent stdout/stderr draining.
- `Sources/pinchos` — the AppKit executable: one `NSStatusItem` and one per-item `DispatchSourceTimer` per configured item, plus menu and lifecycle projection of `PinchosCore` runner snapshots and a `ConfigWatcher` (`DispatchSourceFileSystemObject`) for live reload.

### Why TOMLKit

[TOMLKit](https://github.com/LebJe/TOMLKit) is a maintained Swift wrapper around `toml++`, a mature C++17 TOML parser — full spec compliance (escaping, nested tables, arrays, dotted keys) without hand-rolling a parser, which is exactly the kind of correctness-critical, already-solved problem worth depending on rather than reimplementing.

One wrinkle: TOMLKit's underlying store is a `std::map`, so iterating a `TOMLTable` returns keys in **alphabetical**, not declaration, order — a known, currently-unresolved limitation upstream ([marzer/tomlplusplus#62](https://github.com/marzer/tomlplusplus/issues/62)). Since v1's left-to-right item ordering is a hard requirement, `ConfigParser` does a small line-scan over the raw text to record the order `[item.*]` headers appear in, then uses TOMLKit purely for spec-compliant parsing and per-item value access. This isn't a second TOML parser — it's a thin, separately-tested pass that only looks for top-level `[item.X]` headers.

Everything else in the app has no third-party dependency.

## Manual QA

See `docs/manual-qa/` for the evidence captured for v1: the example config running in the bar, a live-reload edit applied without relaunch, and a deliberately broken config recovering via the `pinchos ⚠︎` item.

## CI

`.github/workflows/ci.yml` runs `swift build` and `swift test` on a macOS runner for every PR and every push to `main`.

## Out of scope for v1

No additional module types beyond `command`, no nested/JSON-path format placeholders, no preferences UI, no login-item management, no code signing/notarization/distribution pipeline, no Homebrew formula, no multi-bar layout engine. See the project brief for the full list.
