# Plan: Change primary color from blue-purple to rich gold yellow

## Summary

Replace the blue-purple primary color (`oklch(55% 0.2 265)`) with a rich gold yellow (`oklch(72% 0.17 85)`) across both daisyUI theme blocks and the hardcoded `.prose a` link color in `assets/css/app.css`. Update `--color-primary-content` to a dark value that ensures accessible contrast on the gold background.

## Changes

**File:** `assets/css/app.css`

### 1. Dark theme `--color-primary` (line 35)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(72% 0.17 85);
```

### 2. Dark theme `--color-primary-content` (line 36)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(20% 0.02 85);
```

### 3. Light theme `--color-primary` (line 71)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(72% 0.17 85);
```

### 4. Light theme `--color-primary-content` (line 72)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(20% 0.02 85);
```

### 5. `.prose a` link color (line 193)

**Before:**
```css
.prose a {
  color: oklch(55% 0.2 265);
  text-decoration: underline;
}
```

**After:**
```css
.prose a {
  color: oklch(72% 0.17 85);
  text-decoration: underline;
}
```

## Details

- The `oklch` color model uses Lightness (L), Chroma (C), and Hue (H).
- Old primary: L=55%, C=0.2, H=265 (blue-purple). New primary: L=72%, C=0.17, H=85 (gold yellow, ~#D4A017).
- Old primary-content: L=98% (near-white). New primary-content: L=20% (near-black with warm hue), providing strong contrast against the lighter gold background.
- Both themes use the same primary/primary-content values for consistency.
- The `.prose a` link color is hardcoded (not using a CSS variable), so it must be updated separately.
- No other theme colors (secondary, accent, neutral, info, success, warning, error) are modified.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic involved.

## Verification

- Run `mix precommit` to ensure no build or lint errors.
- Visually inspect both light and dark themes to confirm gold primary color renders correctly.
- Verify primary buttons, links, and other primary-colored elements use the new gold.
- Confirm text on primary backgrounds (primary-content) is readable with sufficient contrast.
- Confirm no other UI elements are unintentionally affected.
