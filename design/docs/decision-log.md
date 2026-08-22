# Pinchos design decision log

Status vocabulary: **Implemented** = current repo behavior · **Issue** = existing issue requirement · **Recommendation** = this design's proposal · **Owner approval required** = do not implement silently.

## D1 — Flat diagnostics → Diagnostics submenu
- Implemented: one long flat item menu exposing all diagnostics at the first level.
- Recommendation: first level = configured actions, `Refresh Now`, separator, compact state summary (value + relative freshness; error promoted when unhealthy), `Diagnostics ▸`, separator, `Open Config`, `Reload Config`, `Quit Pinchos` (≈6–10 rows). All existing diagnostics move intact into `Diagnostics ▸` (exact state, last attempt/success, duration, exit/signal/timeout/launch detail, skipped/coalesced, scheduler line, per-stream byte counts + truncation, bounded previews, `Copy Full Output`/`Copy Full Error`), plus `Click Action ▸` and per-action submenus. Nothing is duplicated between summary and Diagnostics: the summary holds value/freshness/error headline; Diagnostics holds exact timestamps and counts.
- Scheduler line promotes to first level only while saturated (queued/coalesced/delayed > 0); otherwise it lives in Diagnostics.
- Status: recommendation; no approval blocker.

## D2 — Global commands inside group-member submenus
- Implemented: every member menu repeats `Open Config` / `Reload Config` / `Quit Pinchos`, so a 4-member group shows them 5×.
- Recommendation: **suppress** the global zone inside member submenus; the group menu carries one global zone. This is a behavioral change and must be stated in release notes.
- Status: recommendation; low risk; owner sign-off with the IA change.

## D3 — Stale and failure markers
- Implemented: a compact stale marker and an error/unavailable warning marker are appended to the title (exact current glyphs live in `ManagedItem` — verify before reuse; recovery title already uses `⚠︎`).
- Recommendation: error/timeout/launch-failure/kept-last-value → trailing ` ⚠︎` (U+26A0 U+FE0E forces text presentation — renders template-monochrome, no emoji). Stale → trailing ` ~`. Running → **no marker**, value retained (no spinner; native indeterminate indicators are banned in the bar). First-run running → `…`. Unavailable/replaced error → `error_text` (default `–`). All markers survive monochrome, inactive, and increased-contrast rendering; VoiceOver speaks the state word instead of the glyph.
- When #14 lands, markers stay textual (no symbol badges) to keep icon-only items one glyph wide.
- Status: recommendation; owner should confirm `~` vs. keeping any current stale glyph.

## D4 — json-v1 state mapping (#19)
- Issue: `state` exists (`"warning"` shown), semantics unspecified.
- Recommendation: allowed values `neutral | warning | failure` (unknown value = malformed). `neutral` → normal presentation. `warning` → ` ⚠︎` suffix + `Warning` headline in summary; **not** a failure: no notification, no on_error policy. `failure` → enters the existing failure pipeline (on_error policy, promoted error line, #21 failure transition), source labeled `reported by command` in Diagnostics.
- Malformed JSON (bad version, unparseable, unknown state): treated as a failed run — bar per `on_error` + `⚠︎`; Diagnostics: `Invalid json-v1 output` + bounded raw preview + `Copy Full Output`. Never rendered raw in the bar.
- Hidden: `hidden: true` behaves like `hide_when_empty` (slot disappears); diagnosable via `pinchos doctor` and annotated rows in containing groups.
- Churn: rapidly changing `text` updates the existing status item in place; tabular digits bound width jitter; menus are built on open so no visible menu churn is possible.
- Evolution: `version` is required; v1 fields are frozen; unknown *extra* fields are ignored (documented), unknown `version` = malformed. Future `json-v2` is a separate opt-in.
- Status: recommendation; **owner approval required** (protocol semantics).

## D5 — Static vs. runtime action ordering (#19)
- Recommendation: static configured `[[item.action]]` entries first (stable muscle memory), then a separator, then runtime `actions` from the latest json-v1 payload, capped at 8. Runtime actions reuse the declarative action model (title + run) — no second execution system.
- Status: recommendation; **owner approval required**.

## D6 — Configured vs. runtime icon precedence (#19 × #14)
- Recommendation: a runtime `icon`/`symbol` in json-v1 output overrides the configured source **while present**; absent field falls back to configured. Deterministic, per-result, no persistence.
- Status: recommendation; **owner approval required**.

## D7 — `symbol` vs `icon` conflict (#14 U1)
- Options: reject config · prefer `symbol` · prefer `icon`.
- Recommendation: **reject** with `item "claude": specify either symbol or icon, not both` (item/key/line context). Smallest strict contract; mirrors existing strict-schema posture (unknown keys already error).
- Status: **owner approval required** (explicitly unresolved in #14).

## D8 — Unavailable SF Symbol at runtime (#14 U2)
- Options: reject config and keep last good · item stays valid, renders text-only with diagnostics.
- Recommendation: **valid config, text-only render**, Diagnostics row `Symbol: "x" unavailable on this macOS`, `pinchos doctor` warning. Rationale: availability varies per machine/OS; a config valid on one Mac must not brick another; parse-time cannot know runtime catalogs.
- Status: **owner approval required**.

## D9 — Icon size contract (#14 U3)
- Options: keep 16×16, no key · add modest size key.
- Recommendation: **keep the existing 16×16 visual target with no size key.** Symbols configured to align with the local-image target. Revisit only with concrete demand.
- Status: **owner approval required**.

## D10 — Event-trigger diagnostic depth (#20)
- Recommendation: triggers are invisible when working. Diagnostics gains two rows: `Refresh: every 5 m + wake, network` (policy summary incl. watched paths in a sub-row per path) and `Last refresh: 2:41:07 PM (network change)` (cause: interval, manual, click, startup, wake, network, file, coalesced). A broken watcher (`Watching: ~/status.json — unavailable`) promotes to the first level only while broken. No trigger dashboard.
- Status: recommendation.

## D11 — Notification behavior (#21)
- Recommendation: transition-only (healthy→failure, failure→recovery), opt-in per item, cooldown default 15 m for repeated distinct failures, zero repeats while the same failure persists. Copy: title = item name; body = exact cause + at most one bounded stderr line (see ui-state-matrix). App icon appears natively; no per-item icon in the notification (identity stays `Pinchos`). Permission denied → surfaced in `pinchos doctor` + a Diagnostics row, never an alert loop.
- Notification click: **no-op in v1** — there is no dashboard destination and programmatically opening an `NSMenu` is unsupported UX. Documented so users don't expect navigation.
- Status: recommendation; click behavior **owner approval required**.

## D12 — Product-name capitalization
- `pinchos` = binary, config file, recovery-item bar title. `Pinchos` = product in menu commands (`Quit Pinchos`), notification identity, Finder name. States lowercase: fresh, stale, running, unavailable, failed, timed out, cancelled, disabled. `Config` in commands; "configuration" in prose.
- Status: recommendation.

## D13 — App-icon selection (#15)
- Three directions explored (see `Pinchos Icon.dc.html`): **A Banderilla** — diagonal skewer through two forms on an ivory field; **B La Barra** — vertical pick pinned into a horizontal bar (menu-bar metaphor); **C Tres Pinchos** — three picks of stepped heights.
- Selected: **C (Tres Pinchos)** — owner pick, superseding the earlier A recommendation. Rationale: three picks of stepped heights are the product story (a row of pinned items); the small-size risk is mitigated by scaling geometry — sticks thicken 2.2 → 3.0 units and heads grow r 3.0 → 3.4 as the canvas shrinks, spacing widened to 7.5 units, so three picks stay distinct at 16 px. No text in the icon. Restrained palette (ivory/charcoal/olive/terracotta) is Finder-only; the template interpretation is solid monochrome. Runtime status-item icons remain user-configured/template and are visually distinct from the app icon.
- Status: **approved by owner** (direction C); production masters to be rendered from the refined geometry in `Pinchos Icon.dc.html` §2.

## D14 — Healthy-path simplification guardrails
- A healthy item's first level never shows: byte counts, exact timestamps, exit codes, scheduler line (unless saturated), stderr previews. A failed item always shows at first level: what failed (exact cause headline), when (relative), one bounded stderr line, and `Copy Full Error`.
- Status: recommendation (the core IA contract).

## Verification notes for implementation
- Exact current marker glyphs, first-run title text, and unavailable-state title must be read from `Sources/pinchos/ManagedItem.swift` before changing them; this log records the design contract, not the current constants.
