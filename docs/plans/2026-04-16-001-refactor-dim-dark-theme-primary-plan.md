---
title: "refactor: Dim dark theme primary color"
type: refactor
status: active
date: 2026-04-16
---

# refactor: Dim dark theme primary color

## Overview

Reduce the lightness and chroma of `--color-primary` in the dark daisyUI theme
so primary-tinted surfaces (buttons, links, accents, focus rings) feel less
glaring during long sessions. Cosmetic CSS change only — no behavior, tests,
or dependencies change.

## Problem Frame

Users report glare from the dark theme's primary color. The current dark-theme
primary `oklch(55% 0.2 265)` is visibly bright against the dim base surfaces
(`--color-base-100: oklch(22% 0.01 260)`), producing punchy-feeling CTAs, links,
and focus rings. The Linear/Notion-inspired palette is the intended aesthetic,
so the fix is a tone-down of the same hue rather than a re-theming.

## Requirements Trace

- R1. Dim the dark theme `--color-primary` so primary surfaces feel softer but still clearly "primary".
- R2. Preserve the hue (`265`) to keep the Linear/Notion-inspired palette intact.
- R3. Leave `--color-primary-content` unchanged — near-white still reads on the dimmer primary.
- R4. Touch only the dark theme block; light theme and all other tokens remain untouched.
- R5. No behavioral, dependency, or config changes.

## Scope Boundaries

- Do not modify the light theme block (`assets/css/app.css` lines 84-117).
- Do not modify any other dark-theme token (secondary, accent, neutral, info, success, warning, error, radii, sizes, border, depth, noise).
- Do not touch `--color-primary-content` (stays at `oklch(98% 0.01 265)`).
- Do not modify `.prose a` at `assets/css/app.css:215` (it hardcodes the old value but is out of scope — link prose color is not covered by this request).
- No Gherkin scenarios, no automated tests, no Elixir/LiveView/router/template/JS changes.
- No dependency bumps, daisyUI plugin config changes, or Tailwind config changes.

## Context & Research

### Relevant Code and Patterns

- `assets/css/app.css:48-81` — dark theme `@plugin "../vendor/daisyui-theme"` block.
- `assets/css/app.css:57` — the single line to change: `--color-primary: oklch(55% 0.2 265);`.
- `assets/css/app.css:58` — `--color-primary-content: oklch(98% 0.01 265);` (unchanged).
- `assets/css/app.css:84-117` — light theme block (explicitly untouched).
- `assets/css/app.css:125` — `@custom-variant dark` maps to `[data-theme=dark]`, so visual verification requires setting the theme via the existing theme toggle (see `.theme-indicator` at `assets/css/app.css:131-134`).

### Institutional Learnings

None directly applicable — this is a cosmetic token tweak with no historical precedent to mirror.

## Key Technical Decisions

- **Target value `oklch(48% 0.15 265)` as the starting point**: The brief specifies this value as a reasonable starting point, with permission to tune by eye. Lightness drop of 7 points and chroma drop of 0.05 is a meaningful softening without going muddy. Hue held at `265` preserves the Linear/Notion palette.
- **Leave `--color-primary-content` alone**: The brief explicitly calls this out, and `oklch(98% 0.01 265)` near-white still clears WCAG-style legibility on a ~48% lightness primary fill by a comfortable margin.
- **Do not touch `.prose a`** (which hardcodes `oklch(55% 0.2 265)` at `assets/css/app.css:215`): It is shared by light and dark themes via `.prose`, not gated by `[data-theme=dark]`. Changing it would also shift light-theme link color, violating R4. Out of scope per the brief.

## Open Questions

### Resolved During Planning

- **Is `.prose a` in scope?** No. It is not gated by the dark-theme variant and changing it would affect the light theme. Scope explicitly excludes light-theme work.
- **Do we need to adjust `--color-primary-content`?** No. The brief explicitly says leave it; near-white on 48%/0.15 primary still reads clearly.

### Deferred to Implementation

- **Final L/C values**: The brief permits tuning by eye. Start at `oklch(48% 0.15 265)`, then eyeball against the verification surfaces below. Implementer may land a nearby value (e.g., 46-50% L, 0.13-0.17 C) if the starting point feels off, as long as it reads as "softer but still clearly primary".

## Implementation Units

- [ ] **Unit 1: Dim `--color-primary` in the dark theme block**

**Goal:** Reduce glare of primary-tinted dark-theme surfaces by lowering lightness and chroma of the primary token.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `assets/css/app.css` (line 57 only)

**Approach:**
- Change `--color-primary: oklch(55% 0.2 265);` to `--color-primary: oklch(48% 0.15 265);` inside the dark theme block (`name: "dark"` at `assets/css/app.css:49`).
- Do not alter any other line. Whitespace, ordering, and surrounding tokens stay identical.
- Start the server with `elixir --sname destila -S mix phx.server`, switch to dark mode via the existing theme toggle, and eyeball the verification surfaces.
- If the starting value feels too dim/washed or still too bright, tune by eye within a narrow band (L 46-50%, C 0.13-0.17, hue fixed at 265). Do not exceed this band without re-reviewing scope.

**Patterns to follow:**
- Match the existing single-line-per-token format of the dark theme block (`assets/css/app.css:53-72`).

**Test scenarios:**
- Test expectation: none — cosmetic token value change with no behavioral surface. Brief explicitly excludes Gherkin and automated tests. Verification is visual only.

**Verification:**
- Filled primary buttons / CTAs in dark mode feel softer, not glaring, but still clearly "primary-colored" (not washed out to neutral).
- Text links and accent highlights tinted with `primary` feel comfortable to read during sustained viewing.
- Focus rings and selected/active borders are still visible but not punchy.
- No visible change in light mode.
- `mix precommit` passes.

## Sources & References

- Target file: `assets/css/app.css`
- daisyUI theme plugin: `assets/vendor/daisyui-theme.js` (referenced by `@plugin "../vendor/daisyui-theme"`)
- Origin prompt: user request (2026-04-16) — dim dark theme primary to address reported glare.
