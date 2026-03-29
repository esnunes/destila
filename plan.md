# Plan: Reduce dark theme primary color brightness

## Problem

The dark theme's primary color is too bright (`oklch(65% 0.2 265)`) and causes visual strain. It should be reduced to `oklch(55% 0.2 265)` to match the light theme's primary lightness for consistency.

## Changes

### File: `assets/css/app.css`

**Line 35** — In the dark theme plugin block, change the primary color lightness from 65% to 55%:

```css
/* Before */
--color-primary: oklch(65% 0.2 265);

/* After */
--color-primary: oklch(55% 0.2 265);
```

No other color variables (secondary, accent, info, success, etc.) should be modified. No other files need changes.

## Verification

- Confirm only `--color-primary` in the dark theme block is changed.
- The chroma (0.2) and hue (265) channels remain unchanged.
- The light theme block (line 71) already uses `oklch(55% 0.2 265)` — after this change both themes share the same primary color definition.
