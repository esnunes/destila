---
title: "feat: BDD feature file for the Create Prompt wizard"
type: feat
date: 2026-03-18
issue: https://github.com/esnunes/destila/issues/3
---

# feat: BDD feature file for the Create Prompt wizard

## Overview

Create a Gherkin `.feature` file (documentation only, no executable step definitions) that describes the "Create Prompt" wizard — the two-step flow where a user picks a workflow type and optionally links a repository before being redirected to the prompt detail page.

## Context from Codebase Analysis

The wizard is implemented in `lib/destila_web/live/new_prompt_live.ex`:

- **Step 1** — User sees two cards: "Feature Request" and "Project". Clicking one fires `select_type` and advances to step 2.
- **Step 2** — A form with a `type="url"` input for repo URL, plus three buttons: "Continue" (submits form), "Skip" (`skip_repo` event), and "Back" (returns to step 1, resets `workflow_type` to `nil`).
- On submit/skip, `create_and_redirect/2` creates the prompt in `Destila.Store` and calls `push_navigate` to `/prompts/:id`.
- Empty-string repo URLs are coerced to `nil` (line 33).
- **No server-side URL validation exists** — the only check is the browser's HTML5 `type="url"` constraint.

## Spec-Flow Analysis: Gaps in the Issue Description

The issue specifies 4 scenarios. Analysis identified these gaps:

| Gap | Severity | Description |
|-----|----------|-------------|
| Back button flow | Important | The wizard has a "Back" button on step 2 — no scenario covers it |
| Scenario 4 vs reality | Critical | Issue says "system shows a validation error" but server does zero URL validation; only browser `type="url"` exists. A LiveView test would bypass this entirely |
| Empty submit vs Skip | Minor | Submitting "Continue" with an empty field silently behaves like "Skip" — potentially confusing UX |
| Prompt defaults | Minor | No scenario verifies the created prompt's title, board placement, or workflow step state on the detail page |

### Decision on Scenario 4

Since this is **documentation-only** (no executable steps), the Gherkin file should describe the **intended behavior** as specified in the issue. A comment or note can flag that server-side validation is not yet implemented, making this scenario aspirational.

## Acceptance Criteria

- [x] Create `features/create_prompt_wizard.feature` with conventional Gherkin syntax
- [x] Include `Background` step: user is logged in
- [x] Scenario 1: Feature Request + valid repo URL → redirect to detail page
- [x] Scenario 2: Project + valid repo URL → redirect to detail page
- [x] Scenario 3: Any type + Skip → prompt created, redirect to detail page
- [x] Scenario 4: Any type + invalid URL → validation error, stays on step 2
- [x] (Bonus) Scenario 5: Back button from step 2 returns to step 1

## Implementation

### Task 1: Create `features/` directory

```bash
mkdir -p features/
```

### Task 2: Write `features/create_prompt_wizard.feature`

The file should follow standard Gherkin syntax with:

- `Feature:` block with a description of the two-step flow
- `Background:` with `Given I am logged in`
- 4 primary scenarios matching the issue requirements
- 1 additional scenario for the Back button (gap identified by analysis)
- User-centric, behavior-focused steps (no implementation details)

**Key phrasing decisions:**
- Step 1 options: "Feature Request" and "Project" (matching the UI card titles)
- Step 2 actions: "Continue" and "Skip" (matching button labels)
- Repo URL examples: `https://github.com/owner/repo` (matching the input placeholder)
- Invalid URL example: `not-a-valid-url` (as specified in the issue)
- Navigation: "new prompt page" for `/prompts/new`, "prompt detail page" for `/prompts/:id`

### Task 3: Run `mix precommit`

Verify the project still compiles and tests pass after adding the new file.

## References

- Issue: https://github.com/esnunes/destila/issues/3
- Wizard implementation: `lib/destila_web/live/new_prompt_live.ex`
- Store create function: `lib/destila/store.ex` (`create_prompt/1`)
- Router (authenticated routes): `lib/destila_web/router.ex`
