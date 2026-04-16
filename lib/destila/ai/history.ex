defmodule Destila.AI.History do
  @moduledoc """
  Thin adapter around `ClaudeCode.History`.

  The LiveView calls this module rather than `ClaudeCode.History` directly
  so tests can swap in canned responses via
  `Application.put_env(:destila, :ai_history_module, ...)`. Also catches
  unexpected exceptions from disk/parse failures and returns them as
  `{:error, {:exception, kind, reason}}`.

  Two entry points:

  - `get_messages/2` — delegates to `ClaudeCode.History.get_messages/2`,
    which returns only visible user/assistant messages after the latest
    compaction boundary (matches VS Code IDE behaviour).

  - `read_all/2` — reads the JSONL file directly and returns every raw
    entry in file order (camelCase keys preserved), including
    pre-compaction messages, system markers (e.g. `compact_boundary`),
    summaries, attachments, and queue operations. Used by the debug
    detail view.
  """

  @default_impl Destila.AI.History.Real

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

  @spec read_all(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_all(session_id), do: read_all(session_id, [])

  @spec read_all(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_all(session_id, opts) when is_binary(session_id) and is_list(opts) do
    impl().read_all(session_id, opts)
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {:exception, kind, reason}}
  end

  defp impl do
    Application.get_env(:destila, :ai_history_module, @default_impl)
  end
end
