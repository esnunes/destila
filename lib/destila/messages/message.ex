defmodule Destila.Messages.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "messages" do
    field(:role, Ecto.Enum, values: [:system, :user])
    field(:content, :string, default: "")

    field(:input_type, Ecto.Enum,
      values: [:text, :single_select, :multi_select, :file_upload, :questions]
    )

    field(:options, {:array, :map})
    field(:questions, {:array, :map})
    field(:selected, {:array, :string})
    field(:step, :integer, default: 1)

    field(:message_type, Ecto.Enum,
      values: [:phase_divider, :phase_advance, :skip_phase, :generated_prompt]
    )

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
      :input_type,
      :options,
      :questions,
      :selected,
      :step,
      :message_type
    ])
    |> validate_required([:prompt_id, :role, :content])
  end
end
