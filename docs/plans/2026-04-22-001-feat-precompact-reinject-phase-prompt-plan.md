---
title: Re-inject phase prompt on pre-compaction via claude_code hook
type: feat
status: completed
date: 2026-04-22
---

# Re-inject phase prompt on pre-compaction via claude_code hook

## Overview

Add a `PreCompact` hook that runs before Claude Code compacts the conversation history and uses `custom_instructions` to carry the phase's initial prompt — wrapped in an `<initial-prompt>` tag — into the compacted context. After compaction the model still sees the original phase instructions and a reference line pointing it back to the tag.

This directly addresses the comment in `lib/destila/ai/conversation.ex:79-83`, which acknowledges that "context compaction hides the original phase prompt (which describes how to signal completion) from the agent" and currently works around the problem by auto-advancing non-interactive phases.

## Problem Frame

Claude Code sessions in Destila run long enough to hit auto-compact. When that happens the full initial phase prompt (assembled in `Destila.AI.Conversation.phase_start/1` and sent as the kickoff `query`) gets summarized away. After compaction:

- Interactive phases lose the description of how the phase should progress and how to call `mcp__destila__session` to signal completion.
- Non-interactive phases lose the criteria that define "done" — today we paper over this by auto-advancing on any completed turn without a `session_action` (see `conversation.ex:137`).

The user request: before compaction fires, ensure the initial prompt is re-added to the conversation, wrapped in an `<initial-prompt>` tag, accompanied by a reference note ("In the `<initial-prompt>` you can find the initial user prompt for reference").

The `claude_code` Elixir SDK exposes hooks (added in 0.19.0; currently on 0.36.3 in `mix.exs:63`). `PreCompact` is the correct lifecycle event. Its sanctioned channel for carrying content into the post-compaction context is the `custom_instructions` field on its output struct, which is passed to the compaction summarizer with instructions about what to preserve verbatim. There is no `additional_context` channel for `PreCompact` — that field only exists on `UserPromptSubmit` and `SessionStart` outputs.

## Requirements Trace

- R1. A `PreCompact` hook runs before every compaction (manual or auto) for every Destila-managed Claude Code session.
- R2. The hook includes the current phase's initial prompt verbatim in its output, wrapped in `<initial-prompt>...</initial-prompt>` tags.
- R3. The hook output instructs the compaction pass to preserve the tag block verbatim and to include a human-facing reference line: *"In the `<initial-prompt>` you can find the initial user prompt for reference."*
- R4. The hook is registered automatically for every workflow-session-backed Claude Code session; no per-phase opt-in required.
- R5. If the hook cannot resolve the workflow context (e.g., `session_id` unknown, AI session row missing), it returns a safe no-op so compaction still proceeds.
- R6. The workaround at `conversation.ex:79-83, 137` is re-evaluated — either documented as a belt-and-suspenders safety net or narrowed, now that the prompt is no longer erased by compaction.

## Scope Boundaries

- **Not** adding an `UserPromptSubmit` hook companion. The plan intentionally uses only `PreCompact` + `custom_instructions`; a post-compact `additional_context` injection via `UserPromptSubmit` is a separate change and explicitly out of scope.
- **Not** persisting the computed phase prompt into the database. The prompt is recomputed at hook time from the workflow session and phase definition, matching the existing pattern in `conversation.ex:33`.
- **Not** changing how phase prompts are assembled in `phase_start/1`. The hook reuses the same `initial_prompt` function reference from the phase definition.
- **Not** changing the non-interactive auto-advance behavior beyond re-evaluating the inline comment. Any rollback of the `_ when non_interactive -> :phase_complete` branch is a follow-up after we see hook behavior in practice.
- **Not** adding support for arbitrary user-defined hooks. We register exactly one hook module.

## Context & Research

### Relevant Code and Patterns

- **Central session options assembly** — `lib/destila/ai/session_config.ex:24-34`. All ClaudeCode opts flow through `session_opts_for_workflow/3`. This is the single place to register `:hooks`.
- **Session startup** — `lib/destila/ai/claude_session.ex:145-194`. `init/1` merges opts and calls `ClaudeCode.start_link/1`; any option produced by `SessionConfig` is forwarded as-is, so adding `:hooks` there requires no change here beyond letting it pass through.
- **Phase prompt construction** — `lib/destila/ai/conversation.ex:21-53`. `phase_start/1` reads `initial_prompt: prompt_fn` from the phase struct and calls `prompt_fn.(ws)`. The hook will replay this same lookup.
- **Phase struct** — `lib/destila/workflows/phase.ex:11-18`. `:initial_prompt` is a function reference; `Workflows.phases(workflow_type) |> Enum.at(phase_number - 1)` retrieves the phase.
- **AI session record** — `lib/destila/ai/session.ex:8` stores `claude_session_id`. `lib/destila/ai/conversation.ex:107-109` updates it when the Claude Code `ResultMessage` arrives. This is the lookup anchor for the hook's `session_id` → `workflow_session_id` mapping.
- **AI context module** — `lib/destila/ai.ex:14-48`. Existing helpers like `get_ai_session_for_workflow/1`. A new `get_ai_session_by_claude_session_id/1` fits here.
- **Existing compaction workaround** — `lib/destila/ai/conversation.ex:79-83, 137`. The `_ when non_interactive -> :phase_complete` branch exists specifically because of the problem this plan solves.

### Institutional Learnings

None directly relevant in `docs/solutions/`. The `2026-04-15-004-refactor-upgrade-claude-code-package-plan.md` confirms we're on `claude_code ~> 0.36`, which includes hooks (introduced in 0.19.0) and the struct-based `ClaudeCode.Hook.Output.*` return shapes (introduced in 0.32.0).

### External References

- **Guide**: `claude_code` hooks guide at https://github.com/guess/claude_code/blob/main/docs/guides/hooks.md.
- **Behaviour source**: `lib/claude_code/hook.ex` defines `@behaviour ClaudeCode.Hook` with `@callback call(input :: map(), tool_use_id :: String.t() | nil) :: hook_result()`.
- **PreCompact output struct**: `lib/claude_code/hook/output/pre_compact.ex` — only specific field is `:custom_instructions`. Wire shape: `%{"hookEventName" => "PreCompact", "customInstructions" => "..."}`.
- **Option shape**: `:hooks` is a map keyed by PascalCase atoms (e.g. `PreCompact:`). Values are lists whose entries can be bare modules implementing the behaviour (shorthand since 0.31.0), bare 2-arity functions, or matcher maps. `PreCompact` does not honor `:matcher`.
- **PreCompact input fields**: `:hook_event_name` (`"PreCompact"`), `:session_id`, `:transcript_path`, `:cwd`, `:trigger` (`"manual"` | `"auto"`), `:custom_instructions` (any already-supplied instructions, e.g. from `/compact <instructions>`).
- **Shorthand return**: `{:ok, custom_instructions: "..."}` is the idiomatic return for `PreCompact` (maps to `%ClaudeCode.Hook.Output.PreCompact{custom_instructions: "..."}`).
- **Upstream CLI note**: The Anthropic Claude Code CLI hook reference describes `PreCompact` and does not document an `additionalContext` channel for it — confirming the Elixir SDK's PreCompact-specific output is limited to `custom_instructions` (plus universal fields like `:continue`, `:system_message`, `:decision`).

## Key Technical Decisions

- **Use `PreCompact` with `custom_instructions`, not `system_message`.** `custom_instructions` is passed directly to the compaction summarization pass and instructs it what to preserve verbatim — the idiomatic path for "carry content across compaction." `system_message` is a transient hint that may not surface in all SDK output modes, per the upstream guide.
- **Module-based hook, not anonymous function.** Using `@behaviour ClaudeCode.Hook` gives us testability and clear ownership. Closures over `workflow_session_id` at registration time would work but couple hook lifetime to registration state and make unit testing awkward.
- **Look up workflow context from `session_id`, not from registration-time closure.** At hook time the input carries `session_id` (Claude Code's session id). We resolve `AI.Session` by `claude_session_id` and recompute the phase prompt from `workflow_session.workflow_type` + `workflow_session.current_phase`. This matches the existing pattern in `conversation.ex:33` and stays robust across session resumes.
- **Recompute the prompt at hook time, do not persist it.** The `initial_prompt` function in the phase struct is deterministic given the workflow session; persisting its output would duplicate state and risk drift if the workflow session is updated between kickoff and compact.
- **Register hooks centrally in `SessionConfig`, not in `ClaudeSession.init/1`.** `SessionConfig.session_opts_for_workflow/3` is already the single source of truth for per-session opts; adding `:hooks` here keeps `ClaudeSession` a pass-through wrapper and aligns with existing `put_*` helpers.
- **Fail closed to no-op.** If the hook can't resolve workflow context (missing `claude_session_id` mapping, unknown workflow type, phase out of range), it returns `:ok` so compaction proceeds unchanged. Blocking compaction on a hook bug would be a worse user experience than losing the re-injection.
- **Keep the workaround in `conversation.ex:137` for now.** The non-interactive auto-advance stays as a safety net; the comment above it gets updated to note the hook is now the primary mechanism. We can revisit removing it in a later change once we have confidence in hook coverage.

## Open Questions

### Resolved During Planning

- *Should we use `PreCompact` or `UserPromptSubmit` to re-inject the prompt?* — `PreCompact`, per user request and because it fires before the destructive operation. `UserPromptSubmit` would be a complementary post-compact injection but is out of scope.
- *Does `PreCompact` support `additional_context`?* — No. Its output struct defines only `:custom_instructions`. We rely on the summarizer to preserve the `<initial-prompt>` block verbatim based on the instruction text.
- *Which key in the `:hooks` map?* — The atom `PreCompact` (PascalCase). `:pre_compact` would silently not fire.
- *Does the hook need to be registered for every session or only some?* — Every workflow-backed session goes through `SessionConfig.session_opts_for_workflow/3`. Register there; one-off `ClaudeCode.query/2` calls (e.g. title generation in `lib/destila/ai.ex:232`) don't use the config path and don't need hooks.
- *How to look up the AI session at hook time?* — Add `Destila.AI.get_ai_session_by_claude_session_id/1` and query `where: ^claude_session_id`.

### Deferred to Implementation

- Exact phrasing of the `custom_instructions` body — the plan specifies structure and required pieces, the implementer picks final wording and iterates based on observed compaction behavior.
- Whether to include the `trigger` (`"manual"` | `"auto"`) in the instructions — may or may not help the summarizer; leave the call to implementation.
- Whether to preserve any existing `input.custom_instructions` (e.g. from a user-issued `/compact <text>`) by concatenating rather than overwriting — likely yes, but the exact join shape is a runtime detail.
- What to log on the no-op path for observability — probably a `Logger.warning` with `session_id`, but logging conventions are an execution detail.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```
SessionConfig.session_opts_for_workflow/3
  └─ put_hooks(opts)        # new step, appends :hooks to the keyword list
       └─ %{ PreCompact: [Destila.AI.Hooks.PreCompact] }

ClaudeCode.start_link(opts)  # (unchanged) — forwards :hooks to the CLI bridge

    ... session runs, context fills up ...

CLI detects compaction threshold → fires PreCompact hook
  │
  ▼
Destila.AI.Hooks.PreCompact.call(input, _tool_use_id)
  ├─ session_id = input.session_id
  ├─ ai_session = AI.get_ai_session_by_claude_session_id(session_id)
  ├─ workflow_session = Workflows.get_workflow_session!(ai_session.workflow_session_id)
  ├─ phase = Enum.at(Workflows.phases(ws.workflow_type), ws.current_phase - 1)
  ├─ phase_prompt = phase.initial_prompt.(workflow_session)
  └─ return {:ok, custom_instructions: """
        Preserve verbatim in the compacted context:

        <initial-prompt>
        #{phase_prompt}
        </initial-prompt>

        After the summary, include this reminder: "In the <initial-prompt>
        you can find the initial user prompt for reference."
        """}

(defensive paths return :ok so compaction proceeds unchanged)
```

## Implementation Units

- [ ] **Unit 1: Add AI session lookup by claude_session_id**

**Goal:** Expose a helper to find an `AI.Session` row by its `claude_session_id` so the hook can map Claude Code's `session_id` back to Destila's workflow context.

**Requirements:** R4, R5

**Dependencies:** None

**Files:**
- Modify: `lib/destila/ai.ex`
- Test: `test/destila/ai_test.exs` (create if missing, otherwise extend)

**Approach:**
- Add `get_ai_session_by_claude_session_id/1` next to `get_ai_session/1` and `get_ai_session_for_workflow/1` (around `lib/destila/ai.ex:14-48`).
- Implementation pattern: `Repo.get_by(Destila.AI.Session, claude_session_id: id)` — mirrors the shape of `get_ai_session_for_workflow/1`.
- Return `nil` when not found; no bang variant needed for this lookup since the hook path must tolerate missing rows.

**Patterns to follow:**
- `Destila.AI.get_ai_session_for_workflow/1` at `lib/destila/ai.ex:14`.
- `Destila.AI.get_ai_session/1` at `lib/destila/ai.ex:33`.

**Test scenarios:**
- Happy path: given a persisted `AI.Session` with `claude_session_id: "cs-abc"`, `get_ai_session_by_claude_session_id("cs-abc")` returns that session.
- Edge case: unknown `claude_session_id` returns `nil`.
- Edge case: `nil` argument returns `nil` (don't crash on callers with no id yet).
- Edge case: empty string returns `nil`.

**Verification:**
- Unit test passes.
- `mix credo` (or existing lint) does not flag the new public function.

- [ ] **Unit 2: Add `Destila.AI.Hooks.PreCompact` hook module**

**Goal:** Implement the `ClaudeCode.Hook` behaviour for `PreCompact`. Resolve workflow context from `session_id`, recompute the phase's initial prompt, and return `custom_instructions` wrapping it in `<initial-prompt>` with the reference line.

**Requirements:** R1, R2, R3, R5

**Dependencies:** Unit 1

**Files:**
- Create: `lib/destila/ai/hooks/pre_compact.ex`
- Test: `test/destila/ai/hooks/pre_compact_test.exs`

**Approach:**
- Declare `@behaviour ClaudeCode.Hook` and implement `call(input, tool_use_id)` with a head that pattern-matches on `%{hook_event_name: "PreCompact"} = input`.
- Resolve the workflow context using the chain documented in the High-Level Technical Design: `session_id → AI.Session → WorkflowSession → phase → initial_prompt`.
- Build `custom_instructions` as a multi-line string containing:
  - An instruction to the summarizer to preserve the `<initial-prompt>` block verbatim in the compacted context.
  - The `<initial-prompt>#{phase_prompt}</initial-prompt>` block.
  - The required reference line: *"In the `<initial-prompt>` you can find the initial user prompt for reference."*
- If the incoming `input.custom_instructions` is a non-empty string (e.g. from `/compact some text`), concatenate rather than discard so user-provided hints are preserved.
- Return `{:ok, custom_instructions: body}` on the happy path.
- On any lookup failure (missing ai_session, missing workflow_session, phase out of range, prompt fn raises), rescue and return `:ok` — log the failure with `session_id` for observability.
- Add a catch-all clause `def call(_input, _tool_use_id), do: :ok` so non-PreCompact events (defensive, should never route here) are silently ignored.

**Execution note:** Write the happy-path unit test first, then the defensive-no-op tests. The hook is small but the behavior contract is the interesting part — test-first keeps us honest about the return shape.

**Technical design:** *(optional — directional guidance, not implementation specification)*

```
@behaviour ClaudeCode.Hook

def call(%{hook_event_name: "PreCompact", session_id: sid} = input, _tool_use_id) do
  with ai_session when not is_nil(ai_session) <- AI.get_ai_session_by_claude_session_id(sid),
       ws when not is_nil(ws) <- Workflows.get_workflow_session(ai_session.workflow_session_id),
       {:ok, phase_prompt} <- compute_phase_prompt(ws) do
    {:ok, custom_instructions: build_instructions(phase_prompt, input[:custom_instructions])}
  else
    _ -> :ok
  end
rescue
  e -> Logger.warning("PreCompact hook failed: #{Exception.message(e)}"); :ok
end
```

**Patterns to follow:**
- Phase lookup pattern at `lib/destila/ai/conversation.ex:262-264` (`get_phase/2` helper using `Enum.at(Workflows.phases(...), phase_number - 1)`).
- Prompt invocation pattern at `lib/destila/ai/conversation.ex:33` (`phase_prompt = prompt_fn.(ws)`).
- Module layout under `lib/destila/ai/` (mirror `claude_session.ex`, `response_processor.ex`, etc.).

**Test scenarios:**
- Happy path: given a workflow session with `workflow_type: :brainstorm_idea`, `current_phase: 1`, and an `AI.Session` with `claude_session_id: "cs-1"`, the hook input `%{hook_event_name: "PreCompact", session_id: "cs-1", trigger: "auto"}` returns `{:ok, custom_instructions: body}` where `body` contains `<initial-prompt>`, the phase's initial prompt text, `</initial-prompt>`, and the reference line *"In the `<initial-prompt>` you can find the initial user prompt for reference."*
- Happy path with `trigger: "manual"`: same expectation, confirming the hook does not gate on trigger type.
- Happy path preserving pre-existing `custom_instructions`: input carries `custom_instructions: "focus on TODOs"`, returned body includes both the user instruction and the `<initial-prompt>` block.
- Edge case: unknown `session_id` → `AI.get_ai_session_by_claude_session_id/1` returns `nil` → hook returns `:ok`.
- Edge case: AI session exists but `workflow_session_id` references a deleted row → hook returns `:ok`.
- Edge case: workflow session's `current_phase` is out of range for its `workflow_type` → hook returns `:ok`.
- Error path: phase's `initial_prompt` function raises → hook rescues and returns `:ok`; a warning is logged.
- Catch-all: hook invoked with a non-PreCompact input (`hook_event_name: "PostToolUse"`) returns `:ok` without side effects.
- Integration scenario: the returned `custom_instructions` body matches the exact structural contract the `SessionConfig` integration test in Unit 3 expects — the `<initial-prompt>` tag pair is present, the phase prompt is verbatim, and the reference line is present.

**Verification:**
- All hook unit tests pass.
- `mix compile --warnings-as-errors` is clean.
- Running `mix test test/destila/ai/hooks/pre_compact_test.exs` succeeds.

- [ ] **Unit 3: Register the PreCompact hook via SessionConfig**

**Goal:** Add `:hooks` to the options produced by `SessionConfig.session_opts_for_workflow/3` so every workflow-backed Claude Code session gets the PreCompact hook automatically.

**Requirements:** R1, R4

**Dependencies:** Unit 2

**Files:**
- Modify: `lib/destila/ai/session_config.ex`
- Test: `test/destila/ai/session_config_test.exs` (create or extend)

**Approach:**
- Add a `put_hooks/1` private helper that does `Keyword.put(opts, :hooks, %{PreCompact: [Destila.AI.Hooks.PreCompact]})`.
- Insert `|> put_hooks()` in the pipeline at `session_config.ex:28-33`, after `put_cwd(ai_session)`.
- Keep `:hooks` as a plain map with atom keys (PascalCase) — this is the exact shape the `claude_code` SDK expects.
- No changes needed in `ClaudeSession.init/1` — it already forwards unknown options verbatim to `ClaudeCode.start_link/1`. Verify this during implementation by reading `lib/destila/ai/claude_session.ex:145-194` (opts pass through after `Keyword.pop` extracts the Destila-specific keys).

**Patterns to follow:**
- Existing `put_*` helpers in `lib/destila/ai/session_config.ex:36-65`.

**Test scenarios:**
- Happy path: `SessionConfig.session_opts_for_workflow(ws, 1)` returns a keyword list whose `:hooks` key equals `%{PreCompact: [Destila.AI.Hooks.PreCompact]}`.
- Integration scenario: `:hooks` is present alongside the existing options (`:append_system_prompt`, `:allowed_tools`, `:ai_session_id`, `:cwd`, `:resume`) — registering hooks does not displace any existing option.
- Edge case: when called with `base_opts` that already contain `:hooks` (none do today, but guard against future callers), the existing entry is overwritten or merged. Document the chosen behavior in the test; overwriting is acceptable since `base_opts` users don't set hooks currently.

**Verification:**
- `mix test test/destila/ai/session_config_test.exs` passes.
- Manual smoke: start a workflow phase locally, let it run until compaction fires (or force `/compact` via the remote shell), and confirm the post-compact context includes the `<initial-prompt>` block and reference line. Documented as a verification step, not a test.

- [ ] **Unit 4: Update the workaround comment in Conversation**

**Goal:** Reflect the new hook in the comment above `lib/destila/ai/conversation.ex:79-83` so future readers understand the hook is the primary mechanism and the auto-advance branch is now a safety net.

**Requirements:** R6

**Dependencies:** Unit 3

**Files:**
- Modify: `lib/destila/ai/conversation.ex`

**Approach:**
- Keep the `_ when non_interactive -> :phase_complete` branch at `conversation.ex:137`.
- Rewrite the docstring comment at `conversation.ex:79-83` to note that the `Destila.AI.Hooks.PreCompact` hook now re-injects the phase prompt into compacted context and that this branch remains as a belt-and-suspenders fallback if the hook doesn't fire or the summarizer drops the block.

**Test scenarios:** Test expectation: none — pure comment change, no behavioral impact.

**Verification:**
- `git diff` shows only comment changes in `conversation.ex`.
- Existing `Destila.AI.ConversationTest` (or equivalent) still passes unchanged.

## System-Wide Impact

- **Interaction graph:** `SessionConfig.session_opts_for_workflow/3` is called from `Destila.Workers.AiQueryWorker` (`lib/destila/workers/ai_query_worker.ex:22-29`). Every worker-run session will now register the hook. The one-off `ClaudeCode.query/2` call in `lib/destila/ai.ex:232` (title generation) bypasses `SessionConfig` and will not get the hook — correct, since that call is stateless and never compacts.
- **Error propagation:** If the hook raises, the rescue in Unit 2 swallows it to `:ok`. If the hook callback times out (default 60 s per the SDK), the CLI proceeds without the preservation directive — functionally the same as "no re-injection," which is acceptable. If `AI.get_ai_session_by_claude_session_id/1` or `Workflows.get_workflow_session/1` throws (e.g., Ecto connection pool exhaustion), the rescue catches it.
- **State lifecycle risks:** The hook reads `workflow_session.current_phase`. If compaction fires during a phase transition (race between `AI.update_ai_session` writing a new `claude_session_id` and the hook firing on the old one), the hook may resolve to a stale phase. This is acceptable — the stale phase's prompt is still more useful than nothing, and the race window is microseconds. Flag as a known quirk, no mitigation needed.
- **API surface parity:** No external API changes; the hook is an internal enhancement. No MCP tool changes, no LiveView changes.
- **Integration coverage:** The hook module's unit tests prove the return shape. The `SessionConfig` test proves registration. Actual end-to-end behavior (the summarizer honoring `custom_instructions`) is a property of `claude_code` + the Claude Code CLI — outside our test boundary. Manual verification via a long-running phase or `/compact` is the realistic integration check.
- **Unchanged invariants:** `phase_start/1` still computes and sends the phase prompt as the kickoff query — the hook is additive, not replacing that path. The `:append_system_prompt`, `:allowed_tools`, `:ai_session_id`, `:resume`, and `:cwd` options remain unchanged. The non-interactive auto-advance branch at `conversation.ex:137` stays in place.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Summarizer ignores the `custom_instructions` preservation directive and drops the `<initial-prompt>` block anyway | Accepted — this is a property of the compaction LLM. The non-interactive auto-advance at `conversation.ex:137` remains as a safety net. If we observe frequent drops, a follow-up plan can add an `UserPromptSubmit` hook that re-injects via `additional_context` post-compaction. |
| Hook times out on slow DB calls | The two lookups (`get_ai_session_by_claude_session_id`, `get_workflow_session`) are indexed single-row queries and complete in milliseconds. Default SDK timeout is 60 s. If we ever see timeouts, pre-caching at session start would be the next step. |
| `session_id` in the hook input is not the `claude_session_id` we stored | Verified via research (`input.session_id` is the CLI session id, same value `ClaudeCode.Message.ResultMessage` carries — we already store this in `AI.Session.claude_session_id` at `conversation.ex:107-108`). If the SDK changes semantics, tests in Unit 2 will catch it. |
| Hook runs on non-workflow Claude Code sessions (e.g. future code paths that bypass `SessionConfig`) | Registration only happens in `SessionConfig.session_opts_for_workflow/3`. Other call sites (title generation via `ClaudeCode.query/2` at `lib/destila/ai.ex:232`) don't pass through here and won't register the hook. |
| Phase prompt is too large and blows past `custom_instructions` size limits | Phase prompts are short (a few hundred to a few thousand characters). No known hard limit, but if one exists the worst case is the SDK truncating — the reference line still survives. No mitigation needed upfront. |

## Documentation / Operational Notes

- Update the inline comment in `Destila.AI.Conversation.handle_ai_result/2` to reference the hook (Unit 4).
- No README / docs / runbook changes. This is an internal reliability improvement; users don't see it directly.
- No migration, no feature flag, no monitoring hook. If we want visibility, a `Logger.info` on successful hook invocation can be added in Unit 2 — deferred to implementation taste.

## Sources & References

- Related code: `lib/destila/ai/session_config.ex:24-34`, `lib/destila/ai/claude_session.ex:145-194`, `lib/destila/ai/conversation.ex:21-53`, `lib/destila/ai/conversation.ex:79-83`, `lib/destila/workflows/phase.ex:11-18`.
- Related prior plan: `docs/plans/2026-04-15-004-refactor-upgrade-claude-code-package-plan.md` (confirms `claude_code ~> 0.36` — hooks available).
- External docs: https://github.com/guess/claude_code/blob/main/docs/guides/hooks.md, https://github.com/guess/claude_code/blob/main/lib/claude_code/hook.ex, https://github.com/guess/claude_code/blob/main/lib/claude_code/hook/output/pre_compact.ex.
- External reference: https://docs.claude.com/en/docs/claude-code/hooks (Anthropic CLI hooks reference — confirms PreCompact event semantics).
