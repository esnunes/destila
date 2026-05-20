defmodule Destila.Agent.WorkflowLoader do
  @moduledoc """
  Loads workflow definitions from `priv/workflows/*.yaml` into
  `:persistent_term` for cheap read-many lookup.

  Called once at app boot. Strict validation: missing required fields raise.
  """

  alias Destila.Agent.Workflow
  alias Destila.Agent.Workflow.Phase

  require Logger

  @workflows_dir "priv/workflows"
  @known_top_keys ~w(name phases)
  @known_phase_keys ~w(name system_prompt kickoff_prompt agent_command)

  @doc """
  Reads every `*.yaml` file in `priv/workflows/`, validates, caches.
  Idempotent — safe to call repeatedly.
  """
  def load_all do
    dir = workflows_dir()

    workflows =
      case File.exists?(dir) do
        true ->
          dir
          |> Path.join("*.yaml")
          |> Path.wildcard()
          |> Enum.map(&parse_file/1)

        false ->
          []
      end

    names = Enum.map(workflows, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dupe | _] -> raise "Duplicate workflow name: #{dupe}"
    end

    Enum.each(workflows, fn wf ->
      :persistent_term.put({__MODULE__, wf.name}, wf)
    end)

    :persistent_term.put({__MODULE__, :__names__}, names)
    :ok
  end

  @doc "Returns the workflow definition or `{:error, :not_found}`."
  def get(name) when is_binary(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> {:error, :not_found}
      %Workflow{} = wf -> {:ok, wf}
    end
  end

  @doc "Returns all loaded workflow names."
  def list_all do
    :persistent_term.get({__MODULE__, :__names__}, [])
    |> Enum.map(fn name ->
      {:ok, wf} = get(name)
      wf
    end)
  end

  # --- Parsing ---

  defp parse_file(path) do
    raw =
      case YamlElixir.read_from_file(path) do
        {:ok, data} -> data
        {:error, reason} -> raise "Failed to parse #{path}: #{inspect(reason)}"
      end

    unless is_map(raw),
      do: raise("Workflow #{path} must be a map at the top level")

    log_unknown_keys(path, raw, @known_top_keys)

    name = Map.get(raw, "name") || raise "Workflow #{path} missing required field: name"
    phases_raw = Map.get(raw, "phases") || raise "Workflow #{path} missing required field: phases"

    unless is_list(phases_raw) and length(phases_raw) > 0,
      do: raise("Workflow #{path}: phases must be a non-empty list")

    phases = Enum.map(phases_raw, &parse_phase(&1, path))

    %Workflow{name: name, phases: phases}
  end

  defp parse_phase(raw, path) when is_map(raw) do
    log_unknown_keys(path, raw, @known_phase_keys)

    %Phase{
      name: required(raw, "name", path),
      system_prompt: required(raw, "system_prompt", path),
      kickoff_prompt: required(raw, "kickoff_prompt", path),
      agent_command: parse_agent_command(required(raw, "agent_command", path), path)
    }
  end

  defp parse_phase(_, path), do: raise("Workflow #{path}: each phase must be a map")

  defp parse_agent_command(cmd, _path) when is_list(cmd), do: cmd
  defp parse_agent_command(cmd, _path) when is_binary(cmd), do: String.split(cmd, " ", trim: true)
  defp parse_agent_command(_, path), do: raise("Workflow #{path}: agent_command must be a list")

  defp required(map, key, path) do
    case Map.get(map, key) do
      nil -> raise "Workflow #{path}: missing required field on phase: #{key}"
      "" -> raise "Workflow #{path}: required field is empty: #{key}"
      v -> v
    end
  end

  defp log_unknown_keys(path, map, known) do
    unknown = Map.keys(map) -- known

    if unknown != [] do
      Logger.warning("Workflow #{path} has unknown keys: #{inspect(unknown)}")
    end
  end

  defp workflows_dir do
    case Application.app_dir(:destila, @workflows_dir) do
      path -> path
    end
  rescue
    _ -> @workflows_dir
  end
end
