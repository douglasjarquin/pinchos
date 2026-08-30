# pinchos web design system

## 0. Research Log

- The supplied `design/Site Landing.dc.html` is the exact landing reference for layout, copy, product mockup, and responsive extrapolation.
- The supplied `design/Site Design System.dc.html` is the exact docs reference for the token page, component anatomy, and content structure.
- `design/docs/design-system.md` is the product-behavior reference only; the site quotes native AppKit behavior and does not restyle the app.
- The image-first review generated separate implementation references for the landing and docs pages at `/Users/douglasjarquin/.codex/generated_images/01a04f15-73fb-7362-8495-d79fb65e6880`; those images confirm an airy editorial composition, but the supplied canvases remain authoritative for copy and values.

## 1. Direction

Quiet editorial paper with an ink-first hierarchy and restrained olive and terracotta accents.
The signature moment is the real DOM menu-bar mockup: the only glossy charcoal surface, showing a healthy bar becoming an actionable failure menu.

## 2. Color

| Token | Value | Use |
| --- | --- | --- |
| `--color-paper` | `#F2EDE3` | Page background |
| `--color-paper-raised` | `#F8F3E8` | Alternate bands, cards, chips |
| `--color-paper-field` | `#FBF8F0` | Input and raised card field |
| `--color-ink` | `#2B2A28` | Text, charcoal band, code background |
| `--color-ink-soft` | `#5C574E` | Body and secondary copy |
| `--color-terracotta` | `#C4593A` | Mark and large display accent only |
| `--color-link` | `#B14E33` | Links, buttons, focus ring |
| `--color-link-readable` | `#A94A30` | Small links and text that need a robust AA margin |
| `--color-olive` | `#6B7F3E` | Overlines, labels, mark |
| `--color-olive-readable` | `#526631` | Small overlines and labels on paper |
| `--color-meta` | `#8A8377` | Captions, metadata, muted mono |
| `--color-meta-readable` | `#6E685F` | Small caption text requiring AA contrast |
| `--color-dark-copy` | `#F2EDE3` | Text on the charcoal band |
| `--color-dark-prompt` | `#E29B7B` | Shell prompt on charcoal |
| `--color-rule` | `rgba(43, 42, 40, .14)` | Hairline rules and borders |

The page uses paper, paper raised, and one charcoal band in that order.
Olive never carries body copy meaning.

## 3. Typography

| Role | Family | Size / line-height | Weight |
| --- | --- | --- | --- |
| Display | Source Serif 4 | `clamp(2.75rem, 6vw, 3.375rem)` / `1.06` | 600 |
| H2 | Source Serif 4 | `2rem` / `1.15` | 600 |
| H3 | Source Serif 4 | `1.375rem` / `1.3` | 600 |
| Body | Bricolage Grotesque | `1.03125rem` / `1.65` | 400 |
| Small | Bricolage Grotesque | `.875rem` / `1.6` | 500 |
| Overline | IBM Plex Mono | `.75rem` / `1.3`, `.09em` tracking | 500 |
| Caption | IBM Plex Mono | `--font-size-caption` / `1.35` | 400 |
| Code | IBM Plex Mono | `.84375rem` / `1.85` | 400 |

Use three families deliberately: editorial serif for hierarchy, Bricolage Grotesque for readable interface copy, and IBM Plex Mono for technical metadata.
All text is sentence case except mono overlines.
Product mockup-specific system typography, native palette values, row geometry, and static specimen dimensions use the `--mockup-menu-*` token family in `tokens.css`.

## 4. Spacing and layout

All spacing derives from a 4px base: `4`, `8`, `12`, `16`, `24`, `32`, `48`, `64`, and `96`.
The landing container is 1080px with 32px side padding; the docs container is 1040px with 32px side padding.
Landing sections use 72px vertical padding and the docs page uses a 72px section rhythm.

Radii are 8px for buttons, 10px for chips and color cards, and 12px for code blocks and product mockups.
The depth strategy is borders plus one product-only shadow: `0 10px 30px rgba(43, 42, 40, .18)`.
The mobile breakpoint is 720px; grids collapse to one column and horizontal padding becomes 20px.

## 5. Components

### Site chrome

- **Structure:** shared header with mark, lowercase wordmark, mono navigation, and shared footer.
- **Variants:** landing header, docs header, recipe explorer header.
- **States:** links have underline or a visible color change on hover and a 2px terracotta focus ring offset by 2px.
- **Accessibility:** semantic `header`, `nav`, `footer`, descriptive mark label, keyboard-reachable links.
- **Motion:** none; transitions are limited to interactive color/background changes.

### Mark and wordmark

- **Structure:** three vertical ink sticks with olive, terracotta, olive heads beside lowercase `pinchos`.
- **Variants:** 17px footer mark, 22px nav mark, 26px docs mark, 30px lockup mark, 16/24/48/96px specimen marks.
- **States:** fixed brand colors; never recolored or outlined.
- **Accessibility:** mark has `aria-hidden` when adjacent to a labelled wordmark and an accessible label when shown alone.
- **Motion:** none.

### Product mockup

- **Structure:** dark system-font menu bar, failing item marker, and a native-looking in-place submenu with a default Run action, TOML-configured actions, a fallback Refresh Now action, a config-backed Hide action, summary, bounded stderr, copy action, and a modifier-gated diagnostics disclosure.
- **Variants:** landing hero and docs component specimen.
- **States:** healthy bar and failing menu are both represented; failure is textual, not color-only; the landing demo switches between the four canonical sample items, opens each item's submenu, exposes `Run <item name>`, configured actions, fallback `Refresh Now`, runtime details, modifier-gated diagnostics, and `Hide`, removes a hidden sample item from the bar, reveals diagnostics only on Option/Alt + left click or Alt+Enter, never reveals them on hover, and demonstrates refresh recovery.
- **Accessibility:** `figure` has a meaningful label, menu-bar items are native buttons with expanded state and controlled-panel relationships, the first submenu action receives focus for normal keyboard activation, the Hide action is a keyboard-reachable button with an explicit restore-through-config explanation, the native diagnostics disclosure remains keyboard reachable after the Alt+Enter equivalent, menu actions are keyboard reachable, and all product vocabulary remains selectable text.
- **Motion:** no idle motion; the landing demo uses instantaneous state changes and the existing 150ms color/background feedback for controls.

### Recipe explorer

- **Structure:** a single-column working surface with a compact intro, labelled search field, live result count, and recipe cards generated from `recipes/*.toml` at build time.
- **Card anatomy:** each card places the complete TOML source in a scrollable charcoal code panel on the left and a theoretical menu-bar preview with item names, example values, and metadata on the right.
- **Variants:** all recipes, filtered results, and an explicit no-results state; multi-item TOML files show each item in the same preview bar.
- **States:** default, keyboard focus, filtered, no results, and responsive stacked cards below the mobile breakpoint.
- **Accessibility:** the search has a visible label and search semantics, the result count is a polite live region, each card has a descriptive heading, source code remains selectable, and no result state explains how to clear the filter.
- **Motion:** filtering is instantaneous; focus and link feedback reuse the existing 150ms color/background transition, with no decorative motion.

### Action and text link

- **Structure:** anchor with one primary action per view and supporting text link.
- **Variants:** filled primary, outlined secondary, mono navigation/footer link.
- **States:** default, hover, active, keyboard focus.
- **Accessibility:** native anchors with descriptive labels and 44px minimum touch target through padding.
- **Motion:** 150ms ease-out color/background transition.

### Raised card and token table

- **Structure:** one-level paper-field card with mono overline, content, and hairline borders; token table uses rows without vertical rules.
- **Variants:** principles, color swatch, type specimen, note, form, voice comparison.
- **States:** default and row hover where meaningful; no disabled state because the docs are static.
- **Accessibility:** headings follow page order; table uses real `table`, `thead`, `tbody`, and scoped headers.
- **Motion:** no decorative motion.

## 6. Motion and interaction

The source designs call for no idle motion.
Interactive anchors use only a 150ms ease-out transition for affordance feedback.
The homepage product mockup is a deliberate scoped client-side exception: its script simulates the sample TOML menu without reading local config or executing commands.
The submenu keeps generated `Run <item name>` and `Refresh Now` defaults first, then renders `[[item.<name>.action]]` entries and the configured `click` action from the canonical TOML sample.
The submenu's `Hide` action simulates setting `hidden = true` in the selected item's TOML table and removes that item from the sample bar; the real app persists that edit and restores the item when the key is removed or set to `false`.
Diagnostics are hidden from the regular submenu and from hover, and the landing demo reveals the native details disclosure only for an Option/Alt + left click or the Alt+Enter keyboard equivalent.
The recipe explorer's search filters the build-generated card list in place and announces the visible count without changing the URL or duplicating the catalog.
Interactive state changes are instantaneous and respect the same reduced-motion rule as the rest of the site.
All motion is disabled under `prefers-reduced-motion: reduce`.

## 7. Depth and surface

Use hairline rules and tonal shifts as the primary surface language.
Only the product mockup receives the documented shadow.
There are no gradients, glass effects, decorative blobs, or dark page surfaces outside the product/code band.

## 8. Accessibility constraints and accepted debt

- Target WCAG 2.2 AA with at least 4.5:1 body contrast and 3:1 large-text contrast.
- Every route has one descriptive title, a language declaration, semantic landmarks, keyboard-reachable links, and visible focus.
- The site has no client-side JavaScript except the homepage ProductMockup demo, whose scoped script only simulates the canonical sample config, and the recipe explorer's scoped filter; the compact design-system specimen remains static.
- Long technical strings wrap or scroll inside their own code block without causing page-level overflow.
- Respect `prefers-reduced-motion` even though the design intentionally has no decorative motion.

| Item | Location | Why accepted | Owner / exit |
| --- | --- | --- | --- |
| Google-hosted font files | Shared layout | Matches the supplied visual reference and keeps the repository free of font binaries | Replace with self-hosted subsets if deployment policy requires it |
