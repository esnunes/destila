---
title: "refactor: Extract project form into shared LiveComponent"
type: refactor
status: active
date: 2026-04-14
---

# refactor: Extract project form into shared LiveComponent

## Overview

Extract the duplicated project creation/edit form logic into a single `ProjectFormLive` LiveComponent, and update both `ProjectsLive` and `CreateSessionLive` to use it. This eliminates ~200 lines of duplicated form rendering, validation, and port definition management spread across three files.

## Problem Frame

Project creation/edit forms exist in three places with duplicated logic:

1. **`ProjectsLive`** — inline `project_form/1` function component (lines 448-609) plus event handlers for validation, port management, create, and update
2. **`ProjectComponents.project_selector/1`** — nearly identical form markup for inline project creation during workflow setup (lines 81-262)
3. **`CreateSessionLive`** — duplicated event handlers for `validate_project_form`, `add_port`, `remove_port`, `update_port`, `create_and_select_project` (lines 112-191)

The validation logic is also duplicated: `ProjectsLive.validate_project_params/2` reimplements checks that already exist in `Project.changeset/2`. The `CreateSessionLive` version is even simpler and skips port definition validation entirely.

## Requirements Trace

- R1. Single source of truth for project form UI (create and edit modes)
- R2. Single source of truth for form validation (use `Project.changeset/2`)
- R3. Both `ProjectsLive` and `CreateSessionLive` use the shared component
- R4. No behavioral changes — existing functionality preserved exactly
- R5. Existing tests continue to pass without modification (or with minimal selector updates)

## Scope Boundaries

- Not changing the `project_selector/1` component's project list/selection UI — only the form portion
- Not changing the Project schema or changeset validations
- Not adding new features (e.g., edit from workflow page)
- Not refactoring the delete confirmation flow in `ProjectsLive`

## Context & Research

### Relevant Code and Patterns

- `lib/destila_web.ex:59-65` — `live_component` macro already defined via `use DestilaWeb, :live_component`
- `lib/destila/projects/project.ex` — `Project.changeset/2` already validates name, location, git URL format, port definitions, and denied env vars
- `lib/destila_web/components/project_components.ex` — `project_selector/1` handles project list + selection UI, currently also contains form markup
- LiveView pattern: LiveComponents handle their own events via `phx-target={@myself}` and notify parents via `send(self(), msg)`

### Key Observation: Changeset vs Manual Validation

`ProjectsLive` has a manual `validate_project_params/2` that reimplements validation already in `Project.changeset/2`. The changeset is more thorough (validates git URL schemes, checks denied env vars like PATH/HOME). The LiveComponent should use `to_form(changeset)` directly, eliminating the manual validation entirely.

## Key Technical Decisions

- **LiveComponent over function component**: The form needs its own event handlers (validate, add/remove port, submit). A LiveComponent with `@myself` targets keeps form state self-contained and avoids polluting parent LiveViews with form events.
- **Changeset-backed form**: Use `Project.changeset/2` → `to_form/2` instead of manual map-based validation. This provides a single validation source and proper error messages.
- **Parent notification via `send/2`**: On successful create/update, the component sends `{:project_saved, project}` to the parent LiveView. The parent decides what to do (refresh list, auto-select, etc.).
- **Mode attr**: The component accepts a `:mode` attr (`:create` or `:edit`) and an optional `:project` attr for edit mode. This replaces the dual `submit_event`/`submit_label` pattern.
- **Keep `project_selector/1` as function component**: The selector (project list + selection) stays as a function component in `ProjectComponents` but delegates to `ProjectFormLive` for the `:create` step instead of rendering its own form.

## Open Questions

### Resolved During Planning

- **Where to put the LiveComponent file?**: `lib/destila_web/live/project_form_live.ex` — follows the convention of LiveView files in `live/` directory, and uses `use DestilaWeb, :live_component`.
- **How to handle port_definitions state?**: Managed internally by the LiveComponent. Initialized from the project's existing port_definitions (edit mode) or empty list (create mode).
- **DOM ID conflicts?**: The component accepts an `id` attr (required by LiveComponent). Use distinct IDs: `"project-form-create"` in ProjectsLive, `"project-form-inline"` in CreateSessionLive. Input IDs inside the component are prefixed with the component ID to avoid clashes.

### Deferred to Implementation

- Exact error message formatting from changeset errors (may need minor adjustments to match current UX)
- Whether the `FocusFirstError` hook on the form needs adjustment for the LiveComponent context

## Implementation Units

- [ ] **Unit 1: Create ProjectFormLive LiveComponent**

**Goal:** Create a self-contained LiveComponent that renders the project form, handles validation and port management events internally, and notifies the parent on save.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Create: `lib/destila_web/live/project_form_live.ex`
- Test: `test/destila_web/live/project_form_live_test.exs`

**Approach:**
- `use DestilaWeb, :live_component`
- Attrs: `id` (required), `mode` (`:create` | `:edit`), `project` (optional, for edit mode), `submit_label` (optional, defaults based on mode), inner_block slot for extra buttons (cancel)
- Internal state: `form` (changeset-backed via `to_form`), `port_definitions` list
- `update/2`: Initialize changeset from `%Project{}` (create) or existing project (edit). Set `port_definitions` from project or empty.
- Event handlers (all scoped via `@myself`):
  - `"validate"` — cast params into changeset, update form assign
  - `"save"` — validate and either create or update via `Destila.Projects`; on success send `{:project_saved, project}` to parent
  - `"add_port"`, `"remove_port"`, `"update_port"` — manage port_definitions list locally
- Render: reuse the exact form markup from current `project_form/1`, adapted to use changeset-backed `@form` and `@myself` targets
- Port definitions managed as a separate assign (not part of the changeset) since they need index-based add/remove; merged into changeset params on submit

**Patterns to follow:**
- `lib/destila_web.ex:59-65` for the `live_component` macro
- Current `project_form/1` in `projects_live.ex` for form markup structure
- `Project.changeset/2` for validation

**Test scenarios:**
- Happy path: render in create mode, fill in name + git URL, submit -> receives `{:project_saved, project}` message
- Happy path: render in edit mode with existing project, change name, submit -> project updated
- Edge case: submit with empty name -> shows validation error
- Edge case: submit with no location (neither git URL nor local folder) -> shows location error
- Edge case: add port definition with invalid format -> shows port validation error
- Happy path: add port, remove port -> port list updates correctly
- Edge case: render in edit mode -> form pre-populated with project values including port definitions

**Verification:**
- Component renders identically to current form in both create and edit contexts
- Parent receives `{:project_saved, project}` on successful submission
- All validation errors surface in the form UI

- [ ] **Unit 2: Update ProjectsLive to use ProjectFormLive**

**Goal:** Replace the inline `project_form/1` function component and related event handlers in `ProjectsLive` with the new `ProjectFormLive` LiveComponent.

**Requirements:** R3, R4, R5

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila_web/live/projects_live.ex`
- Test: `test/destila_web/live/projects_live_test.exs`

**Approach:**
- Remove the `project_form/1` function component definition (lines 441-609)
- Remove event handlers: `validate_form`, `add_port`, `remove_port`, `update_port`, `create_project`, `update_project`
- Remove `validate_project_params/2` helper and `new_form/0` helper
- Remove assigns: `form`, `errors`, `port_definitions` (these are now internal to the LiveComponent)
- Keep assigns: `creating`, `editing_project_id`, `delete_confirming_id`
- In the template, replace `<.project_form ...>` with `<.live_component module={ProjectFormLive} id="project-form-create" mode={:create}>` (for create) and `<.live_component module={ProjectFormLive} id="project-form-edit" mode={:edit} project={project}>` (for edit within the stream)
- Add `handle_info({:project_saved, _project}, socket)` to reset `creating`/`editing_project_id` state. The PubSub handlers already refresh the project stream.
- For the cancel button, use the inner_block slot to render a cancel button that sends `phx-click="cancel"` to the parent (no `phx-target` since it targets the parent LiveView)

**Patterns to follow:**
- Current `handle_info` PubSub handlers in `ProjectsLive` for stream refresh pattern

**Test scenarios:**
- Happy path: create project flow works end-to-end (click new, fill form, submit, project appears in list)
- Happy path: edit project flow works end-to-end (click edit, modify fields, save, changes reflected)
- Happy path: cancel create returns to list view
- Happy path: cancel edit returns to display mode for that project
- Edge case: validation errors display correctly in create mode
- Edge case: validation errors display correctly in edit mode

**Verification:**
- All existing `ProjectsLiveTest` tests pass
- ProjectsLive module is significantly shorter (~300 lines removed)
- No form-related event handlers remain in ProjectsLive

- [ ] **Unit 3: Update CreateSessionLive and ProjectComponents to use ProjectFormLive**

**Goal:** Replace the duplicated form markup in `ProjectComponents.project_selector/1` and the duplicated event handlers in `CreateSessionLive` with the shared `ProjectFormLive` LiveComponent.

**Requirements:** R3, R4, R5

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila_web/live/create_session_live.ex`
- Modify: `lib/destila_web/components/project_components.ex`
- Test: `test/destila_web/live/project_inline_creation_live_test.exs`

**Approach:**
- **CreateSessionLive**: Remove event handlers `validate_project_form`, `add_port`, `remove_port`, `update_port`, `create_and_select_project`. Remove assigns: `project_form`, `port_definitions`, and the project-creation portion of `errors`. Add `handle_info({:project_saved, project}, socket)` that sets `project_id` to the new project's ID, refreshes the projects list, and resets `project_step` to `:select`.
- **ProjectComponents**: In the `:create` step of `project_selector/1`, replace the inline form (lines 89-253) with `<.live_component module={ProjectFormLive} id="project-form-inline" mode={:create} submit_label="Create & Select">`. Remove the `form`, `errors`, and `port_definitions` attrs from `project_selector/1` since they're no longer needed. Keep `step`, `projects`, `selected_id`, and `target` attrs.
- The "Back to selection" button stays in `project_selector/1` (outside the LiveComponent), targeting the parent via `phx-target={@target}`.

**Patterns to follow:**
- Current `project_selector/1` for the selection UI structure
- Unit 2's approach for parent notification handling

**Test scenarios:**
- Happy path: create project inline during workflow creation -> project created and auto-selected
- Happy path: project selector shows existing projects, allows selection
- Happy path: "Create New Project" button switches to form, "Back to selection" returns
- Edge case: validation errors in inline form display correctly
- Integration: create project inline, verify it appears in project list after going back to select

**Verification:**
- All existing inline creation tests pass
- CreateSessionLive module is shorter (~80 lines removed)
- ProjectComponents form markup replaced with LiveComponent mount (~170 lines removed)

- [ ] **Unit 4: Cleanup and verification**

**Goal:** Remove any dead code, verify all tests pass, run precommit checks.

**Requirements:** R4, R5

**Dependencies:** Units 2, 3

**Files:**
- Modify: `lib/destila_web/components/project_components.ex` (remove unused attrs if any remain)

**Approach:**
- Run `mix precommit` to check formatting, compilation warnings, and tests
- Verify no unused imports or aliases remain
- Confirm `ProjectComponents` attrs are trimmed to only what's needed (remove `form`, `errors`, `port_definitions` if not already done in Unit 3)
- Verify the `FocusFirstError` hook still works within the LiveComponent context

**Test expectation: none -- pure cleanup and verification pass**

**Verification:**
- `mix precommit` passes cleanly
- No compilation warnings
- All test suites pass

## System-Wide Impact

- **Interaction graph:** `ProjectFormLive` sends `{:project_saved, project}` → parent LiveView handles it. PubSub broadcasts from `Destila.Projects.create_project/1` and `update_project/2` continue to work as before for cross-view refresh.
- **Error propagation:** Validation errors stay within the LiveComponent. Only successful saves notify the parent.
- **State lifecycle risks:** None — the LiveComponent manages its own form state. Parent state (creating/editing flags) remains in the parent.
- **API surface parity:** Both pages get identical form behavior since they share the same component.
- **Unchanged invariants:** Project schema, changeset validations, PubSub broadcasts, router, and the project selector's list/selection UI are unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| DOM ID conflicts between two instances of the component on different pages | Component requires unique `id` attr; input IDs are prefixed with component ID |
| Edit mode within a stream requires passing the project to the component on each stream render | The `project` attr update triggers `update/2` which reinitializes the form |
| `FocusFirstError` hook may not fire correctly inside LiveComponent | Test explicitly; hook binds to form element which is rendered by the component |

## Sources & References

- `lib/destila_web/live/projects_live.ex` — current project CRUD page
- `lib/destila_web/live/create_session_live.ex` — workflow creation with inline project creation
- `lib/destila_web/components/project_components.ex` — current shared project selector component
- `lib/destila/projects/project.ex` — Project schema and changeset
- `lib/destila_web.ex:59-65` — LiveComponent macro definition
