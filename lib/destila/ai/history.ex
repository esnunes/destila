defmodule Destila.AI.History do
  @moduledoc """
  Thin adapter around `ClaudeCode.History.get_messages/2`.

  The LiveView calls `Destila.AI.History.get_messages/1,2` rather than
  `ClaudeCode.History` directly so tests can swap in canned responses via
  `Application.put_env(:destila, :ai_history_module, ...)`. Also catches
  unexpected exceptions from disk/parse failures and returns them as
  `{:error, {:exception, kind, reason}}`.
  """

  @default_impl ClaudeCode.History

  @spec get_messages(String.t()) ::
          {:ok, [ClaudeCode.History.SessionMessage.t()]} | {:error, term()}
  def get_messages(session_id), do: get_messages(session_id, [])

  @spec get_messages(String.t(), keyword()) ::
          {:ok, [ClaudeCode.History.SessionMessage.t()]} | {:error, term()}
  def get_messages(session_id, opts) when is_binary(session_id) and is_list(opts) do
    impl().get_messages(session_id, opts)
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {:exception, kind, reason}}
  end

  defp impl do
    Application.get_env(:destila, :ai_history_module, @default_impl)
  end
end
