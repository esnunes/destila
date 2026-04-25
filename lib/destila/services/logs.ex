defmodule Destila.Services.Logs do
  @moduledoc """
  Helpers for locating and preparing service log files.

  Logs are captured via `tmux pipe-pane` into
  `~/.cache/destila/services/<log_key>.log` and truncated on each new
  service start. Files are deleted when the owning session/project is
  archived or deleted.

  Naming convention (encoded in `Destila.Services.Target.log_key`):

    * `session-<session-id>.log`         — workflow-session services
    * `project-<project-id>.log`         — non-self-hosted project services
    * `project-destila-<branch>.log`     — the self-hosted Destila project

  For the self-hosted Destila case the BEAM does not write to this file
  itself — point your launcher's stdout/stderr at it (e.g. wrap your
  start command with `>> ~/.cache/destila/services/project-destila-<branch>.log 2>&1`).
  A `LogTailer` is started on boot for self-hosted projects so anything
  appended to the file streams to the service detail page automatically.
  """

  @doc """
  Returns the absolute directory path where service log files live.
  """
  def log_dir do
    cache_home = System.get_env("XDG_CACHE_HOME", Path.expand("~/.cache"))
    Path.join([cache_home, "destila", "services"])
  end

  @doc """
  Returns the absolute path to the log file for the given log key.
  """
  def log_path(log_key) when is_binary(log_key) do
    Path.join(log_dir(), "#{log_key}.log")
  end

  @doc """
  Creates the log directory if it does not already exist.
  """
  def ensure_log_dir do
    File.mkdir_p!(log_dir())
    :ok
  end
end
