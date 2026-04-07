# Plan: Change primary color from purple/blue to red

## Summary

Shift the application's primary color from purple/blue (OKLCH hue 265) to a bright, vivid red (OKLCH hue ~25) across both dark and light themes, and update the hardcoded prose link color to match.

## Changes

### 1. Dark theme `--color-primary` (line 35)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(55% 0.22 25);
```

### 2. Dark theme `--color-primary-content` (line 36)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(98% 0.01 25);
```

### 3. Light theme `--color-primary` (line 71)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
```

**After:**
```css
--color-primary: oklch(55% 0.22 25);
```

### 4. Light theme `--color-primary-content` (line 72)

**Before:**
```css
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary-content: oklch(98% 0.01 25);
```

### 5. Prose link color (line 193)

The `.prose a` rule hardcodes the primary color instead of using the CSS custom property.

**Before:**
```css
.prose a {
  color: oklch(55% 0.2 265);
```

**After:**
```css
.prose a {
  color: oklch(55% 0.22 25);
```

## Details

- The OKLCH color model uses three channels: Lightness (L), Chroma (C), and Hue (H).
- Hue shifts from `265` (purple/blue) to `25` (red range). The target `#EF4444` maps approximately to `oklch(55% 0.22 25)` in OKLCH.
- Chroma increases slightly from `0.2` to `0.22` to achieve a vivid, saturated red comparable to `#EF4444`.
- Lightness stays at `55%` for both themes — this provides good contrast and matches the existing convention.
- `--color-primary-content` keeps `98%` lightness with minimal chroma, ensuring white text on the red background remains highly readable. Only the hue shifts to keep a slight warm tint.
- The existing `--color-error` already uses hue `25` with similar parameters. The primary will now share that hue but the error color has different lightness values per theme (60% dark, 55% light), so they remain distinguishable through context and usage.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic involved.

## Verification

- Visually inspect both light and dark themes in a browser.
- Confirm primary buttons, links, and interactive elements display the new red color.
- Confirm text on primary-colored backgrounds (buttons, badges) remains legible.
- Confirm `.prose a` links in chat messages reflect the new red color.
- Confirm the error color remains visually distinct from the new primary.
