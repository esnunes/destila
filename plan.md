# Plan: Change primary color from purple-blue to magenta

## Summary

Update the OKLCH hue value from `265` (purple-blue) to `330` (magenta) in three locations within `assets/css/app.css`. Lightness and chroma values remain unchanged.

## File: `assets/css/app.css`

### Step 1: Update dark theme primary color (lines 57-58)

Change the `--color-primary` and `--color-primary-content` custom properties inside the dark theme daisyUI plugin block:

- Line 57: `--color-primary: oklch(55% 0.2 265);` → `--color-primary: oklch(55% 0.2 330);`
- Line 58: `--color-primary-content: oklch(98% 0.01 265);` → `--color-primary-content: oklch(98% 0.01 330);`

### Step 2: Update light theme primary color (lines 93-94)

Change the `--color-primary` and `--color-primary-content` custom properties inside the light theme daisyUI plugin block:

- Line 93: `--color-primary: oklch(55% 0.2 265);` → `--color-primary: oklch(55% 0.2 330);`
- Line 94: `--color-primary-content: oklch(98% 0.01 265);` → `--color-primary-content: oklch(98% 0.01 330);`

### Step 3: Update prose link color (line 215)

Change the hardcoded color on `.prose a`:

- Line 215: `color: oklch(55% 0.2 265);` → `color: oklch(55% 0.2 330);`

## Constraints

- Only `assets/css/app.css` is modified
- No Gherkin scenarios are affected (visual-only change)
- Both light and dark themes are updated consistently
- No other color properties (secondary, accent, neutral, etc.) change
- The secondary color (hue 290) remains unchanged despite being adjacent in the color wheel
