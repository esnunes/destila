# Plan: Change primary color from purple/blue to golden yellow

## Summary

Update the application's primary color from purple/blue (`oklch(55% 0.2 265)`) to golden yellow (`oklch(75% 0.18 85)`, approximately `#EAB308`) in both the light and dark daisyUI theme definitions in `assets/css/app.css`. Also update the `--color-primary-content` values to use the yellow hue, and fix the hardcoded purple link color in the `.prose a` rule.

## Changes

**File:** `assets/css/app.css`

### 1. Dark theme primary color (line 35)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(75% 0.18 85);
```

### 2. Dark theme primary-content hue (line 36)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(20% 0.02 85);
```

The primary is now a bright yellow, so content on top of it should be dark for contrast (matching the existing warning-content pattern on line 48).

### 3. Light theme primary color (line 71)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(75% 0.18 85);
```

### 4. Light theme primary-content hue (line 72)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(20% 0.02 85);
```

Same rationale — dark text on bright yellow background.

### 5. Prose link color (line 193)

**Before:**
```css
color: oklch(55% 0.2 265);
```

**After:**
```css
color: oklch(75% 0.18 85);
```

This hardcoded color mirrors the primary and should track the new value.

## Details

- The `oklch` color model uses three channels: Lightness (L), Chroma (C), and Hue (H).
- The hue rotates from `265` (purple/blue) to `85` (yellow). Lightness increases from `55%` to `75%` since yellow needs higher lightness to appear vibrant. Chroma goes from `0.2` to `0.18`.
- `oklch(75% 0.18 85)` converts to approximately `#EAB308` (Tailwind's `yellow-500`).
- The `--color-primary-content` switches from light-on-dark to dark-on-light because yellow is a bright color that needs dark text for readable contrast (WCAG).
- No other color variables (secondary, accent, neutral, info, success, warning, error) are modified.
- All components using the daisyUI `primary` color token (buttons, badges, links, etc.) will automatically inherit the new color.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic involved.
- **Gherkin impact:** None — no feature scenarios reference specific colors.

## Verification

1. Run `mix precommit` to verify compilation and tests pass.
2. Visually inspect both light and dark themes in a browser to confirm:
   - Primary-colored elements (buttons, badges, links) appear golden yellow.
   - Text on primary-colored backgrounds is readable (dark text on yellow).
   - No other UI elements are unintentionally affected.
