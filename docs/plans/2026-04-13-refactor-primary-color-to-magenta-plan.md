---
title: "refactor: Change primary color from purple-blue to magenta"
type: refactor
status: active
date: 2026-04-13
---

# refactor: Change primary color from purple-blue to magenta

## Overview

Shift the application's primary color from purple-blue (OKLCH hue 265) to magenta (OKLCH hue 330) across both light and dark themes, plus a hardcoded prose link color.

## Problem Frame

The current primary color uses a purple-blue hue (265) in the OKLCH color space. The design direction calls for magenta (hue 330) instead. All five occurrences of the primary hue (across three CSS rules) must change consistently.

## Requirements Trace

- R1. Dark theme `--color-primary` and `--color-primary-content` use hue 330
- R2. Light theme `--color-primary` and `--color-primary-content` use hue 330
- R3. Prose link color (`.prose a`) uses hue 330
- R4. No other color properties (secondary, accent, neutral, etc.) change
- R5. Lightness and chroma values remain unchanged

## Scope Boundaries

- Only `assets/css/app.css` is modified
- No Gherkin scenarios are affected — visual-only change
- No JavaScript, Elixir, or template changes

## Context & Research

### Relevant Code and Patterns

- `assets/css/app.css:48-81` — dark theme daisyUI plugin block
- `assets/css/app.css:84-117` — light theme daisyUI plugin block
- `assets/css/app.css:214-217` — `.prose a` color rule
- Colors use OKLCH format: `oklch(lightness chroma hue)`

## Key Technical Decisions

- **Change only the hue component**: Lightness and chroma stay the same so the color's perceived brightness and saturation are preserved. Only the hue rotates from 265 to 330.

## Implementation Units

- [ ] **Unit 1: Update primary color hue to magenta**

**Goal:** Change all five OKLCH hue values from 265 to 330

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `assets/css/app.css`

**Approach:**
Replace the hue value `265` with `330` in exactly five locations:
1. Dark theme `--color-primary: oklch(55% 0.2 265)` → `oklch(55% 0.2 330)` (line 57)
2. Dark theme `--color-primary-content: oklch(98% 0.01 265)` → `oklch(98% 0.01 330)` (line 58)
3. Light theme `--color-primary: oklch(55% 0.2 265)` → `oklch(55% 0.2 330)` (line 93)
4. Light theme `--color-primary-content: oklch(98% 0.01 265)` → `oklch(98% 0.01 330)` (line 94)
5. `.prose a` color: `oklch(55% 0.2 265)` → `oklch(55% 0.2 330)` (line 215)

**Patterns to follow:**
- Existing OKLCH color format in the same file

**Test expectation:** none — pure styling change with no behavioral effect

**Verification:**
- `grep -c "0.2 265\|0.01 265" assets/css/app.css` returns 0 (no remaining purple-blue primary references)
- `grep -c "0.2 330\|0.01 330" assets/css/app.css` returns 5 (all five values updated)
- Visual check: primary-colored UI elements (buttons, links, accents) render magenta in both light and dark themes

## System-Wide Impact

- **Interaction graph:** None — CSS custom properties propagate automatically through daisyUI's theme system
- **API surface parity:** Both light and dark themes updated consistently
- **Unchanged invariants:** Secondary, accent, neutral, info, success, warning, and error colors are untouched

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Missing a hue-265 reference | Verification grep confirms zero remaining instances |
