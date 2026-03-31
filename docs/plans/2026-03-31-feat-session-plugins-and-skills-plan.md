# Plan: Install plugins and enable skills in every AI session

## Summary

Ensure every `Destila.AI.ClaudeSession` has two plugins (`compound-engineering@every-marketplace` and `impeccable@impeccable`) installed and enabled, and the `Skill` tool available via `setting_sources`. All setup runs synchronously in `init/1` before `ClaudeCode.start_link/1`.

## Problem

AI sessions currently start with no plugins and no skill discovery. The `Skill` tool is already in `@default_allowed_tools`, but `setting_sources` is not passed to `ClaudeCode.start_link/1`, so skills are never discovered from the filesystem. The two required plugins are not installed or enabled.

## Change

**File:** `lib/destila/ai/claude_session.ex` — `init/1` callback (line 225)

### Current `init/1` flow

```elixir
def init(opts) do
  {timeout_ms, claude_opts} = Keyword.pop(opts, :timeout_ms, @default_timeout_ms)
  claude_opts = Keyword.put_new(claude_opts, :allowed_tools, @default_allowed_tools)
  claude_opts = Keyword.put_new(claude_opts, :mcp_servers, %{"destila" => Destila.AI.Tools})

  case ClaudeCode.start_link(claude_opts) do
    {:ok, claude_session} -> ...
    {:error, reason} -> {:stop, reason}
  end
end
```

### New `init/1` flow

Insert plugin/marketplace setup **before** `ClaudeCode.start_link/1`, and add `setting_sources` to `claude_opts`:

```elixir
def init(opts) do
  {timeout_ms, claude_opts} = Keyword.pop(opts, :timeout_ms, @default_timeout_ms)
  claude_opts = Keyword.put_new(claude_opts, :allowed_tools, @default_allowed_tools)
  claude_opts = Keyword.put_new(claude_opts, :mcp_servers, %{"destila" => Destila.AI.Tools})
  claude_opts = Keyword.put_new(claude_opts, :setting_sources, ["user", "project"])

  # Register marketplaces and install/enable plugins before starting the session.
  # All calls are idempotent; failures stop the session.
  with {:ok, _} <- ClaudeCode.Plugin.Marketplace.add("every-marketplace"),
       {:ok, _} <- ClaudeCode.Plugin.Marketplace.add("impeccable"),
       {:ok, _} <- ClaudeCode.Plugin.install("compound-engineering@every-marketplace"),
       {:ok, _} <- ClaudeCode.Plugin.enable("compound-engineering@every-marketplace"),
       {:ok, _} <- ClaudeCode.Plugin.install("impeccable@impeccable"),
       {:ok, _} <- ClaudeCode.Plugin.enable("impeccable@impeccable") do
    case ClaudeCode.start_link(claude_opts) do
      {:ok, claude_session} ->
        timer_ref = schedule_timeout(timeout_ms)

        {:ok,
         %{
           claude_session: claude_session,
           timeout_ms: timeout_ms,
           timer_ref: timer_ref
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  else
    {:error, reason} -> {:stop, {:plugin_setup_failed, reason}}
  end
end
```

### Step-by-step changes

1. **Add `setting_sources` to `claude_opts`** (1 line after existing `put_new` calls):
   ```elixir
   claude_opts = Keyword.put_new(claude_opts, :setting_sources, ["user", "project"])
   ```
   This tells the SDK to discover skills from `~/.claude/skills/` (user) and `.claude/skills/` (project).

2. **Add marketplace registration** (2 calls):
   ```elixir
   {:ok, _} <- ClaudeCode.Plugin.Marketplace.add("every-marketplace")
   {:ok, _} <- ClaudeCode.Plugin.Marketplace.add("impeccable")
   ```

3. **Add plugin install + enable** (4 calls):
   ```elixir
   {:ok, _} <- ClaudeCode.Plugin.install("compound-engineering@every-marketplace")
   {:ok, _} <- ClaudeCode.Plugin.enable("compound-engineering@every-marketplace")
   {:ok, _} <- ClaudeCode.Plugin.install("impeccable@impeccable")
   {:ok, _} <- ClaudeCode.Plugin.enable("impeccable@impeccable")
   ```

4. **Wrap existing `ClaudeCode.start_link/1` in the `with` success branch** and add an `else` clause that returns `{:stop, {:plugin_setup_failed, reason}}`.

### What stays the same

- `@default_allowed_tools` already includes `"Skill"` — no change needed.
- The `start_link`, `for_workflow_session`, `session_opts_for_workflow`, and all other functions are unchanged.
- No new modules, no new tests.

## Verification

Manual verification:
1. Start the application and create a new workflow session.
2. Confirm the session starts successfully (no `{:stop, ...}` crash).
3. In the AI session, verify that skills are discoverable (the `Skill` tool should appear in the tool list).
4. Verify plugins are active by checking `claude plugins list` shows both plugins enabled.
