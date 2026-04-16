defmodule Destila.AI.History.Real do
  @moduledoc """
  Production implementation of `Destila.AI.History`.

  - `get_messages/2` delegates to `ClaudeCode.History.get_messages/2` (chain-built,
    filters pre-compaction history).
  - `read_all/2` reads the JSONL file directly and returns every raw entry in
    file order. Original camelCase keys are preserved so callers can pass
    user/assistant entries straight to `ClaudeCode.History.SessionMessage.from_entry/1`.
  """

  @spec get_messages(String.t(), keyword()) ::
          {:ok, [ClaudeCode.History.SessionMessage.t()]} | {:error, term()}
  def get_messages(session_id, opts) do
    ClaudeCode.History.get_messages(session_id, opts)
  end

  @spec read_all(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_all(session_id, opts) do
    with {:ok, path} <- ClaudeCode.History.find_session_path(session_id, opts),
         {:ok, content} <- File.read(path) do
      entries =
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, map} -> [map]
            {:error, _} -> []
          end
        end)

      {:ok, entries}
    end
  end
end
