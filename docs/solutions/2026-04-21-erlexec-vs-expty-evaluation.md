---
title: "erlexec vs expty — PTY backend evaluation"
date: 2026-04-21
plan: docs/plans/2026-04-21-001-refactor-evaluate-erlexec-over-expty-plan.md
decision: hold — land wrapper, defer backend swap pending manual smoke
status: partial
---

# erlexec vs expty — PTY backend evaluation

## Problem

`expty` (NIF wrapping `forkpty(3)`) is today's PTY backend behind the
in-browser xterm.js terminal. It is pre-1.0, single-maintainer, and
sparsely released; a NIF crash takes the whole BEAM node down. The
plan's evaluation asked whether `erlexec` — actively maintained,
out-of-BEAM port — is a better long-term home, conditional on passing
four gates (capability parity, build/deploy, teardown hygiene, test
parity).

## Decision

**Land the `Destila.Terminal.PTY` wrapper over `expty` (Unit 1).**
**Defer the backend swap (Unit 4) until the manual smoke tests from
Unit 2 are performed by a human.**

The wrapper — the reversibility foundation — is merged regardless of
which backend ultimately wins. Every remaining gate needs at most a
one-module change and a dep flip.

### Why not flip now

Three of the four gates have *automated* evidence pointing toward
`erlexec`. The fourth (Gate 1, capability parity) needs
browser + tmux + Claude CLI end-to-end validation that a non-interactive
agent cannot reasonably perform. The plan itself labels that validation
non-negotiable:

> Unit 2 Gate 3 and the manual smoke in Unit 4 are non-negotiable.

Running the swap before that smoke risks shipping a regression whose
first symptom would be "interactive terminal broken" in production.

## Evidence by gate

Spike performed on a throwaway branch (`spike/erlexec-evaluation`,
deleted). Host: macOS 15 (Darwin 24.6, arm64), Erlang 28.4, Elixir
1.19.0, Apple clang 17. `erlexec` v2.2.4 (2026-04-15) was the exact
version exercised.

### Gate 1 — Capability parity (R1, R2): partial pass

Verified automatically against trivial shell children:

- **spawn with PTY**: `:exec.run/2` with `[:pty, :monitor, {:stdout, pid}, {:stderr, pid}, {:winsz, {rows, cols}}]` spawns under a real PTY. `printf` output arrived on stdout in order.
- **stdin write**: `:exec.send(ospid, "hello\n")` delivered bytes into a
  `read`/`echo` loop child; child echoed `"GOT:hello\r\n"` (note the
  `\r\n`, consistent with real PTY line discipline).
- **winsz**: `:exec.winsz(ospid, 40, 120)` returned `:ok`. Argument order
  is `(rows, cols)` — the inverse of `ExPTY.resize(pty, cols, rows)`.
  The wrapper's public `PTY.resize/3` keeps `(cols, rows)` to match
  xterm.js and hides the flip in the backend.
- **kill**: `:exec.kill(ospid, 15)` reliably triggered the `:DOWN`
  message.
- **exit message shape**: `{:DOWN, ospid, :process, pid, reason}` was
  observed with three different `reason` shapes in this one spike:
  `:normal` (exit status 0), `{:exit_status, 15}` (after SIGTERM), and
  the documented integer-encoded form (not hit in the spike but
  possible). The wrapper must normalize all three before calling
  `:exec.status/1`, which crashes on anything other than the integer
  shape.

**Not verified — reserved for manual smoke:**

- `tmux attach` inside `:pty` end-to-end.
- Ctrl-C propagation from xterm.js → port → tmux-client → tmux-server →
  child process (Claude CLI).
- xterm.js color + cursor rendering over the PubSub → Channel path.
- SIGWINCH propagation into tmux on browser resize.

### Gate 2 — Build/deploy (R3): pass on macOS, not measured on Linux

```
mix deps.get         1.5 s wall (just fetching erlexec + rebar3 plugins)
mix deps.compile     3.7 s wall (C++ build of exec-port)
```

Used Apple clang, already installed. No extra packages needed. One
harmless `-Wunused-variable` warning in `exec_impl.cpp:560`. Linker
complained `ld: warning: -undefined suppress is deprecated` twice —
cosmetic, build succeeded.

**Not measured:** Linux cold build. If Destila's CI or release image
lacks a C++ toolchain, that would shift Gate 2 to partial. Before
Unit 4 lands, confirm whether the production/CI build environment
already ships `g++` and `make` — if Destila is dev-host-only today,
this gate collapses to "dev hosts" and is already satisfied here.

### Gate 3 — Teardown hygiene: pass (partial)

Automated: an Erlang parent process called `:exec.run_link/2` to spawn
`sh -c 'sleep 30'`, then the parent was killed. Two seconds later,
`ps -p <ospid>` showed no process. The port reaped the child
automatically via `kill_timeout`.

```
ps before parent exit:
  PID TTY           TIME CMD
42399 ??         0:00.01 /bin/zsh -c /bin/sh -c 'sleep 30'
ps after parent killed (2s):
  PID TTY           TIME CMD
```

**Not verified — reserved for manual smoke:**

- tmux **client** teardown (vs a plain `sleep`). tmux forks a client
  process attached to a separate server; the concern is whether the
  client detaches cleanly when its PTY goes away without leaving a
  ghost attached to the tmux server.
- Dev-loop hot-reload churn: does repeatedly opening/closing the
  in-browser terminal in `mix phx.server` leak clients?
- Behavior when Phoenix OTP restarts `exec-port` (the single out-of-BEAM
  helper) mid-session — every live PTY child dies together; this is an
  *improvement* over a NIF crash (which would take the node down) but
  still a shared-fate property worth documenting.

### Gate 4 — Test parity (R5): pass (by design)

`test/destila/terminal/server_test.exs` now mocks `Destila.Terminal.PTY`
(not `ExPTY`). Swapping the backend is invisible to the test suite —
Gate 4 is trivially satisfied by the Unit 1 wrapper.

## Wrapper contract (landed under expty)

Contract the wrapper exposes (see `lib/destila/terminal/pty.ex`):

```
spawn(owner, cmd:, args:, cwd:, cols:, rows:) ::
  {:ok, handle} | {:error, term()}

write(handle, iodata)        :: :ok
resize(handle, cols, rows)   :: :ok
kill(handle, signal)         :: :ok

# Messages the wrapper sends to `owner`, invariant across backends:
{:pty_output, handle, iodata}
{:pty_exit,   handle, {:status, integer} | {:signal, atom_or_int, bool}}
```

Under `expty`, `handle` is the pty pid; the wrapper links to it and
registers `on_data`/`on_exit` callbacks that forward normalized
messages. Under `erlexec` (future), `handle` becomes `{erl_pid, ospid}`
and the wrapper would use `:exec.run_link` + `:monitor`, translating
`{:DOWN, ...}` into `{:pty_exit, handle, reason}` and normalizing the
three exit-reason shapes (`:normal`, integer, `{:exit_status, N}`).

## What a green-light swap looks like

All of the following before Unit 4 merges:

1. Human opens the in-browser terminal, attaches to a tmux session,
   runs `claude --resume <id>` inside it, types, issues Ctrl-C, resizes
   the browser panel, closes the tab.
2. `pgrep -fa tmux` after step 1 shows no orphaned tmux clients.
3. Same checks on the team's Linux environment (CI runner or release
   base image), including a fresh `mix deps.get && mix deps.compile`
   to confirm the C++ toolchain is present.
4. The `(cols, rows)` → `(rows, cols)` flip at the `:exec.winsz` seam
   has an explicit wrapper-level test pinning argument order.

If all four check out, the swap itself is a small change:
`lib/destila/terminal/pty.ex` backend body, `mix.exs` dep line + `:exec`
in `extra_applications`, done.

## Reversal criteria (if we stay)

Reasons to reopen this evaluation and pursue the swap:

- `expty` not updated on Hex for 12+ months past its last release
  (2024-09-30 at time of writing) without a fork-and-own plan in place.
- A NIF crash in `expty` observed in production or dev, even once.
- New platform support needed that `expty`'s precompiled binary matrix
  does not cover.
- A bug in `expty` that requires a local fork to fix and upstream is
  unresponsive.

## References

- Plan: `docs/plans/2026-04-21-001-refactor-evaluate-erlexec-over-expty-plan.md`
- Wrapper landed: `lib/destila/terminal/pty.ex`
- Call site: `lib/destila/terminal/server.ex`
- Tests: `test/destila/terminal/server_test.exs`
- erlexec 2.2.4: https://hex.pm/packages/erlexec
- erlexec PTY impl: https://github.com/saleyn/erlexec/blob/master/c_src/exec_impl.cpp
