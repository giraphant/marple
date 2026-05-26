# marple Native — Layout & Token Spec (skeleton-first)

> Status: **learning draft, NOT implemented.** No code changes yet.
> Principle: **color values + font faces are theme tokens (swappable "skin"); this doc fixes the structure that stays constant across every theme — spacing, type *scale/weight*, component anatomy, measure, alignment.**
> North-star: Ulysses (warm paper, one signature accent, content-preview list rows, content-as-hero editor, calm chrome). Direction: bolder/editorial, not system-neutral.
> Rule for implementation later: **chrome uses system semantic colors directly; only custom values (`bg-paper`, the reading-theme, type dots) go through a theme — never hardcode those. Spacing/type/radius come from the small constant sets in §1.1 / §1.2 / §1.4.**
> Color model **revised 2026-05-23 → lightweight native** (after studying CotEditor + CodeEdit): see §1.3. We deliberately do NOT build Obsidian's 3-tier token tree.

---

## 1. Foundations (the contract)

### 1.1 Spacing scale (one scale, pick from it everywhere)
Base unit 4pt. Vary by zone for rhythm — never the same padding everywhere.

| token | pt | typical use |
|---|---|---|
| `space-1` | 2 | tight inline gaps |
| `space-2` | 4 | icon↔label |
| `space-3` | 6 | title↔preview in a row |
| `space-4` | 8 | row inner padding (compact) |
| `space-5` | 12 | row vertical padding |
| `space-6` | 16 | pane padding, section content |
| `space-7` | 20 | between sidebar groups |
| `space-8` | 24 | between inspector sections; heading top margin |
| `space-9` | 32 | reading column top padding |
| `space-10` | 40 | reading column horizontal margin |

### 1.2 Type roles (size + weight = skeleton; the face is theme)
Ratio ~1.15–1.25 between adjacent steps. **Reading body is larger than UI body** (Ulysses lesson: editor type bigger than chrome).

| role | size pt | weight | line-spacing | use |
|---|---|---|---|---|
| `display` | 28 | semibold | tight | reading doc title (H1) |
| `title` | 20 | semibold | — | reading H2 (section headings) |
| `title3` | 17 | semibold | — | reading H3; list/inspector pane headers |
| `headline` | 15 | semibold | — | list-row title; sidebar item |
| `reading-body` | 17–18 | regular | ~0.45×font (≈8pt) | reading paragraph |
| `body` | 15 | regular | — | UI body |
| `callout` | 13 | regular | — | inspector label/value |
| `subheadline` | 13 | regular | — | **list-row preview** |
| `caption` | 11 | medium/semibold | — | section headers, counts |
| `caption2` | 10.5 | medium | — | chip text |

Weights used: `regular` / `medium` / `semibold`. Avoid `bold` except `display`.

### 1.3 Color — LIGHTWEIGHT NATIVE MODEL (not a token tree)
> Evidence: **CotEditor + CodeEdit** (shipped, refined, native, themed apps) both do **chrome = system semantic colors + materials (≈zero custom tokens); content = one small theme.** macOS hands you light/dark/accent/contrast/vibrancy/active-inactive for free. **Do NOT build Obsidian's 3-tier system** (primitive palette + ~40 semantic roles + scales) — that is an Electron necessity, not a native one.
>
> Table = the semantic names used throughout §2–6 and what each is *backed by*. Most ride the system (define **nothing** — views may use the system color directly). Only a handful are **custom** (marple's warm-paper personality).

| token (used in §2–6) | backed by | define? |
|---|---|---|
| `text-primary/secondary/tertiary` | `.foregroundStyle(.primary/.secondary/.tertiary)` | system — no |
| `text-link` / `accent` | `.tint` / `Color(nsColor: .controlAccentColor)` (or `accent-signature`) | system — no\* |
| `selection-bg` | `Color(nsColor: .unemphasizedSelectedTextBackgroundColor)` | system — no |
| `hover-bg` / chip bg | `.quaternary` fill | system — no |
| `divider` / `border-hairline` | `Divider()` / `.separatorColor`, 1pt | system — no |
| `bg-sidebar` / `bg-list` / `bg-surface` | `NavigationSplitView` sidebar vibrancy / window+panel default / material (`.bar`) | system — no |
| `danger` / `success` | `.red` / `.green` | system — no |
| focus ring | system (free on focusable controls) | system — no |
| **`bg-paper`** (= `bg-content`) | **custom** warm off-white reading surface (the signature) | **yes** |
| **`accent-signature`** *(optional)* | **custom** brand accent, only if overriding the system accent app-wide | optional |
| **`bg-chrome`** *(optional)* | **custom** warm panel tint, only if you want the whole window warm beyond stock gray | optional |
| **`type-paper/book/author/topic/chapter/note`** | **custom** per-type dot colors (reuse web) | **yes** |
| **reading content colors** | **custom** small Theme struct (below) | **yes** |

\* Personality choice — pick ONE: keep the system accent (zero work, follows the user's macOS accent) **or** define `accent-signature` once to fix marple's brand color.

**Reading-pane content theme** — one `Codable` struct, JSON on disk, ~8–12 fields (only what markdown rendering needs beyond system colors): `text · heading · link · quote · codeFg · codeBg · emphasis` (+ `bg` = `bg-paper`). Fields may carry `bold`/`italic` (Ulysses-style emphasis). Held by one `@Observable`/singleton, read directly by the reading view (CodeEdit's `ThemeModel.shared` pattern) — **no `EnvironmentKey` token graph**.

> **Total custom-color surface = `bg-paper` + (optional `accent-signature`/`bg-chrome`) + 6 type dots + ~10 reading-theme fields. Stop there.**

**Skip entirely:** primitive neutral palette, accent-as-HSL derivation, the ~40 semantic-role layer, `-rgb` opacity triplets (SwiftUI has `.opacity()`), and any spacing/type/radius token *scale* beyond the tiny constants in §1.1 / §1.2 / §1.4.

### 1.4 Radii, borders, insets
- `radius-row` 6 — selection block
- `radius-chip` capsule
- `radius-card` 10–12
- `border-hairline` 1pt → `divider`
- `inset-row` 6–8pt — selection is an **inset rounded block**, never a full-bleed bar.

### 1.5 Density
Define one **comfortable** density now; leave a hook for `compact` later. Row min-heights below.

### 1.6 Motion tokens
- `dur-fast` 150ms · `dur` 200–250ms · curve **ease-out** (no bounce).
- Use for: selection, inspector toggle, navigation. **No load choreography.**

---

## 2. Window & chrome
- Min window 900×600.
- **Toolbar:** leading = sidebar toggle; center = current pane + count; trailing = actions **as icons** (e.g. "open in external editor" → icon + tooltip, *not* a text button) + inspector toggle.
- **Tab strip:** fixed height; tab = icon + label + close-on-hover; selected = `accent`-tinted block (subtle), `radius-row`.

---

## 3. Pane — Sidebar (library)
- Width: min 220, ideal 240. `bg-sidebar`.
- **Section header:** `caption`, `text-tertiary`; `space-6` above / `space-3` below.
- **Row:** `[icon 16]` `space-2` `[label headline]` `Spacer` `[count callout · text-secondary · monospacedDigit]`. Row height ≈ 28–30. Horizontal `inset-row`.
- **Selection:** inset rounded block (`radius-row`, `selection-bg`) — NOT full-width saturated blue.
- Group spacing: `space-7`.

---

## 4. Pane — List (entries)  ← biggest perceived-quality fix
- Width min 320. `bg-list`. Sticky header: `title3` + count, search field, sort/filter buttons.
- **Row anatomy (replace the gold-star wall):**
  ```
  VStack(alignment: .leading, spacing: space-3) {
    Title       // role=headline, text-primary, lineLimit 2
    Preview     // role=subheadline, text-secondary, lineLimit 2–3   ← use entry.preview
    MetaLine    // only if present: author · year · #works/type        (role=caption, text-tertiary)
  }
  padding: vertical space-5, horizontal space-5
  ```
  - **Rating:** if shown at all → ONE small `rating`-token filled mark + number. Never 5 repeated stars. PDF → small icon, `text-tertiary`.
  - **Separation:** rely on whitespace + subtle `selection-bg`; if dividers, hairline **inset** (not full-bleed).
  - **Selection:** inset rounded block (`radius-row`, `selection-bg`).
  - Natural height variation comes from preview `lineLimit` — that *is* the "how much is here" signal (same idea as the web card).

---

## 5. Pane — Reading (the hero)
- Detail column, `bg-content` (warm paper).
- **Measure:** content max-width 680–720pt, centered; horizontal margin `space-10`; top padding `space-9`.
- **Body:** `reading-body`; line-spacing ≈8pt; paragraph spacing `space-6`.
- **Headings:** `title` / `title3`; **`space-8` above, `space-4` below** (more air before a heading than after = rhythm). Heading emphasis may use `accent`.
- **Links / wikilinks:** `text-link`; underline subtle or weight-based.
- **Quote / list / code:** indent via spacing tokens; code uses mono face (theme) on `bg-surface`.
- **Word count:** optional minimal pill, top-trailing, `caption`, `text-tertiary` (Ulysses-style).

---

## 6. Pane — Inspector
- Width min 240 / ideal 300 / max 420. `bg-surface`.
- **Icon strip:** icons 18, `text-secondary`, `space-7` apart, vertical `space-4`, `divider` under. (Add tooltips/tiny labels for recall.)
- **Section:** header (`caption`, semibold, `text-tertiary`; **no `.uppercase` for Chinese**) + content; sections `space-8` apart; content padding `space-6`.
- **Stat row:** `[label callout text-secondary]` `Spacer` `[value callout monospacedDigit]`; spacing `space-3`.
- **Scalar row:** label `Spacer` value/edit; firstTextBaseline aligned; tap-to-edit (keep).
- **Themes (chips):** **flow layout** (chips size to text, wrap between chips — NOT `LazyVGrid(.adaptive)` which breaks words). Chip = `caption2`, padding h `space-3` v `space-1`, `bg`= chip token, capsule. **× shows on hover or only in add-mode**; "+添加" in the section header.
- **Relations:** group header (`caption` + count) + rows; row = `callout`, lineLimit 1, full-width tap target, **`hover-bg` on hover** (so it reads as clickable); group by type or add a type dot/icon; cap ~30 + "show more".

---

## 7. Component states (ship all, not half)
`default · hover · selected · focus · disabled · loading · empty · error`
- **Loading:** list **skeleton rows** (not a center spinner) once a metadata cache exists.
- **Empty:** `ContentUnavailableView` (already used — keep).
- **Error:** inline `danger` token (already done for save failures).

---

## 8. Theme system (lightweight — how the skin plugs in)
- **Chrome:** rides system semantic colors + materials (§1.3 table). Flips light/dark/accent automatically — **no theme code**.
- **Content:** one small `Codable` Theme struct (§1.3 reading colors + `bg-paper`, optionally `accent-signature`/type dots), JSON on disk. Held by one `@Observable`/singleton (CodeEdit's `ThemeModel.shared`); the reading view reads it directly.
- **Light / dark / sepia:** each theme declares an `appearance`; switch by reassigning the model's `selectedTheme` (the pane re-renders). Force the content subtree with `.colorScheme(theme.appearance)`; let chrome follow the system.
- **Debugging (your goal):** flipping a palette = pointing the reading pane at another `.json` / toggling one `@Observable` property — chrome needs zero changes. This is *why* the lightweight model serves "themes for easy debugging" better, not worse.

---

## Appendix — implementation priority (for later, when you choose to build)
1. **List-row anatomy** (§4) + **reading-column metrics** (§5) — biggest perceived gain, zero theme dependency.
2. **Token plumbing (LIGHT)** — spacing + type + radius *constants* (§1.1/§1.2/§1.4); `bg-paper` + 6 type dots + the small reading Theme (§1.3). Chrome stays on system colors — nothing to plumb.
3. **Selection-as-inset** (§1.4) + **chip flow layout** (§6).
4. **Inspector rhythm + relation affordances** (§6).
5. **Theme switching** (§8) — Light/Dark/Sepia.
6. **Personality** — custom monoline sidebar icons.
