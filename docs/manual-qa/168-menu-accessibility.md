# #168 menu accessibility evidence

Live AX and screenshots on this Mac: 2026-11-13, binary `.build/release/pinchos` at `e0ed634fdbb681a6f46d636ba333f51d6f7c8e98`, Light appearance.
VoiceOver speech was not captured (optional; not a blocker).
System Events still timed out.

## Q2 decisions (accepted)

1. Name and spoken state are combined in a single `accessibilityLabel` (`name, ` plus `ValueFreshness.spokenDescription`). Glyphs stay in the visible title only.
2. Recovery extras speak exactly these three strings: `pinchos, no items configured`, `pinchos, no configuration found`, `pinchos, configuration error`.
3. Diagnostics (Copy Full Output/Error, runtime state, icon notes) are Option-click only. A plain click is the compact menu.
4. Informational rows are native disabled/dimmed `NSMenuItem`s (`action == nil`, `isEnabled == false`).
5. The value text in titles and spoken labels is capped at 60 graphemes before the freshness marker. The name prefix, state suffix, row labels, and recovery parse-error row are not capped.

## Probe (2026-11-13 11:49)

Douglas granted Accessibility for `/opt/homebrew/Caskroom/cursor-cli/2026.11.11-043ef28/dist-package/node` and `/Users/douglasjarquin/.local/share/mise/installs/python/3.14.7/bin/python3.14`.
The `cursor-agent` worker (pid 20604) started Thu Nov 12 10:57:37 2026, before that grant.

One non-prompting check from each binary, copying Finder `AXRole`:

- python3.14: `AXIsProcessTrusted=True`, `AXUIElementCopyAttributeValue` err 0, `AXRole=AXApplication`, `AXTitle=Finder`.
- `/tmp/pinchos-168-probe/a11y-probe-once`: `AXIsProcessTrusted=true`, same Finder role/title, err 0.

Parent chain for both: the leaf binary → `/bin/zsh` → `/opt/homebrew/Caskroom/cursor-cli/2026.11.11-043ef28/dist-package/node` (`cursor-agent` pid 20604) → `/sbin/launchd`.
Screen Recording was already allowed (`CGRequestScreenCaptureAccess=true`, `screencapture` 3840×2160 PNG).

## What the product does now

Status-item extras expose `AXDescription` as name plus `ValueFreshness.spokenDescription`.
The visible `⌛︎`/`⚠︎` markers stay in `AXTitle` only.
Informational rows are `enabled=false`.
Unreadable icon files get the same text-only diagnostic note as unavailable symbols.
`lastTrimmedLine` splits on CR, LF, and CRLF the same way `DiagnosticPreviewFormatter` does, so `printf '42\r\n'` renders as `42`.
Value text in titles and spoken labels runs through `boundedVisibleText` (sanitize, then cap at 60 graphemes) before the freshness marker.

## Automated evidence

`mise run verify` on `e14050a` exited 0: 212 `pinchosTests` and 213 `PinchosCoreTests`, then a release build.
The CRLF / sanitize-then-truncate / spoken-cap follow-up (`508b39b`) exited 0: 216 `pinchosTests`, 220 `PinchosCoreTests`.
The ellipsis-after-cheap-clip follow-up (`e0ed634`) exited 0: 217 `pinchosTests`, 220 `PinchosCoreTests`.
`289c68e` re-ran `mise run verify` and exited 0: 217 `pinchosTests`, 220 `PinchosCoreTests`, then a release build.
Targeted AppKit property tests live in `Tests/pinchosTests/MenuAccessibilityTests.swift`.
The durable spoken-glyph check is `testFailedWithoutValueThenRefreshingSpeaksWithoutGlyphs` (landed in `039b2b3` on this branch).

## Sample config used on this Mac

Release binary `.build/release/pinchos` with `XDG_CONFIG_HOME=/tmp/pinchos-168`.

```toml
[item.clock]
run = "printf '72'"
interval = "1h"
format = "{output}%"
symbol = "checkmark"

[[item.clock.menu]]
label = "Reset"
value = "2026-09-07"

[[item.clock.menu]]
label = "Usage"
run = "printf '81'"
cache = "1h"

[[item.clock.menu]]
label = "Open docs"
action = "true"

[[item.clock.menu]]
label = "Usage and open"
run = "printf '81'"
cache = "1h"
action = "true"

[[item.clock.menu]]
separator = true

[item.fail]
run = "printf 'nope'; exit 1"
interval = "manual"

[[item.fail.menu]]
label = "Retry"
action = "true"

[item.long]
run = "printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx%s' \"$(printf '\\0')Open Config\""
interval = "manual"

[[item.long.menu]]
label = "Controls"
value = "ok\u0000go"

[item.badicon]
run = "printf 'ok'"
interval = "manual"
icon = "/nonexistent/pinchos-168-icon.png"

[item.badsymbol]
run = "printf 'ok'"
interval = "manual"
symbol = "pinchos.definitely.not.a.real.symbol"
```

## Live AX (this session)

Full transcript: [`168/ax-live-2026-11-13.txt`](168/ax-live-2026-11-13.txt).
Pinchos pid 49124, Light appearance.

Expanded extras, `roleDesc=status menu`, `subrole=AXMenuExtra`, `enabled=true`:

- `title=ok` / `desc=badsymbol, ok, fresh`
- `title=ok` / `desc=badicon, ok, fresh`
- `title=` 59 `x` plus `…` / `desc=long,` same truncated value `, fresh`
- `title=– ⚠︎` / `desc=fail, failed` (glyph in title only)
- `title=72%` / `desc=clock, 72%, fresh`

Clock menu, screenshot [`168/clock-menu-light.png`](168/clock-menu-light.png):

- `Reset: 2026-09-07` and `Usage: 81` are `enabled=false`
- `Open docs`, `Usage and open: 81`, `Refresh Now`, `Collapse Pinchos`, `Open Config`, `Reload Config`, `Quit Pinchos` are `enabled=true`
- Separator is an empty `enabled=false` menu item

Fail extra menu: `Retry` is `enabled=true`; Refresh/Collapse/Open/Reload/Quit stay enabled.

AXPress on `Collapse Pinchos` returned 0.
The bar dropped from five extras to one checkmark `72%` extra ([`168/collapsed-extra-light.png`](168/collapsed-extra-light.png)).
The AX tree then reported empty `AXChildren` / `AXMenuBar=NoValue`, so collapsed submenu rows were not re-read.

Missing config (`XDG_CONFIG_HOME=/tmp/pinchos-168-missing`), screenshot [`168/missing-config-menu-light.png`](168/missing-config-menu-light.png):

- Extra `title=pinchos` / `desc=pinchos, no configuration found`
- `Create Example Config`, `Open Config`, `Open Config Directory`, `Reload`, `Quit` all `enabled=true`

Malformed config (`XDG_CONFIG_HOME=/tmp/pinchos-168-bad`), screenshot [`168/malformed-config-menu-light.png`](168/malformed-config-menu-light.png):

- Extra `title=pinchos ⚠︎` / `desc=pinchos, configuration error`
- Parse-error line `enabled=false`
- `Open Config`, `Open Config Directory`, `Reload`, `Quit` `enabled=true`

## Earlier in-process dump (e14050a)

In-process `NSMenuItem` dump at `e14050a` (not VoiceOver).
Effective appearance then: `NSAppearanceNameDarkAqua`.

- Informational rows: `enabled=false`, `action=nil`.
- Action rows and global controls: `enabled=true`, target `StatusItemController`.
- Recovery parse error spoke `pinchos, configuration error`; missing config spoke `pinchos, no configuration found`.
- That dump was not a live AX read.

## What was not verified in this session

- VoiceOver speech was not captured. That is optional and does not block #168.
- `osascript` System Events timed out (`-1712`) listing pinchos extras.
- CGEvent Control-F8 moved focus into 1Password's Help menu, not the status extras.
- Escape dismissed that Help menu.
- Arrow/Return/Escape were not proven on Pinchos extras via the keyboard.
- Option-click diagnostics were not invoked from a real menu-bar click. Tests cover Option-click via `makeLifecycleMenu(revealsDiagnostics: true)` and the shipped plain-click path via `makeLifecycleMenuImmediately`.
- Increase Contrast was not switched.
- Dark appearance was not re-checked in this live session (only Light).
- Collapsed submenu AX rows were not captured after the extra count dropped to one.

## Manual checklist

Launch `.build/release/pinchos` with the sample config above.

### Keyboard, expanded

1. Control-F8 until a Pinchos extra is focused. Not done (Control-F8 hit 1Password Help).
2. Space or Return opens the compact menu. Menu opened via AXPress, not keyboard.
3. Down/up arrows reach every informational and action row. Not driven.
4. Return on an informational row does nothing. Not driven.
5. Return on Open docs / Usage and open / Refresh Now invokes the action. Not driven.
6. Escape dismisses the menu. Escape was sent only to dismiss 1Password Help.
7. Option-open Copy Full Output / Copy Full Error. Not done.

### Keyboard, collapsed

1. Return on Collapse Pinchos. Done via AXPress; extras collapsed to one `72%` extra.
2. Confirm extras collapse to one Pinchos extra. Done (screenshot).
3. Open that extra, right-arrow into a per-item submenu. AX tree empty after collapse; not done.
4. Confirm Expand / Reload / Quit sit in the collapsed root. Not re-read.
5. Return on Expand Pinchos. Not done.

### Keyboard, recovery

1. Missing config extra and menu captured via AX and screenshot.
2. Malformed config error line is not an action (`enabled=false`); Open/Reload/Quit stay enabled.
3. Escape dismisses the recovery menu. Not driven from the keyboard.

### VoiceOver

Speech not captured (optional, not a blocker).
The AXDescription values above are the labels VoiceOver is expected to read.
Speech was not confirmed.

### Appearance

1. Dark: in-process dump at `e14050a` only.
2. Light: this live session.
3. Increase Contrast: not switched.
