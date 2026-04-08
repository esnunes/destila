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
