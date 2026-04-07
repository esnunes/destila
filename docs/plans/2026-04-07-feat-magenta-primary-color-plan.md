# Plan: Change primary color from blue-purple to vivid magenta

## Summary

Update the primary color across the Destila web application from blue-purple (hue 265) to vivid magenta/fuchsia (hue 328) in OKLCh format. This is a purely cosmetic change with no behavioral impact.

## Background

The current primary color uses OKLCh hue 265 (blue-purple). The target is a vivid magenta similar to #FF00FF/fuchsia, which maps to approximately hue 328 on the OKLCh hue wheel.

## Changes

### File: `assets/css/app.css`

**5 lines changed across 3 locations.**

#### 1. Dark theme block (lines 35–36)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(55% 0.27 328);
--color-primary-content: oklch(98% 0.01 328);
```

#### 2. Light theme block (lines 71–72)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(55% 0.27 328);
--color-primary-content: oklch(98% 0.01 328);
```

#### 3. Prose link color (line 193)

**Before:**
```css
color: oklch(55% 0.2 265);
```

**After:**
```css
color: oklch(55% 0.27 328);
```

## Details

- **Hue:** 265 → 328. Magenta/fuchsia sits at ~328 on the OKLCh hue wheel.
- **Chroma:** 0.2 → 0.27. Increased to produce a vivid, saturated magenta. Pure fuchsia (#FF00FF) has very high chroma (~0.31) in OKLCh; 0.27 is vivid while remaining safely within sRGB gamut at 55% lightness.
- **Lightness:** Unchanged at 55% for the primary and 98% for the content color, preserving the existing contrast ratio.
- **Content color:** `oklch(98% 0.01 328)` — a near-white with a slight magenta tint, providing excellent contrast (>7:1) against the 55% lightness primary background.
- **Prose links:** Line 193 hardcodes the primary color for `.prose a` elements. This must be updated to match the new magenta primary.
- **No other variables** (secondary, accent, neutral, info, success, warning, error) are affected.
- **No Gherkin scenarios** are affected — this is purely cosmetic.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic involved.

## Verification

- Visually inspect both light and dark themes in a browser to confirm the primary color appears as vivid magenta.
- Confirm buttons, links, and other primary-colored elements use the new magenta.
- Verify prose links (`.prose a`) also display in magenta.
- Check that text on primary-colored backgrounds (e.g., button labels) remains readable.
- Run `mix precommit` to ensure no build or test regressions.
