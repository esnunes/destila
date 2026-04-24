defmodule Destila.Services.Logs do
  @moduledoc """
  Helpers for locating and preparing per-session service log files.

  Logs are captured via `tmux pipe-pane` into `tmp/services/<session_id>.log`
  and truncated on each new service start. Files are deleted when the
  session is archived or deleted.
  """

  @log_dir "tmp/services"

  @doc """
  Returns the absolute directory path where service log files live.
  """
  def log_dir, do: Path.join(File.cwd!(), @log_dir)

  @doc """
  Returns the absolute path to the log file for the given workflow session id.
  """
  def log_path(ws_id) when is_binary(ws_id) do
    Path.join(log_dir(), "#{ws_id}.log")
  end

  @doc """
  Creates the log directory if it does not already exist.
  """
  def ensure_log_dir do
    File.mkdir_p!(log_dir())
    :ok
  end
end
