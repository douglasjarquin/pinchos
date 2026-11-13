# #168 menu accessibility evidence

This is the factory pass for current native menus.
It is not a VoiceOver speech sign-off.

Live AppKit dump and release-binary launch: `e14050a4351ebcfa98af1a45dccca5c829225aa5` on 2026-11-13.
CRLF splitting, sanitize-then-truncate, and spoken-value caps: `508b39b7aa9b62edbd5f34af9be1ab48c09ca2bb`.
Failed-without-value then refreshing no longer speaks `⚠︎`/`⌛︎` from the previous title: `039b2b3096f2ceeb4477d12d1300ed1e6a51a476`.
`#168` stays parked until a human runs the checklist below with Accessibility granted.

## What the product does now

Status-item buttons, collapsed first-level rows, and recovery items expose a spoken `accessibilityLabel` that includes the item or recovery name plus `ValueFreshness.spokenDescription`.
The visible `⌛︎`/`⚠︎` markers stay in the title only.
Informational rows keep `action == nil` and `isEnabled == false`.
Unreadable icon files get the same text-only diagnostic note as unavailable symbols.
`lastTrimmedLine` splits on CR, LF, and CRLF the same way `DiagnosticPreviewFormatter` does, so `printf '42\r\n'` renders as `42`.
Titles and spoken values run through `boundedVisibleText` (sanitize, then cap at 60 graphemes).

## Automated evidence

`mise run verify` on `e14050a` exited 0 in 118.83s: 212 `pinchosTests` and 213 `PinchosCoreTests`, then a release build.
The CRLF / sanitize-then-truncate / spoken-cap follow-up (`508b39b7aa9b62edbd5f34af9be1ab48c09ca2bb`) re-ran `mise run verify` on this Mac and exited 0: 216 `pinchosTests`, 220 `PinchosCoreTests`, then a release build.
Targeted AppKit property tests live in `Tests/pinchosTests/MenuAccessibilityTests.swift` and the recovery presentation tests.
Follow-up tests cover `42\r\n` rendering as `42`, last-line selection for multi-line CRLF, and bounded spoken labels for long values.

## Sample config used on this Mac

Release binary `.build/release/pinchos` with `XDG_CONFIG_HOME=/tmp/pinchos-168`.
PID 60372 opened this config (`phys_footprint` 16 MB) and was stopped after capture.

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

`pinchos doctor` against that config reported the missing icon file and unavailable symbol.
A missing-config `XDG_CONFIG_HOME` reported `config: missing; run 'pinchos init'`.
A malformed file reported a parse error at line 1.

## AppKit / NSMenuItem dump summary

In-process dump of real `NSMenuItem` and status-item button attributes at `e14050a` (full text was under `/tmp/pinchos-168/ax-menus.txt`).
Effective appearance while dumping: `NSAppearanceNameDarkAqua`.

- Informational rows (`Reset`, `Usage`, diagnostics, icon fallback, recovery error text): `enabled=false`, `action=nil`.
- Action rows, combined value/action rows, Refresh Now, Collapse/Expand, Open Config, Reload Config, Quit, and Copy: `enabled=true`, target `StatusItemController`.
- Stale/failed titles still show `⌛︎`/`⚠︎`. At `e14050a` the dumped `axLabel` spoke the state in words and did not contain those glyphs. That dump was not re-run at `508b39b`/`d3f91d65`; those commits spoke `baseTitle` (including a leftover `⚠︎` while refreshing with no last-good value). The follow-up on this branch restores spoken text from `lastSuccessfulTitle` so that path cannot speak the glyph. That restore is covered by `testFailedWithoutValueThenRefreshingSpeaksWithoutGlyphs`, not by a new live AX dump.
- Control characters became Control Pictures (`␀`, `␊`) in title and label.
- Recovery parse error spoke `pinchos, configuration error`; missing config spoke `pinchos, no configuration found`.
- Live status-item button: title `72`, `axLabel` `clock, 72, fresh`, template symbol image present.
- Collapsed first-level rows with submenus are enabled with AppKit's native `submenuAction:` so keyboard/VoiceOver can open the submenu.

## What was not verified

This session had a WindowServer and a console login, but it was not an interactive GUI agent.

- `screencapture` failed with `could not create image from display`.
- Live-process AX returned `kAXErrorAPIDisabled` (`-25211`).
- System Events timed out (`-1712`).
- Control-F8, arrows, Return, Escape, and submenu focus were not driven.
- VoiceOver was not enabled or spoken.
- Light appearance was not switched.
- Increase Contrast was unset in `com.apple.universalaccess`.
- Option-click diagnostics were dumped in-process (`revealsDiagnostics: true`) but not invoked from a real menu-bar click.

Do not treat `e14050a` or this follow-up as VoiceOver speech sign-off or keyboard-navigation sign-off.

## Manual checklist (logged-in session, Accessibility already granted)

Launch `.build/release/pinchos` with the sample config above (`XDG_CONFIG_HOME` pointing at a scratch directory that contains `pinchos/pinchos.toml`).
Do not claim a row done unless you performed it.

### Keyboard, expanded

1. Control-F8 (or the current menu-extras focus chord) until a Pinchos extra is focused.
2. Space or Return opens the compact menu.
3. Down/up arrows reach every informational row (Reset, Usage, separator) and every action (Open docs, Usage and open, Refresh Now, Collapse Pinchos, Open Config, Reload Config, Quit Pinchos).
4. Return on an informational row does nothing.
5. Return on Open docs / Usage and open / Refresh Now invokes the action.
6. Escape dismisses the menu.
7. Option-open the same extra and confirm Copy Full Output / Copy Full Error are reachable and Return copies.

### Keyboard, collapsed

1. From an expanded menu, Return on Collapse Pinchos.
2. Confirm extras collapse to one Pinchos extra.
3. Open that extra, right-arrow (or Return) into a per-item submenu, left-arrow or Escape returns to the collapsed root.
4. Confirm Expand Pinchos, Reload Config, and Quit Pinchos are in the collapsed root, not repeated inside every submenu.
5. Return on Expand Pinchos restores per-item extras.

### Keyboard, recovery

1. Point `XDG_CONFIG_HOME` at a missing config directory, relaunch, open the `pinchos` extra, and reach Create Example Config, Open Config, Reload, and Quit.
2. Replace the file with invalid TOML, reload, and confirm the error line is not an action and that Open Config / Reload / Quit still work.
3. Escape dismisses the recovery menu.

### VoiceOver

1. Enable VoiceOver.
2. Move the VoiceOver cursor to each Pinchos extra in expanded mode.
3. Confirm the extra announces name, value, and state in words (`clock, 72, fresh`), not only `⌛︎` or `⚠︎`.
4. Walk the compact menu: informational rows are readable and not offered as buttons; actions are offered as buttons.
5. Repeat on a stale item and a failed item.
6. Repeat in collapsed mode, including submenu entry/exit.
7. Repeat on missing-config and malformed-config recovery extras (`pinchos, no configuration found` / `pinchos, configuration error`).
8. Option-open diagnostics and confirm Copy actions are announced as actions.

### Appearance

1. Repeat the keyboard extra-focus and one VoiceOver extra announcement in Dark (already observed as `NSAppearanceNameDarkAqua` during the dump).
2. Switch to Light and repeat extra-focus plus one announcement.
3. Enable Increase Contrast and repeat extra-focus plus one announcement.
4. Restore the previous appearance when done.
