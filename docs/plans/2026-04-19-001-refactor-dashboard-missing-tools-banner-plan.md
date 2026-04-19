---
title: "refactor: Dashboard missing-tools banner and feature overview"
type: refactor
status: completed
date: 2026-04-19
---

# refactor: Dashboard missing-tools banner and feature overview

## Overview

Replace the current crafting-summary dashboard at `/` with a landing page that serves two purposes:

1. Warn the user about missing required external tools on their `PATH` (`claude`, `tmux`, `ffmpeg`, `agent-browser`) via a non-dismissible informational banner with a "Recheck" button.
2. Orient users toward the product by rendering four plain Tailwind call-to-action cards: **Crafting Board**, **Drafts**, **New Workflow**, **Projects**.

The change removes the existing hero/live-activity/PubSub-driven summary and adds a single new context module `Destila.Deps` that owns the tool metadata and wraps `System.find_executable/1` per tool.

## Problem Frame

The current `DestilaWeb.DashboardLive` duplicates the crafting board's summary with a live-updating PubSub subscription (`"store:updates"`). That repeats content that already exists elsewhere in the app and makes the landing page less useful to new users who don't yet know which features exist.

Separately, Destila depends on four external CLI tools that must be on the user's `PATH` for the core flows to work (Claude Code runner, tmux-based terminals, media tooling, and the agent browser). If any is missing, the user can currently only discover this by triggering a feature that crashes downstream. A landing-page banner gives the user a single place to see which tools are missing and how to install them, without hiding any UI.

## Requirements Trace

- **R1.** Dashboard at `/` detects the four required tools on mount (no cache) and renders a banner iff at least one is missing.
- **R2.** The banner lists each missing tool with (a) a short note on what the tool is used for, (b) an inline shell install command with a copy affordance, and (c) a link to the official install docs.
- **R3.** The banner is purely informational — no dismiss control, no `disabled` state propagated to any CTA.
- **R4.** A "Recheck" button re-runs detection; still-missing tools remain listed.
- **R5.** The page renders four CTA cards (Crafting Board, Drafts, New Workflow, Projects), each with title + short description + `<.link navigate={…}>` to an existing route.
- **R6.** The current crafting-summary block, the `store:updates` PubSub subscription, and the `crafting_prompts`/`crafting_summary` assigns are removed.
- **R7.** The dashboard no longer shows a welcome hero, live counts, or recent-activity lists.
- **R8.** A `Destila.Deps` context module owns the required-tools list and exposes a single check function returning per-tool status; no caching between invocations.
- **R9.** `:mimic` is added as a `test`-only dependency and used in tests to stub `Destila.Deps`.
- **R10.** Gherkin coverage at `features/dashboard.feature` with matching LiveView tests at `test/destila_web/live/dashboard_live_test.exs`; every test carries `@tag feature: "dashboard", scenario: "..."`.
- **R11.** `mix precommit` passes.

## Scope Boundaries

**In scope:**
- New `Destila.Deps` context + module-level doc and metadata.
- Full rewrite of `lib/destila_web/live/dashboard_live.ex`.
- Banner and CTA cards as local function components inside `DashboardLive` (no promotion to `core_components`).
- `:mimic` added to `mix.exs` deps and wired into `test/test_helper.exs` / tests.
- `features/dashboard.feature` + `test/destila_web/live/dashboard_live_test.exs`.

**Explicit non-goals:**
- No new routes or route changes in `DestilaWeb.Router`.
- No schema changes or migrations.
- No PubSub subscriptions on the dashboard.
- No promotion of the banner or card components into `core_components` (per brief: wait for a second use case).
- No client-side dismiss/hide behaviour, no `disabled` state on any CTA when tools are missing.
- No caching layer for tool detection (no ETS, no `:persistent_term`, no process state).
- No new install-automation (the banner only shows commands; it does not run them).
- No removal of existing tool-missing error handling elsewhere (e.g., tmux/claude runtime checks) — this is additive.

## Context & Research

### Relevant Code and Patterns

- **Current dashboard** — `lib/destila_web/live/dashboard_live.ex` is the full file to rewrite. It currently subscribes to `"store:updates"`, assigns `:crafting_prompts` and `:crafting_summary`, and renders a single crafting-board card using daisyUI `card`/`card-body`/`card-title` classes. These classes must be replaced with hand-written Tailwind per the project's "avoid daisyUI, write our own components" guideline in `CLAUDE.md`.
- **Layout wrapper** — `lib/destila_web/components/layouts.ex:10-22` defines `<Layouts.app flash={@flash} page_title={...}>`. All dashboard content must live inside it. The layout already reserves 16rem / 60rem of sidebar offset via `ml-16 sidebar-open:ml-60`.
- **Sidebar active state** — `lib/destila_web/components/layouts.ex:44-76`. The sidebar uses `active={@page_title == "..."}` but the dashboard has no sidebar entry today; the rewritten dashboard keeps `page_title: "Dashboard"` so no sidebar item becomes active, matching current behaviour.
- **Existing feature routes (targets for CTAs)** — `lib/destila_web/router.ex:40-48`:
  - `/crafting` → `CraftingBoardLive`
  - `/drafts` → `DraftsBoardLive`
  - `/workflows` → `CreateSessionLive`
  - `/projects` → `ProjectsLive`
- **Icon component** — `lib/destila_web/components/core_components.ex:445` exposes `<.icon name="hero-..."/>`. Per `CLAUDE.md`, **never** use the `Heroicons` module directly; always use `<.icon>`.
- **Navigation component** — `CLAUDE.md` mandates `<.link navigate={...}>` (not `live_redirect`) for CTAs.
- **Phoenix 1.8 layout rules** — `CLAUDE.md` requires `<Layouts.app flash={@flash} ...>` at the top of every LiveView template and forbids calling `<.flash_group>` outside `layouts.ex`.
- **BDD test linking** — `test/destila_web/live/drafts_board_live_test.exs:1-14` demonstrates the canonical shape: `@moduledoc "...Feature: features/drafts_board.feature"` + module-level `@feature "drafts_board"` + per-test `@tag feature: @feature, scenario: "..."`.
- **ConnCase + sandbox** — `test/support/conn_case.ex` runs every test with the SQL sandbox; the dashboard tests won't insert data but still use the same case module for consistency.
- **Existing feature files** — `features/drafts_board.feature`, `features/crafting_board.feature`. The new `features/dashboard.feature` follows the same header style (`Feature:` + short description paragraph + grouped scenarios with `# ---` section separators).
- **No existing dashboard tests** — `test/destila_web/live/` has no `dashboard_live_test.exs` today; this plan creates the first one.
- **PubSub helper (used elsewhere, removed here)** — `lib/destila/pub_sub_helper.ex` and `lib/destila/workflows.ex` broadcast `:workflow_session_created`/`:workflow_session_updated` on `"store:updates"`. Removing the dashboard's subscription does not affect other subscribers.

### Institutional Learnings

`docs/solutions/` does not exist in this repo. Adjacent prior plans consulted:

- `docs/plans/2026-04-18-001-feat-drafts-board-plan.md` — canonical shape for a new feature with a feature file, BDD tags, and local function components.
- `docs/plans/2026-04-16-002-feat-project-setup-command-plan.md` and `docs/plans/2026-04-14-001-feat-project-service-management-plan.md` — both already shell out to / invoke external tools (tmux, claude) but do not pre-check their presence. A Deps context centralizes that.

### External References

- **`System.find_executable/1`** — Elixir stdlib; returns the absolute path to an executable on `$PATH` or `nil`. Exactly what's needed per tool and already available; no new dependency required for detection.
- **`:mimic`** — https://hex.pm/packages/mimic. Concurrent-safe, module-level mocking library. Used here to stub `Destila.Deps.check/0` per test without monkey-patching `System.find_executable/1` globally. Must be added as `only: :test` and `copy/1`'d once in `test/test_helper.exs` so tests can call `Mimic.stub/3` on the module.

## Key Technical Decisions

- **One `Destila.Deps` context, one public function** — the brief is explicit: "a single check function that wraps `System.find_executable/1` per tool and returns each tool's status." Shape the public API as `Destila.Deps.check/0 :: [%{name: binary(), display_name: binary(), purpose: binary(), install_command: binary(), docs_url: binary(), available?: boolean()}]`. Tool metadata is defined as a module attribute (`@required_tools`) inside `Destila.Deps` so it is a single source of truth and trivially stubbable.
- **No caching** — the brief says "No caching. The LiveView calls it on mount and on the recheck event." Keep `check/0` pure: iterate `@required_tools`, call `System.find_executable/1`, return the list. Four `find_executable` calls per mount / recheck is negligible.
- **Banner and cards as private function components in `DashboardLive`** — do not promote to `core_components` until a second use case appears (brief). Use Phoenix function components (`attr :tools, :list, required: true` etc.) rather than ad-hoc helper functions so the markup stays self-documenting.
- **Render banner iff at least one tool is missing** — compute `missing = Enum.reject(tools, & &1.available?)` in `mount`/recheck and assign it. Template conditional: `<%= if @missing_tools != [] do %> … <% end %>`. This guarantees the empty-missing-list case renders nothing, per the constraint.
- **Copy affordance = inline `phx-hook` colocated script** — per `CLAUDE.md`, never use inline `<script>`; use `:type={Phoenix.LiveView.ColocatedHook}` with a `.CopyToClipboard` hook. The hook attaches a click handler that writes the parent element's `data-copy` attribute to `navigator.clipboard.writeText` and briefly toggles a "Copied" label. `phx-update="ignore"` is required because the hook owns the "Copied" DOM state.
- **Recheck = a `phx-click` button** — `<.button phx-click="recheck">Recheck</.button>`. The handler re-invokes `Destila.Deps.check/0` and re-assigns `:missing_tools`. No streams needed; the banner is a small static list, not a collection.
- **`:mimic` over custom behavior + injection** — stubbing `Destila.Deps` directly is simpler than introducing a behaviour / injection seam for a single call site. `:mimic` requires `Mimic.copy(Destila.Deps)` in `test_helper.exs` and `use Mimic` in the test module, then `Destila.Deps |> stub(:check, fn -> [...] end)` per test.
- **No default priority for banner visibility** — no `currentScope`-style flag; visibility is derived purely from assigns.
- **Banner is non-dismissible at the template level** — simply do not render a dismiss control. No JS state, no cookie, no LiveView event.
- **CTA card destinations match the existing router exactly** — `~p"/crafting"`, `~p"/drafts"`, `~p"/workflows"`, `~p"/projects"`. Use verified routes so any typo becomes a compile error.

## Open Questions

### Resolved During Planning

- **Which tools belong in the required list?** — `claude`, `tmux`, `ffmpeg`, `agent-browser` (per brief). No other tools added speculatively.
- **Where does the tool metadata live?** — inside `Destila.Deps` as a module attribute. Keeping it colocated with the check function is simpler than a separate config file and there is no runtime configurability requirement.
- **How is the banner suppressed when all tools are present?** — the LiveView assigns `missing_tools` (empty list when nothing is missing) and the template renders the banner block only when `@missing_tools != []`.
- **Does `:mimic` need to be `copy/1`'d globally?** — yes. `test/test_helper.exs` calls `Mimic.copy(Destila.Deps)` once so any test module `use Mimic` can stub it.
- **Does removing the `"store:updates"` subscription break anything?** — no. The subscription is only used to refresh `:crafting_prompts`, which is being removed. Other subscribers to `"store:updates"` (e.g., `CraftingBoardLive`, `ProjectsLive`) are untouched.

### Deferred to Implementation

- Exact copy for each tool's `purpose` string and `docs_url`. Candidates:
  - `claude` → "Claude Code CLI — runs AI sessions inside Destila." Docs: https://docs.claude.com/en/docs/claude-code
  - `tmux` → "Terminal multiplexer used to host long-running workflow terminals." Docs: https://github.com/tmux/tmux/wiki/Installing
  - `ffmpeg` → "Media processing for workflow video artifacts." Docs: https://ffmpeg.org/download.html
  - `agent-browser` → "Headless browser automation used by the browser testing skills." Docs: (to be chosen from the project's own docs or the upstream CLI page).
  Finalize the exact strings and docs URLs at implementation time; the structure is fixed by the context API.
- Exact Tailwind spacing/typography for the CTA cards — plan specifies "plain Tailwind cards" but the final spacing/typography tokens are a visual-polish concern best finalized when the cards are rendered. Card contract: wrapping `<.link navigate={…}>`, title + description stacked, hover state via utility classes only (no `@apply`).
- Whether the copy-to-clipboard hook shows a persistent "Copied" indicator or just a transient tooltip. Decide during implementation; both satisfy R2's "copy affordance" language.

## Implementation Units

- [ ] **Unit 1: Add `:mimic` as a test-only dependency**

  **Goal:** Make `:mimic` available for stubbing `Destila.Deps` in tests.

  **Requirements:** R9

  **Dependencies:** None

  **Files:**
  - Modify: `mix.exs`
  - Modify: `test/test_helper.exs`
  - Modify: `mix.lock` (implicit via `mix deps.get`)

  **Approach:**
  - Add `{:mimic, "~> 1.7", only: :test}` to the deps list in `mix.exs`. Pin on the current `1.x` line; confirm the exact version at implementation time via `mix hex.info mimic`.
  - In `test/test_helper.exs`, after `ExUnit.start()` and before the existing `Ecto.Adapters.SQL.Sandbox.mode(...)` call, add `Mimic.copy(Destila.Deps)`. Copying is required so per-test `stub/2` calls work.
  - `Mimic.copy/1` must reference a module that exists, so this Unit must land **after** Unit 2 (or in the same commit). Order the work so `Destila.Deps` exists before `Mimic.copy(Destila.Deps)` compiles. In practice: implement Unit 2 first, then Unit 1.

  **Patterns to follow:**
  - `mix.exs:42-71` — existing deps block; append with same style (`{:pkg, "~> x.y", only: :test}`).
  - `test/test_helper.exs` — keep the existing three lines intact; insert `Mimic.copy(Destila.Deps)` as the new third line.

  **Test scenarios:**
  - Test expectation: none — scaffolding. Validated indirectly by Unit 4's tests stubbing `Destila.Deps` successfully.

  **Verification:**
  - `mix deps.get` succeeds and adds `:mimic` to `mix.lock`.
  - `mix compile` succeeds.
  - `mix test` still runs (even with no Deps usage yet) and the new `Mimic.copy/1` line does not raise.

- [ ] **Unit 2: Add `Destila.Deps` context**

  **Goal:** Create a single-purpose module that owns the required-tools list and exposes `check/0` returning per-tool status.

  **Requirements:** R1, R2, R8

  **Dependencies:** None

  **Files:**
  - Create: `lib/destila/deps.ex`
  - Test: `test/destila/deps_test.exs`

  **Approach:**
  - Define `@required_tools` as a compile-time list of maps with keys `:name` (binary, used for `find_executable`), `:display_name` (human label shown in the banner), `:purpose` (one-line description), `:install_command` (inline shell command like `brew install ffmpeg`), `:docs_url` (official install docs).
  - Public API: `check/0 :: [%{... + available?: boolean()}]`. Implementation: `Enum.map(@required_tools, fn t -> Map.put(t, :available?, System.find_executable(t.name) != nil) end)`.
  - Keep the module free of Phoenix or LiveView concerns so it can be called from anywhere; `DashboardLive` is the only caller today.
  - Do **not** add a `missing/0` helper — the LiveView can derive missing tools via `Enum.reject/2` on the result. Avoid premature abstraction.
  - Do **not** add caching. Every call shells out to `System.find_executable/1` four times.

  **Patterns to follow:**
  - `lib/destila/projects.ex:1-30` — lean context module style: `defmodule Destila.Projects do`, a short `@moduledoc` describing the boundary, a handful of public functions, no macros.
  - Keep the module attribute order: `@moduledoc`, `@required_tools`, then functions.

  **Test scenarios:**
  - **Happy path:** `Destila.Deps.check/0` returns a list of maps with the expected metadata keys for each of the four tools.
  - **Happy path:** each returned map has `available?: boolean()`; using a test-only stub path or a known-present tool (e.g., `sh`, verified via `System.find_executable/1`), confirm `true`; using a guaranteed-absent name (a random UUID string) confirm `false`. Implementation approach: parametrize the module attribute via a test that calls `check/0` without stubbing and only asserts structural shape, and a unit-style test that exercises the `available?` derivation by wrapping `System.find_executable/1` in a thin private function — OR simply assert the list shape and move the `available?` semantics to an integration test once `:mimic` is in place.
  - **Edge case:** the `@required_tools` list length is exactly 4 and its `:name` values are `["claude", "tmux", "ffmpeg", "agent-browser"]`. This prevents silently adding/removing tools without updating the plan.
  - Test expectation: **do not mock `System.find_executable/1`** in the Deps unit test — mocking the stdlib is brittle. Assert on structural shape and on the hard-coded tool names; behavioural correctness is asserted in Unit 4 where `Destila.Deps` itself is stubbed.

  **Verification:**
  - `mix test test/destila/deps_test.exs` passes.
  - Calling `Destila.Deps.check/0` from IEx returns a four-element list with the expected tool names.

- [ ] **Unit 3: Rewrite `DestilaWeb.DashboardLive`**

  **Goal:** Replace the crafting-summary dashboard with a missing-tools banner + feature-overview CTA cards.

  **Requirements:** R1, R2, R3, R4, R5, R6, R7

  **Dependencies:** Unit 2 (`Destila.Deps` must exist)

  **Files:**
  - Modify: `lib/destila_web/live/dashboard_live.ex`
  - Test: exercised via Unit 4's LiveView tests

  **Approach:**
  - Remove `import DestilaWeb.BoardComponents`, the `Phoenix.PubSub.subscribe(...)` call in `mount/3`, the `list_workflow_sessions()` call, all `handle_info/2` clauses, `crafting_summary/1`, `classify_crafting_prompt/1`, `section_label/1`, and the existing `render/1` body.
  - New `mount/3`:
    - `{:ok, socket |> assign(:page_title, "Dashboard") |> assign_tool_status()}`
    - where `assign_tool_status/1` calls `Destila.Deps.check/0`, derives `missing = Enum.reject(tools, & &1.available?)`, and assigns both `:tools` (for potential future use) and `:missing_tools`.
  - Add `handle_event("recheck", _params, socket)` that calls `assign_tool_status/1` and returns `{:noreply, socket}`.
  - Render tree (directional, not prescriptive):
    - `<Layouts.app flash={@flash} page_title={@page_title}>`
    - outer wrapper: `p-6 lg:p-8 max-w-6xl mx-auto space-y-8`
    - `<%= if @missing_tools != [] do %>` → private component `missing_tools_banner/1` with attrs `tools: list, id: "missing-tools-banner"`.
    - always-on feature-overview block → private component `feature_overview/1` that renders four `feature_card/1` components.
  - Private function components (inside the same module, `def` or `defp` depending on style; Phoenix allows `defp` for function components used locally):
    - `missing_tools_banner/1`: renders a colored alert surface (hand-written Tailwind — `rounded-lg border border-amber-300 bg-amber-50 p-4` etc., no `@apply`) with heading "Some required tools are missing", a `<ul>` of tools (each row: display_name + purpose + `<code>`-styled install command with a `phx-hook=".CopyToClipboard"` button + docs link), and a "Recheck" button (`phx-click="recheck"`, DOM id `recheck-tools`).
    - `feature_card/1`: `attr :title, :description, :navigate, :icon, :id`. Renders `<.link navigate={@navigate} id={@id} class="...">` with a title, description, and subtle hover states. Must remain enabled even when tools are missing (no disabled state, no guard).
    - `feature_overview/1`: a grid (`grid grid-cols-1 md:grid-cols-2 gap-4`) of four `feature_card/1` calls hard-coded to `/crafting`, `/drafts`, `/workflows`, `/projects`.
  - Copy-to-clipboard colocated hook:

    ```heex
    <button phx-hook=".CopyToClipboard" phx-update="ignore" id={"copy-" <> tool.name} data-copy={tool.install_command}>
      Copy
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            navigator.clipboard.writeText(this.el.dataset.copy)
          })
        }
      }
    </script>
    ```

    (Directional guidance only; exact UX for the "Copied" feedback finalized in implementation per "Deferred to Implementation".)
  - DOM ids to add (needed by tests):
    - `missing-tools-banner` on the banner wrapper
    - `tool-<name>` on each missing-tool `<li>` (e.g., `tool-ffmpeg`)
    - `recheck-tools` on the recheck button
    - `feature-card-crafting`, `feature-card-drafts`, `feature-card-new-workflow`, `feature-card-projects` on each CTA link
    - `feature-overview` on the CTA grid container
  - Do **not** call `<.flash_group>` anywhere in the template (forbidden by `CLAUDE.md`).
  - No `@apply` anywhere.
  - No `Heroicons.*` calls — only `<.icon name="hero-...">`.

  **Patterns to follow:**
  - `lib/destila_web/live/drafts_board_live.ex` — current in-repo LiveView style (assign-driven, no inline scripts, small template).
  - `lib/destila_web/components/layouts.ex:10-22` — the `<Layouts.app>` wrapper shape.
  - `lib/destila_web/components/core_components.ex:51-130` — hand-written Tailwind component idioms (list-syntax `class` attributes, `attr :rest, :global`).

  **Test scenarios:**
  - Covered in Unit 4 (LiveView tests). This unit itself has no isolated test file; its behaviour is validated end-to-end.

  **Verification:**
  - `mix compile --warnings-as-errors` succeeds.
  - Visiting `/` in dev renders a dashboard with no crash, no daisyUI `card` classes, and — if any required tool is genuinely absent on the dev host — a banner listing it.
  - `grep -r "store:updates" lib/destila_web/live/dashboard_live.ex` returns nothing.
  - `grep -r "crafting_prompts\|crafting_summary\|section_label" lib/destila_web/live/dashboard_live.ex` returns nothing.

- [ ] **Unit 4: Gherkin feature + LiveView tests**

  **Goal:** Add `features/dashboard.feature` with the scenarios from the brief and a matching LiveView test module that stubs `Destila.Deps` via `:mimic`.

  **Requirements:** R10, R11

  **Dependencies:** Unit 1 (`:mimic`), Unit 2 (`Destila.Deps`), Unit 3 (LiveView rewrite)

  **Files:**
  - Create: `features/dashboard.feature`
  - Create: `test/destila_web/live/dashboard_live_test.exs`

  **Approach:**
  - `features/dashboard.feature`: copy the Gherkin block from the brief verbatim, with the file-opening header comment and `# --- Missing-tools banner ---` / `# --- Feature overview ---` section separators preserved.
  - `test/destila_web/live/dashboard_live_test.exs`:
    - `@moduledoc "...Feature: features/dashboard.feature"`.
    - `use DestilaWeb.ConnCase, async: false` (consistent with `drafts_board_live_test.exs`).
    - `use Mimic` at module top so `stub/2` is available in every test.
    - Helper `stub_tools/1` that takes a list of `{name, available?}` tuples and stubs `Destila.Deps.check/0` to return the matching maps. This keeps each test readable.
    - One `describe` block per brief section (`"Missing-tools banner"` and `"Feature overview"`), each test tagged with `@tag feature: "dashboard", scenario: "<exact scenario text>"`.
    - Assertions use `has_element?/2` + `element/2` against the DOM ids listed in Unit 3, never against raw text content (per `CLAUDE.md`).
    - Navigation tests use `render_click/2` on the CTA link element, then assert on the resulting LiveView redirect via `assert_redirect/2` (or `assert {:error, {:live_redirect, %{to: "/crafting"}}} = ...`) rather than asserting on post-navigation HTML.
  - Recheck test: stub `Destila.Deps.check/0` twice — first returning `ffmpeg` as missing, then stubbing again with `ffmpeg` available, and verifying the banner updates after clicking `#recheck-tools`. `Mimic.stub/3` supports re-stubbing within a single test.

  **Patterns to follow:**
  - `test/destila_web/live/drafts_board_live_test.exs:1-40` — module doc, `@feature` attribute, test setup style.
  - Mimic usage idiom: `Destila.Deps |> stub(:check, fn -> [...] end)`.

  **Test scenarios:**
  The following scenarios from `features/dashboard.feature` must each have at least one `@tag`-linked test:
  - **Happy path:** "Banner is hidden when all required tools are available" — stub all four as available, assert `refute has_element?(view, "#missing-tools-banner")`.
  - **Happy path:** "Banner lists each missing tool with an install hint" — stub `ffmpeg` + `agent-browser` missing; assert `has_element?(view, "#missing-tools-banner")`, `has_element?(view, "#tool-ffmpeg")`, `has_element?(view, "#tool-agent-browser")`, `refute has_element?(view, "#tool-claude")`, `refute has_element?(view, "#tool-tmux")`, and the banner row includes a copy button (`#copy-ffmpeg`) and a docs link (`a[href]` inside the row).
  - **Edge case:** "Banner is informational and does not disable any feature" — stub `claude` missing; assert banner is present AND all four CTA links remain present with correct `href`s (no `disabled` attribute, no `aria-disabled="true"`).
  - **Edge case:** "Banner cannot be dismissed" — with a missing tool stubbed, assert the banner has no element matching `[phx-click*="dismiss"]`, no `button[aria-label*="dismiss"]`, and no `button[aria-label*="close"]`.
  - **Integration:** "Recheck refreshes the banner after I install a tool" — stub missing `ffmpeg`, mount, assert `#tool-ffmpeg` present; re-stub with all tools available; click `#recheck-tools`; assert banner absent.
  - **Integration:** "Recheck still shows tools that remain missing" — stub `ffmpeg` + `agent-browser` missing; click recheck without re-stubbing; assert both rows still present.
  - **Happy path:** "Dashboard shows call-to-action cards for the main features" — stub all tools available; assert `#feature-card-crafting`, `#feature-card-drafts`, `#feature-card-new-workflow`, `#feature-card-projects` present and each contains non-empty descriptive text.
  - **Integration:** "Crafting Board CTA navigates to the crafting board" — click `#feature-card-crafting`, assert `assert_redirect(view, ~p"/crafting")` (or the LiveView navigation equivalent).
  - **Integration:** "Drafts CTA navigates to the drafts board" — same shape → `~p"/drafts"`.
  - **Integration:** "New Workflow CTA navigates to workflow creation" — same shape → `~p"/workflows"`.
  - **Integration:** "Projects CTA navigates to the projects page" — same shape → `~p"/projects"`.
  - **Edge case:** "Dashboard does not show live activity, stats, or a hero block" — assert `refute has_element?(view, "#hero")`, and `refute view |> render() =~ "Waiting for You"` (the old `section_label`), and `refute view |> render() =~ "Processing"` used as a section header. Where such content was previously present, test against the absence of the current crafting-summary DOM ids rather than free text to avoid false positives.

  **Verification:**
  - `mix test --only feature:dashboard` runs every linked test and passes.
  - `mix test test/destila_web/live/dashboard_live_test.exs` passes.
  - Every scenario in `features/dashboard.feature` has at least one `@tag` link in the test module.
  - `mix precommit` passes end-to-end.

## System-Wide Impact

- **Interaction graph:**
  - `DashboardLive` stops subscribing to `"store:updates"`. Other subscribers (`CraftingBoardLive`, `ProjectsLive`, `DraftsBoardLive`) are untouched; the PubSub channel and event atoms remain.
  - `Destila.Deps.check/0` is a new public API surface but a narrow one. Only `DashboardLive` calls it today.
- **Error propagation:**
  - `System.find_executable/1` cannot raise for well-formed binaries; no error-handling layer needed.
  - Clipboard hook failures (e.g., `navigator.clipboard` unavailable in insecure contexts) silently no-op. Intentional — copy is an affordance, not a guarantee.
- **State lifecycle risks:**
  - No persistent state introduced. No migration. No cache invalidation surface.
  - Re-stubbing via `:mimic` is scoped to a single test; no global test pollution.
- **API surface parity:** No changes to router, schemas, or existing contexts. The `Destila.Deps` module is additive.
- **Integration coverage:** The recheck flow is the one place where a unit test alone wouldn't prove the behaviour — Unit 4's integration test covers it by re-stubbing between clicks.
- **Unchanged invariants:**
  - `/` remains the landing route in `DestilaWeb.Router`.
  - All four CTA routes (`/crafting`, `/drafts`, `/workflows`, `/projects`) are unchanged.
  - `"store:updates"` PubSub semantics are unchanged — the dashboard simply stops listening.
  - `<Layouts.app>` wrapper, sidebar, and flash-group behaviour are unchanged.
  - `mix precommit` alias (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`) is unchanged and is the acceptance gate.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Tests that stub `Destila.Deps` could bleed state across tests and cause flakes. | Use `:mimic`'s per-test stub lifecycle (stubs are automatically reset between tests); `async: false` matches the existing LiveView tests; `Mimic.copy/1` is called exactly once in `test/test_helper.exs`. |
| `navigator.clipboard` is unavailable in some browser contexts (HTTP, older browsers), breaking the "copy" affordance. | Copy is an affordance, not a requirement — the install command is visible on screen regardless. The hook silently no-ops on failure. Document this caveat in the hook if useful. |
| A future contributor adds a tool to `@required_tools` without updating the banner UI assumptions (e.g., a tool with no install command). | Unit 2's test asserting the exact four tool names catches accidental additions and forces a deliberate test update. |
| The LiveView navigation assertions in Unit 4 depend on `assert_redirect` semantics that differ between `live_redirect` and `navigate`. | Use `<.link navigate={...}>` consistently and follow the `drafts_board_live_test.exs` precedent for assertion shape. |
| Removing the `"store:updates"` subscription could be interpreted as a regression if a user expected live activity on `/`. | Explicitly called out as a non-goal in the brief and in this plan's Scope Boundaries. Documented in the commit message. |
| `:mimic` version drift (e.g., a breaking release) could break tests on future `mix deps.get`. | Pin to the current `~> 1.x` line at add-time; record the resolved version in `mix.lock`. |

## Documentation / Operational Notes

- No user-facing docs beyond the banner copy itself.
- No rollout, migration, or monitoring concerns — change is pure UI + one new pure context function.
- Commit as a single PR ordered: Unit 2 → Unit 1 → Unit 3 → Unit 4 (so `Mimic.copy(Destila.Deps)` in `test_helper.exs` compiles at every intermediate commit).

## Sources & References

- Brief: user prompt (inline, no origin requirements doc).
- Related code:
  - `lib/destila_web/live/dashboard_live.ex` (rewrite target)
  - `lib/destila_web/router.ex` (CTA route targets)
  - `lib/destila_web/components/layouts.ex` (layout contract)
  - `lib/destila_web/components/core_components.ex` (`<.icon>`, `<.button>`)
  - `lib/destila/projects.ex` (context module style reference)
  - `test/destila_web/live/drafts_board_live_test.exs` (BDD test shape)
  - `test/support/conn_case.ex` (test case module)
  - `features/drafts_board.feature` (feature file style reference)
- Related plans:
  - `docs/plans/2026-04-18-001-feat-drafts-board-plan.md`
  - `docs/plans/2026-04-16-002-feat-project-setup-command-plan.md`
- External docs:
  - Elixir `System.find_executable/1` — https://hexdocs.pm/elixir/System.html#find_executable/1
  - `:mimic` — https://hexdocs.pm/mimic/
  - Phoenix colocated hooks — https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.ColocatedHook.html
