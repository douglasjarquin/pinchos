# Pinchos design package

Design artifacts and engineering handoff for **pinchos** — a native macOS menu-bar utility (github.com/douglasjarquin/pinchos). Produced August 2026 against commit-current `main` and open issues #14, #15, #19, #20, #21. No production code was changed.

## Design direction

Pinchos should read as a built-in macOS menu extra: native `NSStatusItem` + `NSMenu`, system typography, semantic colors, template icons, zero idle motion. Hierarchy comes from menu structure, separators, and submenus — not cards, panels, or color. The one significant IA change: the current long flat diagnostic menu becomes a short common path (~6–10 rows) with a `Diagnostics` submenu; failures promote to the first level.

## Canvases (`design/*.dc.html`)

| File | Covers |
|---|---|
| `Menu Bar State Board.dc.html` | All 28 menu-bar item states at realistic scale, light + dark, crowded bar, long/short values, groups, recovery, contrast/inactive notes |
| `Item Menu Prototype.dc.html` | Interactive command-item menu: 20+ scenarios (healthy, running, stale, failures, timeout, disabled, click/action diagnostics, truncation, scheduler pressure, future states), Diagnostics submenu, light/dark |
| `Groups + Recovery Prototype.dc.html` | Group menus (healthy/mixed/nested/hidden/disabled/many members), member submenus, all recovery states (absent, empty, syntax error, semantic error, broken-while-running, recovered) |
| `Future Extensions State Board.dc.html` | Issues #14/#19/#20/#21: SF Symbol variants + fallbacks, json-v1 state mapping, runtime actions, event-trigger diagnostics, failure/recovery notifications, permission denied |
| `Pinchos Icon.dc.html` | Three app-icon directions, selected refinement, 512→16 px, light/dark desktops, Finder + notification contexts, template variant, app icon vs. user status-item icons |

Canvases simulate native menus for review only — production remains AppKit `NSMenu`. They use the system font stack, no network, no external libraries.

## Documentation (`design/docs/`)

- `design-system.md` — principles, typography, spacing, color, icons, motion, copy, accessibility, component inventory + lifecycle rules
- `surface-map.md` — every product surface and how users reach it (there is no window, settings UI, dashboard, or onboarding wizard)
- `ui-state-matrix.md` — trigger → runtime state → presentation/tooltip/menu/diagnostics/actions/visibility/accessibility/notification/recovery, for all current and pending states
- `decision-log.md` — decisions and recommendations, with owner-approval status for unresolved issue questions (U1–U3, #19 precedence, notification click, etc.)
- `handoff.md` — per-change: current behavior, proposed behavior, AppKit primitive, state, accessibility, performance constraint, likely implementation area, scope
