---
title: "fix: Right-align back button on workflow creation page"
type: fix
date: 2026-04-09
---

# fix: Right-align back button on workflow creation page

## Overview

The "Back to workflow selection" button on the workflow creation form page (`create_session_live.ex`, `:form` view) is left-aligned. It should be right-aligned to match the pattern used on the archived sessions page.

## Current state

**Workflow creation page** (`lib/destila_web/live/create_session_live.ex:228-235`):
```heex
<div class="overflow-y-auto h-screen px-6 py-6">
  <div class="max-w-2xl mx-auto space-y-6">
    <.link
      navigate={~p"/workflows"}
      class="btn btn-ghost btn-sm text-base-content/40"
    >
      &larr; Back to workflow selection
    </.link>
```
The link is a block-level element inside `space-y-6` with no alignment — it renders left-aligned by default.

**Archived sessions page** (`lib/destila_web/live/archived_sessions_live.ex:35-43`):
```heex
<div class="flex items-center justify-between mb-6">
  <h1 class="text-2xl font-bold tracking-tight">Archived Sessions</h1>
  <.link
    navigate={~p"/crafting"}
    class="text-xs text-base-content/40 hover:text-base-content/60 transition-colors flex items-center gap-1"
  >
    <.icon name="hero-arrow-left-micro" class="size-3.5" /> Back to Crafting Board
  </.link>
</div>
```
The link is right-aligned via `justify-between` in a flex row alongside the page heading.

## Changes

### 1. Right-align the back button (`lib/destila_web/live/create_session_live.ex`)

Replace lines 230-235 with a right-aligned link that matches the archived sessions page style:

**Before:**
```heex
<.link
  navigate={~p"/workflows"}
  class="btn btn-ghost btn-sm text-base-content/40"
>
  &larr; Back to workflow selection
</.link>
```

**After:**
```heex
<div class="flex justify-end">
  <.link
    navigate={~p"/workflows"}
    class="text-xs text-base-content/40 hover:text-base-content/60 transition-colors flex items-center gap-1"
  >
    <.icon name="hero-arrow-left-micro" class="size-3.5" /> Back to workflow selection
  </.link>
</div>
```

Key changes:
- Wrap in `<div class="flex justify-end">` to right-align
- Replace `btn btn-ghost btn-sm` classes with the archived sessions link style: `text-xs text-base-content/40 hover:text-base-content/60 transition-colors flex items-center gap-1`
- Replace `&larr;` HTML entity with `<.icon name="hero-arrow-left-micro" class="size-3.5" />` to match the archived page's icon usage

### 2. Generate video

Record a video showing the workflow creation page with the right-aligned back button.

## Scope

- Single file change: `lib/destila_web/live/create_session_live.ex`
- No backend changes, no test changes needed (button text and navigation target unchanged)
