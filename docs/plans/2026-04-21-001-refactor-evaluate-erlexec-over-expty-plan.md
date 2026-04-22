---
title: "Evaluate erlexec as a replacement for expty"
type: refactor
status: partial
date: 2026-04-21
decision: docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md
---

# Evaluate erlexec as a replacement for expty

## Overview

Destila currently uses [`expty`](https://github.com/cocoa-xu/expty) (a NIF wrapping `forkpty(3)`) to allocate a pseudo-terminal for the in-browser xterm.js panel that attaches to the per-session tmux. `expty` is pre-1.0, single-maintainer, sparsely released, and self-describes as "WIP." This plan evaluates whether [`erlexec`](https://github.com/saleyn/erlexec) (v2.2.4, 2026-04-15) is a better long-term home for that PTY path, produces the evidence needed to decide, and — if the evaluation passes its gates — lands the swap behind a thin internal wrapper.

The scope is the terminal PTY path only. It is deliberately not a broader "replace every subprocess call" effort.

## Problem Frame

`expty` works today, but it introduces two forward-looking risks that the team wants to quantify:

- **Maintenance risk.** `expty` is at v0.2.1 on Hex (2024-09-30), with a v0.2.2 GitHub release (2025-11-19) that has not been pushed to Hex. ~2k all-time Hex downloads, 3 dependents. Bus-factor-one. If upstream stalls, we inherit NIF + `forkpty` + multi-platform-prebuilds maintenance.
- **Crash blast radius.** `expty` is an in-BEAM NIF. A crash in the NIF takes the whole node down. `erlexec` delegates to an out-of-process `exec-port` C++ helper, so a crash there is isolated by port semantics.

Offsetting those, `expty` ships precompiled NIFs for 11 platform tuples, and our code is on the vendor's happy path (xterm.js over a WebSocket is effectively `expty`'s reason to exist). `erlexec` compiles C++ from source at dep-fetch time and has no public precedent we found for the exact tmux-attach-under-PTY shape. Note also that `erlexec`'s crash isolation is per-node, not per-child: a single `exec-port` OS process manages every child spawned through `:exec` on the BEAM node. Its crash still leaves the BEAM up (unlike a NIF crash) and OTP can restart it, but every live terminal session dies with it — the improvement over a NIF is "the node survives," not "individual children are isolated from each other." The evaluation's job is to surface evidence on both sides, then decide.

## Requirements Trace

- R1. **Capability parity.** Any replacement must cover every `ExPTY` call we make today: spawn-with-pty, async stdout delivery, async exit notification, stdin write, PTY resize (TIOCSWINSZ), and signalled kill.
- R2. **Tmux-under-PTY correctness.** The exact shell-attaches-to-tmux workflow must behave identically: colored output, interactive input, SIGWINCH on resize, clean teardown when the owning GenServer dies.
- R3. **Build/CI acceptability.** The replacement's deployment footprint (toolchain, OS packages, extra processes) must be characterized and acceptable on our dev machines and whatever CI/host runs Destila today. If it is not, the evaluation must surface that plainly and end with "stay on expty."
- R4. **Reversible landing.** Any code change must be reversible: the migration must be behind an internal wrapper so we can revert to `expty` by editing one module and flipping a dep.
- R5. **Test parity.** The test suite must continue to cover `Destila.Terminal.Server` without real subprocess spawns, and must not lose any of the assertions currently enforced in `test/destila/terminal/server_test.exs`.

Success criterion: either a merged, green swap behind a wrapper, or a written decision to stay, grounded in the spike results — not in speculation.

## Scope Boundaries

**In scope**
- `lib/destila/terminal/server.ex` — the only production call site of `ExPTY`
- `test/destila/terminal/server_test.exs` — the only test that mocks `ExPTY`
- `mix.exs` dep entry for `expty` (may be swapped to `erlexec`)
- A thin internal wrapper (`Destila.Terminal.PTY`) that both implementations implement against
- A documented spike that exercises tmux + Claude CLI under `erlexec`'s PTY mode

**Explicitly out of scope**
- Replacing any other subprocess launcher (no touch to `System.cmd`, `ClaudeCode` callers, `Destila.Terminal.Tmux`, or setup tasks)
- Cross-cutting refactors of the terminal/session architecture
- Windows support changes (we do not target Windows; `erlexec` does not support it)
- Broader policy about NIFs vs ports across the codebase

## Context & Research

### Relevant Code and Patterns

- `lib/destila/terminal/server.ex` — the entire `ExPTY` surface in one GenServer: `spawn/3`, `on_data/2`, `on_exit/2`, `write/2`, `resize/3`, `kill/2`, plus `Process.link/1` and `{:EXIT, pty, _}` handling in `handle_info/2`. Terminal-output is forwarded via `Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:terminal_output, data})`.
- `lib/destila/terminal/tmux.ex` — the tmux shell-out helpers (`ensure_session`, `escape_shell`, `window_exists?`, `new_window`, `send_keys`) that drive what `expty` ends up attaching to. Unchanged by this plan.
- `lib/destila_web/live/terminal_live.ex:46-51` — the only caller that starts `TerminalServer`. Remains unchanged; calls the same public API.
- `test/destila/terminal/server_test.exs` — uses `Mimic.copy(ExPTY)` + per-function `stub/3` to fake the PTY. This is the pattern we need to preserve (mock the wrapper, not the underlying lib).
- `test/test_helper.exs:6` — `Mimic.copy(ExPTY)` site. Will become `Mimic.copy(Destila.Terminal.PTY)` after the wrapper lands.
- `mix.exs:70` — current `{:expty, "~> 0.2"}` dependency line.

### Institutional Learnings

No existing `docs/solutions/` entries reference PTY, tmux-under-PTY, `expty`, or `erlexec`. No prior brainstorms or plans exist for this evaluation. The `2026-04-12-feat-inline-xterm-terminal-plan.md` document is the design origin for the current `expty`-based setup — worth re-reading before committing to any swap, since it records why a real PTY (not a plain `Port.open/2`) was required.

### External References

- erlexec v2.2.4 release (2026-04-15): https://hex.pm/packages/erlexec — actively maintained, 57M+ all-time downloads, monthly-to-quarterly cadence.
- erlexec API docs: https://hexdocs.pm/erlexec/exec.html — `:pty`, `{:pty, pty_opts()}`, `{:winsz, {rows, cols}}`, `:exec.send/2`, `:exec.winsz/3`, `:exec.kill/2`, `:monitor` / `run_link`.
- erlexec PTY C impl: https://github.com/saleyn/erlexec/blob/master/c_src/exec_impl.cpp — real `posix_openpt()` + `setsid()` + `TIOCSCTTY`, i.e. a real PTY not a pipe. Recent commit (2026-04-10) "Fix PTY process group handling" landed 5 days before 2.2.4.
- erlexec `winsz` regression test: `src/exec.erl:1660` (`test_winsz/0`) spawns `cat` under `pty` and resizes. Equivalent to `ExPTY.resize/3`.
- expty v0.2.1 on Hex (2024-09-30): https://hex.pm/packages/expty. v0.2.2 exists on GitHub (2025-11-19) but not published to Hex.
- Phoenix `forkpty(3)` rationale for this codebase: `docs/plans/2026-04-12-feat-inline-xterm-terminal-plan.md:856`.

### Interface Mapping (one-to-one)

| `ExPTY` call | `erlexec` equivalent | Notes |
|---|---|---|
| `ExPTY.spawn(file, args, cwd:, cols:, rows:, closeFDs: true)` | `:exec.run_link(cmd, [:pty, {:cd, cwd}, {:winsz, {rows, cols}}, {:stdout, self()}, {:stderr, self()}, {:env, env}, :monitor])` | `closeFDs` has no direct analog; `erlexec` already closes non-std FDs in the child. |
| `ExPTY.on_data(pty, fn …)` | Receive `{:stdout, ospid, data}` / `{:stderr, ospid, data}` in `handle_info/2` | Message-driven instead of callback-registered. Small refactor. |
| `ExPTY.on_exit(pty, fn …)` | `{:DOWN, ospid, :process, pid, reason}` via `:monitor`, decode with `:exec.status/1` | Richer signal info preserved. |
| `ExPTY.write(pty, data)` | `:exec.send(ospid, data)` | 1:1. |
| `ExPTY.resize(pty, cols, rows)` | `:exec.winsz(ospid, rows, cols)` | **Argument order flip: rows, cols**. Easy to get wrong. |
| `ExPTY.kill(pty, 15)` | `:exec.kill(ospid, 15)` or `:exec.kill(ospid, :sigterm)` | 1:1. |

No capability gaps identified. The migration is mechanical, with the critical caveat that the end-to-end shape (tmux-attach inside a PTY, with Ctrl-C, resize, and clean process-group teardown) has no public precedent under `erlexec` and requires empirical validation.

## Key Technical Decisions

- **Introduce an internal `Destila.Terminal.PTY` wrapper.** Both `expty` and `erlexec` are hidden behind four public calls (`spawn/2`, `write/2`, `resize/3`, `kill/2`) plus the normalized messages the wrapper sends to the owner pid (`{:pty_output, handle, iodata}`, `{:pty_exit, handle, reason}`). Rationale: reversibility (R4), single point of mocking, and it forces us to name our actual requirements (the wrapper's contract) rather than inheriting a library's vocabulary.
- **Validate before migrating.** We do a dedicated spike under `erlexec` against the real tmux + Claude CLI workflow before touching `Destila.Terminal.Server`. Rationale: the external research found zero public evidence of this shape running on `erlexec`, and a PTY process-group bug was patched this month. A post-swap discovery of a blocker would be far more expensive than a throwaway spike.
- **Keep the Phoenix.PubSub contract unchanged.** `{:terminal_output, data}` and `:terminal_exited` remain the only two messages broadcast on `topic`. Rationale: the xterm.js Channel hook already consumes these; changing them would expand scope.
- **`run_link` with `:monitor`, not a naked `Process.link/1`.** `erlexec` returns `{pid, ospid}`; the owner process should link to the Erlang pid (for teardown) and monitor for the `:DOWN` message (for exit notification with signal/status). Rationale: matches `erlexec`'s documented supervision model and preserves the current "GenServer dies when PTY dies" behavior.
- **`kill_timeout` on spawn.** We accept the `erlexec` default but make it explicit in the wrapper so we can tune it (SIGTERM → wait N seconds → SIGKILL) once we observe teardown behavior under tmux. Rationale: tmux can fork children; a too-short timeout could leak processes.
- **Decision gate, not an implicit assumption.** After the spike, if any of the four evaluation criteria (below) fails, the plan ends at a written "stay on expty" decision in `docs/solutions/`, not a forced migration.

### Evaluation Criteria (Go/No-Go Gates)

| Gate | Pass condition | If fails |
|---|---|---|
| **Capability parity (R1, R2)** | All 4 wrapper calls (`spawn`, `write`, `resize`, `kill`) plus normalized output/exit messages behave correctly against tmux-attach, including Ctrl-C propagation and clean teardown | No-go. Document finding, stay on `expty`. |
| **Build/deploy (R3)** | `mix deps.get && mix compile` works on macOS and Linux dev hosts; no new system packages beyond already-installed toolchains; cold-build adds less than a minute | No-go unless a clearly acceptable mitigation exists (e.g. Docker base image already has g++). |
| **Teardown hygiene** | Owner GenServer crash reaps tmux client and leaves no orphaned processes; SIGTERM from `:exec.kill/2` propagates cleanly | No-go. Orphaned tmux clients across hot-reload cycles in dev would be a severe regression. |
| **Test parity (R5)** | Existing `server_test.exs` assertions reproduce with the wrapper mocked; no reduction in coverage | Revisit test strategy; may require a small integration test that spawns a real trivial child (e.g. `cat`). |

## Open Questions

### Resolved During Planning

- **Does `erlexec` allocate a real PTY (not a pipe)?** Yes — `c_src/exec_impl.cpp` uses `posix_openpt()` + `setsid()` + `TIOCSCTTY`. Children pass `isatty()`.
- **Does `erlexec` support PTY resize?** Yes, `:exec.winsz/3` with a live regression test at `src/exec.erl:1660`.
- **Windows?** `erlexec` is POSIX-only. We don't target Windows. Non-issue.
- **Does `erlexec` ship precompiled binaries?** No. It builds `exec-port` from C++ at dep-fetch time. Must be factored into the build-impact evaluation.

### Deferred to Implementation

- **Exact `kill_timeout` for our tmux workload.** The default may be fine; validated empirically during the spike.
- **Whether to merge `:stdout` and `:stderr` into one PubSub message type.** `expty` multiplexes both onto the same `on_data` callback. Under `erlexec` we receive them as separate messages. We can decide when writing the wrapper whether to merge in the wrapper (preserving current broadcast shape) or preserve the split.
- **Whether to keep the `TERM=xterm-256color COLORTERM=truecolor` env injection at the `env` option level instead of as extra arguments to `/usr/bin/env`.** `erlexec` takes `{env, [{"TERM", "xterm-256color"}, ...]}` directly, which is cleaner. Decide during Unit 2.
- **Whether Oban workers (or any other worker that runs user-supplied commands under supervision) would benefit from the same wrapper.** Out of scope for this plan; note for future consideration only.
- **What is the actual production/CI build environment for Destila today?** Gate 2 depends on knowing this. Enumerate before starting Unit 2: the CI runner image, any Docker base image used for releases, and whether a multi-stage build already has a C++ toolchain in the builder stage. If no production release pipeline exists yet (the app runs on dev hosts only), Gate 2 collapses to "dev hosts" and should say so explicitly.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```text
                        Destila.Terminal.Server (GenServer)
                                     │
                                     ▼
                     ┌───── Destila.Terminal.PTY ─────┐
                     │  spawn/1, write/2, resize/3,   │
                     │  kill/2, status/1, parse/1     │
                     └──────────────┬─────────────────┘
                                    │
                  ┌─────────────────┴─────────────────┐
                  ▼ (today)                           ▼ (after swap)
          ExPTY NIF (in-BEAM)                 :exec port (out-of-BEAM)
          forkpty(3)                          exec-port → posix_openpt
          callbacks: on_data/on_exit          messages:  {:stdout, ospid, data}
          ExPTY.resize(pty, cols, rows)                  {:DOWN, ospid, ...}
          ExPTY.kill(pty, 15)                 :exec.winsz(rows, cols)
                                              :exec.kill(ospid, 15)
```

Contract the wrapper exposes:

```text
spawn(owner, opts) ->
    {:ok, handle}
    | {:error, reason}

write(handle, iodata)        -> :ok
resize(handle, cols, rows)   -> :ok
kill(handle, integer_signal) -> :ok

# Messages the wrapper sends to `owner`, consistently, regardless of backend:
{:pty_output, handle, iodata}
{:pty_exit,   handle, {:status, integer} | {:signal, integer_or_atom, core?}}
```

The `handle` is opaque: an Erlang pid under the expty backend, an `{erl_pid, ospid}` tuple under the erlexec backend. Only the wrapper inspects it.

Notes on the exit message shape (needed because the two backends surface different information):

- Under **erlexec**, `{:DOWN, ospid, :process, pid, reason}` is decoded via `:exec.status/1` into `{:status, N}` or `{:signal, atom, core?}` — the shape above is a 1:1 projection.
- Under **expty**, `on_exit` yields `(exit_code, signal)` as a pair. The wrapper synthesizes `{:status, exit_code}` when `signal == 0`, otherwise `{:signal, signal_int, false}` — `core?` is always `false` because expty does not expose it. Implementers should treat `core?` as best-effort, not a guarantee.

## Implementation Units

- [x] **Unit 1: Introduce `Destila.Terminal.PTY` wrapper over the existing expty backend**

**Goal:** Land the wrapper module as a no-op refactor: `Destila.Terminal.Server` calls the wrapper, the wrapper calls `ExPTY`, behavior and broadcast shape are unchanged. Baseline for the swap.

**Requirements:** R4, R5

**Dependencies:** None.

**Files:**
- Create: `lib/destila/terminal/pty.ex`
- Modify: `lib/destila/terminal/server.ex` (replace direct `ExPTY.*` calls with `PTY.*`)
- Modify: `test/test_helper.exs` (swap `Mimic.copy(ExPTY)` for `Mimic.copy(Destila.Terminal.PTY)`)
- Modify: `test/destila/terminal/server_test.exs` (stub the wrapper, not `ExPTY`)

**Approach:**
- Wrapper exposes `spawn/2` (taking an explicit `owner` pid plus opts), `write/2`, `resize/3`, and `kill/2`. The owner pid is captured at spawn time so the wrapper can send normalized messages (`{:pty_output, handle, iodata}`, `{:pty_exit, handle, reason}`) back to the GenServer, which consumes them in `handle_info/2`.
- Under the expty backend, the wrapper registers `on_data` and `on_exit` callbacks internally, and those callbacks `send/2` normalized messages to the captured owner. The callback-vs-message difference never leaks past the wrapper; `Destila.Terminal.Server` only ever sees the normalized messages.
- `Destila.Terminal.Server.init/1` now links to the `handle`, not directly to a `pty`. Behavior is unchanged; the `{:EXIT, handle, _}` clause still fires.

**Execution note:** Characterization-first. Before editing `server.ex`, confirm the current `server_test.exs` fully exercises the six `ExPTY` calls and the two PubSub broadcast shapes. Add any gap-filling tests (still against `ExPTY`) *before* introducing the wrapper, so the wrapper change is demonstrably behavior-preserving.

**Patterns to follow:**
- `Destila.Terminal.Tmux` — a small, testable shell-out module. Mirror its "one module, narrow contract, everything else shells out" shape.
- Existing Mimic usage in `test/destila/terminal/server_test.exs` — re-target at the wrapper module.

**Test scenarios:**
- Happy path: `TerminalServer.start_link/1` triggers one `PTY.spawn/2` call with the expected owner pid, argv, cwd, cols/rows, and env. Verifies argv shape and wrapper options.
- Happy path: when the GenServer receives a `{:pty_output, handle, "hello"}` message from the (stubbed) wrapper, it broadcasts `{:terminal_output, "hello"}` on the expected PubSub topic. Verifies that the GenServer — not the wrapper — owns the translation from wrapper message to PubSub message.
- Happy path: when the GenServer receives a `{:pty_exit, handle, _}` message, it broadcasts `:terminal_exited` and stops cleanly. Verifies exit plumbing.
- Happy path: `TerminalServer.write/2` → `PTY.write/2` call with identical payload.
- Happy path: `TerminalServer.resize/3` → `PTY.resize/3` called with `cols, rows` (wrapper's public contract uses `cols, rows`; the erlexec-specific `rows, cols` flip lives inside the wrapper backend, not in its API).
- Edge case: resize before first output still updates GenServer state.
- Error path: `PTY.spawn/2` returns `{:error, reason}` → GenServer stops cleanly (document existing behavior; do not invent new behavior).
- Integration: on GenServer `terminate/2`, `PTY.kill(handle, 15)` is called exactly once; if the handle is already dead, not called again.
- Characterization-only (new): `TerminalServer.resize/3` and the `:terminal_exited` broadcast on PTY exit — neither of these is currently exercised by `server_test.exs`; add them here *before* introducing the wrapper, so Unit 1's behavior preservation is demonstrable rather than assumed.

**Verification:**
- `mix test test/destila/terminal/server_test.exs` is green.
- `mix precommit` is green.
- Manual smoke test: open the in-browser terminal panel, type, resize the panel, observe colored tmux output.

- [~] **Unit 2: Time-boxed erlexec spike (throwaway branch)** — automated portion complete; manual smoke (tmux, browser, Ctrl-C, orphan-check on Linux) deferred to a human. Evidence captured in `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`.

**Goal:** Empirically verify all four evaluation gates (Capability parity, Build/deploy, Teardown hygiene, Test parity) against `erlexec` without committing the app to the swap.

**Requirements:** R1, R2, R3 (gate-only; no production code change merges from this unit)

**Dependencies:** Unit 1 (so the spike can swap backends by implementing a second wrapper behind the same contract).

**Files:** No files are committed to `main` from this unit. Spike artifacts live on a throwaway branch and are summarized into `docs/solutions/`.

**Approach:**
- On a spike branch, add `{:erlexec, "~> 2.2"}` (and temporarily keep `expty`) to `mix.exs`. Implement an `erlexec` backend for `Destila.Terminal.PTY` that satisfies the same contract Unit 1 established.
- Verify Gate 1 (Capability parity) by running the app locally end-to-end: open the in-browser terminal, attach to a tmux session, launch `claude --resume <id>`, type Ctrl-C, resize the browser panel, close the tab, observe teardown.
- Verify Gate 2 (Build/deploy) by: (a) running `mix deps.clean erlexec && mix deps.compile` on macOS and on one Linux dev host or container, timing the cold build; (b) checking whether any `libcap-dev`/equivalent is required in our current build environment (README says it's required on Linux for setuid, not for plain PTY — confirm empirically).
- Verify Gate 3 (Teardown hygiene) by: killing the GenServer mid-stream (`Process.exit(pid, :kill)`), and using `ps` / `pgrep tmux` to confirm no orphaned tmux clients remain; repeating for SIGTERM and for normal GenServer `terminate/2`.
- Verify Gate 4 (Test parity) by: running the existing `server_test.exs` against the `erlexec` backend (should be unchanged because the tests mock the wrapper, not the backend). If the tests still pass without changes, Gate 4 passes.

**Execution note:** Spike only. Do not merge production code from this unit. The sole deliverable is evidence captured in Unit 3.

**Patterns to follow:**
- `erlexec` Elixir example in `hexdocs.pm/erlexec/exec.html`: `:exec.run(~c"bash -i", [:pty, :pty_echo, :monitor, {:stdout, self()}, {:stderr, self()}, :stdin])`.
- Keep the spike module small and disposable; there is no need to polish it.

**Test scenarios:**
- Manual: tmux session attaches, shows colored `ls` output, SIGWINCH on resize produces correct pane dimensions inside tmux.
- Manual: Ctrl-C inside Claude CLI inside tmux inside the PTY cancels only the Claude command, not the whole shell.
- Manual: closing the browser tab → GenServer terminate → `pgrep -fa tmux` / `ps` shows no orphaned tmux client processes.
- Manual: crashing the GenServer (`Process.exit(pid, :kill)`) also reaps the child within `kill_timeout`.
- Build: `mix deps.clean erlexec && mix deps.compile` completes on macOS and on Linux; capture wall-clock cost.
- Automated: `mix test test/destila/terminal/server_test.exs` passes unchanged with the erlexec backend wired up.

**Verification:**
- Each gate is marked pass or fail in Unit 3's decision record, with the evidence captured (log excerpts, `ps` output, build-time numbers).
- Spike branch is discarded regardless of outcome; code lands only in Unit 4 (if all gates pass).

- [x] **Unit 3: Write decision record and choose a path** — `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`. Decision: land wrapper, defer backend swap pending manual smoke.

**Goal:** Produce a concrete, permanent decision record that either green-lights the swap or documents why we stay on `expty`. Either outcome is acceptable and is the actual deliverable of the evaluation.

**Requirements:** R1, R2, R3 (evidence-backed)

**Dependencies:** Unit 2.

**Files:**
- Create: `docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`

**Approach:**
- Record, per gate, the evidence gathered in Unit 2 and the pass/fail verdict.
- Capture the final recommendation: either "migrate, follow Unit 4" or "stay on expty, reassess when (concrete trigger)".
- If staying, record the concrete trigger that would reopen this evaluation (e.g., `expty` unmaintained for 12+ months, NIF crash observed in production, need for Windows dropped).

**Execution note:** Test expectation: none — this is a decision artifact.

**Patterns to follow:**
- Existing `docs/solutions/` structure (frontmatter + prose). If none exist yet, establish a minimal shape that other solutions can adopt: problem, evidence, decision, reversal criteria.

**Test scenarios:**
- Test expectation: none — this unit produces a document, not code.

**Verification:**
- File exists, is linked from this plan, and contains an unambiguous decision sentence. Reviewer can understand the decision without re-running the spike.

- [ ] **Unit 4: Swap the wrapper's backend from expty to erlexec (conditional on Unit 3 passing all gates)** — blocked on manual smoke (see decision record). Not performed in this pass.

**Goal:** Replace `expty` with `erlexec` behind the wrapper introduced in Unit 1, keeping `Destila.Terminal.Server` and the PubSub contract unchanged.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** Unit 3 must record "migrate."

**Files:**
- Modify: `lib/destila/terminal/pty.ex` (backend swap)
- Modify: `mix.exs` (remove `:expty`, add `:erlexec`, add `:exec` to `extra_applications` in `application/0` so the `:exec` OTP application starts at boot)
- Modify: `mix.lock` (regenerated)
- Modify: `test/destila/terminal/server_test.exs` (only if the wrapper's contract proves leaky; ideally unchanged)

**Approach:**
- Replace the expty backend inside the wrapper with the erlexec implementation validated in Unit 2.
- Wrapper's contract (message shape, argument order, `handle` opacity) is unchanged.
- Pay attention to the `winsz` argument order flip: the wrapper takes `cols, rows` and calls `:exec.winsz(ospid, rows, cols)`. Add a comment here because this is the one asymmetry likely to cause a bug during review.
- Use `run_link` with `:monitor` so the owner GenServer both links (for teardown) and monitors (for signal-decoded exit status).
- Ensure the `:exec` OTP application is started at boot (via `extra_applications: [:exec]` in `mix.exs`). Without this, `:exec.run_link/2` returns `{:error, :not_started}` at first call. The wrapper should not call `:exec.start/0` lazily — the application tree owns that.
- Preserve `cwd`, env injection (`TERM=xterm-256color`, `COLORTERM=truecolor`), and initial rows/cols on spawn.

**Execution note:** This unit merges only if Unit 3 green-lights it. If any gate fails in Unit 2, Unit 4 is not performed and the plan closes at Unit 3.

**Patterns to follow:**
- `erlexec` API reference: `:pty`, `{:winsz, {rows, cols}}`, `:exec.send/2`, `:exec.winsz/3`, `:exec.kill/2`, `:exec.status/1`, `{:DOWN, ospid, :process, pid, reason}`.
- Existing message-driven `handle_info/2` style in `server.ex`; the wrapper's normalized messages should land in the same clauses we added in Unit 1.

**Test scenarios:**
- Happy path: existing `server_test.exs` passes unchanged (this is the signal that the wrapper contract held).
- Happy path: manual end-to-end — open terminal, attach tmux, run Claude CLI, resize, close tab, check `pgrep` for orphans (same four checks as Unit 2 Gate 3, now against the production code path).
- Edge case: `winsz(cols, rows)` produces the correct `(rows, cols)` at the `:exec.winsz` layer — add one explicit wrapper-level test that asserts the argument order, because this is the one failure mode most likely to pass unit tests but silently mis-size the PTY.
- Error path: `:exec.run_link` returns `{:error, reason}` → wrapper returns `{:error, reason}`, GenServer stops cleanly.
- Integration: GenServer `terminate/2` triggers `:exec.kill(ospid, 15)`; subsequent `{:DOWN, ospid, ...}` does not crash the already-terminating GenServer.

**Verification:**
- `mix test` is green.
- `mix precommit` is green.
- `mix deps.get && mix deps.compile` succeeds on a clean checkout on macOS and one Linux environment.
- Manual end-to-end smoke: terminal opens, tmux attaches, Claude CLI works, resize works, clean teardown (no orphaned tmux clients).

## System-Wide Impact

- **Interaction graph:** `TerminalLive` → `Destila.Terminal.Server` (GenServer) → `Destila.Terminal.PTY` (new wrapper) → {`ExPTY` today / `:exec` after swap}. PubSub subscribers of `"terminal:<session_id>"` are unaffected.
- **Error propagation:** GenServer link/monitor semantics change underneath — `erlexec` exposes an `{erl_pid, ospid}` pair, the wrapper normalizes. Owner still dies with the PTY, as it does today.
- **State lifecycle risks:** Orphaned tmux clients on crash are the primary risk. `erlexec`'s `run_link` + `kill_timeout` + recent (2026-04-10) PTY process-group fix suggest this is handled, but we validate explicitly in Unit 2 Gate 3.
- **API surface parity:** `Destila.Terminal.Server.write/2` and `resize/3` signatures do not change. `TerminalLive` does not change. The Phoenix Channel contract does not change.
- **Integration coverage:** The mocked unit tests alone will not catch tmux-under-PTY regressions. Unit 2 Gate 3 and the manual smoke in Unit 4 are non-negotiable.
- **Unchanged invariants:** PubSub messages (`{:terminal_output, binary}`, `:terminal_exited`) and the `TerminalServer` public API remain byte-identical. If either changes, something has gone wrong and the reviewer should push back.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `erlexec`'s PTY path has no public precedent for tmux-attach + interactive CLI, and the process-group code was patched 5 days before the latest release. | Unit 2 spike explicitly validates tmux + Claude CLI + Ctrl-C + resize + teardown before committing. Failure at Gate 3 means no migration. |
| `erlexec` compiles C++ from source at `mix deps.get`, adding a toolchain requirement to every build host and CI runner. | Unit 2 Gate 2 measures the cold-build cost on macOS and Linux and confirms the required toolchain is already present. Failure means staying on `expty`. |
| Argument-order asymmetry between `ExPTY.resize(cols, rows)` and `:exec.winsz(ospid, rows, cols)`. | Wrapper owns the conversion; an explicit unit-level test in Unit 4 pins the order. The wrapper's public contract uses `cols, rows` (matching the xterm.js mental model). |
| Losing `expty`'s 11 precompiled platform binaries in favor of `erlexec`'s source build. | Acceptable iff Gate 2 passes on our real build environments. Document the toolchain requirement in `README.md` or wherever setup instructions live (follow-on to Unit 4 if we migrate). |
| In-BEAM NIF crash risk of `expty` vs. out-of-BEAM port risk of `erlexec`. | This risk cuts *toward* migrating; call it out explicitly in Unit 3's decision record. |
| The evaluation stalls and the spike branch rots. | Unit 2 is time-boxed. If gates cannot be decided in one focused pass, Unit 3 still runs and records "insufficient evidence — stay on expty" rather than leaving the question open. |

## Documentation / Operational Notes

- If Unit 4 lands, update `README.md` (or the equivalent setup doc) to note the C++ toolchain requirement for `erlexec` on any new build host. No other runbook changes expected — no new services, no new ports, no new env vars.
- Unit 3's decision record (`docs/solutions/2026-04-21-erlexec-vs-expty-evaluation.md`) becomes the canonical reference; future maintainers should read it before reopening this question.
- No migration for users or data. This is a library-level swap with no persisted state.

## Sources & References

- Current implementation: `lib/destila/terminal/server.ex`
- Current tests: `test/destila/terminal/server_test.exs`, `test/test_helper.exs:6`
- Current dep: `mix.exs:70` (`{:expty, "~> 0.2"}`)
- Original terminal design rationale: `docs/plans/2026-04-12-feat-inline-xterm-terminal-plan.md`
- erlexec v2.2.4 on Hex: https://hex.pm/packages/erlexec
- erlexec HexDocs: https://hexdocs.pm/erlexec/exec.html
- erlexec README (platforms, build requirements): https://github.com/saleyn/erlexec/blob/master/README.md
- erlexec PTY C implementation: https://github.com/saleyn/erlexec/blob/master/c_src/exec_impl.cpp
- erlexec `winsz` regression test: https://github.com/saleyn/erlexec/blob/master/src/exec.erl (`test_winsz/0`, line 1660)
- expty on Hex (v0.2.1, 2024-09-30): https://hex.pm/packages/expty
- expty GitHub (v0.2.2 release, not on Hex): https://github.com/cocoa-xu/expty/releases/tag/v0.2.2
