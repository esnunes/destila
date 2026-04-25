defmodule Destila.Mise do
  @moduledoc """
  Helpers for invoking the `mise` CLI from the application.

  Currently exposes a single helper to opt-in trust the `.mise.toml`
  files in a working directory before launching commands that may
  source the project's tool versions and environment.
  """

  require Logger

  alias Destila.Projects.Project

  @doc """
  Runs `mise trust -y --all -C <cwd>` when the project has
  `mise_auto_trust` enabled.

  Always returns `:ok` — failures are logged and swallowed so callers
  can keep going (untrusted `.mise.toml` files just mean `mise` will
  prompt at runtime, which is recoverable).

  `context` is a free-form string used in the warning message so the
  same helper can be called from worker, project-services, and ad-hoc
  paths without losing trace information.
  """
  def maybe_trust(project, cwd, context \\ nil)

  def maybe_trust(%Project{mise_auto_trust: true} = project, cwd, context)
      when is_binary(cwd) and cwd != "" do
    {output, status} =
      System.cmd("mise", ["trust", "-y", "--all", "-C", cwd], stderr_to_stdout: true)

    if status != 0 do
      Logger.warning(
        "mise trust -y --all -C #{cwd} exited #{status} for project #{project.id}#{context_suffix(context)}: #{output}"
      )
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "mise trust failed for project #{project.id}#{context_suffix(context)}: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      :ok
  end

  def maybe_trust(_project, _cwd, _context), do: :ok

  defp context_suffix(nil), do: ""
  defp context_suffix(context), do: " (#{context})"
end
