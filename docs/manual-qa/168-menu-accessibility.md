# #168 menu accessibility evidence

Tested commit: `e14050a4351ebcfa98af1a45dccca5c829225aa5` on 2026-11-13.

This is the factory pass for current native menus, not a VoiceOver speech sign-off.

## What this commit changed

Status-item buttons, collapsed first-level rows, and recovery items now expose a spoken `accessibilityLabel` that includes the item or recovery name plus `ValueFreshness.spokenDescription`.
The visible `⌛︎`/`⚠︎` markers stay in the title only.
Informational rows keep `action == nil` and `isEnabled == false`.
Unreadable icon files now get the same text-only diagnostic note as unavailable symbols.
Command output in titles is sanitized through `DiagnosticPreviewFormatter.sanitizeVisibleText` before display.

## Automated evidence

`mise run verify` exited 0 in 118.83s: 212 `pinchosTests` and 213 `PinchosCoreTests`, then a release build.
Targeted AppKit property tests live in `Tests/pinchosTests/MenuAccessibilityTests.swift` and the recovery presentation tests.

## Real Mac evidence and limits

A release binary was launched on this host with a sample config covering static, cached, action, combined, separator, failure, long/control-character, missing-icon, and unavailable-symbol surfaces.
Doctor reported the icon fallback failures.
In-process `NSMenuItem` dumps for expanded, collapsed, diagnostics, and recovery menus are under `/tmp/pinchos-168/ax-menus.txt`.

This session could not drive VoiceOver speech, Control-F8/keyboard navigation, screenshots, Light appearance, or Increase Contrast.
The Accessibility API returned `kAXErrorAPIDisabled` (`-25211`) for the live process, System Events timed out, and `screencapture` could not create an image from the display.

Those interactive checks still need a logged-in session with Accessibility already granted.
The full capture and the remaining checklist are in `/tmp/pinchos-168/EVIDENCE.md`.
