# Plan: Change primary button color to indigo

## Summary

Shift the primary color from the current purple/violet (hue 265) to indigo (hue ~277) in both light and dark daisyUI theme definitions in `assets/css/app.css`. This also updates the `--color-primary-content` hue to match.

## Context

The primary color is defined as a CSS custom property using the OKLCh color model. daisyUI's `btn-primary` class reads from `--color-primary`, so changing the custom property is the only change needed — all buttons and UI elements using the primary color will update automatically.

Tailwind CSS v4's indigo-500 maps to approximately `oklch(0.585 0.233 277)`. We'll target a similar hue (277) while keeping the current lightness and chroma values that already work well with the design system.

## Changes

**File:** `assets/css/app.css`

### Dark theme (lines 35-36)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(55% 0.22 277);
--color-primary-content: oklch(98% 0.01 277);
```

### Light theme (lines 71-72)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(55% 0.22 277);
--color-primary-content: oklch(98% 0.01 277);
```

## Details

- The OKLCh hue shifts from 265 (purple/violet) to 277 (indigo), aligning with Tailwind's indigo palette.
- Chroma increases slightly from 0.2 to 0.22 to match indigo's natural saturation and keep vibrancy.
- Lightness stays at 55% (dark theme) and 55% (light theme) — no brightness change.
- The `--color-primary-content` hue updates to 277 to maintain tonal harmony with the new primary.
- No template, component, or JavaScript changes are required — all primary buttons use `btn-primary` which reads from `--color-primary`.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 4 (lines 35-36, 71-72)
- **Risk:** Low — CSS custom property value changes only, no logic involved.

## Verification

- Visually inspect primary buttons in both light and dark themes to confirm they appear indigo.
- Verify `btn-soft` (default button variant) also reflects the indigo tint.
- Confirm no other UI elements are unintentionally affected (secondary, accent, etc. remain unchanged).
