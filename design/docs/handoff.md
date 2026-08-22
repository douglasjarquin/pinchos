# Pinchos engineering handoff

For an AppKit engineer. Each change: current → proposed, primitive, state, accessibility, performance constraint, likely area, scope. **Do not implement owner-approval items (marked ⏳) without sign-off — see decision-log.md.**

Likely implementation areas referenced below:
`ManagedItem` = `Sources/pinchos/ManagedItem.swift` · `ManagedGroupItem` = `Sources/pinchos/ManagedGroupItem.swift` · `Controller` = `Sources/pinchos/StatusItemController.swift` · `ItemConfig` = `Sources/PinchosCore/ItemConfig.swift` · `Recovery` = `Sources/PinchosCore/RecoveryState.swift` · `Parser` = `Sources/PinchosCore/ConfigParser.swift` · `CLI` = `Sources/pinchos/PinchosCLI.swift`

## H1 — Restructure the item menu (current scope, D1)
- Current: single flat `NSMenu` listing actions, refresh, and every diagnostic row.
- Proposed: zones — [configured actions] · `Refresh Now` (omit when a `refresh = true` action exists) · separator · summary rows (disabled; value + relative freshness; when unhealthy: promoted error headline + one bounded stderr line + `Copy Full Error`) · `Diagnostics ▸` · optional `Click Action ▸` / per-action `▸` submenus · separator · scheduler line **only while saturated** · `Open Config` · `Reload Config` · `Quit Pinchos`.
- Primitive: `NSMenu` + `NSMenuItem.submenu`; build in `menuNeedsUpdate`/`NSMenuDelegate` on open.
- State: reads existing runtime record (state, timestamps, exit detail, counters, previews) — no new state machine.
- Accessibility: summary rows get `accessibilityLabel` mirroring their text; truncated previews get `accessibilityHelp` pointing to the Copy command.
- Performance: submenus constructed lazily on open, released on close; no retained view hierarchy; previews built from already-bounded buffers.
- Area: `ManagedItem` (menu construction), `Controller` (shared global zone). Scope: current.

## H2 — Suppress global commands in group-member submenus (D2 ⏳)
- Current: member submenus repeat Open/Reload/Quit.
- Proposed: member submenu = member's menu minus the global zone; group menu carries one global zone. Document as behavioral change.
- Primitive: parameterized menu builder (`includeGlobalZone: Bool`).
- Area: `ManagedItem` + `ManagedGroupItem`. Scope: current.

## H3 — Marker unification (D3, partially ⏳)
- Current: stale + warning suffix markers exist (verify exact glyphs in `ManagedItem` title application).
- Proposed: ` ⚠︎` (U+26A0 U+FE0E) for failed/timeout/launch/kept-last; ` ~` for stale; `…` first-run running; `error_text` for replaced/unavailable. Tabular figures for numeric-looking values via monospacedDigitSystemFont only when value parses numeric-ish.
- Accessibility: `accessibilityValue` = value + state word ("81 percent, stale") — glyphs never announced.
- Performance: pure string/attributed-title computation at value-apply time; no timers.
- Area: `ManagedItem`. Scope: current.

## H4 — Tooltip guidance for click semantics (current scope)
- Current: left-click behavior (click command / refresh_on_click / nothing) is invisible.
- Proposed: append one terse line to the tooltip: `Click: open usage` / `Click: refresh` (nothing when unconfigured); right-click is never explained (platform convention). Accessibility custom action mirrors the click command.
- Area: `ManagedItem` (tooltip assembly). Scope: current.

## H5 — Recovery menu polish (current scope)
- Current: recovery item exists (`pinchos` / `pinchos ⚠︎`) with create/open/reload/quit actions.
- Proposed IA: disabled headline (`No configuration found` / `Config error · line 12`) · disabled path or bounded error preview row · `Copy Error` (malformed only) · separator · primary command (`Create Example Config` | `Open Config`) · `Open Config Directory` · `Reload Config` · separator · `Quit Pinchos`. When last good config still runs, add disabled row `Last good config still running`.
- Primitive: `NSMenu` on the recovery `NSStatusItem`; error preview uses the existing bounded-preview formatter.
- Area: `Recovery` (state exposure), `Controller` (menu). Scope: current.

## H6 — SF Symbols (#14, D7/D8/D9 ⏳)
- Current: `icon` file path only; `symbol` key ignored by parser.
- Proposed: parse+validate `symbol` (non-empty string; both-keys per U1 decision); render via `NSImage(systemSymbolName:accessibilityDescription:)`, aligned to the 16×16 target (U3: no size key); unavailable symbol per U2 (text-only + Diagnostics row + doctor warning); icon-source changes ride the in-place update path (part of `ItemConfig` equality, no rebuild).
- Accessibility: `accessibilityDescription` on the symbol image = item name; icon-only announces name+value+state.
- Area: `ItemConfig`, `Parser`, `ManagedItem.applyIcon()`, `Controller` (diff), `CLI` (doctor). Scope: #14.

## H7 — json-v1 (#19, D4/D5/D6 ⏳)
- Proposed mapping: `text`→title (existing pipeline incl. max_length/format questions documented in issue), `tooltip`→toolTip, `state`→marker/summary/failure pipeline per D4, `hidden`→existing hide path, `icon`/`symbol`→per-result override (D6), `actions`→runtime menu zone after static actions, cap 8 (D5).
- Malformed: failed-run treatment; Diagnostics `Invalid json-v1 output` + bounded raw preview + Copy Full Output.
- Performance: parse once per run inside existing output bounds; runtime actions stored as value objects; menu built on open.
- Area: `PinchosCore` (protocol decode), `ManagedItem` (apply), `ItemConfig` (`output` key). Scope: #19.

## H8 — Event-trigger diagnostics (#20, D10)
- Proposed: Diagnostics rows `Refresh: every 5 m + wake, network` (+ one row per watched path) and `Last refresh: 2:41:07 PM (network change)`; record last-cause enum (interval, manual, click, startup, wake, network, file, coalesced); broken watcher promotes to first level while broken (`Watching: ~/status.json — unavailable ⚠︎`).
- Performance: cause is a stored enum; watcher rows read watcher state on menu open only.
- Area: scheduler/runner + `ManagedItem` (rows). Scope: #20.

## H9 — Notifications (#21, D11, click ⏳)
- Proposed: `UNUserNotificationCenter`, transition-only, cooldown timestamps (no timers), copy per ui-state-matrix; identity = `Pinchos.app` icon (needs #15); permission denied → doctor + Diagnostics row; click = no-op v1.
- Area: new small notifier behind an abstraction; `ManagedItem` transition hook. Scope: #21 (identity depends on #15).

## H10 — App identity (#15, D13 ✓)
- Deliverables from design: `Pinchos Icon.dc.html` selected direction (Tres Pinchos, owner-approved) with 1024→16 masters, template/monochrome interpretation, Finder/notification contexts. Bundle: `LSUIElement` accessory (no Dock), Finder name `Pinchos`.
- Area: packaging (new), no runtime UI change. Scope: #15.

## Constraint checklist for every change
- No `NSPopover`, no custom windows/panels, no SwiftUI dashboards, no webviews, no settings UI.
- No timers/observers owned by presentation; menus lazy-open/release; previews always bounded; copy commands always complete.
- Status never color-only; template rendering everywhere in the bar; system colors only.
- Arbitrary user content: Unicode-safe, control-char sanitized (existing formatter), grapheme-aware truncation with explicit markers.
- The healthy path must stay ≤10 first-level rows; failures must be explained at first level.

## Answers to the design-review questions
1. Built-in feel: yes — every surface is a stock primitive with system metrics. 2. Simpler healthy path: 6–10 rows is the floor without hiding actions. 3. Terminal-free diagnosis: yes — promoted error + Diagnostics + Copy commands. 4. Diagnostics reachable, not dominant: one submenu level. 5. Idle work: none — menus lazy, markers are strings, cooldowns are timestamps. 6. Settings app: none introduced. 7. json-v1 stays a state protocol, not a UI language (D4 caps semantics). 8. Groups remain native hierarchical menus. 9. Icon-only a11y labels specified (name+value+state). 10. Stale/warn/failure legible without color (`~`, `⚠︎`, words). 11. Icon legible small (single diagonal stroke + two counters; 16 px pass in canvas). 12. Arbitrary content honored (bounded previews, copies, Unicode rules). 13. Open issues incorporated; unresolved decisions marked ⏳, never assumed. 14. Every component maps to an existing Pinchos behavior; nothing speculative was added.
