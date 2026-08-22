# Pinchos design system

A deliberately small system for a menu-bar utility whose UI is mostly native `NSMenu`. Nothing here introduces a component framework; it constrains how native primitives are used.

## Principles

1. **Native before custom.** `NSStatusItem`, `NSMenu`, `NSMenuItem`, native tooltips, `UNUserNotificationCenter`, standard alerts only when unavoidable. A custom view requires a written case covering memory, lifecycle, accessibility, and idle cost.
2. **Quiet when healthy.** A healthy item is a value in the menu bar and nothing else. No badges, no motion, no color.
3. **Failure must remain discoverable.** Every failure is visible as a text marker in the bar and explained at the first menu level.
4. **Common actions before diagnostics.** Configured actions and Refresh Now come first; byte counts live one level down.
5. **State never depends on color alone.** Template rendering is monochrome; markers are textual; VoiceOver announces state words.
6. **User output is untrusted and size-bounded.** Arbitrary Unicode, control characters, multi-line, multi-megabyte — always sanitized, truncated with an explicit marker, and fully recoverable via Copy commands.
7. **No idle visual work.** No timers, animation, or observers owned by presentation. Menus are built when opened, released when closed.
8. **Configuration remains declarative.** No settings UI of any kind. Recovery happens inside the status item.
9. **Preserve macOS conventions.** System menu metrics, title case for commands, standard separators, `Quit Pinchos` last.
10. **Every added visual element must justify its runtime and cognitive cost.** Default answer is no.

## Typography

Apple system typography only. No custom fonts, no web fonts.

| Role | Spec |
|---|---|
| Menu-bar status title | System 13 pt regular (NSStatusItem default). Monospaced **digits** (tabular figures) only when the value is numeric-looking and refresh would otherwise cause width jitter. Never full monospace for command output. |
| Standard menu action | System 13 pt regular, native title case (`Refresh Now`, `Open Config`) |
| Disabled summary row | System 13 pt regular, disabled (system gray). Value portion may use tabular digits. |
| Diagnostic label/value | System 13 pt regular, disabled rows in the Diagnostics submenu; `Label: value` form |
| Error/warning summary | System 13 pt regular, disabled row; leading `⚠︎` text marker; never bold, never red-only |
| Canvas annotations (design files only) | SF Mono 10–12 px — never appears in the product |

## Spacing and sizing

Use AppKit defaults; document only what implementation needs.

- Status-item icon target: **16×16 pt** template image (existing contract; unchanged by #14 — see decision U3)
- Icon→text gap inside a status item: system default (~4–5 pt); never hand-tuned
- Menu width: natural NSMenu sizing; diagnostic previews bounded so menus stay ≤ ~360 pt
- First-level density: **6–10 rows** for a healthy item (actions + refresh + summary + Diagnostics + 3 global commands); hard ceiling 14 before content must move into a submenu
- Submenu required when: >2 rows of same-topic detail (Diagnostics, Click Action, per-action), or repeated structures (group members)
- Separators: standard `NSMenuItem.separator()` between action zone / state zone / global zone — exactly the zones, never decorative

## Color

Runtime UI uses semantic system colors and template rendering only. No hard-coded black/white/brand colors in status items or menus.

- **Light/dark appearance:** template images and `labelColor`-family colors adapt automatically; nothing to design per-appearance
- **Increased contrast:** inherits system behavior automatically because no custom colors exist
- **Inactive menu bar:** system dims status items; no compensation
- **Selected menu row:** system highlight (accent color); never imitated
- **Warning/failure semantics:** carried by text markers (`⚠︎`, `~`) and words, optionally `systemOrange`/`systemRed` on submenu detail rows — never color alone
- **The app icon is the only place with a product palette** (see `Pinchos Icon.dc.html`): ivory `#F2EDE3`, charcoal `#2B2A28`, olive `#6B7F3E`, terracotta `#C4593A`

## Icons

- **SF Symbols (#14):** rendered via the native symbol image path with template/automatic tint; aligned to the 16×16 target of local icons; real symbol names available on macOS 14 only
- **Local template images:** current behavior unchanged — `isTemplate = true`, 16×16
- **Invalid/unavailable icon or symbol:** item renders text-only; a `⚠︎`-free diagnostic row (`Icon: file not readable` / `Symbol: unavailable on this macOS`) plus `pinchos doctor` warning. Icon problems are not failures — the command result stays authoritative
- **Warning marker:** trailing ` ⚠︎` (U+26A0 U+FE0E, text presentation) on the title — error, timeout, launch failure, unavailable-with-kept-value
- **Stale marker:** trailing ` ~` on the title
- **Icon-only items:** full VoiceOver label (name, value, state); tooltip carries the title
- **Group icons:** optional, same 16×16 template contract; group summary stays text
- **App icon vs. status icons:** the app icon (Finder, notifications) may use restrained color; runtime status-item icons are always template/monochrome

## Motion

None beyond macOS defaults. No pulsing, spinners, marquees, animated graphs, or custom loading indicators. Running state = last useful value retained (tooltip and menu say `Running…`); first run with no prior value = `…` placeholder text. Reduced Motion needs no special handling because nothing moves.

## Copy

Terse, literal, operational. Native title case for commands; sentence-fragment status lines; exact errors when known; relative time in compact summaries (`updated 2 m ago`), exact time in diagnostics (`Last success: 2:41:07 PM`). No snack metaphors, marketing language, exclamation marks, emoji, anthropomorphism, or vague "Something went wrong".

Naming:
- `pinchos` — binary, config, and recovery-item title; `Pinchos` — product name in commands (`Quit Pinchos`) and notifications
- State vocabulary (exact, lowercase in values): `fresh`, `stale`, `running`, `unavailable`, `failed`, `timed out`, `cancelled`, `disabled`
- `Config` in command labels (`Open Config`); "configuration" in prose/docs

## Accessibility

- Every status item: `accessibilityLabel` = item name; `accessibilityValue` = current value + state (`"81 percent, stale"`); errors announced (`"failed, exit 1"`)
- Icon-only items announce name, value, and state — never an unlabeled image
- Truncated previews: `accessibilityHelp` notes truncation and points to `Copy Full Output`
- Copy commands are the accessible alternative to visually bounded previews
- Full Keyboard Access: everything is a real `NSMenuItem`, so arrow-key/typeahead navigation is inherited — a hard reason to avoid custom views
- Contrast: inherited from system colors; no color-only state (see markers)
- Arbitrary Unicode: rendered as-is in values; control characters sanitized to control pictures (`␉`, `␛`), newlines shown as `␊` in single-line contexts
- Notifications: standard `UNUserNotificationCenter` accessibility, terse bodies

## Component inventory + performance/lifecycle

| Component | Primitive | Timer | Observer | Retains output | Created | Released | Exists while menu closed |
|---|---|---|---|---|---|---|---|
| Status item title/icon | `NSStatusItem` + button | no¹ | no | current value string only | at config load | at item removal | yes (it *is* the bar presence) |
| Item menu (first level) | `NSMenu` (delegate-built) | no | no | no — reads runtime state on open | on menu open | on menu close | no |
| Diagnostics submenu | `NSMenu` | no | no | bounded previews built on open | on open | on close | no |
| Click/per-action submenus | `NSMenu` | no | no | bounded previews on open | on open | on close | no |
| Group menu + member submenus | `NSMenu` hierarchy | no | no | no | on open | on close | no |
| Recovery item/menu | `NSStatusItem` + `NSMenu` | no | no | bounded error preview | on recovery state | on successful reload | item yes, menu no |
| Tooltip | native `toolTip` string | no | no | bounded string | on value update | with item | yes (string only) |
| Notification (#21) | `UNUserNotificationCenter` | no² | no | 1 bounded stderr line | on state transition | fire-and-forget | n/a |

¹ Refresh timers belong to the existing scheduler/runner, not to presentation. ² Cooldown is a stored timestamp comparison, not a live timer.

Rule: presentation projects the authoritative runtime/config state that Pinchos already owns. No second UI state machine, no cached view hierarchies, no idle polling.
