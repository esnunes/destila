# Plan: Change primary color from purple/blue to bright yellow

## Summary

Update the `--color-primary` and `--color-primary-content` CSS custom properties in both the light and dark daisyUI theme blocks in `assets/css/app.css` to use a bright, vivid yellow (oklch hue ~90) with dark (near-black) content text for strong readability contrast. Also update one hardcoded primary color reference in the `.prose a` rule.

## Problem

The current primary color is a purple/blue (`oklch(55% 0.2 265)`) with white content text (`oklch(98% 0.01 265)`). The project needs a bright yellow primary color instead.

### Current values

| Theme | Token                    | Current value              |
|-------|--------------------------|---------------------------|
| Dark  | `--color-primary`        | `oklch(55% 0.2 265)`     |
| Dark  | `--color-primary-content`| `oklch(98% 0.01 265)`    |
| Light | `--color-primary`        | `oklch(55% 0.2 265)`     |
| Light | `--color-primary-content`| `oklch(98% 0.01 265)`    |

Additionally, `.prose a` on line 193 hardcodes `color: oklch(55% 0.2 265)` instead of referencing the theme token.

## Change

**File:** `assets/css/app.css`

### 1. Dark theme block (lines 35–36)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(85% 0.19 90);
--color-primary-content: oklch(20% 0.02 90);
```

### 2. Light theme block (lines 71–72)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(85% 0.19 90);
--color-primary-content: oklch(20% 0.02 90);
```

### 3. Prose link color (line 193)

**Before:**
```css
color: oklch(55% 0.2 265);
```

**After:**
```css
color: oklch(85% 0.19 90);
```

### Rationale for chosen values

| Token              | Value                  | Why |
|--------------------|------------------------|-----|
| `--color-primary`  | `oklch(85% 0.19 90)`  | Hue 90 = vivid yellow in oklch. Lightness 85% makes it bright and punchy. Chroma 0.19 keeps it saturated without going out-of-gamut on sRGB displays. |
| `--color-primary-content` | `oklch(20% 0.02 90)` | Near-black with a warm tint matching the yellow hue. 20% lightness gives strong contrast against the 85% yellow background (APCA contrast ~75+). |

Both themes use the same primary values because yellow reads well on both light and dark backgrounds. The content color is dark (near-black) rather than white because dark text on yellow has significantly better readability than white text on yellow.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic or markup changes.
- **Gherkin scenarios:** None affected — purely cosmetic.

## Verification

1. Run `mix precommit` to ensure no compilation or test regressions.

2. Visual spot-check (optional):
   - Start the server and confirm buttons, links, badges, and other `primary`-colored elements now render as bright yellow with dark text.
   - Verify both light and dark themes via the theme toggle.
   - Confirm `.prose a` links inside markdown-rendered chat messages also appear yellow.
