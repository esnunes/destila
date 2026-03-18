---
title: "Bootstrap Destila — AI prompt crafting web app prototype"
type: feat
date: 2026-03-17
issue: https://github.com/esnunes/destila/issues/1
---

# Bootstrap Destila — AI Prompt Crafting Web App Prototype

## Overview

Build a visual prototype of Destila, an Elixir/Phoenix web application that helps developers convert ideas into detailed AI prompts through guided workflows. This is a **UI prototype only** — all data is mocked in-memory, no real database or AI API calls. The app showcases the full UX flow: login, dashboard, two kanban boards, prompt creation, and a chat-based refinement workflow.

## Problem Statement / Motivation

Developers lack a structured workflow for transforming raw ideas (feature requests, bug reports, new projects) into high-quality, actionable AI prompts. They either write prompts from scratch or iterate manually. Destila solves this by providing guided, step-by-step workflows. This prototype validates the core UI/UX before building real integrations.

## Technical Approach

### Architecture

- **Framework:** Phoenix 1.8 with LiveView (Elixir 1.19, Erlang/OTP 28)
- **Project generation:** `mix phx.new destila --no-ecto --no-mailer --no-dashboard`
  - No Ecto — all data is mocked in-memory
  - No mailer — not needed for prototype
  - No LiveDashboard — not needed for prototype
- **Data layer:** GenServer-backed ETS tables for concurrent read access with seeded data on startup
- **Styling:** Tailwind CSS (included by default) — target a Linear/Notion aesthetic with generous whitespace, refined typography, subtle shadows
- **Interactivity:** Phoenix LiveView for all pages; SortableJS via JS hooks for kanban drag-and-drop
- **Auth:** Simple session-based mock auth via a custom Plug (any credentials accepted)

### Key Technology Decisions

| Decision | Choice | Rationale |
|---|---|---|
| LiveView vs Controllers | LiveView | Kanban drag-and-drop, chat interface, and multi-step forms are all LiveView sweet spots |
| Database | None (GenServer/ETS) | Issue explicitly requires "no real database"; in-memory data resets on restart which is fine for a prototype |
| CSS Framework | Tailwind (default) | Ships with Phoenix; sufficient for Linear/Notion aesthetic with custom design tokens |
| Drag-and-drop | SortableJS via JS Hook | Proven pattern with LiveView; lightweight, well-documented |
| Components | Function components | Stateless, simple; LiveComponent only if kanban cards need isolated drag state |
| Auth | Custom Plug | `phx.gen.auth` requires Ecto; a 10-line Plug is simpler for fake auth |

### Data Structures

All data lives in ETS, managed by a `Destila.Store` GenServer started in the supervision tree.

```elixir
# Prompt
%{
  id: "uuid",
  title: "Add dark mode support",
  workflow_type: :feature_request | :project,
  repo_url: "https://github.com/org/repo" | nil,
  board: :crafting | :implementation,
  column: :request | :distill | :done | :todo | :in_progress | :review | :qa | :impl_done,
  steps_completed: 2,
  steps_total: 4,
  position: 0,
  created_at: ~U[...],
  updated_at: ~U[...]
}

# Message (for chat workflow)
%{
  id: "uuid",
  prompt_id: "uuid",
  role: :system | :user,
  content: "What problem are you trying to solve?",
  input_type: :text | :single_select | :multi_select | :file_upload | nil,
  options: [%{label: "...", description: "..."}] | nil,
  selected: ["option_label"] | nil,
  step: 1,
  created_at: ~U[...]
}
```

### Route Structure

```
GET  /login                          SessionLive (login page)
POST /login                          SessionController.create (set session)
GET  /logout                         SessionController.delete (clear session)

GET  /                               DashboardLive (board previews)
GET  /crafting                       CraftingBoardLive (prompt crafting kanban)
GET  /implementation                 ImplementationBoardLive (implementation kanban)
GET  /prompts/new                    NewPromptLive (creation wizard)
GET  /prompts/:id                    PromptDetailLive (chat workflow)
```

## Implementation Phases

### Phase 1: Project Setup & Foundation

Generate the Phoenix project and establish the base layout, routing, and mocked authentication.

**Tasks:**

- [ ] Generate Phoenix project: `mix phx.new destila --no-ecto --no-mailer --no-dashboard`
- [ ] Configure `mise.toml` in project root (Erlang 28.4, Elixir 1.19.0-otp-28)
- [ ] Set up global layout in `lib/destila_web/components/layouts/root.html.heex`:
  - App name "Destila" (links to dashboard)
  - Nav links: Dashboard, Prompt Crafting, Implementation
  - Global "+ Create" button
  - User avatar/name with logout dropdown
- [ ] Create `DestilaWeb.Plugs.RequireAuth` plug:
  - Check session for `:current_user`
  - Redirect to `/login` if missing
  - Assign `current_user` map to conn
- [ ] Create `SessionLive` for login page:
  - Simple email/password form (any credentials work)
  - POST to `SessionController.create` which sets session and redirects to `/`
- [ ] Create `SessionController` with `create` (set session) and `delete` (clear session, redirect to `/login`)
- [ ] Add route pipeline with `RequireAuth` plug for all authenticated routes
- [ ] Set up Tailwind design tokens for Linear/Notion aesthetic:
  - Font: Inter or system sans-serif
  - Muted color palette, subtle borders, generous spacing
  - Card shadows, hover states

**Success criteria:** User can visit `/login`, enter any credentials, see the authenticated layout with header nav, and log out.

### Phase 2: Data Layer & Seeding

Build the in-memory data store and populate it with example data.

**Tasks:**

- [ ] Create `Destila.Store` GenServer module (`lib/destila/store.ex`):
  - Owns an ETS table (`:set`, `:public`, `:named_table`)
  - API functions: `list_prompts/0`, `get_prompt/1`, `update_prompt/2`, `create_prompt/1`
  - API functions: `list_messages/1`, `add_message/2`
  - API functions: `move_card/3` (prompt_id, new_column, new_position)
- [ ] Add `Destila.Store` to application supervision tree (`lib/destila/application.ex`)
- [ ] Create `Destila.Seeds` module (`lib/destila/seeds.ex`) called from `Store.init/1`:
  - 8-10 prompt cards distributed across both boards:
    - Crafting Board: 2 in Request, 2 in Distill (one with partial chat), 1 in Done
    - Implementation Board: 2 in Todo, 1 in In Progress, 1 in Review, 1 in QA, 1 in Done
  - Mix of "Feature Request" and "Project" workflow types
  - Some with linked repos, some without
  - At least one Distill prompt with 5-6 chat messages showing a mid-workflow conversation
  - Chat messages demonstrating all input types (text, single-select, multi-select, file upload)

**Success criteria:** `Destila.Store.list_prompts()` returns seeded data; messages exist for at least one prompt.

### Phase 3: Dashboard

Build the landing page with board preview summaries.

**Tasks:**

- [ ] Create `DashboardLive` (`lib/destila_web/live/dashboard_live.ex`):
  - Fetch prompts from `Store`, group by board
  - Render two board preview cards side by side
- [ ] Each board preview shows:
  - Board name and description
  - Card count per column (e.g., "Request: 2 | Distill: 2 | Done: 1")
  - Last 2-3 recent card titles as a mini list
  - Click navigates to full board view (`/crafting` or `/implementation`)
- [ ] Style: clean cards with subtle borders, hover effect, clear visual hierarchy

**Success criteria:** Dashboard shows accurate summaries for both boards; clicking a preview navigates to the board.

### Phase 4: Kanban Boards

Build both kanban board views with drag-and-drop card movement.

**Tasks:**

- [ ] Create shared function components (`lib/destila_web/components/board_components.ex`):
  - `board_column/1` — renders a column header with card count and card list
  - `board_card/1` — renders a card with: title, workflow type badge, repo URL (if any), sub-step progress bar (steps_completed / steps_total)
- [ ] Create `CraftingBoardLive` (`lib/destila_web/live/crafting_board_live.ex`):
  - Three columns: Request, Distill, Done
  - "+ New Prompt" button in header area
  - Cards grouped by column from `Store`
- [ ] Create `ImplementationBoardLive` (`lib/destila_web/live/implementation_board_live.ex`):
  - Five columns: Todo, In Progress, Review, QA, Done
  - Cards grouped by column from `Store`
- [ ] Add SortableJS hook (`assets/js/hooks/sortable.js`):
  - Initialize SortableJS on each column's card list
  - On drag end: `this.pushEvent("card_moved", {id, from_column, to_column, new_index})`
  - Handle `card_moved` event in LiveView to update `Store` and re-render
- [ ] Card click navigates to `/prompts/:id` (prompt detail page)
- [ ] Install SortableJS: add to `assets/vendor/` or via npm in `assets/`

**Success criteria:** Both boards render with correct columns and seeded cards; cards can be dragged between columns; clicking a card navigates to its detail page.

### Phase 5: Prompt Creation Flow

Build the multi-step prompt creation wizard.

**Tasks:**

- [ ] Create `NewPromptLive` (`lib/destila_web/live/new_prompt_live.ex`):
  - Step 1: Pick workflow type — two selectable cards: "Feature Request" and "Project", each with icon and description
  - Step 2: Link repository — text input for repo URL with "Skip" option
  - Step 3: Create prompt in `Store`, redirect to `/prompts/:id`
- [ ] Track wizard step in LiveView assigns (`@step`)
- [ ] New prompt lands in `crafting` board, `request` column
- [ ] Wire up the "+ Create" button in global header and "+ New Prompt" on Crafting Board to navigate to `/prompts/new`
- [ ] Style: centered card layout, clear step indicator, smooth transitions between steps

**Success criteria:** User can create a new prompt through the 3-step flow; prompt appears on the Crafting Board in the Request column.

### Phase 6: Prompt Detail Page (Chat Workflow)

Build the chat-based prompt refinement interface — the core UX of the app.

**Tasks:**

- [ ] Create `PromptDetailLive` (`lib/destila_web/live/prompt_detail_live.ex`):
  - Header: editable title (inline edit with `phx-blur`), workflow type badge, repo URL, step progress indicator
  - Chat area: scrollable message list + input area at bottom
- [ ] Render messages from `Store.list_messages(prompt_id)`
- [ ] System (AI) messages styled differently from user messages (left-aligned vs right-aligned, different colors)
- [ ] Input types rendered based on the current system message's `input_type`:
  - **Free text:** standard text input with send button
  - **Single-select cards:** horizontally or vertically arranged option cards; clicking one selects it and submits
  - **Multi-select cards:** similar to single-select but with checkboxes; "Confirm" button to submit selections
  - **File upload:** upload button showing a mocked file thumbnail on "upload"
  - **All structured inputs include an "Other" freeform text option**
- [ ] On user response:
  - Save user message to `Store`
  - Advance to next mocked AI message (pre-defined in a workflow script)
  - Auto-scroll chat to bottom
- [ ] Define mocked workflow scripts (`lib/destila/workflows.ex`):
  - **Feature Request workflow** (4 steps):
    - Step 1: "What problem are you solving?" (free text)
    - Step 2: "What type of feature is this?" (single-select: UI Enhancement, API Change, Performance, Infrastructure)
    - Step 3: "Which areas are affected?" (multi-select: Frontend, Backend, Database, DevOps)
    - Step 4: "Any mockups or references?" (file upload)
  - **Project workflow** (3 steps):
    - Step 1: "Describe your project idea" (free text)
    - Step 2: "What's the primary tech stack?" (single-select: Web App, Mobile App, CLI Tool, Library)
    - Step 3: "Which features are in scope for v1?" (multi-select: Auth, Dashboard, API, Admin Panel, Notifications)
- [ ] When all steps complete:
  - Show completion message in chat
  - Move prompt to `done` column on Crafting Board via `Store`
  - Update step progress indicator
- [ ] Moving prompt from Done (crafting) to Implementation Board: for the prototype, add a "Send to Implementation" button that moves the card to `todo` on the Implementation Board

**Success criteria:** User can open a prompt, interact with the chat using all input types, complete the workflow, and see the card move to Done.

### Phase 7: Visual Polish

Refine the UI to achieve the Linear/Notion premium aesthetic.

**Tasks:**

- [ ] Typography: consistent heading hierarchy, appropriate font weights, comfortable line heights
- [ ] Whitespace: generous padding on all containers, spacing between elements
- [ ] Cards: subtle box shadows on hover, smooth border transitions, rounded corners
- [ ] Badges: color-coded workflow type labels (e.g., blue for Feature Request, purple for Project)
- [ ] Progress bars: thin, colored progress indicators on board cards
- [ ] Transitions: smooth page transitions, fade-in for new chat messages
- [ ] Empty states: friendly messages for empty columns ("No prompts yet — create one!")
- [ ] Active nav state: highlight current page in header navigation
- [ ] Login page: centered card with app branding, clean form styling
- [ ] Chat input area: sticky at bottom, clear visual separation from message history

**Success criteria:** The app feels polished and premium, comparable to Linear or Notion in visual quality.

## Acceptance Criteria

### Functional Requirements

- [ ] User can log in with any credentials and see the authenticated dashboard
- [ ] User can log out and return to the login page
- [ ] Dashboard shows accurate previews of both boards with card counts and recent titles
- [ ] Prompt Crafting Board displays 3 columns (Request, Distill, Done) with seeded cards
- [ ] Implementation Board displays 5 columns (Todo, In Progress, Review, QA, Done) with seeded cards
- [ ] Cards show: title, workflow type badge, repo URL (if linked), sub-step progress indicator
- [ ] Cards can be dragged between columns on both boards
- [ ] Clicking a card navigates to its detail page
- [ ] User can create a new prompt via the 3-step flow (type, repo, start)
- [ ] New prompts appear in the Request column on the Crafting Board
- [ ] Prompt detail page shows editable title, workflow badge, repo URL, step progress
- [ ] Chat interface supports free text, single-select, multi-select, and file upload inputs
- [ ] All structured inputs include an "Other" freeform text option
- [ ] Completing all steps moves the prompt to Done on the Crafting Board
- [ ] At least one seeded prompt has a partially completed chat conversation
- [ ] Global header shows: "Destila" link, nav links, Create button, user avatar with logout
- [ ] All navigation paths work (header links, board preview clicks, card clicks, back navigation)

### Non-Functional Requirements

- [ ] Clean, minimal aesthetic matching Linear/Notion style
- [ ] No real database connections or AI API calls
- [ ] Data resets on app restart (in-memory only)
- [ ] App runs with `mix phx.server` after standard setup

## Dependencies & Prerequisites

- Erlang 28.4 and Elixir 1.19.0 (already configured in `mise.toml`)
- Phoenix 1.8 (installed via `mix archive.install hex phx_new`)
- SortableJS (vendored or npm-installed in `assets/`)
- No external services required

## Learnings from Reference Codebase

The existing "Prompter" Go codebase in the repo provides relevant patterns:

1. **Avoid nested anchor tags** — clickable cards with inner clickable elements must use `<div>` + click handlers, not nested `<a>` tags (causes duplicate rendering bugs)
2. **Unified templates for state transitions** — use visual hierarchy (badges, markers) to differentiate states rather than separate page templates
3. **Domain model** — Repository, PromptRequest, Message, Revision structure maps well to this project's data model
4. **HTMX/partial update pattern** — LiveView handles this natively, but the co-located handler+template pattern is worth following

## File Structure

```
destila/
├── lib/
│   ├── destila/
│   │   ├── application.ex          # Supervision tree (add Store)
│   │   ├── store.ex                # GenServer + ETS data store
│   │   ├── seeds.ex                # Seed data module
│   │   └── workflows.ex            # Mocked chat workflow definitions
│   └── destila_web/
│       ├── components/
│       │   ├── core_components.ex   # Phoenix default + custom components
│       │   ├── board_components.ex  # Kanban board/column/card components
│       │   ├── chat_components.ex   # Chat message/input components
│       │   └── layouts/
│       │       ├── root.html.heex   # Global layout with header nav
│       │       └── app.html.heex    # App layout
│       ├── controllers/
│       │   └── session_controller.ex # Login/logout POST handlers
│       ├── live/
│       │   ├── session_live.ex       # Login page
│       │   ├── dashboard_live.ex     # Dashboard with board previews
│       │   ├── crafting_board_live.ex # Prompt Crafting kanban
│       │   ├── implementation_board_live.ex # Implementation kanban
│       │   ├── new_prompt_live.ex    # Prompt creation wizard
│       │   └── prompt_detail_live.ex # Chat workflow detail page
│       ├── plugs/
│       │   └── require_auth.ex       # Mock auth plug
│       └── router.ex                 # Routes
├── assets/
│   └── js/
│       └── hooks/
│           └── sortable.js           # SortableJS LiveView hook
├── mise.toml
└── mix.exs
```

## Open Questions

None blocking — the issue specification is comprehensive. Minor prototype-scope decisions (exact card colors, animation timing, mobile layout) can be made during implementation.

## References

- Issue: https://github.com/esnunes/destila/issues/1
- Phoenix 1.8 docs: https://hexdocs.pm/phoenix/overview.html
- LiveView drag-and-drop with SortableJS: https://fly.io/phoenix-files/liveview-drag-and-drop/
- Reference codebase: `.claude/worktrees/wonderful-grothendieck/` (Go "Prompter" app)
