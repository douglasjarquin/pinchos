# Runtime

Output bounds, reload, recovery, and removed syntax. Moved out of the README.

## Runtime safety

All command output is retained in bounded tails with one process-wide memory budget.
Command sessions use one process-wide scheduler and cannot overlap on the same source.
Timeout, reload, removal, quit, SIGTERM, and SIGINT settle owned process groups through the shared lifecycle deadline.
Menu and diagnostics previews sanitize control characters and are bounded independently from retained output.
Command diagnostics remain bounded and available for troubleshooting.

Commands and actions are unsandboxed code executed with the user's permissions.
Review executables, arguments, paths, network destinations, credentials, and write targets before placing them in TOML.

## Command execution policy

Primary sources, dynamic menu values, actions, `pinchos run`, and `pinchos doctor` share one internal policy (`CommandExecutionPolicy`).
The policy is not a public config surface: there are no per-item `shell`, `env`, or `cwd` keys.

- **Shell.** `/bin/sh -c` only. Non-login and non-interactive, so shell startup files are not loaded.
- **PATH.** `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin`. Apple Silicon Homebrew first, then the launchd system directories. Inherited `PATH` is ignored so Finder/`open` and Terminal resolve the same tools.
- **Working directory.** The resolved `HOME` directory, not the process's launch cwd (`/` under Finder/`open`, the current shell directory under Terminal).
- **HOME and inherited environment.** `HOME` comes from the host when set, otherwise `NSHomeDirectory()`. `USER`, `LOGNAME`, `TMPDIR`, locale/`TZ`, and `__CF_USER_TEXT_ENCODING` are copied when present and non-empty. Missing `HOME`/`USER`/`TMPDIR` fall back to the process owner and the system temp directory. `SHELL` is `/bin/sh`.
- **Not inherited.** Arbitrary host variables, including secrets, custom PATH entries, and Terminal-only values such as `SSH_AUTH_SOCK`. Commands that need credentials should read them from files the command already knows about.

This makes supported system and Homebrew tools resolve consistently.
It does not make Finder and Terminal identical arbitrary user environments.

`pinchos doctor` inspects the same PATH and HOME policy without running user commands.
Missing tools are reported as not found on that PATH.
Doctor output does not dump the inherited environment or secret values.

## Live reload and recovery

Valid changes apply incrementally while preserving unchanged source/cache identity.
Added, removed, changed, and reordered items are reconciled under one concurrent lifecycle deadline.
Malformed configuration leaves the last known-good items running and exposes recovery actions for creating, opening, reloading, or quitting.

## Removed development syntax

The 0.1 release is intentionally breaking because the earlier development schema never shipped.
`type`, legacy `action` and `info` tables, groups, item triggers, notifications, structured output, visibility flags, scheduler settings, shell/environment overrides, output bounds, error policies, freshness policies, config mutation, and launchd service commands are rejected.
There are no compatibility aliases or migration writers.
