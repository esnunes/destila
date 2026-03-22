defmodule Destila.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field(:role, Ecto.Enum, values: [:system, :user])
    field(:content, :string, default: "")
    field(:raw_response, :map)
    field(:selected, {:array, :string})
    field(:phase, :integer, default: 1)

    belongs_to(:prompt, Destila.Prompts.Prompt)

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :prompt_id,
      :role,
      :content,
      :raw_response,
      :selected,
      :phase
    ])
    |> validate_required([:prompt_id, :role, :content])
  end
end
