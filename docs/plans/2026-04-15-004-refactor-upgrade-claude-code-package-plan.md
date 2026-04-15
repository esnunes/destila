---
title: "refactor: Upgrade claude_code package from 0.32.2 to 0.36.3"
type: refactor
status: active
date: 2026-04-15
---

# refactor: Upgrade claude_code package from 0.32.2 to 0.36.3

## Overview

Bump the `claude_code` Elixir package from v0.32.2 to v0.36.3 and adapt
the codebase to three breaking API changes introduced across the intermediate
versions. The upgrade brings runtime resolution of the `~/.claude` path
(v0.36.3), eliminates stray `CallbackProxy` error logs (v0.36.2), replaces
the `hermes_mcp` backend with `anubis_mcp` (v0.33.0–v0.34.0), and enforces
that all session options are configured at session-start time rather than
per-query (v0.36.1).

## Problem Frame

The locked version (0.32.2) uses `hermes_mcp` as its internal MCP transport,
which is now replaced by `anubis_mcp ~> 1.0`. Several bug fixes and
improvements across v0.33–v0.36 are desirable, including the fix for
compile-time `~/.claude` path evaluation that breaks container/release builds
(v0.36.3). Three breaking changes require code changes in this repo.

## Requirements Trace

- R1. Version constraint in `mix.exs` resolves to 0.36.3
- R2. `mix.lock` updated with new transitive deps (`anubis_mcp`, no `hermes_mcp`)
- R3. MCP tool DSL in `tools.ex` uses the new description-inside-block syntax
- R4. `max_turns` and any other per-session options are moved to `start_link` opts; `stream/3` is called with 2 arguments
- R5. All existing tests continue to pass (`mix precommit` green)

## Scope Boundaries

- No new features — this is a pure upgrade/adaptation
- No changes to MCP tool behaviour or tool names
- No changes to session lifecycle logic beyond moving `max_turns` placement
- `ClaudeCode.Test.*` stub API assumed stable; no test rewrite unless compilation fails

## Context & Research

### Relevant Code and Patterns

- `mix.exs:63` — current constraint `{:claude_code, "~> 0.32"}`
- `lib/destila/ai/tools.ex` — defines 3 MCP tools with old DSL syntax
- `lib/destila/ai/claude_session.ex:148–186` — `init/1` builds `claude_opts` and calls `ClaudeCode.start_link/1`
- `lib/destila/ai/claude_session.ex:215–237` — `handle_call` for `query_streaming` builds `stream_opts` with `:max_turns, 200` default and passes them to `ClaudeCode.stream/3`
- `test/destila/ai/session_test.exs` — unit tests using `ClaudeCode.Test.stub/2` and `ClaudeCode.Test.allow/3`

### Institutional Learnings

- The `claude_code` dependency ships built-in Mix tasks — `mix deps.update` is the correct update path, not rebuilding from scratch
- `ClaudeCode.Test.stub/2` receives `fn _query, _opts ->` callbacks in existing tests; verify the arity remains stable after upgrade

### External References

- https://github.com/guess/claude_code/releases — full changelog for v0.32.3 → v0.36.3

## Key Technical Decisions

- **Bump constraint to `~> 0.36`:** Allows patch updates within 0.36.x without re-locking. Using `~> 0.36.3` would be more precise but `~> 0.36` follows the project's existing style.
- **Move `max_turns` to `init/1`:** Since `stream/3` no longer accepts per-query options, the default `max_turns: 200` must be added to `claude_opts` before calling `ClaudeCode.start_link/1`. Callers of `query_streaming/3` can no longer override `max_turns` per query — this was already the effective behaviour in v0.36.1+, so making it explicit is accurate.
- **Remove the opts argument from `ClaudeCode.stream/3` call:** After v0.36.1 the function signature is `stream/2`. Passing a third argument would raise a compile error or behave unexpectedly; remove `stream_opts` (beyond `stream_topic` extraction) from the call site.

## Open Questions

### Resolved During Planning

- **What is the new MCP tool DSL syntax?** Confirmed from source: `tool :name do description "..." field(...) def execute(...) end end`. The `description` call is a compile-time DSL macro, now first line inside the block instead of a positional argument.
- **Can `max_turns` still be passed to `stream/3`?** No. v0.36.1 removed all per-query option overrides. The value must be set at `start_link` time.
- **Does `hermes_mcp` need an explicit dep update in `mix.exs`?** No — it was never a direct dep; it was transitive. `mix deps.update claude_code` will replace it with `anubis_mcp` in `mix.lock` automatically.

### Deferred to Implementation

- **Exact `stream/2` vs `stream/3` arity after v0.36.1:** Verify by compiling after the bump. If `stream/3` still compiles (soft deprecation), the removal of the opts argument is still the correct behaviour change. If it raises, fix is the same.
- **`ClaudeCode.Test.stub/2` signature stability:** Assumed stable; confirm by running tests after upgrade. If the stub API changed, adapting test helpers is a follow-on task.

## Implementation Units

```
mix.exs                 ──►  mix.lock
    │
    ▼
lib/destila/ai/tools.ex (DSL)
    │
    ▼
lib/destila/ai/claude_session.ex (stream opts + max_turns)
    │
    ▼
mix precommit (compile + test)
```

---

- [ ] **Unit 1: Bump version constraint and update lockfile**

**Goal:** Change the `claude_code` version constraint in `mix.exs` and run `mix deps.update` to resolve v0.36.3 and its new transitive deps.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `mix.exs`
- Modified by deps.update: `mix.lock`

**Approach:**
- Change `{:claude_code, "~> 0.32"}` to `{:claude_code, "~> 0.36"}` in `mix.exs`
- Run `mix deps.update claude_code` — this pulls in `anubis_mcp ~> 1.0` and removes `hermes_mcp` from the lockfile
- Do not run `mix deps.clean --all` (per CLAUDE.md guidelines)

**Patterns to follow:**
- `mix.exs:63` — existing constraint style uses `~> MAJOR.MINOR`

**Test scenarios:**
- Test expectation: none — this unit only changes the version string and lockfile; compilation in Unit 4 verifies the resolved versions are correct

**Verification:**
- `mix.exs` shows `{:claude_code, "~> 0.36"}`
- `mix.lock` contains `claude_code: {:hex, :claude_code, "0.36.3", ...}`
- `mix.lock` contains `anubis_mcp` entry, no `hermes_mcp` entry

---

- [ ] **Unit 2: Update MCP tool DSL in tools.ex**

**Goal:** Move the tool description from a positional argument to a `description "..."` call inside the `do` block for all three tools in `tools.ex`.

**Requirements:** R3

**Dependencies:** Unit 1 (package must resolve for the macro to compile)

**Files:**
- Modify: `lib/destila/ai/tools.ex`

**Approach:**
- For each of the three `tool` calls (`ask_user_question`, `session`, `service`): remove the description string from the second positional argument of the `tool` macro and add `description "..."` as the first line inside the `do` block
- The rest of the block (`field/2`, `def execute/1`, `def execute/2`) is unchanged
- Preserve the exact description strings verbatim

**Technical design (directional — not implementation specification):**

Before:
```
tool :ask_user_question,
     "Present one or more structured questions..." do
  field(...)
  def execute(_params) do ... end
end
```

After:
```
tool :ask_user_question do
  description "Present one or more structured questions..."
  field(...)
  def execute(_params) do ... end
end
```

Apply the same transformation to `:session` and `:service`.

**Patterns to follow:**
- `lib/destila/ai/tools.ex:8` — `use ClaudeCode.MCP.Server, name: "destila"` remains unchanged

**Test scenarios:**
- Test expectation: none — the MCP tool behaviour is unchanged (description strings are identical, `execute/1` and `execute/2` callbacks are unchanged). Compilation in Unit 4 confirms the DSL is accepted.

**Verification:**
- `lib/destila/ai/tools.ex` compiles without warnings
- Tool names, field definitions, and execute callbacks are identical to before
- `mix compile` passes

---

- [ ] **Unit 3: Move `max_turns` to session start, remove opts from `stream/3`**

**Goal:** Ensure `max_turns: 200` is set at session-start time (in `claude_opts` inside `init/1`) and that `ClaudeCode.stream/3` is called with 2 arguments.

**Requirements:** R4

**Dependencies:** Unit 1

**Files:**
- Modify: `lib/destila/ai/claude_session.ex`

**Approach:**
- In `init/1` (around line 148): add `claude_opts = Keyword.put_new(claude_opts, :max_turns, 200)` before the `ClaudeCode.start_link(claude_opts)` call. Place it alongside the existing `Keyword.put_new` calls for `:allowed_tools`, `:mcp_servers`, and `:setting_sources`.
- In `handle_call({:query_streaming, ...})` (around line 215): remove `:max_turns` from `stream_opts`. After extracting `stream_topic`, the remaining opts (minus `:timeout` which is already consumed before the GenServer call) should not be forwarded to `ClaudeCode.stream`. The stream call becomes `ClaudeCode.stream(state.claude_session, prompt)` (2-arity).
- Any remaining opts that callers legitimately need to pass (e.g., `:timeout` for GenServer.call, `:stream_topic` for PubSub) are already consumed before reaching `ClaudeCode.stream` and require no further change.

**Patterns to follow:**
- `lib/destila/ai/claude_session.ex:148–159` — existing `Keyword.put_new` pattern for session defaults

**Test scenarios:**
- Happy path: existing `query_streaming/3` tests in `test/destila/ai/session_test.exs` pass unchanged — the stub ignores `max_turns` and the result collection logic is identical
- Edge case: callers that previously passed `max_turns` as a stream-time opt (none found in codebase) would need to move that opt to `start_link`; confirm by grepping for `query_streaming.*max_turns` (none expected)
- Integration: `query_streaming/3` still broadcasts chunks and returns `{:ok, result}` with the same shape — existing broadcast tests cover this

**Verification:**
- `ClaudeCode.stream` in `claude_session.ex` is called with 2 arguments
- `claude_opts` in `init/1` includes `max_turns: 200` as a default
- All tests in `test/destila/ai/session_test.exs` pass

---

- [ ] **Unit 4: Verify with `mix precommit`**

**Goal:** Confirm the upgrade compiles cleanly, unused deps are unlocked, formatting is correct, and all tests pass.

**Requirements:** R5

**Dependencies:** Units 1, 2, 3

**Files:**
- No file changes — this is a verification step

**Approach:**
- Run `mix precommit` (alias: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`)
- If compilation fails due to API changes not yet identified in planning, fix at implementation time and record the fix
- If tests fail due to `ClaudeCode.Test` API changes, adapt test helpers accordingly

**Test scenarios:**
- Test expectation: none — this unit is the verification gate for all prior units

**Verification:**
- `mix precommit` exits 0
- No `hermes_mcp` warnings or undefined references
- No warnings about `ClaudeCode.stream/3` arity

## System-Wide Impact

- **Interaction graph:** `ClaudeSession` → `ClaudeCode.start_link` / `ClaudeCode.stream` / `ClaudeCode.stop`. No other modules call ClaudeCode directly except `lib/destila/ai.ex` (uses `ClaudeCode.query/2` for one-off queries — verify this function signature is unchanged in v0.36.x).
- **Error propagation:** No change — errors from the ClaudeCode process surface through the existing stream reduction as before.
- **State lifecycle risks:** None — moving `max_turns` to `start_link` is additive. Sessions that are already started will not be affected mid-flight.
- **API surface parity:** `Destila.AI.ClaudeSession.query_streaming/3` public API is unchanged — callers do not pass `max_turns` directly.
- **Integration coverage:** `test/destila/ai/session_test.exs` covers start/stop, streaming, broadcast, and inactivity timeout. No new tests are needed unless the `ClaudeCode.Test` API changed.
- **Unchanged invariants:** The `Destila.AI.Tools` MCP server tool names (`ask_user_question`, `session`, `service`) and their field schemas are unchanged — only the DSL description placement changes.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `ClaudeCode.Test.*` stub API changed in v0.36.x | Compile and run tests; if the arity or module name changed, adapt the stub calls in test files |
| `ClaudeCode.query/2` (used in `lib/destila/ai.ex`) removed or renamed | Check after bump; if changed, adapt the one-off query call |
| `anubis_mcp ~> 1.0` introduces a compile-time conflict with another dep | `mix deps.update` will report conflicts; resolve by checking `mix hex.info anubis_mcp` |
| `stream/3` still compiles (soft deprecation) but options are silently ignored | The fix (remove opts from call) is correct regardless; confirms via test behaviour |

## Sources & References

- Related code: `lib/destila/ai/claude_session.ex`, `lib/destila/ai/tools.ex`, `mix.exs`
- Changelog: https://github.com/guess/claude_code/releases
