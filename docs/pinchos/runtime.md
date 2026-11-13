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
- **PATH.** `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`. Apple Silicon Homebrew first, then `/usr/local/bin`, then the launchd system directories. Inherited `PATH` is ignored so Finder/`open` and Terminal resolve the same tools.
- **Working directory.** The resolved `HOME` directory, not the process's launch cwd (`/` under Finder/`open`, the current shell directory under Terminal).
- **HOME and inherited environment.** `HOME` comes from the host when set, otherwise `NSHomeDirectory()`. `USER`, `LOGNAME`, `TMPDIR`, locale/`TZ`, and `__CF_USER_TEXT_ENCODING` are copied when present and non-empty. Missing `HOME`/`USER`/`TMPDIR` fall back to the process owner and the system temp directory. `SHELL` is `/bin/sh`.
- **Not inherited.** Arbitrary host variables, including secrets and custom PATH entries. `SSH_AUTH_SOCK` is not inherited; launchd's ssh-agent can set it for GUI apps as well as Terminal, and Pinchos does not pass it through. Commands that need credentials should read them from files the command already knows about.

This makes supported system and Homebrew tools resolve consistently.
It does not make Finder and Terminal identical arbitrary user environments.

`pinchos doctor` inspects the same PATH and HOME policy without running user commands.
It checks primary `run`, submenu `run`, and submenu `action` the same way.
A compound shell expression is `[UNKNOWN]`, not a missing-tool failure.
Unquoted `~/` expands against HOME the way `/bin/sh` does.
Shell builtins such as `export` and `eval` are unknown, not missing.
An unterminated quote or trailing backslash is `[FAIL]`.
Missing tools are reported as not found on that PATH, with a reminder to install onto it or use an absolute path.
Unreadable icon files suggest a readable path or `symbol`.
Doctor labels itself as a CLI inspection so it is not mistaken for a live GUI cache.
It prints the resolved config path and available version/install information.
Doctor output does not dump the inherited environment, credential metadata, or login-item state.

## Refresh Now, retries, and coalescing

Refresh Now requests every distinct value source the selected Pincho uses, including manual submenu rows with no `cache` interval.
It never executes action rows.
Equivalent primary and submenu commands share one source, so one request does not multiply identical executions.

Opening a menu is synchronous and never waits on a refresh.
Fresh values do not refresh on open.
A never-attempted (unavailable) row may start a background refresh immediately.
Stale values, failed refreshes that still have a last-good value, and failed refreshes with no value may request a background retry only after **30 seconds** have elapsed since the last attempt settled (`CommandSource.retryInterval`).
The gate uses completion time, not when the refresh was admitted or started, so a slow command or a long FIFO wait does not make the next menu open retry immediately.
That cadence is fixed; there is no TOML key for it.
Explicit Refresh Now bypasses the delay.
Manual submenu values use the same cadence after an initial failure; success stays manual-only until Refresh Now.

Each source has at most one in-flight refresh.
Additional `refresh()` callers join that execution instead of stacking waiters.
ManagedItem keeps at most one apply-task per menu row (`menuRowRefreshTasks`) and at most one primary refresh task (`pendingRefreshPermitTask`); extra Refresh Now clicks coalesce there.
Reload, removal, and shutdown cancel obsolete work and cannot execute stale actions.
Last-good values, FIFO scheduler admission, process limits, and cancellation stay as they are.

## Freshness and failure presentation

Presentation interprets existing source timestamps.
It does not add a polling loop, a trigger subsystem, or a public freshness key.

Each consumer uses the shared last-success timestamp against its own window: `interval` for the primary value, `cache` for a submenu row.
Manual consumers omit a window and do not age.
Registration order cannot change that: two consumers of one command with 60s and 300s windows, created in either order, still diverge at 90s.

The fixed states are unavailable, fresh, age-stale, queued/refreshing, failed-with-value, and failed-without-value.
Last-good text stays visible while a refresh is queued or running and after a failed command.
Age-stale and scheduler-delayed share the ⌛︎ marker.
VoiceOver says "stale, scheduler delayed" when the value aged out and no later attempt has started.
It says "stale" when the value aged out without that scheduler delay.
A value that has aged out while a refresh is queued or running keeps the ⌛︎ marker and is spoken "stale, refreshing".
A value still inside its window is spoken "refreshing" with no marker.
A failed command uses the warning marker and keeps the last-good value.
There is no separate scheduler-delay glyph.
Diagnostics add `Delay: scheduler` when that delay is why the value aged out.
Option-click diagnostics show last attempt, last success, queued or active refresh, and the last terminal reason for both the primary value and each dynamic menu `run` row.
Those menus read this process's cache snapshots.
They do not run commands merely to inspect them, and `pinchos doctor` does not invent that live cache.
Age, failure, and scheduler delay stay distinguishable on those rows.
Copied summaries stay the existing Copy Full Output/Error actions: previews are bounded and sanitized; copy still uses the retained text.
Initial failure does not invent a success timestamp or value.
The same interpretation is used for the menu-bar title, submenu values, collapsed first-level rows, VoiceOver labels, and diagnostic snapshots (`State`, `Stale`, and `Delay: scheduler` when the scheduler has not attempted since the value aged out).

Scalar age starts at command success in Pinchos.
Upstream observation time is not inferred from Remainder or any other provider.

## Live reload and recovery

Valid changes apply incrementally while preserving unchanged source/cache identity.
Added, removed, changed, and reordered items are reconciled under one concurrent lifecycle deadline.
After a reload commits, a cached menu row whose source is new or changed refreshes once immediately.
A retained cached row with no carried value is requested the same way, so a first attempt cancelled while still queued is not stranded until the cache timer.
A row whose source the registry kept and that already has a settled value does not refresh on commit; it keeps that value and the 30-second retry gate.
A new or changed manual row does not run on commit; it first runs on the next menu open, Refresh Now, or equivalent explicit request.
Malformed configuration leaves the last known-good items running and exposes recovery actions for creating, opening, reloading, or quitting.

## Removed development syntax

The 0.1 release is intentionally breaking because the earlier development schema never shipped.
`type`, legacy `action` and `info` tables, groups, item triggers, notifications, structured output, visibility flags, scheduler settings, shell/environment overrides, output bounds, error policies, freshness policies, config mutation, and launchd service commands are rejected.
There are no compatibility aliases or migration writers.
