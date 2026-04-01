# Plan: Change primary color theme from purple/blue to soft yellow

## Summary

Replace the purple/blue primary color (`oklch(55% 0.2 265)`) with a soft/muted yellow across both light and dark themes in `assets/css/app.css`. Update the primary-content color from light/white to dark for readable contrast against yellow backgrounds. Also fix a hardcoded primary color reference in the `.prose a` selector.

## Problem

The current primary color uses a purple/blue hue (hue angle 265 in oklch). The user wants a soft yellow identity instead. The content color (text on primary backgrounds) is currently near-white, which won't be readable on a yellow background — it needs to become dark.

## Change

**File:** `assets/css/app.css`

### 1. Dark theme primary colors (lines 35–36)

#### Before

```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

#### After

```css
--color-primary: oklch(78% 0.12 85);
--color-primary-content: oklch(25% 0.03 85);
```

### 2. Light theme primary colors (lines 71–72)

#### Before

```css
--color-primary: oklch(55% 0.2 265);
--color-primary-content: oklch(98% 0.01 265);
```

#### After

```css
--color-primary: oklch(75% 0.13 85);
--color-primary-content: oklch(25% 0.03 85);
```

### 3. Hardcoded prose link color (line 193)

#### Before

```css
.prose a {
  color: oklch(55% 0.2 265);
  text-decoration: underline;
}
```

#### After

```css
.prose a {
  color: oklch(75% 0.13 85);
  text-decoration: underline;
}
```

### Color rationale

| Property | Theme | Value | Explanation |
|----------|-------|-------|-------------|
| `--color-primary` | Dark | `oklch(78% 0.12 85)` | Slightly brighter yellow for dark backgrounds — higher lightness (78%) compensates for dark surroundings. Lower chroma (0.12) keeps it soft/muted rather than neon. Hue 85 is warm yellow. |
| `--color-primary` | Light | `oklch(75% 0.13 85)` | Slightly darker than the dark-theme variant to maintain contrast against the near-white light background. Marginally higher chroma for warmth against a bright context. |
| `--color-primary-content` | Both | `oklch(25% 0.03 85)` | Dark brown-yellow for text on yellow buttons/backgrounds. 25% lightness ensures WCAG AA+ contrast against both yellow variants. Low chroma keeps it neutral-dark. |
| `.prose a` | — | `oklch(75% 0.13 85)` | Matches light-theme primary. Could alternatively use `var(--color-primary)` but matching the existing pattern of a hardcoded value keeps the change minimal. |

### Alternative consideration for `.prose a`

The hardcoded color on `.prose a` (line 193) could be replaced with `color: var(--color-primary)` to automatically track the theme's primary color. This would be a minor improvement but changes the pattern — worth considering as a follow-up.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 5 (lines 35, 36, 71, 72, 193)
- **Risk:** Low — CSS custom property value changes only, no logic or markup changes.
- **Behavioral impact:** None — purely cosmetic. No Gherkin scenarios affected.

## Verification

1. Run the app:
   ```bash
   mix phx.server
   ```

2. Check in both light and dark themes:
   - **Buttons** (`btn-primary`): Should be soft yellow with dark readable text.
   - **Focus rings**: Should glow yellow instead of purple.
   - **Links in prose/markdown**: Should be yellow.
   - **Any primary-colored UI elements**: Should consistently show yellow.

3. Confirm no purple/blue remnants — search for `265` hue references in CSS to verify the hardcoded `.prose a` was caught.

4. Spot-check contrast: dark text on yellow buttons should be clearly readable in both themes.
