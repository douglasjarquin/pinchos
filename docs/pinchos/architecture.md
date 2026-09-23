# Architecture

Modules, tests, and manual QA. Moved out of the README.

- `Sources/PinchosCore` contains TOML parsing, the config diff, bounded command execution, the scheduler, source/cache actors, formatting, and diagnostics.
- `Sources/pinchos` contains AppKit ownership, menu projection, live reload coordination, recovery, signals, and shutdown.
- `Tests/PinchosCoreTests` covers parser, source/cache, scheduler, process, output, and formatting contracts.
- `Tests/pinchosTests` covers AppKit-headless lifecycle, menus, reload, recovery, signals, and CLI behavior.

Manual QA evidence belongs under [`docs/manual-qa`](docs/manual-qa).
The current headless environment cannot grant the one-time macOS Screen Recording and Accessibility permissions required for real screenshots.
