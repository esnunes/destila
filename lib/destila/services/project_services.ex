defmodule Destila.Services.ProjectServices do
  @moduledoc """
  Lifecycle and pull-and-restart funnel for project-level services.

  Owns all `service_state` transitions on `Destila.Projects.Project`.
  `ServiceManager` is a pure side-effect engine — this module persists the
  resulting state via `Destila.Projects.update_project_service_state/2`
  and broadcasts updates.

  Three triggers funnel through `pull_and_restart/1`:
    1. `Destila.Workers.ProjectServicePullRestartWorker` (cron + session
       hooks)
    2. The "Pull latest & restart" button on the detail page
    3. Boot-time `resume_all/0` (indirectly, via `start/1`)

  When `Destila.Projects.self_hosted?/1` is true, the restart path
  delegates to an external supervisor by calling `System.stop/1`.
  """

  require Logger

  alias Destila.{Git, Mise, Projects, PubSubHelper}
  alias Destila.Projects.Project
  alias Destila.Services.{LogTailer, ServiceManager, Target}

  @doc """
  Starts the project's service. Refuses when already `"running"`.

  On success persists `service_state.status = "running"` and broadcasts
  `:service_status`. On failure persists `"stopped"` and broadcasts
  `{:project_service_error, :start, reason}`.
  """
  def start(%Project{} = project) do
    case current_status(project) do
      "running" ->
        {:error, :already_running}

      _ ->
        case Project.webservice?(project) do
          false ->
            persist_status(project, "stopped")

            PubSubHelper.broadcast_project_service_error(
              project.id,
              :start,
              "Project is not configured as a webservice"
            )

            {:error, :not_a_webservice}

          true ->
            target = Target.for_project(project)

            cond do
              is_nil(target.cwd) or target.cwd == "" ->
                persist_status(project, "stopped")

                PubSubHelper.broadcast_project_service_error(
                  project.id,
                  :start,
                  "Project has no working directory"
                )

                {:error, :no_working_directory}

              true ->
                Mise.maybe_trust(project, target.cwd, "project service")

                case ServiceManager.execute_target(target, "start") do
                  {:ok, state} ->
                    {:ok, _project} =
                      Projects.update_project_service_state(project, merge_state(project, state))

                    {:ok, state}

                  {:error, reason} = error ->
                    persist_status(project, "stopped")

                    PubSubHelper.broadcast_project_service_error(
                      project.id,
                      :start,
                      reason
                    )

                    error
                end
            end
        end
    end
  end

  @doc """
  Stops the project's service. Always best-effort.

  For self-hosted projects, halts the running Destila BEAM via
  `System.stop/1`. The external supervisor (if any) will respawn it; on
  the next boot `resume_all/0` re-marks the project as `"running"` to
  reflect reality.
  """
  def stop(%Project{} = project) do
    if Projects.self_hosted?(project) do
      stopped_state =
        (project.service_state || %{})
        |> Map.put("status", "stopped")

      {:ok, _} = Projects.update_project_service_state(project, stopped_state)
      PubSubHelper.broadcast_project_service_status(project.id, stopped_state)

      _ = :sys.get_state(Destila.PubSub)

      System.stop(0)
      {:ok, stopped_state}
    else
      target = Target.for_project(project)

      case ServiceManager.execute_target(target, "stop") do
        {:ok, state} ->
          {:ok, _project} =
            Projects.update_project_service_state(project, merge_state(project, state))

          {:ok, state}

        {:error, reason} = error ->
          Logger.warning("ProjectServices: stop failed for #{project.id}: " <> inspect(reason))

          error
      end
    end
  end

  @doc """
  Stops then starts the project's service.

  For self-hosted projects, see `self_restart/1` instead — `pull_and_restart/1`
  routes self-hosted restarts through `self_restart/1` automatically.
  """
  def restart(%Project{} = project) do
    _ = stop(project)
    project = Projects.get_project(project.id) || project
    start(project)
  end

  @doc """
  Truncates the project's service log file and broadcasts a clear event.
  """
  def clear_logs(%Project{} = project) do
    target = Target.for_project(project)
    ServiceManager.clear_logs_target(target)
  end

  @doc """
  Removes the project's service entirely: cleans up tmux + log file and
  clears `service_state` to `nil`.
  """
  def remove(%Project{} = project) do
    target = Target.for_project(project)
    ServiceManager.cleanup_target(target)

    # Also kill the dedicated tmux session entirely so no stray windows linger.
    System.cmd("tmux", ["kill-session", "-t", target.tmux_session_name], stderr_to_stdout: true)

    {:ok, _project} = Projects.update_project_service_state(project, nil)
    :ok
  end

  @doc """
  Resumes all project-level services with persisted status `"running"` or
  `"starting"`. Each project starts asynchronously so a slow startup does
  not block app boot.

  Self-hosted projects are handled specially: since the Destila BEAM is
  already running, they are marked `"running"` directly without being
  (re)launched inside tmux.
  """
  def resume_all do
    mark_self_hosted_running()

    Projects.list_projects_by_service_status(["running", "starting"])
    |> Enum.reject(&Projects.self_hosted?/1)
    |> Enum.each(fn project ->
      Task.start(fn ->
        try do
          start(project)
        rescue
          e ->
            Logger.error(
              "ProjectServices.resume_all: start failed for #{project.id}: " <>
                Exception.format(:error, e, __STACKTRACE__)
            )
        end
      end)
    end)

    :ok
  end

  defp mark_self_hosted_running do
    Projects.list_projects()
    |> Enum.filter(&Projects.self_hosted?/1)
    |> Enum.each(fn project ->
      new_state =
        (project.service_state || %{})
        |> Map.put("status", "running")

      {:ok, _} = Projects.update_project_service_state(project, new_state)
      PubSubHelper.broadcast_project_service_status(project.id, new_state)

      target = Target.for_project(project)
      _ = LogTailer.start_for(target.log_key, topic: target.pubsub_topic)
    end)
  end

  @doc """
  Single funnel for the three auto-restart triggers (cron, session hooks,
  manual button) plus the in-app self-restart path.

  Sequence:
    1. fetch
    2. dirty? → halt on dirty
    3. diverged? → halt on diverged
    4. ahead? → noop on not-ahead (just persist last_pulled_at)
    5. fast_forward
    6. self-hosted? → `self_restart/1`, else `restart/1`
  """
  def pull_and_restart(project_id) when is_binary(project_id) do
    case Projects.get_project(project_id) do
      nil ->
        {:error, :project_not_found}

      project ->
        do_pull_and_restart(project)
    end
  end

  defp do_pull_and_restart(%Project{} = project) do
    folder =
      case Git.effective_local_folder(project) do
        {:ok, f} -> f
        {:error, _} -> nil
      end

    cond do
      is_nil(folder) ->
        broadcast_error(project, :working_directory, "Project has no checkout on disk")
        {:error, :no_working_directory}

      true ->
        with :ok <- step(project, :fetch, fn -> Git.fetch(folder) end),
             {:ok, branch} <- step(project, :default_branch, fn -> Git.default_branch(folder) end),
             {:ok, false} <- guard_dirty(project, folder),
             {:ok, false} <- guard_diverged(project, folder),
             {:ok, ahead?} <- step(project, :ahead, fn -> Git.ahead?(folder) end) do
          case ahead? do
            false ->
              persist_pull_metadata(project, branch)
              {:ok, :noop}

            true ->
              case Git.fast_forward(folder) do
                :ok ->
                  persist_pull_metadata(project, branch)

                  if Projects.self_hosted?(project) do
                    self_restart(Projects.get_project(project.id) || project)
                  else
                    restart(Projects.get_project(project.id) || project)
                  end

                {:error, reason} ->
                  broadcast_error(project, :fast_forward, reason)
                  {:error, {:fast_forward, reason}}
              end
          end
        end
    end
  end

  @doc """
  Self-restart path for the Destila self-hosted project. Hard-gated on
  `Projects.self_hosted?/1` — a misfire on a non-self project raises.

  Sequence: persist `"starting"` → broadcast → sync → `System.stop(0)`.

  External supervisor respawns Destila; on boot, `resume_all/0` reads
  persisted `"starting"`/`"running"` status and re-invokes `start/1`.
  """
  def self_restart(%Project{} = project) do
    unless Projects.self_hosted?(project) do
      raise ArgumentError,
        message: "ProjectServices.self_restart/1 invoked on non-self-hosted project #{project.id}"
    end

    starting_state =
      project.service_state
      |> Kernel.||(%{})
      |> Map.put("status", "starting")

    {:ok, _project} = Projects.update_project_service_state(project, starting_state)
    PubSubHelper.broadcast_project_service_status(project.id, starting_state)

    # Defensive: give the broadcast a tick to land before the SIGTERM cascade.
    _ = :sys.get_state(Destila.PubSub)

    System.stop(0)
  end

  # ─── Helpers ────────────────────────────────────────────────────────────

  defp step(project, stage, fun) do
    case fun.() do
      :ok ->
        :ok

      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        broadcast_error(project, stage, reason)
        err
    end
  end

  defp guard_dirty(project, folder) do
    case Git.dirty?(folder) do
      {:ok, true} ->
        broadcast_error(project, :dirty, "working tree has uncommitted changes")
        {:error, :dirty}

      {:ok, false} ->
        {:ok, false}

      {:error, reason} ->
        broadcast_error(project, :dirty, reason)
        {:error, {:dirty, reason}}
    end
  end

  defp guard_diverged(project, folder) do
    case Git.diverged?(folder) do
      {:ok, true} ->
        broadcast_error(project, :diverged, "local has diverged from origin")
        {:error, :diverged}

      {:ok, false} ->
        {:ok, false}

      {:error, reason} ->
        broadcast_error(project, :diverged, reason)
        {:error, {:diverged, reason}}
    end
  end

  defp current_status(%Project{service_state: nil}), do: nil
  defp current_status(%Project{service_state: %{"status" => status}}), do: status
  defp current_status(_), do: nil

  defp merge_state(project, new_state) do
    base = project.service_state || %{}
    Map.merge(base, new_state)
  end

  defp persist_status(project, status) do
    new_state =
      (project.service_state || %{})
      |> Map.put("status", status)

    {:ok, _} = Projects.update_project_service_state(project, new_state)
    new_state
  end

  defp persist_pull_metadata(project, branch) do
    new_state =
      (project.service_state || %{})
      |> Map.put("default_branch", branch)
      |> Map.put("last_pulled_at", DateTime.utc_now() |> DateTime.to_iso8601())

    {:ok, _} = Projects.update_project_service_state(project, new_state)
  end

  defp broadcast_error(project, stage, details) do
    PubSubHelper.broadcast_project_service_error(project.id, stage, details)
  end
end
