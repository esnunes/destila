# Plan: Reduce dark theme primary color brightness

## Summary

Reduce the lightness of the dark theme's primary color in `assets/css/app.css` from 65% to 55% to reduce visual strain and align with the light theme's primary lightness.

## Change

**File:** `assets/css/app.css` (line 35)

**Before:**
```css
--color-primary: oklch(65% 0.2 265);
```

**After:**
```css
--color-primary: oklch(55% 0.2 265);
```

## Details

- The dark theme is defined as a daisyUI theme plugin starting at line 26.
- The `oklch` color model uses three channels: Lightness (L), Chroma (C), and Hue (H).
- Only the L channel changes: `65%` → `55%`. Chroma (`0.2`) and Hue (`265`) remain unchanged.
- The light theme (line 71) already uses `oklch(55% 0.2 265)` for its primary color, so this change makes them consistent.
- No other color variables are modified. `--color-primary-content` (line 36) stays at `oklch(98% 0.01 265)`.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 1 (line 35)
- **Risk:** Low — single CSS custom property value change, no logic involved.

## Verification

- Visually inspect the dark theme in a browser to confirm the primary color appears less bright.
- Confirm no other UI elements are unintentionally affected (secondary, accent, etc. should be unchanged).
