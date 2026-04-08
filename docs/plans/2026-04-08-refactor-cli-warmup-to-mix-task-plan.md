---
title: "refactor: CLI binary warmup from supervision tree to Mix task"
type: refactor
date: 2026-04-08
---

# refactor: CLI binary warmup from supervision tree to Mix task

## Overview

`Destila.AI.CliWarmer` runs as a temporary `Task` in the supervision tree at application boot. It calls `ClaudeCode.Adapter.Port.Resolver.find_binary/1` and `ClaudeCode.Adapter.Port.Installer.version_of/1` to pre-warm the Claude CLI binary (avoiding macOS Gatekeeper SIGKILL races on first invocation). This refactor moves the check to a Mix task (`mix destila.setup`) so the binary installation happens at project setup time, not at every application boot.

## Prerequisites

None — the `claude_code` dependency already ships `Mix.Tasks.ClaudeCode.Install` which handles installation, version checking, and user-facing output.

## Changes

### Step 1: Create `mix destila.setup` Mix task

**File:** `lib/mix/tasks/destila.setup.ex` (new)

```elixir
defmodule Mix.Tasks.Destila.Setup do
  @shortdoc "Sets up Destila development dependencies"

  @moduledoc """
  Ensures the Claude CLI binary is installed.

  Checks for the binary using the same resolver the runtime uses
  (`ClaudeCode.Adapter.Port.Resolver.find_binary/1`). If the binary
  is not found, delegates to `mix claude_code.install`.

  ## Usage

      mix destila.setup
  """

  use Mix.Task

  alias ClaudeCode.Adapter.Port.Resolver

  @impl Mix.Task
  def run(_args) do
    case Resolver.find_binary() do
      {:ok, path} ->
        Mix.shell().info("Claude CLI already available at #{path}")

      {:error, _reason} ->
        Mix.Task.run("claude_code.install")
    end
  end
end
```

Key decisions:

- Uses `Resolver.find_binary/1` (no opts — uses app config defaults, matching runtime behavior) rather than `System.find_executable/1`.
- On `{:error, _}`, delegates entirely to `mix claude_code.install` which handles installation, version output, and error reporting. No need to duplicate any of that logic.
- On `{:ok, path}`, prints the path and exits. No version check — `find_binary/1` in `:bundled` mode already validates the version matches and auto-reinstalls on mismatch (see `Resolver.find_bundled/0` → `check_bundled_version/1`).
- No defensive error handling — if something fails, it blows up.

### Step 2: Wire into `mix setup` alias

**File:** `mix.exs` — line 81

Add `"destila.setup"` to the `setup` alias. Place it after `"deps.get"` (so the `claude_code` dependency is available) and before `"ecto.setup"`:

```elixir
# Before:
setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build", "git.hooks"],

# After:
setup: ["deps.get", "destila.setup", "ecto.setup", "assets.setup", "assets.build", "git.hooks"],
```

### Step 3: Delete `Destila.AI.CliWarmer`

**File:** `lib/destila/ai/cli_warmer.ex` — delete entirely.

### Step 4: Remove `claude_cli_warmer/0` from `Destila.Application`

**File:** `lib/destila/application.ex`

**4a.** Remove the `++ claude_cli_warmer()` from the children list (line 23). Change:

```elixir
      DestilaWeb.Endpoint
    ] ++ claude_cli_warmer()
```

To:

```elixir
      DestilaWeb.Endpoint
    ]
```

**4b.** Delete the entire `claude_cli_warmer/0` private function (lines 35-40):

```elixir
  defp claude_cli_warmer do
    case Application.get_env(:claude_code, :adapter) do
      {ClaudeCode.Test, _} -> []
      _ -> [Destila.AI.CliWarmer]
    end
  end
```

Also remove the comment block above it (lines 31-34).

### Step 5: Add test for `mix destila.setup`

**File:** `test/mix/tasks/destila.setup_test.exs` (new)

```elixir
defmodule Mix.Tasks.Destila.SetupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "run/1" do
    test "reports binary already available when found" do
      output = capture_io(fn -> Mix.Tasks.Destila.Setup.run([]) end)

      assert output =~ "Claude CLI already available at"
    end
  end
end
```

This test verifies the happy path — when the binary is found (which it will be in the dev/test environment since `mix setup` / `mix claude_code.install` has already been run), the task reports its location. Testing the `{:error, _}` → `Mix.Task.run("claude_code.install")` delegation path would require either mocking `Resolver.find_binary/1` or uninstalling the binary, neither of which is practical. The `claude_code.install` task itself is tested in the `claude_code` dependency.

### Step 6: Run `mix precommit`

Verify compilation, formatting, and all tests pass.

## Files changed

| File | Change |
|---|---|
| `lib/mix/tasks/destila.setup.ex` | **New** — Mix task that checks for Claude CLI binary |
| `mix.exs` | Add `"destila.setup"` to `setup` alias |
| `lib/destila/ai/cli_warmer.ex` | **Deleted** — No longer needed |
| `lib/destila/application.ex` | Remove `claude_cli_warmer/0` helper and its invocation |
| `test/mix/tasks/destila.setup_test.exs` | **New** — Test for the Mix task |

## Acceptance criteria

- `mix destila.setup` exists and checks for the Claude CLI binary via `Resolver.find_binary/1`
- When binary is found, task prints location and exits
- When binary is not found, task delegates to `mix claude_code.install`
- `Destila.AI.CliWarmer` module no longer exists
- `Destila.Application` no longer references `CliWarmer` or `claude_cli_warmer/0`
- `mix setup` runs `destila.setup` after `deps.get`
- `mix precommit` passes
