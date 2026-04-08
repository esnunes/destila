defmodule Mix.Tasks.Destila.Setup do
  @shortdoc "Verifies Destila development dependencies"

  @moduledoc """
  Verifies that the Claude CLI is available on the system.

  Uses `ClaudeCode.Adapter.Port.Resolver` in `:global` mode, which matches
  the runtime configuration (`config :claude_code, cli_path: :global`). It
  checks `$PATH` and common install locations (e.g. `~/.local/bin/claude`).

  If the CLI is missing, the task prints install instructions and exits
  with a non-zero status. It does not install anything automatically.

  ## Usage

      mix destila.setup
  """

  use Mix.Task

  alias ClaudeCode.Adapter.Port.Resolver

  @impl Mix.Task
  def run(_args) do
    case Resolver.find_binary(cli_path: :global) do
      {:ok, path} ->
        Mix.shell().info("Claude CLI available at #{path}")

      {:error, _reason} ->
        Mix.shell().error("""
        Claude CLI not found on this system.

        Install it with the official script:

            curl -fsSL https://claude.ai/install.sh | bash

        This places the binary at ~/.local/bin/claude, which Destila
        resolves automatically via `cli_path: :global`. Make sure
        ~/.local/bin is on your $PATH, then re-run `mix destila.setup`.

        Alternative install methods are documented at
        https://docs.anthropic.com/en/docs/claude-code.
        """)

        exit({:shutdown, 1})
    end
  end
end
