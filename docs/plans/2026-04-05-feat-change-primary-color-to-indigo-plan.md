# Plan: Change primary color from blue-purple to indigo

## Summary

Update the application's primary color from the current blue-purple (`oklch(55% 0.2 265)`) to indigo by shifting the OKLCH hue from 265 to ~264 and adjusting lightness/chroma to match Tailwind's indigo-600 (`oklch(0.4958 0.1866 277.02)`). Also update the hardcoded prose link color to match.

## Changes

### 1. Dark theme primary color

**File:** `assets/css/app.css` (lines 35–36)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(50% 0.19 277);
--color-primary-content: oklch(98% 0.01 277);
```

### 2. Light theme primary color

**File:** `assets/css/app.css` (lines 71–72)

**Before:**
```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

**After:**
```css
--color-primary: oklch(50% 0.19 277);
--color-primary-content: oklch(98% 0.01 277);
```

### 3. Hardcoded prose link color

**File:** `assets/css/app.css` (line 193)

**Before:**
```css
.prose a {
  color: oklch(55% 0.2 265);
```

**After:**
```css
.prose a {
  color: oklch(50% 0.19 277);
```

## Details

- The OKLCH color model uses three channels: Lightness (L), Chroma (C), and Hue (H).
- Tailwind's indigo-600 is approximately `oklch(0.4958 0.1866 277.02)`. We round to `oklch(50% 0.19 277)` for readability.
- The hue shifts from 265 (blue-purple) to 277 (indigo). Lightness decreases slightly from 55% to 50% to match the deeper indigo tone. Chroma adjusts from 0.2 to 0.19.
- `--color-primary-content` remains a near-white color with minimal chroma — only the hue channel is updated to 277 for tonal consistency. It stays high-contrast for text on an indigo background.
- Both dark and light themes get the same primary values (they were already identical before this change).
- Line 193 has a hardcoded color matching the old primary used for `.prose a` (markdown link styling). This must be updated to match.
- All ~19 component files reference the primary color through Tailwind/daisyUI utility classes (`bg-primary`, `text-primary`, `btn-primary`, etc.) which resolve to `--color-primary`. No component files need modification.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic involved.
- **Gherkin scenarios affected:** None — purely cosmetic theming change.

## Verification

- Visually inspect both light and dark themes in a browser to confirm the primary color appears as indigo.
- Verify buttons (`btn-primary`), links, badges, and other primary-colored elements look correct.
- Confirm `.prose a` links in chat messages match the new indigo primary.
- Confirm `--color-primary-content` text remains readable on the new indigo background.
- Confirm no other UI elements are unintentionally affected (secondary, accent, etc. should be unchanged).
