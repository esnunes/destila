# Entity Refactoring & Schema Migration Learnings

**Date:** 2026-03-24  
**Search Context:** Entity renaming, schema migrations, LiveView restructuring, workflow type changes, refactoring patterns

## Critical Plan Documents Found

### 1. **Introduce Project Entity** (2026-03-21)
**File:** `/Users/nunes/src/github.com/esnunes/destila/docs/plans/2026-03-21-feat-introduce-project-entity-plan.md`

**Relevance:** HIGHLY RELEVANT for entity introduction and schema changes
- **Pattern**: Multi-phase entity introduction with storage layer, seed migration, and reference updates
- **Key Insight**: When introducing new entities that replace existing fields (e.g., `repo_url` → `project_id`), use a 7-phase approach:
  1. Add entity CRUD to store/context
  2. Update seeds to use new entity
  3. Find and replace all field references (systematic grep recommended)
  4. Create management UI
  5. Redesign wizard integration
  6. Update AI context/prompts
  7. Update tests and feature files
- **Critical Gotcha**: 9+ files reference the old field (`repo_url`). Missing a reference causes runtime errors. Mitigate with thorough `grep` and full test suite.
- **Scope**: Affects Store, Seeds, 9+ LiveViews, Workflows, Tests, Feature files
- **File Impact**: 15+ files touched across data layer, UI, AI phases, tests

### 2. **Redesign Crafting Board** (2026-03-23)
**File:** `/Users/nunes/src/github.com/esnunes/destila/docs/plans/2026-03-23-feat-crafting-board-redesign-plan.md`

**Relevance:** RELEVANT for LiveView restructuring and state computation
- **Pattern**: Replacing complex UI paradigms (kanban board) with new paradigms (sectioned list + toggle)
- **Key Insight**: When redesigning LiveView pages, separate concerns:
  1. Data layer (preloads, context queries)
  2. LiveView state (mount/handle_params for URL state)
  3. Derived state (pure functions for classification/grouping)
  4. Template rendering (conditional branches for view modes)
- **Helper Functions**: `classify_prompt/1` — pure, easily testable classification function
- **URL State**: Use `handle_params/3` and `push_patch/2` for persistent state (filter, view mode)
- **Preloads**: Always preload associations early if they're used in multiple places
- **Empty States**: Define behavior for all view combinations

### 3. **Store Raw AI Responses & Derive Display State** (2026-03-22)
**File:** `/Users/nunes/src/github.com/esnunes/destila/docs/plans/2026-03-22-refactor-raw-ai-response-storage-plan.md`

**Relevance:** RELEVANT for schema refactoring patterns and field renaming strategy
- **Pattern**: Schema simplification — drop derived columns, store raw data, derive at read time
- **Key Insight**: When refactoring schemas, eliminate synthetic/derived data:
  - Drop: `input_type`, `options`, `questions`, `message_type` (derived)
  - Rename: `step` → `phase` (systematic field rename across 15+ sites)
  - Add: `raw_response` (store source of truth)
  - Implement processing function: `Messages.process/2` handles read-time derivation
- **Field Rename Pattern**: Systematic `step:` → `phase:` across all message creation sites
- **Phase-Based Grouping**: Eliminate synthetic divider messages, derive from `phase` field
- **Processing Function**: `process/2` function centralizes how data is displayed
- **Test Strategy**: Helper functions use new field names; tests updated systematically

### 4. **Replace ETS with SQLite via Ecto** (2026-03-22)
**File:** `/Users/nunes/src/github.com/esnunes/destila/docs/brainstorms/2026-03-22-sqlite-migration-brainstorm.md`

**Relevance:** RELEVANT for major schema and persistence layer changes
- **Pattern**: Swapping underlying persistence technology while keeping external behavior identical
- **Key Insight**: When doing large refactors, separate concerns:
  1. Schema layer (Ecto schemas, changesets)
  2. Context layer (CRUD, associations, broadcasting)
  3. Caller updates (LiveViews, workflows)
  4. Test strategy (sandbox isolation, no shared seeds)
- **Validation**: Move validation from LiveViews into changesets
- **Broadcasting**: Maintain existing PubSub message shapes during refactor
- **Context Modules**: `Projects`, `Prompts`, `Messages` contexts follow Phoenix conventions
- **Test Cleanup**: Remove shared seed data, each test creates its own data
- **Field Persistence**: Distinguish between persistent (DB) and runtime (in-memory) state

## Refactoring Patterns Identified

### Pattern 1: Entity Introduction
**Applied by:** Introduce Project Entity plan
```
1. Add storage/CRUD functions
2. Update seed data with entity references
3. Find all field references (grep for old field)
4. Update each caller systematically
5. Create management UI
6. Integrate into existing flows (wizards, AI prompts)
7. Update tests and feature files
```

### Pattern 2: Schema Simplification
**Applied by:** Store Raw AI Responses plan
```
1. Identify derived vs. source-of-truth data
2. Drop derived columns
3. Add raw/source column if needed
4. Create processing function for read-time derivation
5. Update all writers to use new schema
6. Update all readers to call processing function
7. Systematic field rename if needed (e.g., step → phase)
```

### Pattern 3: LiveView Restructuring
**Applied by:** Crafting Board Redesign plan
```
1. Separate data layer (preloads, queries)
2. Implement pure classification/grouping functions
3. Use handle_params/3 for URL state
4. Compute derived state from filters/toggles
5. Use conditional rendering for view modes
6. Test each view combination
```

### Pattern 4: Persistence Layer Swap
**Applied by:** SQLite Migration brainstorm
```
1. Create new schema layer (Ecto schemas)
2. Create context layer with same API (Store → Projects/Prompts/Messages)
3. Migrate broadcasting to new contexts (keep message shapes)
4. Update all callers to use new contexts
5. Update test strategy (sandbox, no seeds)
6. Run full test suite (all 65 tests)
```

## Warnings & Gotchas

### From Project Entity Introduction
- **Broad Refactoring Scope**: 9+ files reference the field. Missing one causes runtime errors.
  - **Mitigation**: Thorough grep search, full test suite
- **Wizard Complexity**: Moving from simple text input to selection + inline creation
  - **Mitigation**: Keep UI simple, use separate sub-views for select/create

### From Raw AI Response Storage
- **Field Rename Complexity**: 15+ sites need `step` → `phase` rename
  - **Mitigation**: Use systematic approach, test after each phase
- **Synthetic Messages**: Currently use phase divider messages; switching to field-based
  - **Mitigation**: Template must handle phase transitions from field value

### From ETS to SQLite
- **Runtime vs. Persistent State**: PID fields (like `ai_session`) can't be stored in DB
  - **Mitigation**: Keep in LiveView assigns or process registry, add string `session_id` for future
- **Test Isolation**: Shared seed data breaks sandbox isolation
  - **Mitigation**: Each test creates its own data via contexts

## Success Metrics

All four plans emphasize:
1. **Test Coverage**: All existing tests pass, no functionality lost
2. **Feature File Alignment**: Gherkin scenarios updated/created and passing
3. **Mix Precommit**: All style checks, compilation, tests pass
4. **Reference Completeness**: Systematic search for all references using grep
5. **PubSub Consistency**: Broadcasting continues working with same message shapes
