---
title: "feat: Re-inject phase prompt around compaction via Claude Code hook"
type: feat
status: active
date: 2026-04-21
---

# feat: Re-inject phase prompt around compaction via Claude Code hook

## Overview

When Claude Code compacts a long conversation, the summary often loses the
original phase prompt that describes the task boundaries, how to signal
completion (e.g. `mcp__destila__session` with `phase_complete`), and
exported-metadata conventions. Symptoms already referenced in-code:
`handle_ai_result/2` auto-advances non-interactive phases "to avoid getting
stuck when context compaction hides the original phase prompt."

This plan restores that context around the compaction boundary by:

1. Wrapping the initial phase prompt inside an `<initial-prompt>` tag so it is
   visually and structurally recognizable in the transcript.
2. Persisting the wrapped prompt to a known file inside the worktree at each
   phase start.
3. Installing a Claude Code hook in the worktree that fires when compaction
   occurs, reads that file, and re-injects the prompt plus a short reference
   note ("In the `<initial-prompt>` tag above you can find the initial user
   prompt for reference.").

## Problem Frame

- Destila orchestrates long-running phases. When a phase generates enough
  tokens to trigger auto-compact (or if the user issues `/compact`), the
  compacted summary can drop phase-specific instructions, breaking
  autonomous progression and structured tool usage.
- The existing workaround in `lib/destila/ai/conversation.ex` is defensive
  (auto-advance non-interactive phases), not corrective. The root problem is
  that the phase prompt is not re-presented to the model post-compact.
- Claude Code supports per-project `.claude/settings.json` hooks. Destila
  already sets `setting_sources: ["user", "project"]` in
  `lib/destila/ai/claude_session.ex`, so hooks written into the worktree
  are honored automatically.

## Requirements Trace

- R1. Each phase start wraps the phase prompt inside `<initial-prompt>` tags
  within the `# Prompt` section delivered to Claude.
- R2. After compaction, the phase prompt is re-delivered to Claude as
  conversation context, followed by a short reference sentence naming the
  `<initial-prompt>` tag.
- R3. The mechanism must be per-worktree (each workflow session has its own
  worktree, so prompts do not leak between sessions).
- R4. When a phase advances (same worktree, next phase), subsequent
  compactions re-inject the *current* phase's prompt, not the previous one.
- R5. The feature must not regress existing tests or require changing the
  Claude session lifecycle (no new GenServers, no changes to
  `SessionProcess` state machine).

## Scope Boundaries

- Only the Claude Code hook surface is used. No MCP changes, no changes to
  `lib/destila/ai/tools.ex`.
- Only `SessionStart` with matcher `compact` is configured. `startup`,
  `resume`, and `clear` matchers are explicitly out of scope (the initial
  phase prompt is already sent as the first user message at phase start, and
  `:resume` sessions continue the same conversation).
- Blocking compaction is out of scope. We do not use `PreCompact` for
  blocking; we only re-supply context after compaction.
- Changes to how `current_scope` / auth work are out of scope.
- Removing or rewriting the existing non-interactive auto-advance safeguard
  in `handle_ai_result/2` is out of scope. Leave it in as a belt-and-braces
  layer.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/ai/conversation.ex` — `phase_start/1` assembles the `# Prompt`
  section from `prompt_fn.(ws)`. This is the single place where phase prompts
  are constructed and where the `<initial-prompt>` wrapping belongs.
- `lib/destila/ai/claude_session.ex` — Initializes `ClaudeCode.start_link/1`
  with `setting_sources: ["user", "project"]`, `cwd` is taken from
  `ai_session.worktree_path`. Confirms `.claude/settings.json` inside the
  worktree is loaded.
- `lib/destila/ai/session_config.ex` — Passes `:cwd` through from
  `ai_session.worktree_path`.
- `lib/destila/workflows/phase.ex` — Phase struct (`system_prompt`,
  `session_strategy`, `allowed_tools`, etc.).
- `lib/destila/workflows/brainstorm_idea_workflow.ex`,
  `lib/destila/workflows/code_chat_workflow.ex` — Examples where phase
  prompts reference `workflow_session.user_prompt`; those prompts are what
  we want preserved.
- `test/destila/ai/conversation_test.exs` — Pattern for testing conversation
  mechanics; uses `DestilaWeb.ConnCase, async: false` and factories for
  workflow sessions / AI sessions.

### Institutional Learnings

- `lib/destila/ai/conversation.ex` already documents the compaction blind
  spot: "This avoids getting stuck when context compaction hides the
  original phase prompt (which describes how to signal completion) from the
  agent." This plan directly addresses that symptom.
- Destila workflow sessions each run in an isolated worktree (see
  `AI.create_ai_session` flow). Writing files under the worktree is the
  established way to expose per-session state to Claude.

### External References

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks
  - `PreCompact` hook fires before compaction but **cannot** inject
    additional context — it only supports `decision: "block"` / exit 2.
    The hook's stdout is discarded.
  - `SessionStart` hook supports `additionalContext` (via JSON output) and
    plain stdout is appended as context. Its matcher `compact` fires
    immediately after auto or manual compaction completes.
- This is the driver for the key decision below: we use `SessionStart` with
  matcher `compact`, not `PreCompact`, because only that surface can
  actually re-inject text after compaction.

## Key Technical Decisions

- **Use `SessionStart` matcher `compact`, not `PreCompact`**: `PreCompact`
  cannot add context (confirmed against Claude Code docs). The semantic
  intent of the user request ("re-add the phase prompt around compaction")
  is satisfied by `SessionStart(compact)`, which fires right after
  compaction and supports `additionalContext`/stdout. The plan acknowledges
  the user framing while selecting the correct hook.
- **Per-worktree settings file**: Write `.claude/settings.json` inside the
  worktree (matches Destila's existing `setting_sources: ["user",
  "project"]`). No global hook installation, no leakage between workflow
  sessions.
- **Separate command script from data file**: The hook entry in
  `settings.json` points at a small shell script shipped from `priv/hooks/`
  and copied into `<worktree>/.claude/hooks/reinject_initial_prompt.sh` at
  setup time. The script reads the current phase prompt from
  `<worktree>/.claude/destila/initial_prompt.txt` and prints it with the
  wrapper tag and reference sentence. This keeps settings.json static and
  makes per-phase updates a simple file write.
- **Single source of truth for wrapping**: Wrapping with
  `<initial-prompt>` happens once, in `phase_start/1`, before the prompt is
  both (a) sent to Claude and (b) persisted to the worktree file. Both the
  first-turn prompt and the hook re-injection use the same wrapped form.
- **Idempotent setup**: Settings and hook script are written on every phase
  start (cheap, covers worktrees that existed before this feature shipped).
  The prompt file is overwritten each phase start so the *current* phase's
  prompt is always what the hook re-injects.

## Open Questions

### Resolved During Planning

- **Which hook event?** `SessionStart` with matcher `compact`. `PreCompact`
  cannot inject context (docs confirm: no `additionalContext` field, stdout
  discarded).
- **Where do hook files live?** Inside the worktree — Destila already
  configures `setting_sources: ["user", "project"]`, so the worktree's
  `.claude/settings.json` is honored.
- **Does the hook need access to DB state?** No. The phase prompt is
  already fully rendered at phase start; persisting the rendered text to a
  worktree file is sufficient. The hook is a pure file read + echo.
- **Should we wrap only the phase prompt or the whole first query
  (tools + skills + service + prompt)?** Only the phase prompt portion.
  Tool descriptions and skills reload via their own mechanisms; re-injecting
  them on every compaction would balloon context. Re-injecting just the
  phase prompt matches the user's intent ("the initial user prompt for
  reference").

### Deferred to Implementation

- **Exact shell-script formatting of the reference sentence**: the sentence
  shape is specified ("In the `<initial-prompt>` tag above you can find
  the initial user prompt for reference."), but trailing newlines and quote
  escaping are best finalized when the script is written.
- **Whether to also fire on matcher `resume`**: deferred. Destila resumes
  Claude sessions via `:resume` option in
  `session_config.ex`. Observing whether resumed sessions need re-injection
  is better learned at execution time; the plan scopes to `compact` only
  and can be extended later.
- **Cleanup of `.claude/destila/` on session archive**: deferred. The
  existing worktree cleanup path will remove these files along with the
  worktree. If worktrees ever outlive sessions, revisit.

## Implementation Units

- [ ] **Unit 1: Wrap phase prompt in `<initial-prompt>` tag at phase start**

**Goal:** The `# Prompt` section sent to Claude at phase start contains the
phase prompt wrapped in `<initial-prompt>...</initial-prompt>` tags.

**Requirements:** R1, R5

**Dependencies:** None

**Files:**
- Modify: `lib/destila/ai/conversation.ex`
- Test: `test/destila/ai/conversation_test.exs`

**Approach:**
- In `phase_start/1`, after `phase_prompt = prompt_fn.(ws)`, build a wrapped
  string `"<initial-prompt>\n#{phase_prompt}\n</initial-prompt>"` and use
  that in the `# Prompt\n\n...` section.
- Keep the wrapping local to `phase_start/1` — do not propagate it through
  `send_message/2` or other call sites (user messages are not phase prompts).

**Patterns to follow:**
- Existing `sections = [...] |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")`
  composition style in `phase_start/1`.

**Test scenarios:**
- Happy path — phase_start with a workflow session sending a phase prompt
  containing "Describe your idea" produces a query whose `# Prompt` section
  contains `<initial-prompt>` before "Describe your idea" and
  `</initial-prompt>` after it.
- Edge case — phase_prompt with embedded angle brackets (e.g. a prompt that
  contains the literal string "<example>") is wrapped without corruption —
  the outer `<initial-prompt>` tag is still the first and last tag in the
  wrapped block.
- Edge case — user messages routed through `send_message/2` are **not**
  wrapped (verifies scope of change).

**Verification:**
- Enqueued Oban job payload for `AiQueryWorker` contains a `"query"` field
  whose text includes `<initial-prompt>` and `</initial-prompt>` around the
  phase prompt.

---

- [ ] **Unit 2: Persist wrapped phase prompt to per-worktree file**

**Goal:** On phase start, write the wrapped phase prompt to
`<worktree_path>/.claude/destila/initial_prompt.txt` so a hook can read it.

**Requirements:** R2, R3, R4

**Dependencies:** Unit 1 (wrapping logic reused), AI session must have a
`worktree_path` at phase start (already required by existing flows).

**Files:**
- Create: `lib/destila/ai/compact_hook_setup.ex` (new, small module
  encapsulating file-write concerns)
- Modify: `lib/destila/ai/conversation.ex` (call the new module from
  `phase_start/1`)
- Test: `test/destila/ai/compact_hook_setup_test.exs` (new)

**Approach:**
- Introduce `Destila.AI.CompactHookSetup` with a single public function
  `install/2` that accepts `worktree_path` and `phase_prompt` (already
  wrapped or to-be-wrapped — see below) and writes the prompt file.
- Keep wrapping logic in `conversation.ex` so both the Claude query and the
  persisted file use the same wrapped string.
- If `worktree_path` is `nil` (shouldn't happen in practice, but defend at
  the boundary since it is I/O), return `:ok` without writing — this keeps
  `phase_start/1` resilient for test setups that skip worktree creation.
- Ensure the target directory exists via `File.mkdir_p!/1`.

**Patterns to follow:**
- Module layout mirrors existing small AI helper modules like
  `lib/destila/ai/session_config.ex` (pure function, no GenServer).

**Test scenarios:**
- Happy path — given a tmp dir as worktree and a prompt string, after
  `install/2` the file at
  `<tmp>/.claude/destila/initial_prompt.txt` exists and contains the exact
  prompt string (including `<initial-prompt>` wrapping).
- Happy path — calling `install/2` twice with different prompts overwrites
  the file with the second prompt (guarantees R4: the current phase's
  prompt is what the hook reads).
- Edge case — `worktree_path` is `nil` → function returns `:ok` and writes
  nothing (no crash).
- Edge case — the target directory does not yet exist → `install/2` creates
  `.claude/destila/` and succeeds.
- Integration — `Conversation.phase_start/1` writes the file with the
  wrapped prompt for the current phase. Assert file contents equal the
  same wrapped string that appears in the Oban job payload.

**Verification:**
- After `phase_start/1` runs in a workflow session with a tmp worktree, the
  file exists, is readable, and matches the prompt sent to Claude.

---

- [ ] **Unit 3: Ship the hook shell script and install it into worktrees**

**Goal:** A small POSIX shell script exists in `priv/hooks/` and is copied
into each worktree's `.claude/hooks/` directory. The script reads the
initial-prompt file and prints it followed by the reference sentence.

**Requirements:** R2, R3

**Dependencies:** Unit 2

**Files:**
- Create: `priv/hooks/reinject_initial_prompt.sh`
- Modify: `lib/destila/ai/compact_hook_setup.ex` (copy script into worktree
  during `install/2`)
- Test: `test/destila/ai/compact_hook_setup_test.exs` (extend)

**Approach:**
- The shipped script lives in `priv/hooks/reinject_initial_prompt.sh` and
  is looked up at runtime via `:code.priv_dir(:destila)`.
- The script reads
  `$CLAUDE_PROJECT_DIR/.claude/destila/initial_prompt.txt` (Claude Code
  exposes `CLAUDE_PROJECT_DIR` as the worktree root for hooks; fall back to
  `./.claude/destila/initial_prompt.txt` relative to `cwd` if unset).
- If the file is missing, the script exits 0 with empty stdout (no-op — do
  not block compaction).
- If the file exists, the script prints its contents followed by a blank
  line and the reference sentence:
  `"In the <initial-prompt> tag above you can find the initial user prompt for reference."`
- `install/2` copies the script to `<worktree>/.claude/hooks/` and sets
  mode `0755`. Overwrite on every call (idempotent, cheap).

**Patterns to follow:**
- Other Destila files under `priv/` (e.g. `priv/skills/`) are shipped with
  the app and accessed via `:code.priv_dir(:destila)`.

**Test scenarios:**
- Happy path — after `install/2`, the script exists at
  `<worktree>/.claude/hooks/reinject_initial_prompt.sh` and has executable
  mode (`File.stat!` mode check).
- Happy path — running the script in a shell with the prompt file present
  (use `System.cmd("sh", [path])` in the test) prints the file contents
  followed by the reference sentence.
- Edge case — running the script when the prompt file is absent exits 0
  with empty stdout.
- Edge case — calling `install/2` twice overwrites the script (simulates
  Destila upgrade where the shipped script changes between releases).

**Verification:**
- Script passes `shellcheck` (if available in CI) and behaves correctly in
  both "file present" and "file absent" scenarios.

---

- [ ] **Unit 4: Write `.claude/settings.json` declaring the SessionStart(compact) hook**

**Goal:** Each worktree contains a `.claude/settings.json` that registers
the shipped script as a `SessionStart` hook for matcher `compact`.

**Requirements:** R2, R3

**Dependencies:** Unit 3

**Files:**
- Modify: `lib/destila/ai/compact_hook_setup.ex` (add settings.json write)
- Test: `test/destila/ai/compact_hook_setup_test.exs` (extend)

**Approach:**
- `install/2` writes `<worktree>/.claude/settings.json` with the following
  shape (values to be serialized via `Jason.encode!`):

  ```
  {
    "hooks": {
      "SessionStart": [
        {
          "matcher": "compact",
          "hooks": [
            { "type": "command",
              "command": ".claude/hooks/reinject_initial_prompt.sh" }
          ]
        }
      ]
    }
  }
  ```

- If a `settings.json` already exists in the worktree (unlikely today, but
  possible once Destila grows more hook features), merge the `SessionStart`
  array by appending our entry if one with the same command is not present.
  Leave all other keys untouched.
- Keep merge logic inside `CompactHookSetup.merge_settings/2` so it is
  unit-testable without touching disk.

**Patterns to follow:**
- JSON handling via `Jason` (standard in Phoenix apps).
- Pure functional merge + I/O boundary separation (e.g.
  `session_config.ex` keeps logic pure and I/O thin).

**Test scenarios:**
- Happy path — after `install/2`, `settings.json` exists, parses as JSON,
  and contains exactly one `SessionStart` entry with matcher `compact` and
  command pointing at `.claude/hooks/reinject_initial_prompt.sh`.
- Edge case — merging into a pre-existing settings.json that has other
  `hooks` (e.g. `PreToolUse`) preserves them and only appends the new
  `SessionStart` compact entry.
- Edge case — merging into a settings.json that *already* has our compact
  entry (same command) does not duplicate it.
- Edge case — a pre-existing settings.json that is not valid JSON is
  handled without crashing the phase. Decision: log a warning and overwrite
  the file (Destila owns the worktree's `.claude/` directory; this is a
  safe default). Test that invalid input triggers the overwrite path.

**Verification:**
- Destila starts a phase → worktree contains a well-formed `settings.json`
  and executable hook script → running Claude Code in that worktree would
  load the hook via its standard `setting_sources` mechanism.

---

- [ ] **Unit 5: End-to-end integration wiring and existing-test audit**

**Goal:** `Conversation.phase_start/1` calls `CompactHookSetup.install/2`
with the worktree path and wrapped phase prompt. Existing tests continue
to pass; new happy-path integration test covers the full flow.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** Units 1–4

**Files:**
- Modify: `lib/destila/ai/conversation.ex` (call `CompactHookSetup.install/2`
  from `phase_start/1`, after `phase_prompt` is wrapped and before the
  Oban worker is enqueued)
- Test: `test/destila/ai/conversation_test.exs` (extend with an integration
  scenario that stubs a tmp worktree path and asserts file presence)

**Approach:**
- Thread the `ai_session.worktree_path` into `phase_start/1` via the
  already-returned `session = ensure_ai_session(ws)`.
- If `session.worktree_path` is `nil` (legacy sessions, test setups),
  skip the install cleanly (Unit 2 already handles this branch).
- Do not call `install/2` from `send_message/2` — prompts only change at
  phase start, so there is no reason to rewrite the file per user message.

**Patterns to follow:**
- Compose with existing helpers inside `phase_start/1`; do not introduce
  new Oban jobs or GenServers.

**Test scenarios:**
- Integration — full `phase_start/1` call against a workflow session whose
  AI session has a `worktree_path` pointing at a tmp dir. Asserts:
  1. Oban job enqueued with a `# Prompt` section containing
     `<initial-prompt>` wrapping.
  2. `<tmp>/.claude/destila/initial_prompt.txt` contains the same wrapped
     prompt.
  3. `<tmp>/.claude/hooks/reinject_initial_prompt.sh` exists and is
     executable.
  4. `<tmp>/.claude/settings.json` parses as JSON and declares the
     SessionStart compact hook.
- Edge case — AI session has no `worktree_path`: phase_start still
  succeeds, Oban job still enqueued, no files created in a tmp dir.
- Regression — existing `conversation_test.exs` cases (`handle_ai_error`,
  etc.) continue to pass unchanged.

**Verification:**
- `mix test test/destila/ai/conversation_test.exs` passes.
- `mix test test/destila/ai/compact_hook_setup_test.exs` passes.
- `mix precommit` reports no new issues.

## System-Wide Impact

- **Interaction graph:** `Conversation.phase_start/1` gains a call edge to
  the new `CompactHookSetup.install/2` which in turn writes three files
  into the worktree. No other call sites are affected.
- **Error propagation:** File-write failures in `install/2` should not
  abort the phase. Wrap I/O at the boundary and log on failure; the phase
  query still gets enqueued. This preserves existing "phase always starts"
  semantics.
- **State lifecycle risks:** The prompt file is overwritten per phase
  start, so stale content from a prior phase cannot leak into a later
  compaction. Worktree deletion (on session archive) removes all three
  files alongside everything else under the worktree — no extra cleanup
  needed.
- **API surface parity:** No MCP tools, no HTTP endpoints, no public
  Phoenix routes changed. Internal Elixir API gains `CompactHookSetup`.
- **Integration coverage:** Unit 5 provides a single integration test that
  exercises the full wrap-persist-install sequence.
- **Unchanged invariants:** `Phase` struct, `SessionProcess` state machine,
  `ClaudeSession` GenServer lifecycle, Oban worker shape, and
  `handle_ai_result/2` non-interactive auto-advance safeguard are all
  preserved. No DB schema changes.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Claude Code docs change the `SessionStart(compact)` behavior or remove stdout-as-context support. | Hook stdout is an established Claude Code feature; if it regresses we can migrate to JSON `additionalContext`. The shell script is trivial to change. |
| User installs a conflicting `.claude/settings.json` via their own tooling. | `CompactHookSetup.merge_settings/2` appends non-destructively when the file is valid JSON; invalid JSON triggers overwrite with a logged warning. |
| Hook fails to execute (e.g. non-POSIX environment, missing `sh`). | A failing hook cannot block compaction (only an explicit `decision: "block"` can). Claude Code continues normally; worst case the re-injection is skipped. |
| Prompt file contains secrets the user would not want re-broadcast. | The prompt file only contains data already sent to Claude at phase start, so there is no new exposure. |
| Worktree-local settings.json confuses a developer debugging locally with `claude` CLI. | Keep the file narrowly scoped to the `SessionStart(compact)` hook. Document in the hook script header that it is managed by Destila. |

## Documentation / Operational Notes

- No user-facing docs change. The behavior is transparent to end users:
  phases simply become more resilient to long conversations.
- Developers running `claude` directly in a Destila worktree will now see a
  post-compact context injection. Add a one-line header comment at the top
  of `reinject_initial_prompt.sh` noting it is managed by Destila.

## Sources & References

- Claude Code hooks documentation — https://code.claude.com/docs/en/hooks
  (consulted 2026-04-21; confirms `PreCompact` cannot add context and
  `SessionStart` matcher `compact` supports `additionalContext` / stdout).
- Related code:
  - `lib/destila/ai/conversation.ex` — phase_start prompt assembly and
    existing comment about compaction hiding the phase prompt.
  - `lib/destila/ai/claude_session.ex` — `setting_sources: ["user",
    "project"]` confirms worktree settings.json is loaded.
  - `lib/destila/ai/session_config.ex` — `:cwd` wiring from
    `ai_session.worktree_path`.
  - `lib/destila/workflows/phase.ex` — Phase struct.
- Related PRs/issues: none yet.
