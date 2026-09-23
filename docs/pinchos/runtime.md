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

## Live reload and recovery

Valid changes apply incrementally while preserving unchanged source/cache identity.
Added, removed, changed, and reordered items are reconciled under one concurrent lifecycle deadline.
Malformed configuration leaves the last known-good items running and exposes recovery actions for creating, opening, reloading, or quitting.

## Removed development syntax

The 0.1 release is intentionally breaking because the earlier development schema never shipped.
`type`, legacy `action` and `info` tables, groups, item triggers, notifications, structured output, visibility flags, scheduler settings, shell/environment overrides, output bounds, error policies, freshness policies, config mutation, and launchd service commands are rejected.
There are no compatibility aliases or migration writers.
