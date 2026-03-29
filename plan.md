# Plan: Dark theme — reduce primary color brightness

## Context

Users report the dark theme's primary color is too bright and causes visual strain. The fix is to reduce the lightness channel of the primary color in the dark theme from 65% to 55%, matching the light theme's primary lightness for consistency.

## Current state

In `assets/css/app.css`, two daisyUI theme blocks define color variables:

- **Dark theme** (line 35): `--color-primary: oklch(65% 0.2 265);`
- **Light theme** (line 71): `--color-primary: oklch(55% 0.2 265);`

The dark theme primary is 10 percentage points brighter than the light theme's. Both themes share the same chroma (0.2) and hue (265).

## Changes

### 1. `assets/css/app.css` — line 35

Change the dark theme's primary color lightness from `65%` to `55%`:

```css
/* Before */
--color-primary: oklch(65% 0.2 265);

/* After */
--color-primary: oklch(55% 0.2 265);
```

**Scope:** Only `--color-primary` in the dark theme block is modified. No other color variables (`--color-primary-content`, `--color-secondary`, `--color-accent`, etc.) are touched. No other files are affected.

## Verification

- Confirm the dark theme primary color now renders at 55% lightness.
- Confirm the light theme primary color remains at 55% lightness (unchanged).
- Confirm no other color variables were modified.
