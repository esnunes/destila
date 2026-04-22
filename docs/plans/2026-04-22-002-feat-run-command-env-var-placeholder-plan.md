---
title: Substitute service env var placeholders in run_command at service start
type: feat
status: completed
date: 2026-04-22
---

# Substitute service env var placeholders in run_command at service start

## Overview

Let a project's `run_command` reference the allocated service port directly in its
argv by writing the service env var name between curly braces. When the service
starts, `{ENV_VAR}` placeholders in `run_command` are replaced with the
ephemeral port allocated for that start, where `ENV_VAR` matches the project's
`service_env_var`. Example:

- `service_env_var = "PORT"`
- `run_command = "elixir --sname destila-{PORT} -S mix phx.server"`
- Allocated port = 1234
- Executed command = `"elixir --sname destila-1234 -S mix phx.server"`

The existing `export PORT=1234 && ...` prefix is preserved so programs that read
the env var continue to work unchanged.

## Problem Frame

`Destila.Services.ServiceManager.build_service_command/4` already allocates a
single ephemeral port per start and exports it under the project's
`service_env_var` before chaining `setup_command; run_command`. That works for
servers that read the port from the environment (Phoenix reads `PORT`), but it
does not help for commands that need the port baked into their argv — e.g.,
Erlang's `--sname destila-<port>` flag, Elixir's `--cookie`, or any one-shot CLI
whose port is a positional argument.

A shell-only workaround (`elixir --sname destila-$PORT ...`) requires the user
to remember shell quoting rules and interacts badly with the `;`-chained
composition already used to run setup before run. Accepting a
project-scoped placeholder `{SERVICE_ENV_VAR}` in `run_command` makes the
intent explicit, keeps quoting out of the user's way, and fits the existing
convention of "one env var name per project, used as both the export name and
the sidebar URL port".

## Requirements Trace

- **R1.** `build_service_command/4` replaces every literal occurrence of
  `{<service_env_var>}` in `run_command` with the allocated port (as a string)
  before composing the final shell string.
- **R2.** Substitution is case-sensitive and requires an exact match between
  the placeholder's identifier and the project's `service_env_var`. A placeholder
  for a different identifier (e.g., `{API_PORT}` when `service_env_var = "PORT"`)
  is left untouched.
- **R3.** The existing `export <ENV_VAR>=<port> && <setup;> <run>` wrapping is
  preserved so `$ENV_VAR` continues to work for processes that read the env var.
- **R4.** Multiple occurrences of the same placeholder in `run_command` are all
  replaced.
- **R5.** `setup_command` is **not** substituted — scope is limited to
  `run_command` per the user's prompt. Other `{…}` text anywhere in either
  command is left untouched.
- **R6.** A `run_command` with no placeholder behaves exactly as today
  (backward compatibility).
- **R7.** The project form surfaces the placeholder convention inline (short
  hint text under the run command input) so users discover it without
  documentation.
- **R8.** `features/service_setup_command.feature` gains a scenario describing
  the substitution; `test/destila/services/service_manager_test.exs` gains
  unit coverage pinned to that scenario. `mix precommit` passes.

## Scope Boundaries

- No changes to the placeholder syntax convention beyond curly braces around
  the exact `service_env_var`. No support for `${PORT}`, `%PORT%`, default
  values, arithmetic, or nested expressions.
- No substitution in `setup_command`. Users who need the port during setup
  can use `$ENV_VAR` shell expansion within `setup_command` as today (the
  export precedes setup in the composed string).
- No changes to port allocation, tmux window index, startup timeout, env var
  validation, or the MCP service tool's JSON contract (`service_state["run_command"]`
  continues to hold the raw, pre-substitution `run_command` — the substituted
  form exists only in the string handed to tmux).
- No form-level validation that the placeholder matches the env var — the
  value is a free-text shell command and over-validation creates false
  positives. An unmatched placeholder simply survives verbatim into the shell,
  where it will fail at runtime like any other shell typo.
- No changes to the project schema or migrations.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/services/service_manager.ex:157-168` — `build_service_command/4`
  is the single composition point. Adding substitution here is the smallest
  possible change that covers every `do_start` / `do_restart` call path.
- `lib/destila/services/service_manager.ex:51-107` — `do_start/2` is the only
  caller of `build_service_command/4`. `project.run_command`,
  `project.service_env_var`, and `port` are all in scope.
- `lib/destila/projects/project.ex:89-116` — `@env_var_pattern` already
  guarantees `service_env_var` matches `^[A-Z][A-Z0-9_]*$`, so placeholder
  keys are regex-safe to interpolate into a `String.replace` pattern without
  escaping.
- `test/destila/services/service_manager_test.exs` — existing
  `build_service_command/4` tests follow the `describe "..." do` style with
  `@tag feature: @feature, scenario: "..."` annotations. New tests match that
  shape.
- `features/service_setup_command.feature` — canonical home for service-start
  composition scenarios. New scenario lives beside the existing
  "Start/restart allocates a port and exports the service env var…" scenario.
- `lib/destila_web/live/project_form_live.ex:181-193` — run command input
  with placeholder hint; follows the existing `<p class="text-xs ...">`
  convention already used under the service env var input.

### Institutional Learnings

- No direct hit in `docs/solutions/`. The closest prior art is
  `docs/plans/2026-04-17-001-refactor-project-service-env-var-plan.md`,
  which introduced the single-env-var model this feature extends.
- String substitution in user-provided commands is a common footgun in other
  systems (double-substitution, accidental recursive expansion). The mitigation
  here is that port is always a positive integer (`reserve_port/0` returns an
  `integer`), so the replacement never reintroduces a placeholder and the
  substitution is a single pass over the string.

### External References

- None required. `String.replace/3` with a literal string pattern is sufficient
  and framework-native.

## Key Technical Decisions

- **Placeholder syntax: `{<ENV_VAR>}`**. Chosen over `${ENV_VAR}` because the
  dollar form collides with shell expansion inside the same string — users
  would expect `${PORT}` to be shell-expanded, and composing two expansion
  passes (Elixir-side then shell-side) creates surprises. Curly-only `{PORT}`
  is unambiguous: the shell never interprets bare curly braces in this
  position, so the substitution is purely an Elixir-side text replacement.
- **Substitute only when `service_env_var` is non-blank**. `do_start` already
  gates on `Project.webservice?/1`, so by the time `build_service_command/4`
  runs the env var is guaranteed non-blank. Still, `build_service_command/4`
  should treat `nil`/blank `env_var` as a no-op substitution to keep the
  helper safe for direct unit testing and any future caller.
- **Replace with `Integer.to_string/1` of the port**. Ports are integers;
  explicit conversion keeps the shell string stable regardless of locale
  settings or future changes to the port source.
- **Use `String.replace/3` with a literal string**, not a regex. The placeholder
  key is already constrained to `^[A-Z][A-Z0-9_]*$`, so there is no regex-escape
  hazard, and a literal-string replace avoids the cognitive overhead of
  anchored regex patterns. `String.replace(run_command, "{#{env_var}}", port_str)`
  is all that is needed.
- **Raw `run_command` survives into `service_state`**. The `starting_state` /
  `running_state` maps persist `project.run_command` verbatim (with placeholders
  intact). Rationale: the stored state describes the configuration, not a
  specific run. The MCP service tool, AI conversation context, and sidebar
  show users/AI what is *configured*, not the ephemeral string that went to
  tmux once.
- **No substitution in `setup_command`**. The prompt is explicit. Users with
  an operational need for the port during setup still have `$ENV_VAR` shell
  expansion available, since the export precedes setup in the composed
  string.
- **Unmatched placeholders are not a validation error**. A `run_command` like
  `"mix phx.server --port {API_PORT}"` with `service_env_var = "PORT"` will
  ship the literal `{API_PORT}` to the shell and fail there. That matches how
  a shell typo fails today and avoids false positives on legitimate shell
  syntax that happens to include curly braces (e.g., shell brace expansion:
  `cp file.{txt,bak}` — unlikely in a run command but technically possible).

## Open Questions

### Resolved During Planning

- **Should `setup_command` also get placeholder substitution?** No — the
  prompt is explicit about `run_command`, and `setup_command` can still use
  `$ENV_VAR` via the preceding `export`. Documented as a scope boundary.
- **What about the MCP tool's `run_command` field in JSON?** Return the raw
  stored `run_command` (with placeholders), not the per-run substituted form.
  The substitution is an execution-time concern; state surfaces show
  configuration.
- **What if the user writes `{port}` (lowercase) when `service_env_var` is
  `PORT`?** No substitution — case-sensitive exact match. The env var regex
  already enforces uppercase identifiers, so the mental model is simple:
  "placeholder looks exactly like the env var name you typed, wrapped in braces."
- **Should we render the substituted command in the service sidebar or
  anywhere else in the UI?** No — the sidebar shows a URL, not a command.
  No user-facing surface shows the composed shell string today, and this
  plan does not add one.

### Deferred to Implementation

- Exact copy of the form hint text ("e.g. `mix phx.server --port {PORT}`" vs.
  a more generic phrasing).
- Whether the existing `build_service_command/4` signature needs a 5th arg or
  whether the substitution happens inside the existing 4-arg shape — the
  substitution can be computed from `run_command` and `env_var` alone, so the
  arity stays at 4.

## Implementation Units

- [ ] **Unit 1: Substitute `{service_env_var}` in run_command inside `build_service_command/4`**

**Goal:** Make `build_service_command/4` substitute every `{<env_var>}`
occurrence in `run_command` with the allocated port before composing the final
shell string. Keep all other behavior identical.

**Requirements:** R1, R2, R3, R4, R5, R6

**Dependencies:** None.

**Files:**
- Modify: `lib/destila/services/service_manager.ex`
- Test: `test/destila/services/service_manager_test.exs`

**Approach:**
- Inside `build_service_command/4`, before chaining `setup_command; run_command`,
  compute `run_command_expanded = substitute_port_placeholder(run_command, env_var, port)`.
- Introduce a small private helper `substitute_port_placeholder/3` colocated in
  the same module:
  - When `env_var` is `nil` or blank, return `run_command` unchanged.
  - Otherwise, replace the literal `"{#{env_var}}"` pattern with
    `Integer.to_string(port)` using `String.replace/3`.
- Replace the existing body's reference to `run_command` with
  `run_command_expanded`. `env_export`, the setup-blank check, and the `;`
  composition stay untouched.
- Do not touch the `setup_command` value. Do not add any new arguments to
  `build_service_command/4`. Do not log or error on unmatched placeholders.

**Patterns to follow:**
- The existing private helper style inside `service_manager.ex` (`wait_for_port/2`,
  `reserve_port/0`).
- `Destila.StringHelper.blank?/1` import already in place at the top of the
  module — use it for the nil/blank guard.

**Test scenarios:**
- Happy path: `build_service_command(nil, "elixir --sname destila-{PORT} -S mix phx.server", "PORT", 1234)`
  returns `"export PORT=1234 && elixir --sname destila-1234 -S mix phx.server"`.
- Happy path (with setup): `build_service_command("mix deps.get", "mix phx.server --port {PORT}", "PORT", 4712)`
  returns `"export PORT=4712 && mix deps.get; mix phx.server --port 4712"`. Setup
  remains untouched; run is substituted.
- Happy path (multiple occurrences): `run_command = "a {PORT} b {PORT} c"` with
  `env_var = "PORT"`, port `9000` → result's run segment is `"a 9000 b 9000 c"`.
- Edge case (no placeholder): `run_command = "mix phx.server"` with any env var
  and port → result matches today's `"export PORT=<port> && mix phx.server"`
  byte-for-byte (regression guard).
- Edge case (different env var name): `run_command = "app --port {API_PORT}"`,
  `env_var = "PORT"`, port `1234` → placeholder is preserved literally:
  `"export PORT=1234 && app --port {API_PORT}"`.
- Edge case (case-sensitive): `run_command = "app --port {port}"`,
  `env_var = "PORT"`, port `1234` → `{port}` is preserved literally.
- Edge case (placeholder in setup_command): `setup_command = "setup {PORT}"`,
  `run_command = "run"`, `env_var = "PORT"`, port `1234` → `setup_command`
  segment still contains `"{PORT}"` literally (not substituted). Pinning R5.
- Edge case (underscored env var): `env_var = "API_PORT"`,
  `run_command = "app --bind 0.0.0.0:{API_PORT}"`, port `8081` →
  placeholder is replaced. Confirms the composed pattern `"{#{env_var}}"` works
  with identifiers containing underscores and digits.
- Edge case (nil env_var): `build_service_command(nil, "run {PORT}", nil, 1234)` →
  `{PORT}` is preserved literally (defensive behavior for direct unit calls;
  this combination cannot occur from `do_start` because the precondition check
  gates it).

**Verification:**
- `mix test test/destila/services/service_manager_test.exs` passes.
- No existing `build_service_command/4` assertion changes needed beyond the
  new scenarios (backward compatibility scenario in this unit pins that
  promise).

---

- [ ] **Unit 2: Gherkin scenario + form hint for the placeholder convention**

**Goal:** Document the placeholder convention as a Gherkin scenario linked to
the new unit tests, and add a short inline hint under the run command input
so users discover the syntax without hunting through docs.

**Requirements:** R7, R8

**Dependencies:** Unit 1.

**Files:**
- Modify: `features/service_setup_command.feature`
- Modify: `lib/destila_web/live/project_form_live.ex`
- Test: `test/destila/services/service_manager_test.exs` (tag sync — new
  scenario reference on the tests added in Unit 1)

**Approach:**
- Add a new scenario to `features/service_setup_command.feature`, placed
  directly after the existing "Start/restart allocates a port and exports the
  service env var for both setup and run" scenario:

  ```
  Scenario: Run command placeholder {ENV_VAR} is substituted with the allocated port
    Given a project whose run command contains a {ENV_VAR} placeholder
    And the project's service env var name matches the placeholder identifier
    When the service is started
    Then every occurrence of {ENV_VAR} in the run command is replaced with the allocated port
    And the run command is still prefixed with the env var export
    And the setup command is not substituted
  ```

  Mirror the feature description paragraph at the top of the file with one
  sentence noting that `run_command` supports a single `{service_env_var}`
  placeholder resolved at start time.
- Update the tests added in Unit 1 to tag the happy path, multiple-occurrences,
  different-env-var-name, case-sensitive, and no-substitution-in-setup test
  cases with:
  `@tag feature: @feature, scenario: "Run command placeholder {ENV_VAR} is substituted with the allocated port"`
  (using the `@feature` attribute already present in the test module).
- In `lib/destila_web/live/project_form_live.ex`, add a `<p class="text-xs
  text-base-content/50 mt-1">` hint directly below the run command input
  (around line 192–193) with copy along the lines of:
  "Use `{PORT}` (or whatever matches your service env var name) to interpolate
  the allocated port into the command." Exact wording is deferred to
  implementation — keep it single-line and consistent with the existing
  "optional" labels.

**Patterns to follow:**
- Existing scenario wording style in `features/service_setup_command.feature`.
- `@tag feature: @feature, scenario: "..."` annotations already in
  `test/destila/services/service_manager_test.exs`.
- The existing form-help text under the service env var input uses
  `<p class="text-xs text-error mt-1">` for errors; a neutral hint uses
  `text-base-content/50` or `text-base-content/60` for consistency with the
  rest of the form's subdued labeling.

**Test scenarios:**
- `mix test --only scenario:"Run command placeholder {ENV_VAR} is substituted with the allocated port"`
  runs a non-empty set and all pass.
- Manual: viewing the project form renders the hint text under the run command
  input (visual check — no automated DOM assertion added, since existing
  projects_live_test coverage already asserts input IDs).

**Verification:**
- `mix test --only feature:service_setup_command` runs a non-empty set and all
  pass.
- Grep `features/` and `test/` for `"Run command placeholder"` — at least one
  feature match and at least one test match, matching strings identical.

---

- [ ] **Unit 3: Precommit pass**

**Goal:** Run `mix precommit` and address any residual warnings, formatting,
or test fallout from Units 1–2.

**Requirements:** R8

**Dependencies:** Units 1–2.

**Files:** none (no code changes expected beyond mechanical formatting).

**Approach:**
- Run `mix precommit` (alias defined in `mix.exs`:
  `["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]`).
- If any warnings surface (e.g., unused private function, pattern-match
  coverage), fix in place.
- Re-run until clean.

**Test expectation:** none — this unit runs the existing suite and formatter;
it does not introduce new tests.

**Verification:**
- `mix precommit` exits 0.

## System-Wide Impact

- **Interaction graph:**
  - `Destila.Services.ServiceManager.do_start/2` → `build_service_command/4`
    (only caller; no other path produces the composed shell string).
  - No change to `PrepareWorkflowSession.run_post_worktree_setup/3` — the
    post-worktree setup path continues to send `setup_command` verbatim to
    tmux and does not reserve a port.
  - `service_state["run_command"]` consumers (MCP `:service` tool,
    `AI.Conversation.build_service_section/1`, sidebar URL derivation) are
    unaffected because the raw, pre-substitution `run_command` is what gets
    persisted.
- **Error propagation:** No new error cases. Unmatched placeholders pass
  through to the shell and fail at runtime identically to any other shell
  typo, which is already the expected UX for misconfigured `run_command`
  values.
- **State lifecycle:** `service_state["run_command"]` remains the raw
  `project.run_command`. No migration or backfill needed. Legacy running
  services continue to work because their `run_command` has no placeholder
  and `String.replace/3` is a no-op on non-matching input.
- **API surface parity:** None. `build_service_command/4` keeps its existing
  arity and public-ish `@doc false` contract. The MCP service tool's JSON
  contract is unchanged.
- **Integration coverage:** The end-to-end path (form saved with placeholder →
  `do_start` → tmux `send_keys` with substituted string) is covered by the
  `build_service_command/4` unit tests plus the existing integration path
  from `do_start` (no changes needed to `do_start` tests, since they already
  assert on `service_state` fields that carry the raw command).
- **Unchanged invariants:**
  - Port allocation count per start: still exactly one.
  - `export <ENV_VAR>=<port> && …` prefix is preserved verbatim.
  - `;`-chained `setup_command; run_command` composition is preserved.
  - Tmux service window index (9), startup timeout, and probe cadence are
    unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| A user's existing `run_command` contains a literal `{PORT}` that was meant to survive verbatim (e.g., documentation string embedded in the command). | Extremely unlikely — `run_command` is a shell command and literal braces in this position are almost always intended as a placeholder. Accept the risk; users can escape by choosing a different `service_env_var` name that does not appear in their command. |
| Substitution logic drifts out of sync with the env var regex (e.g., env var regex is relaxed but placeholder matching stays strict, or vice versa). | Substitution uses the literal string `"{#{env_var}}"` keyed off the stored `service_env_var` — it automatically tracks whatever the schema validates. No independent regex to maintain. |
| Users expect shell-style `${PORT}` or `$PORT` to be substituted by Elixir. | Form hint in Unit 2 calls out the `{PORT}` curly-only syntax. Actual `$PORT` still works via the shell export. No silent surprise. |
| Scope creep into `setup_command`, default values, or richer templating. | Scope Boundaries section and Key Technical Decisions explicitly defer these. Feature scenario mentions run command only. |

## Documentation / Operational Notes

- No separate docs update required — the in-repo feature file is the
  user-facing specification.
- Form hint added in Unit 2 is the only user-visible documentation surface.
- No rollout flag, migration, or monitoring change. The change is effective
  on deploy for the next service start; currently-running services are
  unaffected until they restart.

## Sources & References

- Origin: user prompt (no upstream requirements document).
- Related prior plans:
  - `docs/plans/2026-04-17-001-refactor-project-service-env-var-plan.md`
    (introduced the single `service_env_var` model this feature extends)
  - `docs/plans/2026-04-16-002-feat-project-setup-command-plan.md`
    (introduced `setup_command; run_command` composition)
  - `docs/plans/2026-04-14-001-feat-project-service-management-plan.md`
    (original service lifecycle design)
- Core source files:
  - `lib/destila/services/service_manager.ex`
  - `lib/destila_web/live/project_form_live.ex`
- Feature file:
  - `features/service_setup_command.feature`
- Tests:
  - `test/destila/services/service_manager_test.exs`
