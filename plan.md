# Plan: Reduce dark theme primary color brightness

## Summary

Reduce the `--color-primary` lightness in the dark theme from 55% to 50% to address user reports that the primary color is still too bright after a previous reduction (65% → 55%).

## Change

**File:** `assets/css/app.css`
**Line:** 35 (dark theme definition inside the `@plugin "../vendor/daisyui-theme"` block with `name: "dark"`)

| Property | Before | After |
|---|---|---|
| `--color-primary` | `oklch(55% 0.2 265)` | `oklch(50% 0.2 265)` |

Only the lightness component (first value) changes. Chroma (0.2) and hue (265) remain the same.

## Scope

- The light theme (`name: "light"`, line 71) also uses `oklch(55% 0.2 265)` for `--color-primary` but is **not** changed — only the dark theme is affected.
- `--color-primary-content` (line 36) stays at `oklch(98% 0.01 265)` — contrast with the darker primary will actually improve slightly.
- No other files need modification; daisyUI theme tokens are defined entirely in `assets/css/app.css`.

## Testing

- No Gherkin scenarios needed — this is a purely cosmetic CSS adjustment with no behavioral changes.
- Visual verification: open the app in dark mode and confirm the primary color (buttons, links, active states) appears slightly darker/less bright.
