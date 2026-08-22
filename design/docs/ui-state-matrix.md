# Pinchos UI state matrix

Legend: **Bar** = menu-bar presentation · **Menu** = first-level summary zone (below the action zone, above Diagnostics) · **Diag** = Diagnostics submenu additions · **A11y** = VoiceOver label/value/announcement · **Notif** = notification behavior with `notify_on = ["failure","recovery"]` (silent otherwise) · `⚠︎` = U+26A0 U+FE0E text-presentation marker · `~` = stale marker. Markers are proposals (see decision log D3). Every menu also contains the action zone (configured actions, `Refresh Now`) and the global zone (`Open Config`, `Reload Config`, `Quit Pinchos`).

## Command items — current scope

| # | State | Trigger | Runtime state | Bar | Tooltip | Menu summary | Diag | Actions available | Visible | A11y | Notif | Recovery |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Text-only fresh | Successful run, within interval + `stale_after` | fresh | `81%` | template (e.g. "Weekly quota resets Monday") | `81% · updated 2 m ago` (disabled) | state fresh, exact timestamps, duration, exit 0, byte counts | actions, Refresh Now, copies | yes | "claude, 81 percent, fresh" | — | — |
| 2 | Local icon + text | `icon` configured | fresh | 16×16 template + `81%` | same | same | `Icon: ~/.config/pinchos/claude.png` | same | yes | same (icon not announced separately) | — | — |
| 3 | SF Symbol + text (#14) | `symbol` configured | fresh | symbol + `81%` | same | same | `Symbol: chart.bar.fill` | same | yes | same | — | — |
| 4 | Icon-only | `icon_only = true` + `icon` | fresh | icon alone | full title required | `81% · updated 2 m ago` | same | same | yes | full: "claude, 81 percent, fresh" | — | — |
| 5 | Symbol-only (#14) | `icon_only` + `symbol` | fresh | symbol alone | full title | same | same | same | yes | same | — | — |
| 6 | Initial / unavailable | Before first successful result | unavailable | `–` (error_text default) | "claude — waiting for first result" | `Unavailable · no result yet` | state unavailable, last attempt (if any) | Refresh Now, actions | yes | "claude, unavailable" | — | — |
| 7 | Running, no prior value | First run in flight | running | `…` | "claude — running" | `Running… · started 0:02 ago` | state running, attempt timestamp | actions (refresh gated — no overlap) | yes | "claude, running" | — | — |
| 8 | Running, prior value | Refresh in flight after success | running | `81%` (unchanged — no spinner) | "claude — running, showing last value" | `81% · refreshing…` | state running + last success intact | same | yes | "claude, 81 percent, refreshing" | — | — |
| 9 | Fresh | = state 1 | fresh | `81%` | template | `81% · updated 2 m ago` | — | — | yes | — | — | — |
| 10 | Stale | `stale_after` exceeded | stale | `81% ~` | template + "stale since 3:12 PM" | `81% · stale · last success 22 m ago` | stale flag, last attempt vs last success | Refresh Now prominent | yes | "claude, 81 percent, stale" | — | — |
| 11 | Error, replace | Non-zero exit, `on_error = "replace"` | failed | `–` | "claude — failed, exit 1" | **Promoted:** `Failed · exit 1 · 12 m ago` + bounded stderr line + `Copy Full Error` | exit detail, stderr bytes/truncation, previews | Refresh Now, copies | yes | "claude, failed, exit 1" | failure → notify once, cooldown | — |
| 12 | Error, keep last | Non-zero exit, `on_error = "keep_last"` | failed (value retained) | `81% ⚠︎` | "claude — failed, showing last good value" | promoted error line + `Last good: 81% · 2:41 PM` | same | same | yes | "claude, failed, showing last good value 81 percent" | failure | — |
| 13 | Timeout | `timeout` exceeded | timed out | `–` or `81% ⚠︎` per on_error | "claude — timed out after 15 s" | `Timed out after 15 s · 3 m ago` | timeout detail, duration = limit | same | yes | "claude, timed out" | failure | — |
| 14 | Launch failure | Shell/binary cannot start | failed (launch) | per on_error + `⚠︎` | "claude — could not launch" | `Launch failed: /bin/zx not found` | launch error string, exit 127 convention | same | yes | "claude, launch failed" | failure | — |
| 15 | Disabled | `disabled = true` | disabled | *(no status item)* | — | *(annotated: no menu)* | — | — | **no** | — | none | re-enable in config; visible in `pinchos doctor` |
| 16 | Hidden, empty output | `hide_when_empty` + empty stdout | fresh/empty | *(no slot)* | — | — | — | — | **no** | — | none | reappears on non-empty output; diagnosable via doctor + group row |
| 17 | Hidden, on error | `hide_on_error` + failure | failed | *(no slot)* | — | — | — | — | **no** | — | failure notification still fires if opted in | reappears on success |
| 18 | Truncated by `max_length` | Output longer than limit | fresh | `Deploy compl…` | **full untruncated** output (capped) | full-ish preview + `… (truncated)` note | `Output: 812 bytes / 1 line`, `Copy Full Output` | copies | yes | value + "truncated, full output available in menu" | — | — |
| 19 | Invalid icon file | `icon` unreadable/missing | fresh (icon degraded) | text-only (no marker) | normal | normal | `Icon: not readable — ~/pin/x.png` | — | yes | normal | — | doctor warning |
| 20 | Unavailable SF Symbol (#14, U2 rec.) | Symbol absent on this macOS | fresh (icon degraded) | text-only | normal | normal | `Symbol: "sparkles.2" unavailable on this macOS` | — | yes | normal | — | doctor warning |
| 21 | Group | `[group.ai]` | per members | `AI: 81% · 43%` | "AI — claude, codex" | disabled summary row per member health | member submenus carry member diagnostics | member actions in submenus | yes | "AI group, claude 81 percent, codex 43 percent" | per-member | — |
| 22 | Nested group | group member is a group | per members | outer title + summary | — | nested row with its own submenu | — | — | yes | announced as nested group | — | — |
| 23 | Missing config | No usable config file | recovery (setup) | `pinchos` | "pinchos — no configuration" | `No configuration found` + path row | — | Create Example Config, Open Config Directory, Reload Config, Quit | yes | "pinchos, no configuration found" | none | Create Example Config is primary |
| 24 | Malformed config | Parse/validation failure on load or reload | recovery (error) | `pinchos ⚠︎` | "pinchos — configuration error" | `Config error · line 12` + bounded parse error + `Copy Error` | — | Open Config, Open Config Directory, Reload Config, Quit | yes | "pinchos, configuration error, line 12" | none | last good config keeps running if one was loaded |
| 25 | json-v1 neutral (#19) | `state` absent or `"neutral"` | fresh | text from JSON | JSON `tooltip` | normal summary | `Output: json-v1` | static + runtime actions | per `hidden` | normal | — | — |
| 26 | json-v1 warning (#19) | `state: "warning"` | fresh + warning | `2 failing ⚠︎` | JSON tooltip | `Warning · 2 failing · updated 1 m ago` | `State: warning (reported by command)` | same | yes | "…, warning" | none (warning ≠ failure) | — |
| 27 | json-v1 failure (#19) | `state: "failure"` | failed (reported) | per on_error + `⚠︎` | JSON tooltip | promoted `Failure reported · 1 m ago` | `State: failure (reported)` | same | yes | "…, failure reported" | failure transition | — |
| 28 | json-v1 hidden (#19) | `hidden: true` | fresh, hidden | *(no slot)* | — | — | doctor: `hidden by structured output` | — | **no** | — | none | reappears when `hidden: false` |

## Item menu variants (see `Item Menu Prototype.dc.html`)

1 healthy/no actions · 2 healthy/multiple actions · 3 manual interval (`Refresh Now` is the only refresh path; summary says `manual`) · 4 running · 5 first run pending · 6 stale · 7 failure-replace · 8 failure-keep-last · 9 timeout · 10 launch failure · 11 disabled (annotated — no menu exists) · 12 click never run (`Click Action ▸ Never run`) · 13 click running · 14 click failed (promoted line) · 15 per-action diagnostics submenus · 16 truncated stdout+stderr with byte counts + copies · 17 scheduler saturation (`Scheduler: 4/4 active, 2 queued, 1 coalesced` — first level only when saturated, else Diagnostics) · 18 event-triggered item (#20: `Refresh: every 5 m + wake, network` + `Last refresh: 2:41:07 PM (network change)`) · 19 runtime actions (#19, after static actions) · 20 notification-enabled item (#21: Diagnostics row `Notifications: failure, recovery · cooldown 15 m`) · 21 permission denied (#21: `Notifications: permission denied — enable in System Settings`)

## Group menu states (see `Groups + Recovery Prototype.dc.html`)

Healthy members · mixed health (fresh + stale `~` + failed `⚠︎`) · member unavailable (`–`) · hidden member (annotated row `hidden — empty output`, disabled) · disabled member (annotated, disabled) · nested group row · long names/values (middle-truncated, full in submenu) · many members (scrolling native menu, no pagination invention)

## Recovery states

Absent config (`pinchos`) · empty file (`pinchos` — treated as setup, `Create Example Config`) · TOML syntax error with line (`pinchos ⚠︎`) · semantic validation error (`pinchos ⚠︎`, e.g. `group "ai": member "claud" not found`) · broken reload while last good config runs (both: items keep running + `pinchos ⚠︎` present) · open/create failure (`Could not create example config — permission denied` row) · successful recovery (recovery item disappears; items appear; no celebration)

## Notifications (#21)

| Event | Title | Body | Rules |
|---|---|---|---|
| Failure (human-friendly value) | `claude` | `Failed · exit 1 — jq: parse error near line 2` | one bounded stderr line max; no raw dumps |
| Failure (technical) | `deploy-watch` | `Timed out after 15 s` | exact cause, no "something went wrong" |
| Recovery | `claude` | `Recovered · 81%` | fires only on failed→success transition |
| Cooldown | — | — | no repeat while same failure persists; `notify_cooldown` (default proposal 15 m) gates repeated failure notifications |
| Permission denied | — | — | no alert, no nagging: `pinchos doctor` + Diagnostics row carry it |
| Click | — | — | no-op in v1 (no dashboard exists to open) — see decision log |
