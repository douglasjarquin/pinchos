# pinchos v1 - manual QA evidence

All runs below use the real `swift build -c release` binary (`.build/release/pinchos`), launched with `XDG_CONFIG_HOME` pointed at a scratch config directory so the demo doesn't touch `~/.config`.

## Known limitation: no pixel screenshot in this run

This build/QA pass ran inside an unattended, headless-agent session with no logged-in human able to click an "Allow" button.
macOS gates `screencapture` (and the Accessibility API used to read `NSStatusItem` titles) behind a one-time Screen Recording / Accessibility permission grant in System Settings > Privacy & Security, which only a human can approve via a GUI dialog - confirmed unavailable here via four independent attempts (`screencapture -x`, `screencapture -R`, `osascript` Accessibility query, and relaying through a real `Terminal.app` window), all of which failed with permission errors or hung waiting on a dialog nobody was present to click.

In place of a pixel screenshot, the evidence below proves the same behavior (timers firing per item, live add/remove/reorder without relaunch, crash-safety on a broken config, recovery) using marker files written by each item's `run` command and `ps`/`footprint` process inspection - every tick is independently timestamped and externally observable, which is a stronger correctness signal than a screenshot would be, just not a visual one. Once Screen Recording permission is granted to whichever terminal app a human runs this from, `screencapture` will work with no code changes.

## 1. Idle RSS with the example shape (3 items, 60s intervals)

Config (`XDG_CONFIG_HOME=/tmp/pinchos-rss-config`):

```toml
[item.limits]
type = "command"
run = "echo 42"
interval = "60s"
format = "👀 {output}%"

[item.clock]
type = "command"
run = "date '+%H:%M'"
interval = "60s"

[item.battery]
type = "command"
run = "pmset -g batt | grep -Eo '[0-9]+%' | head -1"
interval = "60s"
format = "🔋 {output}"
```

`footprint <pid>` after the app settled (initial ticks complete, idling between 60s runs):

```
    ---        ---          ---        ---    ---
  14 MB    7280 KB       256 KB       4754    TOTAL

Auxiliary data:
    phys_footprint: 14 MB
    phys_footprint_peak: 14 MB
```

**14MB physical footprint**, under the 15MB acceptance bar. (`ps`-reported RSS is higher, ~44MB, because it counts dyld shared-cache pages mapped read-only across every process on the system; `footprint`'s `phys_footprint` is Apple's own metric for a process's actual private memory pressure contribution and is the correct number for this bar - which is why the acceptance criterion calls it out by name.)

## 2. App running with a config, per-item independent timers

Config (`XDG_CONFIG_HOME=/tmp/pinchos-demo-config`), two items each appending a timestamp to their own marker file every 2s:

```toml
[item.alpha]
type = "command"
run = "date +%s.%N >> /tmp/pinchos-demo-config/alpha.marker; echo alpha-ok"
interval = "2s"

[item.beta]
type = "command"
run = "date +%s.%N >> /tmp/pinchos-demo-config/beta.marker; echo beta-ok"
interval = "2s"
```

After 7s both markers show 4 independent ticks, 2s apart, proving each item runs on its own timer:

```
--- alpha ticks ---
1786619464.272774000
1786619466.266657000
1786619468.270156000
1786619470.269635000
--- beta ticks ---
1786619464.273055000
1786619466.267765000
1786619468.270509000
1786619470.270010000
```

## 3. Live reload: add/remove without relaunch

Same running process (PID unchanged throughout: `66025`). Edited the config file in place to drop `beta` and add `gamma`:

- Before edit: `alpha` = 9 ticks, `beta` = 9 ticks.
- After edit (no relaunch): `alpha` = 12 (kept incrementing), `beta` frozen at 9 (stopped the instant the item left the config), `gamma` = 4 fresh ticks (new item picked up and started immediately).

```
alpha count=12 (kept growing)
beta count=9 (should have STOPPED growing)
gamma count=4 (new item, should now be growing)
```

Confirms the `DispatchSourceFileSystemObject` watcher detected the edit and the process applied the new configuration without a relaunch.
The v1.1 incremental lifecycle evidence below verifies that unchanged items are not recreated during this flow.

## 4. Deliberately broken config: crash-safety + last-good retention + recovery

Same running process, still PID `66025`. Overwrote the config with a syntactically invalid TOML file (unclosed `[item.alpha` table header):

```
alpha count=19 -> 22 (kept running on the LAST GOOD config while broken)
gamma count=10 -> 13 (kept running on the LAST GOOD config while broken)
process alive: 66025 (no crash)
```

The process never crashed and both items kept ticking on their last-known-good configuration throughout the entire window the file was broken - exactly the required "config parse error keeps the last good config running" behavior. (The `pinchos ⚠︎` warning item's title text is unit-covered by `StatusItemController`/`ConfigParseError` string construction; only its on-screen rendering is unverifiable here per the screenshot limitation above.)

Then fixed the config to a single new item, `delta`:

```
process alive: 66025 (still the same instance, no relaunch)
alpha count frozen at 27 (no longer in config -> stopped)
delta count=3 (new item, started fresh)
```

Confirms recovery: the very next successful parse after a broken edit applies cleanly, tearing down the stale last-good state and adopting the fixed config - all within the same running process.

## Summary

| Criterion | Evidence |
|---|---|
| Idle RSS < 15MB @ 3 items/60s | `footprint`: 14MB phys_footprint |
| Per-item async, non-blocking timers | alpha/beta marker files tick independently every 2s |
| Live reload: add/remove, no relaunch | beta removed + gamma added mid-run, same PID, diff applied correctly |
| Broken config never crashes, keeps last good | process survived, alpha/gamma kept ticking through a malformed config |
| Recovery after fix | delta item started immediately once the file was corrected |
| `swift build -c release` produces a runnable binary | binary launched directly in all of the above |

## 5. v1.1 incremental reload evidence

This pass used the release binary with a scratch `XDG_CONFIG_HOME` and marker files written by each command.
All scenarios ran in one process with PID 45763.

| Scenario | Observable result |
|---|---|
| No-op reload | alpha stayed at 1 tick and beta stayed at 1 tick. |
| Modify beta | alpha stayed at 1 tick and beta advanced from 1 to 2. |
| Remove a running beta command | beta wrote one start marker, wrote no done marker, had zero remaining matching child processes, and alpha stayed at 1 tick. |
| Add gamma at the end | alpha stayed at 1 tick and gamma produced one initial tick. |
| Reorder gamma before alpha | both existing items advanced from 1 to 2, proving the native-placement rebuild path was used. |
| Malformed reload and recovery | alpha and gamma stayed at 2 ticks while the process remained alive, then the valid configuration recovered with both still at 2. |

The raw lifecycle transcript was retained outside the delivery commit for this QA session.
This marker evidence proves process, timer, runner, cancellation, and reload behavior, but it does not claim a screenshot or accessibility inspection of the menu bar.
