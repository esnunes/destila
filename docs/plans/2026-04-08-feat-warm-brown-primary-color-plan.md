# Plan: Change primary color to warm brown

## Summary

Shift the primary color from purple/blue (hue 265) to a warm, earthy brown (coffee/chocolate tone) by changing the OKLCH hue to ~60 and adjusting lightness and chroma for a rich, natural appearance. Three locations in `assets/css/app.css` need updating.

## Changes

**File:** `assets/css/app.css`

### 1. Dark theme primary color (lines 35–36)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(45% 0.12 60);
--color-primary-content: oklch(98% 0.01 60);
```

### 2. Light theme primary color (lines 71–72)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(45% 0.12 60);
--color-primary-content: oklch(98% 0.01 60);
```

### 3. Prose link color (line 193)

**Before:**
```css
color: oklch(55% 0.2 265);
```

**After:**
```css
color: oklch(45% 0.12 60);
```

## Details

- **Color model:** OKLCH — Lightness (L), Chroma (C), Hue (H).
- **Hue shift:** `265` (purple/blue) → `60` (warm brown/amber zone). Hue 60 in OKLCH produces earthy brown tones reminiscent of coffee or chocolate.
- **Lightness adjustment:** `55%` → `45%`. Lowering lightness produces a deeper, richer brown rather than a washed-out tan. This ensures the color reads as a confident, saturated brown.
- **Chroma adjustment:** `0.2` → `0.12`. Brown tones have naturally lower chroma than blues/purples. Reducing chroma avoids an unnatural neon-orange and produces an authentic coffee/chocolate feel.
- **Content color:** Stays at `98%` lightness (near-white), with hue shifted to `60` to maintain a warm tint. The contrast ratio between `oklch(45% 0.12 60)` and `oklch(98% 0.01 60)` is well above the WCAG AA threshold of 4.5:1.
- Both dark and light themes use the same primary color values, keeping the brand consistent across themes.
- No other color variables (secondary, accent, neutral, info, success, warning, error) are changed.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic involved.
- **Behavioral impact:** None — purely visual. No Gherkin scenarios affected.

## Verification

- Visually inspect both dark and light themes in a browser to confirm the primary color appears as a warm, rich brown.
- Check that buttons, links, and any primary-colored UI elements look cohesive.
- Verify prose links inside chat messages use the new brown color.
- Confirm text on primary-colored backgrounds (using `--color-primary-content`) is readable with sufficient contrast.
- Confirm no other UI elements are unintentionally affected.
