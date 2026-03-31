# Plan: Improve dark theme contrast for cards, filters, and empty banners

## Summary

Increase the lightness separation between dark theme base color tokens (`base-100`, `base-200`, `base-300`, `neutral`) in `assets/css/app.css` so that layered surfaces — cards on backgrounds, filter buttons on cards, empty-state banners — are clearly distinguishable without modifying any component templates or Tailwind classes.

## Problem

The current dark theme base colors have very low lightness separation:

| Token       | Current value             | Lightness |
|-------------|--------------------------|-----------|
| `base-100`  | `oklch(22% 0.01 260)`    | 22%       |
| `base-200`  | `oklch(19% 0.008 260)`   | 19%       |
| `base-300`  | `oklch(26% 0.012 260)`   | 26%       |
| `neutral`   | `oklch(35% 0.02 260)`    | 35%       |

- `base-100` to `base-200` gap: **3%** — cards (`bg-base-100`) sit on backgrounds (`bg-base-200`) and are nearly invisible.
- Empty banners use `bg-base-200/20` and `border-base-300/50`, compounding the low contrast with opacity modifiers.
- Filter buttons and sidebar elements use `bg-base-300/50` for hover states, which barely registers.

For reference, the light theme has 2% gaps but starts at 99% lightness where human perception is more sensitive. In darker ranges, larger gaps are needed.

## Affected components (read-only — these drive our verification, not our changes)

- **Cards**: `bg-base-100` on `bg-base-200` backgrounds (`dashboard_live.ex:68`, `archived_sessions_live.ex:61`, `projects_live.ex:285`, `session_live.ex:15`)
- **Empty banners**: `bg-base-200/20 border-base-300/50` (`crafting_board_live.ex:268,280`, `archived_sessions_live.ex:48`)
- **Sidebar**: `bg-base-200 border-base-300` (`layouts.ex:33`)
- **Filter/hover states**: `bg-base-300/50` (`layouts.ex:95,112,137`)
- **Dividers**: `border-base-300/50` (`layouts.ex:63,73`)
- **Nested containers**: `bg-base-200/50` (`crafting_board_live.ex:303`, `projects_live.ex:404`)

## Change

**File:** `assets/css/app.css` — dark theme block (lines 31–33, 41)

### Before

```css
--color-base-100: oklch(22% 0.01 260);
--color-base-200: oklch(19% 0.008 260);
--color-base-300: oklch(26% 0.012 260);
--color-neutral: oklch(35% 0.02 260);
```

### After

```css
--color-base-100: oklch(22% 0.01 260);
--color-base-200: oklch(15% 0.008 260);
--color-base-300: oklch(30% 0.015 260);
--color-neutral: oklch(38% 0.02 260);
```

### Rationale for each change

| Token       | Before | After | Delta | Why |
|-------------|--------|-------|-------|-----|
| `base-100`  | 22%    | 22%   | —     | Main surface stays the same; it's the reference point. |
| `base-200`  | 19%    | 15%   | −4%   | Background/recessed surfaces drop from 3% to **7%** below `base-100`, making cards clearly pop. Sidebar background also becomes more distinct. |
| `base-300`  | 26%    | 30%   | +4%   | Borders, dividers, and hover states jump from 4% to **8%** above `base-100`. Even with `/50` opacity modifiers, the contrast remains visible. |
| `neutral`   | 35%    | 38%   | +3%   | Keeps proportional spacing above `base-300` (8% gap vs previous 9%). Used for active/selected states. |

The chroma bump on `base-300` (0.012 → 0.015) adds a subtle blue tint to borders, making them feel intentional rather than muddy.

## Scope

- **Files changed:** 1 (`assets/css/app.css`)
- **Lines changed:** 3 (lines 32, 33, 41)
- **Risk:** Low — CSS custom property value changes only, no logic or markup changes.
- **Light theme:** Untouched.

## Verification

1. Run the app:
   ```bash
   mix setup && mix ecto.reset   # first-time only
   PORT=4001 mix phx.server
   ```

2. Use `agent-browser` to screenshot the following views in dark mode and confirm:
   - **Crafting board** (`/`): Cards are clearly distinguishable from the board background; empty section banners (dashed borders) are visible.
   - **Sidebar**: Sidebar background is darker than the main content area; dividers and hover states are visible.
   - **Projects page** (`/projects`): Project cards stand out from the background.
   - **Archived sessions** (`/archived`): Empty banner and session cards are distinguishable.

3. Spot-check that the light theme is visually unchanged (switch theme via the theme toggle).
