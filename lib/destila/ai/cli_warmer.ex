defmodule Destila.AI.CliWarmer do
  @moduledoc """
  Pre-warms the bundled Claude CLI binary at application boot.

  On macOS, Gatekeeper can SIGKILL (exit 137) a freshly-copied unsigned-by-the-user
  binary on its first few invocations while it verifies the code signature in the
  background. The first user request that triggers a cold install of the CLI is
  therefore liable to fail with `{:provisioning_failed, {:cli_exit, 137}}` even
  though the binary itself is fine.

  Running the install + a `--version` probe at boot pushes that cost (and the
  Gatekeeper race) off the critical path. `ClaudeCode.Adapter.Port.Installer`
  already retries `--version` once on exit 137, so by the time a real user
  request arrives the binary is on disk and Gatekeeper has cached its
  verification.

  Runs as a temporary `Task` so a warmup failure does not crash the supervision
  tree -- a failed warmup just means the first real request pays the install
  cost itself, which is the same behavior as today.
  """

  require Logger

  alias ClaudeCode.Adapter.Port.Installer
  alias ClaudeCode.Adapter.Port.Resolver

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&warm/0]},
      restart: :temporary
    }
  end

  defp warm do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, path} <- Resolver.find_binary([]),
         {:ok, version} <- Installer.version_of(path) do
      elapsed = System.monotonic_time(:millisecond) - started_at
      Logger.info("Claude CLI warmed (v#{version}) at #{path} in #{elapsed}ms")
    else
      {:error, reason} ->
        Logger.warning("Claude CLI warmup failed: #{inspect(reason)}")
    end
  end
end
