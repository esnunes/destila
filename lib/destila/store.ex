defmodule Destila.Store do
  use GenServer

  @table :destila_store

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def list_prompts do
    :ets.match_object(@table, {{:prompt, :_}, :_})
    |> Enum.map(fn {_key, prompt} -> prompt end)
    |> Enum.sort_by(& &1.position)
  end

  def list_prompts(board) do
    list_prompts()
    |> Enum.filter(&(&1.board == board))
  end

  def get_prompt(id) do
    case :ets.lookup(@table, {:prompt, id}) do
      [{_, prompt}] -> prompt
      [] -> nil
    end
  end

  def create_prompt(attrs) do
    id = generate_id()
    now = DateTime.utc_now()

    prompt =
      Map.merge(
        %{
          id: id,
          title: "Untitled Prompt",
          workflow_type: :feature_request,
          repo_url: nil,
          board: :crafting,
          column: :request,
          steps_completed: 0,
          steps_total: 4,
          position: System.unique_integer([:positive]),
          created_at: now,
          updated_at: now
        },
        attrs
      )
      |> Map.put(:id, id)

    :ets.insert(@table, {{:prompt, id}, prompt})
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {:prompt_created, prompt})
    prompt
  end

  def update_prompt(id, attrs) do
    case get_prompt(id) do
      nil ->
        nil

      prompt ->
        updated = Map.merge(prompt, attrs) |> Map.put(:updated_at, DateTime.utc_now())
        :ets.insert(@table, {{:prompt, id}, updated})
        Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {:prompt_updated, updated})
        updated
    end
  end

  def move_card(id, new_column, new_position) do
    update_prompt(id, %{column: new_column, position: new_position})
  end

  def list_messages(prompt_id) do
    :ets.match_object(@table, {{:message, prompt_id, :_}, :_})
    |> Enum.map(fn {_key, msg} -> msg end)
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  def add_message(prompt_id, attrs) do
    id = generate_id()
    now = DateTime.utc_now()

    message =
      Map.merge(
        %{
          id: id,
          prompt_id: prompt_id,
          role: :system,
          content: "",
          input_type: nil,
          options: nil,
          selected: nil,
          step: 1,
          created_at: now
        },
        attrs
      )
      |> Map.put(:id, id)

    :ets.insert(@table, {{:message, prompt_id, id}, message})
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {:message_added, message})
    message
  end

  # Server callbacks

  @impl true
  def init(_) do
    table = :ets.new(@table, [:set, :public, :named_table])
    Destila.Seeds.seed()
    {:ok, table}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
