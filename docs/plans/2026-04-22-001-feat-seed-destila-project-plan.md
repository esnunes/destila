---
title: "feat: Seed destila project on database setup"
type: feat
status: active
date: 2026-04-22
---

# feat: Seed destila project on database setup

## Overview

Add a database seed that automatically creates a `destila` project row whenever
the application's database is set up, so a freshly provisioned environment
already has the dogfooding project configured and ready to run.

## Problem Frame

A fresh checkout of this codebase lands an empty `projects` table after `mix
setup` / `mix ecto.setup`. Developers then have to manually create the
`destila` project through the UI before they can exercise any workflow that
operates on a project (chat, sessions, phase execution). That is friction on
every clean environment.

The `projects` table supports the full seed attribute set today
(`name`, `git_repo_url`, `setup_command`, `run_command`, `service_env_var`),
and the project currently has no `priv/repo/seeds.exs` file and no `run
priv/repo/seeds.exs` step wired into the `ecto.setup` alias. Both gaps need to
be closed together for the seed to actually run on fresh setup.

## Requirements Trace

- R1. A `destila` project row exists in the database after a clean
  `mix setup` / `mix ecto.setup` run, with the exact attributes:
  - `name: "destila"`
  - `git_repo_url: "https://github.com/esnunes/destila"`
  - `setup_command: "mise trust -y && mix setup"`
  - `run_command: "elixir --sname destila-PORT -S mix phx.server"`
  - `service_env_var: "PORT"`
- R2. Running the seed repeatedly must not produce duplicate rows or crash
  (idempotent: a second run is a no-op, a modified manual row is not silently
  overwritten).
- R3. The seed must be triggered from the standard setup flow
  (`mix setup` / `mix ecto.setup`) without requiring a separate command.
- R4. The seed must pass all existing `Destila.Projects.Project` changeset
  validations (uppercase `service_env_var`, allowed scheme on `git_repo_url`,
  at least one of `git_repo_url`/`local_folder` provided).

## Scope Boundaries

- **In scope:** creating `priv/repo/seeds.exs`, seeding the single `destila`
  project, wiring it into the `ecto.setup` alias.
- **Out of scope:** seeding users, sessions, messages, drafts, workflows, or
  any other domain object.
- **Out of scope:** environment-aware seed branching (prod vs. dev vs. test).
  This app is currently a single-environment dev tool — all envs get the same
  seed behavior, and the test environment does not run `ecto.setup` seeds
  (see Key Technical Decisions).
- **Out of scope:** changing `Destila.Projects.Project` schema, validations,
  or `Destila.Projects` context API.
- **Out of scope:** moving the setup command, run command, or env var into
  any kind of config/constant. They live inline in the seed file.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/projects/project.ex` — Ecto schema and changeset for projects.
  Enforces `validate_required([:name])`, at-least-one-location
  (`git_repo_url` or `local_folder`), git scheme allow-list
  (`https://`, `http://`, `ssh://`, `git://`), and `service_env_var` format
  (uppercase, not in `@denied_env_vars`). `PORT` is not in the denied list
  and matches `^[A-Z][A-Z0-9_]*$`, so it passes validation.
- `lib/destila/projects.ex` — context module with `create_project/1` (inserts
  through the changeset and broadcasts `:project_created` on success) and
  `list_projects/0` (active projects only). No built-in upsert or `by_name`
  finder — idempotency has to be handled at the seed level.
- `mix.exs` — `ecto.setup` alias currently runs only
  `ecto.create --quiet` and `ecto.migrate --quiet`. The `test` alias does the
  same but then runs `test` directly, so a seed added to `ecto.setup` would
  not run in the test environment (which is the desired behavior — test runs
  use factories/fixtures, not seeded rows).
- `priv/repo/` — no existing `seeds.exs` file. This is the standard Phoenix
  location for it; `mix run priv/repo/seeds.exs` is the conventional hook.

### Institutional Learnings

- None specific to seeding under `docs/solutions/`. The codebase is
  small enough and the change is low-risk enough that no prior-art lookup is
  needed.

### External References

- Not used. Phoenix's default seeds.exs pattern is well-established and
  directly applicable here.

## Key Technical Decisions

- **Use `Destila.Projects.create_project/1`, not direct `Repo.insert`.**
  This routes the seed through the same changeset validations the UI uses,
  so any future validation change is honored automatically. The
  `:project_created` broadcast during seeding is harmless because no
  LiveView processes are subscribed at seed time (seeds run in a one-shot
  `mix run` context, not the running server).
- **Idempotency via name lookup, not upsert.** Query for an existing project
  where `name == "destila"` before inserting. If one exists, log and skip.
  This preserves any manual edits a developer has made to the row (e.g.
  changed `run_command` during debugging) instead of silently overwriting
  them. SQLite + Ecto `on_conflict` would require a unique index on `name`,
  which is a schema change outside this plan's scope.
- **Wire the seed into `ecto.setup`, not `setup`.** The top-level `setup`
  alias calls `ecto.setup`, so adding `run priv/repo/seeds.exs` to
  `ecto.setup` automatically covers `mix setup`, `mix ecto.setup`, and
  `mix ecto.reset` (which calls `ecto.drop` + `ecto.setup`). The `test`
  alias runs `ecto.create` + `ecto.migrate` directly (not through
  `ecto.setup`), so adding the seed step there is not needed and not
  desired — tests should rely on per-test setup, not global seeds.
- **Log outcome from the seed file.** Use `IO.puts/1` to print whether the
  project was created or already existed. This gives the developer
  immediate feedback during `mix setup` without introducing any real
  logging dependency.
- **Inline attribute map.** A single `%{...}` literal in `seeds.exs` is
  clearer than extracting a helper or module constant for one row. If more
  seed data is ever added, the file can be restructured at that time.

## Open Questions

### Resolved During Planning

- **Should the seed run in the test environment?** No. The test alias in
  `mix.exs` runs `ecto.create --quiet`, `ecto.migrate --quiet`, `test`
  directly — it does not go through `ecto.setup` — so adding the seed to
  `ecto.setup` leaves test behavior untouched, which is what we want.
- **Should we overwrite an existing row or leave it alone?** Leave it
  alone. Preserving manual edits is more valuable than enforcing exact
  attribute values on every run; the primary failure mode this seed guards
  against is "table is empty on fresh setup", not "table drifted from
  spec".
- **Use `Projects.create_project/1` or `Repo.insert` directly?** Use the
  context function so validations and broadcasts stay consistent with the
  rest of the app.

### Deferred to Implementation

- None. Every planning-time question has a concrete answer above.

## Implementation Units

- [ ] **Unit 1: Create idempotent seed file for the destila project**

**Goal:** Add `priv/repo/seeds.exs` that inserts the `destila` project when
it does not already exist and is a no-op when it does.

**Requirements:** R1, R2, R4

**Dependencies:** None.

**Files:**
- Create: `priv/repo/seeds.exs`

**Approach:**
- Look up an existing project with `name == "destila"` via an Ecto query
  on `Destila.Projects.Project` scoped through `Destila.Repo`
  (context has no `get_by_name`, so a one-line query is cleaner than
  adding a public API just for seeding).
- If none exists, call `Destila.Projects.create_project/1` with the exact
  attribute map from R1.
- Pattern-match on the `{:ok, _} | {:error, changeset}` return: on `:ok`,
  `IO.puts` a short "seeded destila project" message; on `:error`, raise
  via `Mix.raise/1` so `mix setup` fails loudly rather than silently
  producing a broken environment.
- If a project already exists, `IO.puts` a "destila project already
  present — skipping" message and return.
- Keep the file flat Elixir (no module definition). Standard
  `priv/repo/seeds.exs` idiom: plain top-level `alias` + expressions.

**Patterns to follow:**
- Public context access: mirror how callers elsewhere in `lib/destila`
  reach projects via `Destila.Projects.*` rather than touching
  `Destila.Projects.Project` directly. The name lookup is the one
  justified exception because no finder exists.
- Binary ID generation is automatic via the schema's `@primary_key`
  declaration — the seed must not set `:id`.

**Test scenarios:**
- Test expectation: none — this is a one-off dev/setup script, not
  feature code. Verification is covered by running `mix ecto.reset`
  locally (see Verification).

**Verification:**
- Running `mix ecto.reset` on a clean checkout leaves exactly one row in
  the `projects` table whose fields match R1 exactly.
- Running `mix run priv/repo/seeds.exs` a second time does not raise,
  does not insert a duplicate row, and prints the "already present" log.
- Manually editing the seeded row's `run_command` in `iex` and then
  re-running `mix run priv/repo/seeds.exs` leaves the manual edit intact.

---

- [ ] **Unit 2: Wire seeds into the `ecto.setup` alias**

**Goal:** Ensure `mix setup`, `mix ecto.setup`, and `mix ecto.reset` all
execute the seed file automatically.

**Requirements:** R3

**Dependencies:** Unit 1 (the file must exist before the alias invokes it).

**Files:**
- Modify: `mix.exs`

**Approach:**
- Update the `"ecto.setup"` entry in `aliases/0` from
  `["ecto.create --quiet", "ecto.migrate --quiet"]` to
  `["ecto.create --quiet", "ecto.migrate --quiet", "run priv/repo/seeds.exs"]`.
- No change to the top-level `setup` alias (it already calls
  `ecto.setup`).
- No change to the `test` alias (intentional — tests stay unseeded).

**Patterns to follow:**
- Existing alias entries in `mix.exs:81-108` — preserve list ordering
  and quoting style.

**Test scenarios:**
- Test expectation: none — this is a one-line alias edit with no
  conditional behavior to test.

**Verification:**
- `mix ecto.reset` ends with the seed's log line printed, and a fresh
  row is present in `projects` afterward.
- `mix test` still passes and does not pick up the seeded row
  (tests run under `MIX_ENV=test` and use a separate database; the
  `test` alias does not go through `ecto.setup`, so the seed does not
  run there).
- `mix setup` on a clean checkout succeeds end-to-end and produces the
  seeded row.

## System-Wide Impact

- **Interaction graph:** `Destila.Projects.create_project/1` broadcasts
  `:project_created` via `Destila.PubSubHelper`. At seed-run time (`mix
  run priv/repo/seeds.exs`), the application is typically not started
  with its full supervision tree and no LiveViews are subscribed, so
  the broadcast is a no-op. If a developer happens to run the seed file
  while the server is running, the broadcast will fire to any connected
  dashboards — that is the correct, existing behavior for "a new project
  appeared".
- **State lifecycle risks:** None meaningful. A failed `create_project`
  call raises via `Mix.raise/1`, aborting setup before downstream
  assets/hooks steps run, which is the right failure mode.
- **Unchanged invariants:** `Destila.Projects.Project` schema,
  validations, and context API remain untouched. The seed is an
  additional caller of `create_project/1`, not a new code path.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A future validation change rejects the seed attribute set. | Seed uses the same changeset as the UI; any regression is caught by `mix setup` failing loudly rather than silently inserting bad data. |
| Developer has manually removed/archived the destila project and expects setup to re-create it. | Idempotency is by `name` only; an archived row still blocks re-creation. Acceptable because `archive_project/1` is the intentional "hide, don't delete" path. Re-creation requires either unarchiving or deleting the archived row first — consistent with how the UI would treat the same situation. |
| `mix run priv/repo/seeds.exs` fails to start the repo when run outside `mix setup`. | `mix run` starts the application by default (including `Destila.Repo`), matching the standard Phoenix seed pattern. No extra `Mix.Task.run("app.start", [])` needed. |

## Sources & References

- Related code:
  - `lib/destila/projects.ex:25` (`create_project/1`)
  - `lib/destila/projects/project.ex` (schema + validations, notably
    `@denied_env_vars` and `@env_var_pattern` at lines 89-90)
  - `mix.exs:81-108` (`aliases/0`, specifically `ecto.setup` at line 91)
- Related directories:
  - `priv/repo/migrations/` (current migrations; no seeds file present)
