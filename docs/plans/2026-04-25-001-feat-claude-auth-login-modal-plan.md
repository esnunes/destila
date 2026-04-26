---
title: "feat: In-app Claude CLI auth login modal with retry"
type: feat
status: active
date: 2026-04-25
---

# feat: In-app Claude CLI auth login modal with retry

## Overview

When the AI session reports a Claude CLI authentication failure, the user can
recover entirely from the chat UI. A "Login to Claude" action renders directly
below the failed system message bubble. Clicking it opens a modal that spawns
`claude auth login` under a pty, displays the OAuth URL the CLI prints, accepts
the resulting token via a form, feeds the token to the same CLI process via
stdin, and on success closes itself and re-runs the user turn that originally
failed -- without leaving the browser.

## Problem Frame

Today, when the local `claude` CLI's credentials expire, the AI session emits
an auth-failure system bubble that simply tells the user to "run `claude
login` in your terminal to re-authenticate, then retry." The user must drop
into a terminal, complete an OAuth flow, paste a token back, and then
manually re-trigger the failed turn from the UI. That workflow is fragile and
inconsistent with the rest of Destila, which keeps developers in the chat UI.

The auth flow should be:

- discoverable directly from the failure bubble
- self-contained -- spawn the CLI, capture the URL, accept the token, verify
- self-cleaning -- never leave an orphaned `claude auth login` OS process
- self-completing -- on success, retry the exact AI turn that failed

## Requirements Trace

- R1. The auth-failure bubble is detectable structurally, not by string
  matching, so chat rendering can opaquely key the action off it.
- R2. A "Login to Claude" action renders **directly below** any auth-error
  bubble (sibling, not nested) and on no other system bubble.
- R3. Clicking the action opens a modal that spawns a fresh
  `claude auth login` process for that flow.
- R4. The modal shows: a loading state until the CLI prints the URL; then the
  URL with copy-to-clipboard; then a token input + submit; then a verifying
  state after submission.
- R5. On success, the modal auto-closes and the failed AI turn is retried.
- R6. On invalid token, the modal shows the CLI's error, kills the spawned
  process, and requires "Restart" to obtain a fresh URL.
- R7. On CLI exit before a URL is printed (or url-wait timeout), the modal
  shows an error and exposes "Restart".
- R8. Closing the modal (X / backdrop / Escape) terminates the spawned
  process. Reopening starts brand-new -- no reused URL/state.
- R9. Authentication is machine-wide (one Claude login, shared by the
  Destila instance). A second open while one is in progress reuses the
  in-progress flow rather than spawning a competing CLI process.
- R10. The retry path targets the specific failed user turn -- not a generic
  phase retry.
- R11. No orphan `claude` OS processes survive: modal close, LV crash,
  application restart, or "Restart" each tear the process down.

## Scope Boundaries

- Not introducing per-user authentication or session-local Claude tokens. One
  Destila instance == one machine-wide Claude login.
- Not switching the project's pty backend. The institutional decision is to
  keep `:expty` behind `Destila.Terminal.PTY` and defer the `:erlexec` swap
  (see `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`). The
  user's prompt mentions adding `:erlexec` -- this plan **does not** add
  `:erlexec`; it reuses the existing wrapper. Captured in Key Technical
  Decisions.
- Not adding a generic "retry last turn" UI affordance. The retry path is
  triggered only by a successful auth-login flow.
- Not touching the existing `retry_phase` button in the chat header. That
  remains a phase-level kickoff retry.
- Not adding browser-side OAuth (popup, postMessage). The user opens the URL
  in their own browser and pastes the token back.

## Context & Research

### Relevant Code and Patterns

- `lib/destila/ai/conversation.ex:142-186` -- `handle_ai_error/2`,
  `error_message/1`, `auth_failed_message/1`, `authentication_error?/1`. This
  is where the auth-failure system message is created today; it's the hook
  point for stamping `message_type: :auth_error`.
- `lib/destila/ai/claude_session.ex:226-298` -- where the `:auth_error` key
  is populated upstream from a `ClaudeCode.Message.AuthStatusMessage`.
- `lib/destila/ai/message.ex` -- schema. Today has only `role :: :system | :user`.
  We add a `message_type` `Ecto.Enum` column.
- `lib/destila/ai/response_processor.ex:39-92` and `derive_message_type/3`
  at line 180 -- runtime message_type derivation. It currently only emits
  `:phase_advance`. We change it to prefer the persisted `message_type` value
  when present, and continue to derive `:phase_advance` from `raw_response`
  for legacy rows.
- `lib/destila/ai.ex:202-212` -- `create_message/2` (already broadcasts
  `{:message_added, msg}` on `"store:updates"`). Pass through the new
  `message_type` attribute.
- `lib/destila_web/components/chat_components.ex:282-419` --
  `chat_message/1` and `render_chat_message/1`. Add a new `render_chat_message/1`
  head matching `%{message: %{message_type: :auth_error}}` that renders the
  system bubble plus a sibling action below it (left-indent `ml-11` matches
  the avatar+gap rhythm already used at line 128).
- `lib/destila_web/live/follow_up_modal.ex` -- the canonical in-app modal
  shape. Stateless `use DestilaWeb, :html` function component; backdrop +
  panel + close-X + ARIA; events bubble straight to the parent LiveView via
  `phx-click`/`phx-window-keydown="close_..."`/`phx-key="escape"`. The
  Claude login modal mirrors this exactly.
- `lib/destila/terminal/pty.ex` and `lib/destila/terminal/server.ex` -- the
  `Destila.Terminal.PTY` wrapper and its single existing consumer. The new
  `Destila.AI.AuthLogin` GenServer copies `Destila.Terminal.Server`'s shape:
  `Process.flag(:trap_exit, true)`, `PTY.spawn(self(), cmd: ..., args: ...)`,
  consume `{:pty_output, handle, iodata}` / `{:pty_exit, handle, _}` in
  `handle_info`, kill in `terminate/2`.
- `lib/destila/sessions/session_process.ex:48-59, 189-191, 270-299` --
  `SessionProcess` client API and the `handle_send_message/3` /
  `handle_retry/2` shapes. The new `retry_after_auth/1` is a sibling of
  `send_message/2` and `retry/1`.
- `lib/destila/workers/ai_query_worker.ex:34-41` -- the Oban worker that
  carries a phase + query. The retry path enqueues a new instance of this
  worker with the prior user turn's content.
- `lib/destila/pub_sub_helper.ex` -- topic helper conventions. New
  `claude_auth_login_topic/0` lives here.
- `lib/destila/application.ex:11-25` -- supervision tree. Add
  `Destila.AI.AuthLogin` as a globally-named singleton child (start
  `:transient` so a crash restarts the genserver fresh on next open).
- `lib/destila_web/live/workflow_runner_live.ex:29-89, 172-223, 278-421,
  494-604, 1331-1336` -- mount + assigns + chat events + handle_info + modal
  render slot. The new modal/events follow `FollowUpModal`'s wiring exactly.

### Institutional Learnings

- `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md` -- "use
  `Destila.Terminal.PTY`, do not introduce a parallel pty pathway." This
  plan defers to that decision; it does **not** add `:erlexec`.

### External References

None needed. The Claude CLI's `claude auth login` URL/token flow is well
understood by the team and exercised manually today; the plan does not
depend on documentation behavior beyond stable stdout output.

## Key Technical Decisions

- **Use `Destila.Terminal.PTY`, not `:erlexec`.** The user prompt asks for
  `:erlexec`. The institutional learning explicitly defers that swap and
  routes all pty consumers through the wrapper. Pulling in `:erlexec` here
  would fork the codebase's pty story. We pass `cmd: "/usr/bin/env"`,
  `args: ["TERM=xterm-256color", "claude", "auth", "login"]` (matching the
  existing `Destila.Terminal.Server` env shape) so the CLI sees a real tty.
- **`message_type` becomes a real DB column.** Today it's runtime-derived
  from `raw_response`. Adding a column lets the auth-error bubble be marked
  structurally at write time -- no string matching, no abuse of
  `raw_response`. The enum starts as `[:phase_advance, :auth_error]`. The
  derivation in `ResponseProcessor` keeps working for legacy `phase_advance`
  rows (no backfill required).
- **`Destila.AI.AuthLogin` is a globally-named singleton GenServer**, not a
  per-modal one. Auth is machine-wide; competing CLI processes would wedge
  the auth helper's local state. A second modal open simply attaches to the
  running flow and reads its current state. Closing the modal stops the
  GenServer, which kills the pty -- this is intentionally global, since
  there's only one machine-wide auth identity to manage. The genserver is
  added under `Destila.Application` with `restart: :transient` so a crash
  doesn't auto-spawn a new pty in the background.
- **The modal is a stateless function component (mirrors
  `FollowUpModal`)**, not a `Phoenix.LiveComponent`. The user prompt
  suggests `LiveComponent`; the established codebase pattern is stateless
  HTML components plus parent-LiveView-owned state and PubSub-driven
  re-renders. We match the codebase. Lifecycle ownership is handled by the
  `WorkflowRunnerLive` calling `AuthLogin.start/0` / `AuthLogin.stop/0`
  on the user's open/close events.
- **Retry is a new dedicated `SessionProcess.retry_after_auth/2`
  operation**, not a re-use of `retry/1` (which restarts the phase). It
  re-enqueues the failed user turn -- identified by the auth_error
  message_id -- via the same `AiQueryWorker` path used for the original
  send. No duplicate user message is persisted; the existing user message
  semantically *is* the retried turn.
- **URL-wait timeout: 30 seconds.** If the CLI hasn't printed a URL by then,
  transition to `:cli_failed`. The `claude` CLI prints the URL within 1-2s
  in practice; 30s is generous and bounded.
- **Token verdict timeout: 60 seconds.** A pty exit without a clear success
  marker, or 60s elapsing post-submit, transitions to `:cli_failed` with a
  generic message. Successful runs typically finish in <5s.
- **URL parsing strategy:** scan stdout chunks for the first
  `https://...` substring matching `https://[^\s\x1b]+`. The CLI prints the
  URL exactly once on a clean line; no need for fancy ANSI stripping
  beyond skipping bytes inside `\x1b[...]` sequences. Document this as a
  brittle dependency (see Risks).
- **Verdict parsing:** success and failure are detected by scanning the
  post-token stdout for case-insensitive markers (`success`,
  `authenticated`, `logged in` for success; `invalid`, `expired`, `failed`,
  `error` for failure) **and** by the pty exit code (0 = success, non-zero
  = failure). The pty-exit signal is authoritative; the stdout marker is a
  pre-emptive optimization for displaying error text. If the markers and
  exit disagree, the exit wins.

## Open Questions

### Resolved During Planning

- *Should the GenServer link to the LiveView or be globally registered?* --
  Globally registered. Auth is machine-wide; multiple modals attach to the
  same flow.
- *Should `:erlexec` be added?* -- No. Use the existing
  `Destila.Terminal.PTY` wrapper.
- *Should the modal be a `LiveComponent` or a stateless function component?*
  -- Stateless function component, mirroring `FollowUpModal`.
- *How is the failed turn identified for retry?* -- By the auth_error
  message's `id`. The previous `role: :user` message in the same phase is
  the failed turn.
- *Where is the new `message_type` column defined?* -- Migration that adds
  `message_type :string` to `messages`, with `Ecto.Enum` enforcement at the
  schema level. No backfill -- existing rows have `nil` and continue to
  derive type at read time.

### Deferred to Implementation

- Exact regex for the URL match -- determine empirically from a single
  manual `claude auth login` run (the captured chunk format may include
  ANSI codes that need stripping).
- Exact stdout markers for success/failure -- determine empirically; the
  exit-code fallback ensures correctness even if the markers shift.
- Whether the PTY's `args` should include `--no-color` or similar flags --
  determine empirically; if the CLI offers a flag that disables ANSI, use
  it to simplify URL parsing.
- Whether the close-via-Escape handler should debounce against a focused
  text input -- if usability testing shows the user accidentally dismisses
  while typing the token, add `phx-key="escape"` only on the dialog root,
  not on the input.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for
> review, not implementation specification. The implementing agent should
> treat it as context, not code to reproduce.*

### State machine inside `Destila.AI.AuthLogin`

```
                       (init / restart)
                              |
                              v
                         +----------+
              spawn pty  | starting |
                         +----+-----+
                              |
              URL parsed ---->|<---- url_timeout (30s)
                              |               |
              .---------------+---------------.
              v                               v
       +--------------+                 +-----------+
       | awaiting_    |                 |cli_failed |
       |   token      |                 +-----+-----+
       +-----+--------+                       |
             |                       (terminate / restart)
             | submit_token (write to stdin)
             v
       +-----------+
       | verifying |
       +-----+-----+
             |
       .-----+------.
       v            v
  +---------+  +--------------+
  |succeeded|  | invalid_token|
  +---------+  +--------------+
       |             |
  (broadcast,    (broadcast;
   parent         pty already
   triggers       exited; modal
   retry +        shows error +
   stop)          "Restart")
```

State changes are broadcast on `claude_auth_login_topic()` as
`{:claude_auth_login_state, snapshot}` where `snapshot` carries
`{state, url, error_message}`.

### Sequence: open -> URL -> token -> success -> retry

```
User       ChatComponents     WorkflowRunnerLive    AuthLogin GS    PTY (claude auth login)
 |            |                     |                   |                  |
 |--click---->|                     |                   |                  |
 |            |--phx-click--------->|                   |                  |
 |            | "open_claude_login" |                   |                  |
 |            |                     |--start()--------->|                  |
 |            |                     |                   |--PTY.spawn------>|
 |            |                     |<--{state,         |                  |
 |            |                     |   :starting}------|                  |
 |            |                     |                   |<--{:pty_output,  |
 |            |                     |                   |    "https://..."}|
 |            |                     |<--{state,         |                  |
 |            |                     |   :awaiting_token,|                  |
 |            |                     |   url}------------|                  |
 |--paste+submit-------------------> "submit_claude_token"                 |
 |            |                     |--submit_token---->|                  |
 |            |                     |                   |--PTY.write------>|
 |            |                     |<--{state,         |                  |
 |            |                     |   :verifying}-----|                  |
 |            |                     |                   |<--{:pty_output,  |
 |            |                     |                   |    "success"} +  |
 |            |                     |                   |    {:pty_exit,0} |
 |            |                     |<--{state,         |                  |
 |            |                     |   :succeeded}-----|                  |
 |            |                     |                                      |
 |            |                     |--SessionProcess                      |
 |            |                     |  .retry_after_auth(ws.id, msg_id)    |
 |            |                     |--AuthLogin.stop()->|                 |
 |            |                     |                   |--PTY.kill------->|
```

## Implementation Units

- [ ] **Unit 1: Mark auth-error messages structurally with a `message_type` column**

**Goal:** Add `message_type` as a real column on `messages`, set it to
`:auth_error` when `Conversation.handle_ai_error/2` builds an auth-failure
message, and have `ResponseProcessor` honor the persisted value.

**Requirements:** R1.

**Dependencies:** none.

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_message_type_to_messages.exs`
- Modify: `lib/destila/ai/message.ex`
- Modify: `lib/destila/ai.ex`
- Modify: `lib/destila/ai/conversation.ex`
- Modify: `lib/destila/ai/response_processor.ex`
- Test: `test/destila/ai/conversation_test.exs` (or new file
  `test/destila/ai/auth_error_message_test.exs` if no per-module test exists)

**Approach:**
- Migration adds nullable `message_type :string` to the `messages` table; no
  backfill (legacy rows fall back to derivation in
  `ResponseProcessor.derive_message_type/3`).
- Schema declares `field :message_type, Ecto.Enum, values: [:phase_advance,
  :auth_error]` and adds it to the changeset cast list.
- `Destila.AI.create_message/2` passes through the new attribute.
- In `Conversation.handle_ai_error/2`, classify the error via the existing
  `error_message/1` shape: if the result indicates an auth failure (i.e.
  `error_message/1` would emit the `auth_failed_message`), set
  `message_type: :auth_error` on the persisted system message. Generic
  failures get `message_type: nil`.
- `ResponseProcessor.derive_message_type/3` returns the persisted value when
  non-nil, otherwise falls back to its current derivation.

**Patterns to follow:**
- `Ecto.Enum` usage: existing `role` field at `lib/destila/ai/message.ex`.
- Migration shape: existing `priv/repo/migrations/*.exs` adding string
  columns to existing tables.

**Test scenarios:**
- Happy path: an auth-failure result map flowing through
  `handle_ai_error/2` persists a system message whose `message_type ==
  :auth_error`.
- Edge case: a non-auth error (network failure, generic CLI error) persists
  a system message whose `message_type` is `nil`.
- Edge case: `ResponseProcessor.process_message/2` returns
  `:auth_error` for a row whose persisted `message_type == :auth_error`,
  regardless of `raw_response` shape.
- Edge case: a legacy row with `message_type == nil` and a `phase_advance`
  shaped `raw_response` still derives to `:phase_advance` (no regression).

**Verification:**
- `mix ecto.migrate` succeeds; `mix test` passes the new tests.
- Querying a freshly inserted auth-failure message via
  `Destila.AI.list_messages_for_workflow_session/1` returns it with
  `message_type: :auth_error`.

---

- [ ] **Unit 2: `Destila.AI.AuthLogin` GenServer + PubSub topic + supervision**

**Goal:** Implement a globally-named singleton GenServer that owns the
`claude auth login` pty lifecycle, parses stdout for the auth URL, accepts
a token via `submit_token/1`, exposes restart/stop, and broadcasts state
changes on a dedicated PubSub topic.

**Requirements:** R3, R4 (loading + URL printing), R6 (kill on invalid),
R7 (cli-failed transition), R8 (kill on stop), R9 (singleton),
R11 (no orphans).

**Dependencies:** none.

**Files:**
- Create: `lib/destila/ai/auth_login.ex`
- Modify: `lib/destila/pub_sub_helper.ex` (add `claude_auth_login_topic/0`
  and `broadcast_claude_auth_login/1`)
- Modify: `lib/destila/application.ex` (add `Destila.AI.AuthLogin` child
  spec with `restart: :transient` and a globally registered name)
- Modify: `test/test_helper.exs` (add `Mimic.copy(Destila.AI.AuthLogin)`)
- Test: `test/destila/ai/auth_login_test.exs`

**Approach:**
- GenServer name: `name: Destila.AI.AuthLogin` (no Registry needed for a
  singleton).
- Public API:
  - `start/0` -- idempotent: if alive, return `:ok`; otherwise
    `DynamicSupervisor.start_child/2` (or just rely on the static
    `Application` child being restarted via `:transient` plus a
    `start_link/1` head that returns `{:error, {:already_started, pid}}`).
  - `current/0` -- `GenServer.call(__MODULE__, :current)`. Returns `{state,
    url, error_message}`. Returns `{:idle, nil, nil}` if not running.
  - `submit_token/1` -- `GenServer.call(__MODULE__, {:submit_token, token},
    timeout)`.
  - `restart/0` -- kill current pty, respawn fresh.
  - `stop/0` -- `GenServer.stop(__MODULE__, :normal, timeout)`. `terminate/2`
    issues `PTY.kill/2`.
- Internal state struct: `%{state: :starting | :awaiting_token |
  :verifying | :invalid_token | :cli_failed | :succeeded, pty: handle,
  url: nil | binary, error_message: nil | binary, url_timer: ref,
  verdict_timer: ref, stdout_buffer: binary}`.
- `init/1`: `Process.flag(:trap_exit, true)`, spawn pty via
  `Destila.Terminal.PTY.spawn(self(), cmd: "/usr/bin/env",
  args: ["TERM=xterm-256color", "COLORTERM=truecolor", "claude", "auth",
  "login"], cwd: System.user_home!(), cols: 120, rows: 40)`, schedule
  `:url_timeout` after 30_000ms, broadcast `:starting`.
- `handle_info({:pty_output, handle, iodata}, state)`: append to
  `stdout_buffer`, scan for URL regex while `state.state == :starting`,
  scan for verdict markers while `state.state == :verifying`, transition
  + broadcast accordingly.
- `handle_info({:pty_exit, handle, _exit_info}, state)`:
  - if `state.state in [:starting, :awaiting_token]` -> `:cli_failed`
  - if `state.state == :verifying` -> if exit was 0 and we already saw a
    success marker, `:succeeded`; else `:invalid_token` with stdout error
    extract
  - any state -> stop the GenServer (it has no pty to manage anymore);
    broadcast final state first.
- `handle_call({:submit_token, token}, _from, %{state: :awaiting_token} =
  state)`: `PTY.write(state.pty, token <> "\n")`, schedule
  `:verdict_timeout` after 60_000ms, transition to `:verifying`,
  broadcast.
- `handle_call({:submit_token, _}, _from, state)`: `{:reply, {:error,
  :wrong_state}, state}`.
- `handle_call(:restart, _from, state)`: kill pty, cancel timers, spawn
  fresh pty, reset to `:starting`.
- `terminate/2`: `Destila.Terminal.PTY.kill(state.pty, 15)` if alive;
  cancel timers.
- Broadcast helper: `broadcast_state(state) :: send to
  Destila.PubSubHelper.claude_auth_login_topic()` with payload
  `{:claude_auth_login_state, %{state: ..., url: ..., error_message: ...}}`.

**Patterns to follow:**
- `lib/destila/terminal/server.ex` (init, trap_exit, pty_output forwarding,
  terminate-kills-pty).
- `lib/destila/services/log_tailer.ex` for `restart: :temporary | :transient`
  + idempotent start patterns.
- `lib/destila/pub_sub_helper.ex` topic helpers: match casing/style
  (`claude_auth_login_topic/0`, `broadcast_claude_auth_login/1`).

**Test scenarios:**
- Happy path: stub `Destila.Terminal.PTY.spawn/2` to capture the owner;
  start the GenServer; send a `{:pty_output, handle, "...https://example.com/auth..."}`
  message; assert state transitions to `:awaiting_token` with the URL;
  assert PubSub broadcast.
- Happy path: from `:awaiting_token`, call `submit_token("tk")`; assert
  `PTY.write` was called with `"tk\n"`; assert state becomes `:verifying`;
  send `{:pty_output, handle, "success"} + {:pty_exit, handle, {:status,
  0}}`; assert state becomes `:succeeded`.
- Error path: `:url_timeout` fires while still `:starting` ->
  `:cli_failed`, pty killed, broadcast emitted.
- Error path: `{:pty_exit, handle, {:status, 0}}` arrives while still
  `:starting` -> `:cli_failed`.
- Error path: from `:verifying`, `{:pty_output, handle, "Invalid token"}` +
  `{:pty_exit, handle, {:status, 1}}` -> `:invalid_token`, `error_message`
  populated, pty terminated.
- Edge case: `submit_token/1` while in `:starting` returns `{:error,
  :wrong_state}` and does not write to pty.
- Edge case: `restart/0` from `:invalid_token` kills any residual pty (or
  no-op if already dead) and spawns a fresh pty; state returns to
  `:starting`; new URL parse path is exercisable.
- Edge case: `start/0` while already alive is a no-op (no second pty
  spawned).
- Integration: `terminate/2` is invoked (e.g. via `GenServer.stop/3`); the
  stubbed `PTY.kill/2` was called.

**Verification:**
- `mix test test/destila/ai/auth_login_test.exs` passes with all the above
  scenarios green.
- After application boot, `Process.whereis(Destila.AI.AuthLogin)` returns
  `nil` until first `start/0` (or returns the pid if started at boot;
  matter of taste -- the plan recommends not auto-starting, see the
  Application unit).

---

- [ ] **Unit 3: Render "Login to Claude" action below auth_error bubbles in chat**

**Goal:** Add a new `render_chat_message/1` head in `ChatComponents` that
renders the existing system bubble plus an action button as a sibling
below it. No other system bubble renders the action.

**Requirements:** R1, R2.

**Dependencies:** Unit 1 (the new `message_type` value).

**Files:**
- Modify: `lib/destila_web/components/chat_components.ex`
- Test: `test/destila_web/components/chat_components_test.exs` (extend
  existing or create) -- the broader integration coverage lives in Unit 7.

**Approach:**
- Add a new `render_chat_message/1` head before the generic fallback,
  matching `%{message: %{message_type: :auth_error}} = assigns`.
- Inside it, render the same outer `<div class="flex gap-3 mb-4">` system
  bubble as the fallback (extract a small private helper if it cuts
  duplication cleanly; otherwise duplicate -- it's small).
- Immediately after the bubble's closing tag, render a sibling action
  block:
  ```
  <div class="ml-11 mb-4">
    <button
      id={"open-claude-login-" <> Integer.to_string(@message.id)}
      type="button"
      phx-click="open_claude_login"
      phx-value-message_id={@message.id}
      class="btn btn-primary btn-sm">
      Login to Claude
    </button>
  </div>
  ```
- The button gets a unique DOM id keyed by message id so tests can target
  the specific bubble.

**Patterns to follow:**
- The existing `:phase_advance` head at
  `lib/destila_web/components/chat_components.ex:327-368` for inline
  action shape and DOM id conventions.
- The existing `ml-11` indent at `chat_components.ex:128` for sibling-of-
  bubble alignment.

**Test scenarios:**
- Happy path: rendering a system message with `message_type: :auth_error`
  produces the bubble + a sibling element matching
  `#open-claude-login-<id>` with text "Login to Claude".
- Edge case: rendering a system message with `message_type: nil` (or
  `:phase_advance`) does **not** produce any `#open-claude-login-*`
  element.
- Edge case: rendering a user message never produces the action.

**Verification:**
- Component test asserts presence/absence of the action via
  `LazyHTML.filter(...)`.

---

- [ ] **Unit 4: `DestilaWeb.ClaudeAuthLoginModal` stateless function component**

**Goal:** Create the modal as a stateless `use DestilaWeb, :html`
component, mirroring `FollowUpModal`. The modal's content adapts based on
the `state` assign, displays the URL when present (with copy-to-clipboard),
exposes a token form, and exposes a Restart button on error states.

**Requirements:** R3 (visual shell), R4 (loading + URL + token form +
verifying), R6 (error display + Restart), R7 (CLI-failed display +
Restart), R8 (Escape closes).

**Dependencies:** none (decoupled from Unit 2 -- consumed via parent
assigns in Unit 6).

**Files:**
- Create: `lib/destila_web/live/claude_auth_login_modal.ex`
- Modify: `lib/destila_web/live/workflow_runner_live.ex` -- add
  `import DestilaWeb.ClaudeAuthLoginModal, only: [claude_auth_login_modal: 1]`
  near the existing `FollowUpModal` import (used in Unit 6).

**Approach:**
- Single function `claude_auth_login_modal/1` rendering an HEEx template.
- Attrs: `open?`, `state` (atom), `url`, `error_message`, `form` (a
  `to_form/2` for the token field), `target_message_id`.
- When `open? == false`, render nothing (`<.fragment :if={false} ...>` or
  early-return via `<%= if @open? do %> ... <% end %>`, matching
  `FollowUpModal` style).
- Outer dialog: `id="claude-auth-login-modal"`, `role="dialog"`,
  `aria-modal="true"`, `aria-labelledby="claude-auth-login-modal-title"`,
  `phx-window-keydown="close_claude_login_modal"`, `phx-key="escape"`.
- Backdrop: `phx-click="close_claude_login_modal"`.
- Panel: same `rounded-xl bg-base-100 shadow-2xl ring-1 ring-base-300/40`
  shell as `FollowUpModal`.
- Header: title `"Login to Claude"`, subtitle changes by state
  (`"Waiting for the Claude CLI..."` while `:starting`, `"Open the URL
  below in your browser"` while `:awaiting_token`, etc.).
- Body, dispatched by `@state` via a single `cond do` block (Elixir does
  not support `else if`):
  - `:starting` -> spinner + "Waiting for Claude CLI..."
  - `:awaiting_token` -> URL display block + copy-to-clipboard button +
    `<.form for={@form} id="claude-login-token-form"
    phx-submit="submit_claude_token">` containing `<.input
    field={@form[:token]} type="text" id="claude-login-token-input"
    placeholder="Paste your token here" autocomplete="off" />` and a
    submit button `id="claude-login-submit"`.
  - `:verifying` -> spinner + "Verifying token..."
  - `:invalid_token` or `:cli_failed` -> `<div class="alert alert-error">`
    showing `@error_message` (with a fallback message when nil) + a
    Restart button `id="claude-login-restart"
    phx-click="restart_claude_login"`.
  - `:succeeded` -> brief "Logged in! Retrying..." spinner (the parent
    will close the modal almost immediately on its broadcast handler;
    this state is mostly transitional).
- Copy-to-clipboard: a small colocated JS hook
  `phx-hook=".CopyClipboard"` on the URL container that copies its
  `data-clipboard` attribute on click. Use `<script
  :type={Phoenix.LiveView.ColocatedHook} name=".CopyClipboard">` per
  `AGENTS.md`. The button has `id="claude-login-copy-url"`.
- Footer: only when `@state in [:starting, :awaiting_token, :verifying]`,
  render a "Cancel" button `phx-click="close_claude_login_modal"`.
- All DOM ids the tests will target are unique and stable.

**Patterns to follow:**
- `lib/destila_web/live/follow_up_modal.ex` for shell, ARIA, backdrop,
  Escape handling, footer button shapes.
- `lib/destila_web/components/core_components.ex` `<.input>` for the form
  field.
- AGENTS.md "Inline colocated js hooks" for the copy-to-clipboard pattern.

**Test scenarios:**
- Test expectation: none on the function component itself in this unit.
  All visual states are exercised through the LV test suite in Unit 7
  (`open?`, transitions, button presence, form submit). The component is
  pure rendering with no logic worth a separate unit test.

**Verification:**
- The component compiles, `mix format` passes, and the LV tests in Unit 7
  exercise every state branch.

---

- [ ] **Unit 5: `SessionProcess.retry_after_auth/2` -- re-run the failed turn**

**Goal:** Add a dedicated retry operation to `SessionProcess` that
re-enqueues the failed user turn (identified by the auth_error message id)
without persisting a duplicate user message and without re-running the
phase kickoff.

**Requirements:** R5 (success triggers retry), R10 (target the specific
failed turn).

**Dependencies:** Unit 1 (auth_error marker), Unit 2 (success broadcast --
informational only here).

**Files:**
- Modify: `lib/destila/sessions/session_process.ex`
- Modify: `lib/destila/ai/conversation.ex` -- add a thin
  `enqueue_query_for_retry/3` (or equivalent) that takes a
  `workflow_session`, `phase`, and `query` content and enqueues
  `Destila.Workers.AiQueryWorker` with the same shape as
  `enqueue_ai_worker/3` -- factored out so retry doesn't duplicate the
  enqueue logic.
- Modify: `lib/destila/workers/ai_query_worker.ex` only if the current
  job-args shape needs an explicit `retry?: true` flag (likely **not**
  needed -- the worker doesn't care).
- Test: `test/destila/sessions/session_process_test.exs` (or equivalent
  existing test file).

**Approach:**
- Public API: `retry_after_auth(session_id, auth_error_message_id)`.
- State-machine handlers: add an `awaiting_input({:call, from},
  {:retry_after_auth, msg_id}, data)` and an
  `awaiting_confirmation({:call, from}, ...)` head. Both:
  1. Look up the auth_error message; find the most recent `role: :user`
     message with the same `phase` whose `inserted_at` precedes it.
  2. Delete the auth_error message (or mark it as resolved -- for now,
     deleting keeps the chat history clean; the user has effectively
     "retried it"). Decision recorded in Open Questions / Deferred.
  3. Call `Conversation.enqueue_query_for_retry(ws, phase, user_msg.content)`.
  4. Transition to `:processing` and reply `:ok`.
- If no preceding user message is found (defensive), reply `{:error,
  :no_user_turn_found}` and remain in current state.

**Patterns to follow:**
- `lib/destila/sessions/session_process.ex:189-191, 270-276`
  (`handle_send_message/3`) for the call/transition shape.
- `lib/destila/ai/conversation.ex:60-73, 261-265` for the existing
  `send_message`/`enqueue_ai_worker` factoring.

**Test scenarios:**
- Happy path: with a phase containing a user message followed by an
  auth_error system message, calling `retry_after_auth(session_id, msg_id)`
  enqueues an `AiQueryWorker` carrying the user message's content and
  transitions to `:processing`.
- Edge case: the auth_error message id is invalid or the phase has no
  preceding user message -> returns `{:error, :no_user_turn_found}` and
  state is unchanged.
- Edge case: called from a state other than `:awaiting_input` /
  `:awaiting_confirmation` -> returns `{:error, :wrong_state}`.
- Integration: after a real auth_error is created via the normal
  `handle_ai_error` path, `retry_after_auth` finds the right user message
  even when other phases have unrelated user messages in the conversation
  history (i.e. the phase scoping works).
- Edge case: the auth_error message is deleted/marked-resolved so that a
  re-render of the chat does not show the action again. (Or, if we keep
  the message and instead toggle a `resolved` flag, this scenario asserts
  that flag.)

**Verification:**
- `mix test` passes; manually triggering `retry_after_auth` via the LV
  tests in Unit 7 confirms an `AiQueryWorker` job is enqueued with the
  expected args (using `Oban.Testing` `assert_enqueued/1`).

---

- [ ] **Unit 6: Wire the modal + auth-login flow into `WorkflowRunnerLive`**

**Goal:** Hook the chat action, the modal, the GenServer broadcasts, and
the retry path together inside `WorkflowRunnerLive`.

**Requirements:** R3 (open), R4 (display states), R5 (success closes +
retries), R6 (invalid retains modal + error), R7 (cli-failed retains modal
+ error), R8 (close terminates), R9 (singleton reattach).

**Dependencies:** Units 2, 3, 4, 5.

**Files:**
- Modify: `lib/destila_web/live/workflow_runner_live.ex`
- Modify: `lib/destila/pub_sub_helper.ex` (subscribe helper if it doesn't
  already exist for the new topic) -- already added in Unit 2.

**Approach:**
- `mount/3`: when `connected?(socket)`, also subscribe to
  `Destila.PubSubHelper.claude_auth_login_topic()`.
- Initial assigns: `claude_login_modal_open?: false`, `claude_login_state:
  :idle`, `claude_login_url: nil`, `claude_login_error: nil`,
  `claude_login_form: to_form(%{"token" => ""}, as: :claude_login)`,
  `claude_login_target_message_id: nil`.
- Event handlers (each is its own `handle_event/3` clause):
  - `"open_claude_login"` with `phx-value-message_id` -> `AuthLogin.start()`,
    set `claude_login_modal_open?: true`, fetch
    `AuthLogin.current()` snapshot into the assigns,
    `claude_login_target_message_id: String.to_integer(msg_id)`. If
    snapshot indicates a flow already in progress (state != `:idle`),
    surface its current URL (this is the singleton reattach behavior for
    R9).
  - `"close_claude_login_modal"` -> `AuthLogin.stop()`, reset assigns to
    initial.
  - `"submit_claude_token"` with `%{"claude_login" => %{"token" => tk}}`
    -> trim token; if blank, re-assign form with an error and return; else
    call `AuthLogin.submit_token(tk)`.
  - `"restart_claude_login"` -> `AuthLogin.restart()`.
  - `"copy_claude_login_url"` -> handled client-side by the colocated hook;
    no server event needed.
- PubSub `handle_info({:claude_auth_login_state, snapshot}, socket)`:
  - update `claude_login_state`, `claude_login_url`, `claude_login_error`
  - if `snapshot.state == :succeeded` and
    `socket.assigns.claude_login_target_message_id` is set: call
    `SessionProcess.retry_after_auth(ws.id,
    socket.assigns.claude_login_target_message_id)`, then
    `AuthLogin.stop()`, then reset modal assigns.
- Render: add `<.claude_auth_login_modal open?={...} state={...} ... />`
  as a sibling of the existing modals inside `Layouts.app` (around line
  1331). Pass all the assigns through.
- Defensive: if the user clicks a stale `Login to Claude` action whose
  message id is no longer current, the retry is best-effort -- the
  `retry_after_auth` returns `{:error, :no_user_turn_found}` and the LV
  flashes a friendly error.

**Patterns to follow:**
- `lib/destila_web/live/workflow_runner_live.ex` event handlers for
  `mark_done`/`close_follow_up_modal`/`select_follow_up` (lines 172-223)
  for open/close/event shapes.
- The mount-time subscription block at lines 29-89 for adding the new
  topic.
- The handle_info clauses at lines 494-604 for the new
  `:claude_auth_login_state` matcher.
- The modal-render slot pattern at lines 1331-1336 for inserting
  `<.claude_auth_login_modal>` next to the FollowUpModal.

**Test scenarios:**
- Test expectation: none new in this unit -- all scenarios are exercised
  end-to-end in Unit 7's LV test file. Confirm the wiring by running that
  suite.

**Verification:**
- `mix compile --warnings-as-errors` passes.
- The Unit 7 test suite passes.
- Manually opening the modal in the browser (with `Destila.AI.AuthLogin`
  Mimic-stubbed in dev or with a real `claude` CLI in dev) shows the
  expected behavior.

---

- [ ] **Unit 7: Gherkin feature file + LiveView integration tests**

**Goal:** Add the Gherkin feature file verbatim from the prompt and the
matching LiveView test module that drives the entire flow with `Mimic`
stubbing of `Destila.AI.AuthLogin`. Each test is `@tag`-linked to a
scenario.

**Requirements:** R1-R11 (all behavioral).

**Dependencies:** Units 1-6.

**Files:**
- Create: `features/claude_auth_login.feature`
- Create: `test/destila_web/live/claude_auth_login_live_test.exs`
- Modify: `test/test_helper.exs` (already done in Unit 2 -- confirm the
  Mimic.copy line is present)

**Approach:**
- Feature file: copy the Gherkin block from the prompt verbatim.
- Test module starts with:
  ```
  defmodule DestilaWeb.ClaudeAuthLoginLiveTest do
    @moduledoc """
    LiveView tests for the in-app Claude CLI auth login modal.
    Feature: features/claude_auth_login.feature
    """
    use DestilaWeb.ConnCase, async: false
    use Mimic
    import Phoenix.LiveViewTest
    @feature "Claude Auth Login Modal"
  ```
- Each test carries `@tag feature: @feature, scenario: "<scenario name
  from .feature>"`. **Every** scenario in the feature file must have at
  least one matching test.
- Setup: stub `Destila.AI.AuthLogin` so its API calls
  (`start/0`, `current/0`, `submit_token/1`, `restart/0`, `stop/0`)
  return canned responses and route broadcast simulation through
  `Phoenix.PubSub.broadcast/3` on
  `Destila.PubSubHelper.claude_auth_login_topic()` to drive the LV's
  handle_info path.
- Driving broadcasts: helper `broadcast_state(state, opts \\ [])` that
  pushes `{:claude_auth_login_state, %{state: state, url: opts[:url],
  error_message: opts[:error]}}` to the topic. Tests await the LV's
  re-render via `render(view)` or `assert_patch`.
- Scenarios mapped to tests:
  - "Login action appears below an auth_error message bubble" -- seed an
    `:auth_error` message; assert `#open-claude-login-<id>` is below the
    bubble; assert the same selector is absent for non-auth bubbles.
  - "Clicking the login action opens the auth modal" -- click; assert
    `#claude-auth-login-modal` is visible; assert `AuthLogin.start/0`
    was called.
  - "Modal displays the authentication URL printed by the CLI" --
    broadcast `:awaiting_token` with a URL; assert URL appears; assert
    `#claude-login-copy-url` exists.
  - "Modal shows a loading state while waiting for the URL" -- open
    modal; before any broadcast, assert loading element is rendered.
  - "User pastes a token and submits it" -- broadcast `:awaiting_token`;
    `render_submit/2` the token form with a token; assert
    `AuthLogin.submit_token/1` was called with the trimmed token; assert
    the modal renders the verifying state (driven by a follow-up
    `:verifying` broadcast).
  - "Successful token closes the modal and retries the failed turn" --
    broadcast `:succeeded`; assert modal is no longer in DOM; assert
    `SessionProcess.retry_after_auth/2` was called with the captured
    message id (use `Mimic.expect`); assert `AuthLogin.stop/0` was
    called.
  - "Invalid token shows an error and forces a restart" -- broadcast
    `:invalid_token` with `error_message: "..."`; assert error text
    visible; assert `#claude-login-restart` exists; assert no token form.
  - "Restarting the flow spawns a new login process" -- click restart;
    assert `AuthLogin.restart/0` was called; broadcast a fresh
    `:awaiting_token` with a new URL; assert the new URL is rendered.
  - "Closing the modal kills the spawned process" -- click backdrop /
    Escape; assert modal closed; assert `AuthLogin.stop/0` was called.
  - "Reopening the modal starts a fresh process" -- close, then reopen;
    assert `AuthLogin.start/0` was called twice; assert no stale URL
    from previous attempt is rendered before broadcasts arrive.
  - "CLI process exits before printing a URL" -- broadcast `:cli_failed`;
    assert error message visible; assert `#claude-login-restart` exists.

**Patterns to follow:**
- `test/destila_web/live/post_completion_followup_live_test.exs:1-32` for
  module shape, BDD tags, and `ClaudeCode.Test.set_mode_to_shared/0` if
  the underlying SessionProcess interactions need a Claude stub.
- `test/destila_web/live/dashboard_live_test.exs:1-90` for `Mimic`
  setup + `set_mimic_global` + `verify_on_exit!` patterns when the
  stubbed module is invoked from a process other than the test process.
- `test/destila/terminal/server_test.exs` for stubbing the `PTY`
  layer (used indirectly here -- the LV tests stub `AuthLogin`, not
  `PTY`).
- `Oban.Testing` `assert_enqueued/1` for asserting the retry's worker
  enqueue.

**Test scenarios:** see the per-scenario list above; all 11 Gherkin
scenarios are 1:1 mapped to LV tests.

**Verification:**
- `mix test test/destila_web/live/claude_auth_login_live_test.exs` passes.
- `mix test --only feature:"Claude Auth Login Modal"` runs all 11 tests.
- `mix precommit` passes (formatter + warnings + full suite).

## System-Wide Impact

- **Interaction graph:**
  - `ChatComponents.render_chat_message/1` gains a new dispatch head that
    is consumed by `WorkflowRunnerLive`'s chat render path.
  - `WorkflowRunnerLive` gains four new `handle_event/3` clauses,
    a new `handle_info/2` clause for the auth-login PubSub topic, and a
    new modal slot in render.
  - `Conversation.handle_ai_error/2` now decorates auth-error messages
    with `message_type: :auth_error` -- consumers that read messages
    purely by `role` and `content` (e.g. markdown rendering) are
    unaffected.
  - `SessionProcess` gains a new `retry_after_auth/2` operation that
    sits alongside `send_message/2` and `retry/1`. The `retry_phase`
    button (existing) is unchanged.
  - `Destila.AI.AuthLogin` is a new application-supervised singleton.
- **Error propagation:**
  - The PTY's `{:pty_exit, ...}` path drives `:cli_failed` /
    `:invalid_token` / `:succeeded` transitions; broadcast deterministic;
    no errors silently swallowed.
  - `submit_token/1` returns `{:error, :wrong_state}` to defend against
    races (e.g. user double-submits while we're already verifying).
  - `retry_after_auth/2` returns `{:error, :no_user_turn_found}` if the
    chat history has been mutated underneath us; the LV flashes a
    friendly message.
- **State lifecycle risks:**
  - PTY cleanup: `terminate/2` always issues `PTY.kill/2` (15 = SIGTERM).
    The `Destila.Terminal.PTY` wrapper links to the pty process so a
    crash of the GenServer also kills the pty.
  - Singleton crash: `restart: :transient` on the application child means
    a normal crash leaves the genserver dead until the next `start/0`
    (no surprise auto-respawn). An abnormal crash *will* respawn -- but
    the restart strategy is deliberate to recover from transient bugs.
  - Stale UI: closing the modal resets all `claude_login_*` assigns; a
    second open re-fetches `AuthLogin.current/0` so no stale URL leaks
    in.
- **API surface parity:**
  - The new `message_type` enum is open for future values
    (`:tool_call_failed`, etc.); the column is nullable and the
    derivation fallback preserves backward compatibility.
- **Integration coverage:**
  - The LV tests in Unit 7 exercise the chat-render -> click ->
    GenServer-stub -> broadcast -> LV-handle_info -> modal-render -> form
    -> retry-enqueue chain end-to-end, which mocks alone wouldn't prove.
- **Unchanged invariants:**
  - The `retry_phase` chat-header button remains a phase-level kickoff
    retry (no semantics change).
  - The `Destila.AI.Message` schema retains its `role` field; only adds a
    new optional column.
  - The `expty` pty backend remains the only pty in use; `:erlexec` is
    explicitly not added.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `claude auth login` stdout format changes (URL location, success/failure markers) | Use exit code as the authoritative success/failure signal; markers are an optimistic optimization. URL parsing is broad (`https://[^\s\x1b]+`). Document the brittle dependency in `Destila.AI.AuthLogin`'s moduledoc. |
| Orphan `claude` OS process if the Erlang VM crashes hard | The `Destila.Terminal.PTY` wrapper links to the pty pid; a VM crash kills the pty under standard signal propagation. Acceptable residual risk for dev tooling. |
| Multiple users / tabs racing on the singleton GenServer | First-open-wins; subsequent opens reattach to the in-progress flow and read its state via `AuthLogin.current/0`. Closing one modal stops the GenServer for everyone -- intentional, since auth is machine-wide. |
| URL never arrives (CLI hangs, network probe blocked) | 30s `:url_timeout` transitions to `:cli_failed` with a generic message and a Restart action. |
| Token verification hangs | 60s `:verdict_timeout` fires `:cli_failed`. |
| `retry_after_auth/2` re-runs against a now-mutated phase history | If the most recent user message in the phase is not the one that produced the auth_error (e.g. user typed something else in another tab), the retry uses the most recent user message regardless. Acceptable because the auth_error effectively pauses chat; in practice no other user input lands in between. Documented as a known limitation. |
| Removing the auth_error message during retry deletes user data | The auth_error message is a system-side bubble created automatically; deleting it on retry is safe and visually clean. (Alternative: keep + flag `resolved: true` -- defer to implementation.) |
| Adding a column to `messages` requires a SQLite migration | SQLite supports `ALTER TABLE ADD COLUMN`; the migration is trivial and zero-downtime in the local-dev SQLite context. |

## Documentation / Operational Notes

- Add a brief moduledoc block to `Destila.AI.AuthLogin` explaining: that
  it owns a singleton pty, that auth is machine-wide, that close/Restart
  kills the pty, and that the URL/verdict parsers depend on `claude` CLI
  output stability.
- After this lands, write a short `docs/solutions/2026-XX-XX-claude-cli-
  auth-login-modal.md` capturing: PTY+singleton+broadcast pattern;
  function-component-modal vs LiveComponent decision; `retry_after_auth`
  shape distinct from `retry_phase`. (Out of scope for this plan; just a
  follow-up suggestion.)
- No environment variables, secrets, or rollout flags. The feature is
  always-on once shipped.

## Sources & References

- Repo research summary (this session)
- Institutional learning: `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`
- Related plan: `docs/plans/2026-04-21-001-refactor-evaluate-erlexec-over-expty-plan.md`
- Related PRs in `git log`: #143 (FollowUp modal), #149 (project services)
- `AGENTS.md` (`CLAUDE.md` symlink) for Phoenix/LiveView/test conventions
