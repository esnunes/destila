# Plan: Change primary color from purple to hot pink

## Summary

Shift the primary color hue from 265 (purple/violet) to 345 (hot pink/fuchsia) across both light and dark themes, and update one hardcoded reference in prose link styling. This is a purely visual/CSS change — no Gherkin scenarios or tests are affected.

## Changes

**File:** `assets/css/app.css`

There are **5 locations** where the primary purple hue (265) appears and must be updated:

### 1. Dark theme `--color-primary` (line 35)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(62% 0.28 345);
```

### 2. Dark theme `--color-primary-content` (line 36)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(98% 0.01 345);
```

### 3. Light theme `--color-primary` (line 71)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(62% 0.28 345);
```

### 4. Light theme `--color-primary-content` (line 72)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(98% 0.01 345);
```

### 5. Prose link color (line 193)

There is a hardcoded reference to the primary color in `.prose a` that does **not** use the CSS custom property. It must also be updated for consistency.

**Before:**
```css
.prose a {
  color: oklch(55% 0.2 265);
```

**After:**
```css
.prose a {
  color: oklch(62% 0.28 345);
```

## Color rationale

The OKLCH values were chosen as follows:

| Channel    | Old value | New value | Reason |
|------------|-----------|-----------|--------|
| Lightness  | 55%       | 62%       | Hot pink is perceived as brighter than purple; 62% ensures vibrancy without washing out |
| Chroma     | 0.2       | 0.28      | Higher saturation for a punchy, vibrant fuchsia (not pastel) |
| Hue        | 265       | 345       | Center of the hot pink/fuchsia range in OKLCH (340-350) |

**Content color** (`--color-primary-content`): only the hue shifts (265 → 345). Lightness stays at 98% and chroma at 0.01 — this produces a near-white with a barely perceptible pink tint, maintaining excellent contrast against the primary background.

## Constraints

- No other color variables (secondary, accent, neutral, info, success, warning, error) are modified
- Both light and dark themes use identical primary values so the brand color is consistent
- No Gherkin scenarios are affected
- Run `mix precommit` after changes and fix any issues

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic involved

## Verification

- Visually inspect both light and dark themes to confirm primary elements render as vibrant hot pink
- Check buttons, links, form focus rings, and any other elements using `primary` / `primary-content` daisyUI classes
- Confirm `.prose a` links match the new primary color
- Verify text on primary-colored backgrounds (`primary-content`) remains readable
