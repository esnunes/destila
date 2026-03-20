# Chore/Task Workflow + AI-Driven Workflow Refactor

**Date:** 2026-03-19
**Status:** Brainstorm

## What We're Building

Add a new "Chore/Task" workflow type for straightforward coding tasks that don't need the full feature request distillation process. The Chore/Task workflow uses AI-driven conversational phases instead of static one-question-per-step flows. Existing workflows (Feature Request, Project) remain unchanged for now and will be migrated to AI-driven phases in a future iteration.

### Chore/Task Workflow

A lightweight workflow for simple implementation tasks. The user describes what they want done, the AI clarifies through conversation, and the output is an implementation-ready prompt (without deep technical details like DB schemas or task lists — stays at the level of technical approach).

### AI-Driven Phases (Chore/Task Only, For Now)

Instead of each step being a single static question with a fixed input type, each Chore/Task step is a **phase** — a multi-turn AI conversation where the AI asks follow-up questions dynamically until sufficient clarity is achieved, then suggests advancing to the next phase (user confirms).

## Why This Approach

- **Better distillation:** Static questions can't adapt to context. AI-driven phases ask relevant follow-ups based on what the user has already said.
- **Future-proof:** Starting with AI-driven phases for Chore/Task establishes the pattern. Feature Request and Project will migrate later.
- **Existing infrastructure:** The AI session system (`Destila.AI.Session`) is already per-prompt and designed for multi-turn conversation.
- **Incremental delivery:** Shipping Chore/Task first with AI phases keeps scope manageable while proving the approach.

## Key Decisions

1. **Chore/Task is the third workflow type** (`:chore_task`) alongside `:feature_request` and `:project`.

2. **Repo URL is mandatory for all workflow types except `:project`.** Currently the wizard allows skipping the repo for feature requests — this changes.

3. **Chore/Task uses AI-driven phases; existing workflows stay static for now.** Feature Request and Project keep their current static step system. The architecture should support both models coexisting.

4. **Phase transitions: AI suggests, user confirms.** The AI determines when enough clarity has been gathered in a phase and suggests moving on. The user confirms before advancing.

5. **Chore/Task has 4 distillation phases:**
   - **Phase 1 — Task Description:** AI asks clarifying questions about what the user wants and how it should work.
   - **Phase 2 — Technical Concerns:** AI asks questions about the technical approach to the problem.
   - **Phase 3 — Gherkin Review:** AI reads existing `.feature` files from the linked repo, determines if changes are needed. If yes, discusses additions/updates/removals with the user. If no changes needed, auto-advances to phase 4.
   - **Phase 4 — Prompt Generation:** AI produces an implementation-ready prompt based on all prior context. User can chat to refine it, then mark as done.

6. **Phase 4 output is a high-level implementation prompt** — includes the technical approach but NOT deep implementation details (no task lists, no DB schema designs, no file-by-file change lists). Suitable to hand to an agent or developer.

7. **Feature Request and Project migration is deferred.** They keep their current static step system. Will be converted to AI-driven phases in a future iteration once the Chore/Task pattern is proven.

## Scope

### In Scope
- New `:chore_task` workflow type with its 4 AI-driven phases
- AI-driven phase system in `PromptDetailLive` (for Chore/Task)
- Making repo URL mandatory for non-project workflows (Feature Request + Chore/Task)
- Updating the wizard Step 1 UI to show the third workflow option
- Updating `Destila.Workflows` module to define Chore/Task phases
- Phase transition UX (AI suggests advancing, user confirms)

### Out of Scope
- Changes to the wizard flow itself (still 3 steps: pick type, link repo, describe idea)
- Changes to the board/kanban system
- Migrating Feature Request or Project to AI-driven phases (deferred)
- Changes to the implementation board workflow

## Resolved Questions

1. **How should the AI know when a phase is "complete enough" to advance?** — AI suggests advancing, user confirms.

2. **What should the Feature Request and Project phases look like after refactor?** — Deferred. They keep their current static step system for now.

## Open Questions

None — all questions resolved.
