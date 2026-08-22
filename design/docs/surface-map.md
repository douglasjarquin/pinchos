# Pinchos surface map

Every product surface and how the user reaches it. **There is no main window, no preferences/settings window, no dashboard, no onboarding wizard, no popover.** Configuration is declarative TOML; operation is menus, tooltips, notifications, and the CLI.

| Surface | Primitive | Reached by |
|---|---|---|
| Command status item | `NSStatusItem` (one per visible top-level item) | Always visible in the menu bar while configured, enabled, and not hidden by `hide_when_empty` / `hide_on_error` / structured `hidden` |
| Command lifecycle menu | `NSMenu` | **Right-click** the item. (Left-click runs `click` if configured; else refreshes if `refresh_on_click`; else does nothing — preserved semantics, discoverability via tooltip + accessibility label) |
| Group status item | `NSStatusItem` (one per group; members give up their own slots) | Always visible; static configured title |
| Group menu | `NSMenu` | Left **or** right click on the group item |
| Member submenu | Native submenu of the group menu | Hover/arrow into a member row; contains that member's normal menu (minus duplicated global commands — see decision log) |
| Tooltip | Native `toolTip` | Hover any status item; shows configured `tooltip` template or full title for `icon_only`/truncated items; real line breaks, capped length |
| Recovery item (`pinchos` / `pinchos ⚠︎`) | `NSStatusItem` + `NSMenu` | Appears automatically when no usable config exists (missing, empty, malformed, or failed); this is the complete first-run and recovery experience |
| Native notification (#21) | `UNUserNotificationCenter` | Opt-in per item (`notify_on`); fires on failure/recovery transitions, subject to cooldown |
| Finder / app identity (#15) | `Pinchos.app`, app icon, `LSUIElement` accessory | Applications folder, Spotlight, notification banners; never the Dock while running |
| CLI | `pinchos` binary | Terminal: `init`, `validate`, `doctor`, `config-path`, `open-config`, `run <item>`, `service …` — `open-config` and the menu's `Open Config` land in the same editor-of-record |

Interaction invariants:
- Left-click semantics on command items are configuration-driven and silent; the menu is always on right-click.
- Hidden items (empty output / error / structured `hidden: true`) occupy no menu-bar slot; they remain diagnosable via `pinchos doctor` and visible as annotated rows inside a containing group's menu.
- Missing/malformed configuration never opens a window; the recovery item owns the entire flow (create example, open config, open directory, reload, quit). While a reload is broken, the last good configuration keeps running alongside `pinchos ⚠︎`.
