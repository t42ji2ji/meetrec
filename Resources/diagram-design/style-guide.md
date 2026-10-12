<!-- diagram-design-profile
name: MeetRec
slug: meetrec
source-url: none
created: 2026-10-12
updated: 2026-10-12
notes: Bundled with MeetRec. Neutral Apple/Vercel-style skin, system fonts, no network
-->
# Style Guide

**The single source of truth for colors, typography, and tokens.** Every diagram draws from this — not from hex values inlined in other reference files or in the shipped templates and examples (those were built under the original editorial skin: replace their color and font values with the tokens below).

This is MeetRec's skin: clean and neutral in the manner of Apple and Vercel interfaces. Pure white (or near-black) paper, near-black ink, grey hierarchy, one blue accent. Sans-serif only, set in the platform's system face. It is already customized: never run onboarding, never ask about the style guide, never offer to save a profile.

---

## Tokens

### Semantic roles

| Role | Purpose | Light | Dark |
|---|---|---|---|
| `paper` | Page background, default node fill | `#ffffff` | `#0a0a0a` |
| `paper-2` | Secondary fill, container bg | `#fafafa` | `#171717` |
| `ink` | Primary text, primary stroke | `#171717` | `#ededed` |
| `ink-strong` | Text on solid `accent` fills | `#ffffff` | `#0a0a0a` |
| `muted` | Secondary text, default arrow stroke | `#4d4d4d` | `#c7c7c7` |
| `soft` | Sublabels, boundary labels | `#666666` | `#a1a1a1` |
| `rule` | Hairline borders | `rgba(0,0,0,0.08)` | `rgba(255,255,255,0.10)` |
| `rule-solid` | Stronger borders, baselines | `#e5e5e5` | `#2e2e2e` |
| `accent` | Focal / 1–2 max per diagram | `#0062d1` | `#3291ff` |
| `accent-tint` | Fill for accent-bordered boxes | `rgba(0,98,209,0.06)` | `rgba(50,145,255,0.12)` |
| `link` | Cross-references, external arrows | `#7928ca` | `#a970ff` |

### Contrast contract

Every text token (`ink`, `muted`, `soft`, `link`, `accent`) clears 4.5:1 on `paper` and on `paper-2` in both skins. Essential non-text marks (lines, arrows, borders, data points) need 3:1 against what they sit on. `rule`, `rule-solid`, `paper-2` and tints are decorative and never the only carrier of meaning. Composite any `rgba()` over `paper` before judging it.

### Series palette (multi-series charts only)

| Token | Light | Dark |
|---|---|---|
| `series-1` | `#1a7f37` | `#3fb950` |
| `series-2` | `#7928ca` | `#a970ff` |
| `series-3` | `#c2410c` | `#f97316` |
| `series-4` | `#a21caf` | `#e879f9` |
| `series-5` | `#666666` | `#a1a1a1` |

Fills at `0.12` opacity light, `0.18` dark; strokes full color. `accent` stays reserved for the focal series. Don't use these on non-chart types.

---

## Typography

Sans-serif only. No serif anywhere, including titles and callouts.

| Role | Family | Size | Weight | Usage |
|---|---|---|---|---|
| `title` | sans | 1.75rem | 600, tracking -0.02em | Page H1 |
| `node-name` | sans | 12px (13px for CJK) | 600 | Human-readable labels |
| `sublabel` | mono | 9px | 400 | Values, IDs, dates, numbers |
| `eyebrow` | mono | 7–8px | 500, tracked 0.12em, uppercase | Type tags, axis labels (Latin only) |
| `arrow-label` | mono | 8px | 400 | Arrow annotations (Latin only) |
| `callout` | sans | 13px | 400, `muted` | Annotation asides |

### Font stack

```css
--font-sans:  -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Geist', 'PingFang TC', 'Noto Sans TC', 'Microsoft JhengHei', system-ui, sans-serif;
--font-serif: var(--font-sans);
--font-mono:  ui-monospace, 'SF Mono', 'Geist Mono', Menlo, monospace;
```

### Font source

Font source: `system`

No font `<link>` and no `@import`: the diagram makes no network request at all. Remove the Google Fonts `<link>` from any template or example you start from, and replace its `--font-*` variables with the stack above.

### Chinese, Japanese and Korean labels

Most meetings are in Traditional Chinese, so most labels will be too.

- **Width budget.** Every wide or full-width character, including full-width punctuation `（）「」，。：`, costs 1em; every other character costs 0.60em (sans) or 0.62em (mono). Sum per character, multiply by font size, add padding, round the box up to a multiple of 4. Never count by script.
- **Floor of 12px.** CJK goes muddy below 12px. If a name doesn't fit, shorten it; don't shrink the type.
- **Arrow labels, eyebrows and legend text switch register.** A CJK label in one of those mono slots becomes 12px sans at weight 500, no tracking, no uppercase, and its mask rect grows to 16px tall.
- **Sublabels stay values.** Keep IDs, numbers and dates in mono; prose sublabels in CJK switch to the sans register above.

---

## Stroke, radius, spacing

| Token | Value | Use |
|---|---|---|
| `stroke-thin` | `1` | Tag-box outlines, leaf nodes |
| `stroke-default` | `1` | Most strokes |
| `stroke-strong` | `1.5` | Emphasis strokes |
| `radius-sm` | `6` | Small tags |
| `radius-md` | `8` | Node boxes |
| `radius-lg` | `12` | Containers, rings |
| `grid` | `4` | Every coord, size, and gap is divisible by 4 (hard rule) |

---

## Node type → treatment

| Type | Fill | Stroke |
|---|---|---|
| `focal` (1–2 max) | `accent-tint` | `accent` |
| `backend` | `paper` | `rule-solid` |
| `store` | `paper-2` | `rule-solid` |
| `external` | `paper-2` | `rule` |
| `input` | `paper-2` | `soft` |
| `optional` | `paper` | `rule-solid` dashed `4,4` |
| `security` | `accent-tint` | `accent @ 0.50` dashed `4,4` |

---

## Constraints (don't break these)

- **One accent.** Blue marks the 1–2 focal things; everything else is ink and greys.
- **No rainbow.** Color beyond `accent` is for multi-series charts only.
- **Flat.** No shadows, gradients, glows, or dotted-paper backgrounds. Hairline borders and generous whitespace carry the structure.
- **Clean container.** The diagram sits directly on `paper`; no framed card around it.
- **Dark mode follows the viewer.** Define the light tokens on `:root` and the dark ones under `@media (prefers-color-scheme: dark)`, so the same file matches the app's appearance.
