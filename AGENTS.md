# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- Build: `swift build` / `swift build -c release`. Test: `swift test`. No Xcode project - pure SwiftPM.
- `Sources/PinchosCore` is UI-free (TOML parsing, duration parsing, `{output}` templating, config-diff engine) and is the only target covered by `swift test`. `Sources/pinchos` is the AppKit executable and has no tests - it's a thin wiring layer over PinchosCore.
- TOMLKit's `TOMLTable` iterates keys alphabetically (backed by `std::map` in the vendored `toml++`), not in file declaration order - see `ConfigParser.declaredItemOrder`, which line-scans for `[item.*]` headers separately from TOMLKit's actual parse/validation. If item ordering ever seems wrong after a TOMLKit upgrade, this is the first place to check.
- Measure idle memory with `footprint <pid>` (`phys_footprint` line), not `ps`'s RSS column - `ps` counts dyld shared-cache pages mapped read-only across every process on the system, inflating a small Swift/AppKit binary's reported RSS by ~3x over its actual physical footprint.
- Config resolution: `$XDG_CONFIG_HOME/pinchos/pinchos.toml` if that env var is set and non-empty, else `~/.config/pinchos/pinchos.toml`. See `Sources/pinchos/ConfigLocation.swift`.
- Manual QA evidence lives in `docs/manual-qa/`. The v1 pass used marker-file timestamps instead of screenshots because this environment has no human available to grant the one-time Screen Recording/Accessibility permission `screencapture`/Accessibility APIs require - if a future session runs with a real logged-in GUI session and that permission already granted, prefer real screenshots.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
