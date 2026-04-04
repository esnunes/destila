# Plan: Change primary color from purple-violet to warm gold

## Summary

Shift the application's primary color from purple-violet (oklch hue ~265) to warm gold (oklch hue ~85) across both light and dark daisyUI themes in `assets/css/app.css`, plus one hardcoded prose link color.

## Problem

The current primary color uses a purple-violet hue (`oklch(55% 0.2 265)`). The desired branding is a warm gold tone instead.

## Change

**File:** `assets/css/app.css` — 4 values across 3 locations

### 1. Dark theme primary (line 35)

```css
/* Before */
--color-primary: oklch(55% 0.2 265);
/* After */
--color-primary: oklch(75% 0.18 85);
```

Rationale: On dark backgrounds (`base-100` at 22% lightness), the gold needs higher lightness (75%) to remain visible and vibrant. Chroma is slightly reduced (0.18) to avoid an overly saturated neon-yellow look against dark surfaces. Hue 85 sits squarely in warm gold territory — between yellow (90) and amber (70).

### 2. Dark theme primary-content (line 36)

```css
/* Before */
--color-primary-content: oklch(98% 0.01 265);
/* After */
--color-primary-content: oklch(20% 0.02 85);
```

Rationale: Gold is a light color, so text/icons on gold backgrounds need to be dark for contrast. Shifting from near-white (98%) to dark (20%) with a warm gold hue ensures readable content on gold buttons and badges.

### 3. Light theme primary (line 71)

```css
/* Before */
--color-primary: oklch(55% 0.2 265);
/* After */
--color-primary: oklch(55% 0.18 85);
```

Rationale: On light backgrounds, 55% lightness provides good contrast while feeling rich and intentional. Chroma 0.18 keeps the gold warm without looking garish. This matches the same hue (85) for brand consistency.

### 4. Light theme primary-content (line 72)

```css
/* Before */
--color-primary-content: oklch(98% 0.01 265);
/* After */
--color-primary-content: oklch(20% 0.02 85);
```

Rationale: Same logic as dark theme — dark text on a gold background for readability. The light theme primary at 55% lightness is mid-range, so dark content (20%) provides strong contrast.

### 5. Hardcoded prose link color (line 193)

```css
/* Before */
.prose a {
  color: oklch(55% 0.2 265);
}
/* After */
.prose a {
  color: oklch(55% 0.18 85);
}
```

Rationale: This inline color was matching the old primary. Update to match the new light-theme primary value for consistency.

### Color summary table

| Token | Theme | Before | After | Change |
|-------|-------|--------|-------|--------|
| `--color-primary` | Dark | `oklch(55% 0.2 265)` | `oklch(75% 0.18 85)` | Hue shift + lightness bump for dark bg visibility |
| `--color-primary-content` | Dark | `oklch(98% 0.01 265)` | `oklch(20% 0.02 85)` | Light→dark for contrast on gold |
| `--color-primary` | Light | `oklch(55% 0.2 265)` | `oklch(55% 0.18 85)` | Hue shift, slight chroma reduction |
| `--color-primary-content` | Light | `oklch(98% 0.01 265)` | `oklch(20% 0.02 85)` | Light→dark for contrast on gold |
| Prose link | — | `oklch(55% 0.2 265)` | `oklch(55% 0.18 85)` | Match new primary |

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic or markup changes.
- **Behavioral impact:** None — purely cosmetic. No Gherkin scenarios affected.

## Verification

1. Run the app:
   ```bash
   PORT=4001 mix phx.server
   ```

2. Check in both themes:
   - **Light theme**: Primary buttons, links, and badges should appear warm gold. Text on gold backgrounds should be dark and readable.
   - **Dark theme**: Gold primary should be bright enough to stand out against the dark background. Gold buttons should have dark, readable text.
   - **Prose content**: Links within markdown/prose sections should use the gold color.

3. Confirm the gold feels warm (not greenish-yellow or orange) — hue 85 in oklch targets classic gold between yellow (90) and amber (70).
