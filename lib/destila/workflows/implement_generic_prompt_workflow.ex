defmodule Destila.Workflows.ImplementGenericPromptWorkflow do
  @moduledoc """
  Defines the Implement Generic Prompt workflow — a single-step form
  that captures an implementation description.
  """

  def steps do
    [
      %{
        step: 1,
        content:
          "Describe what you want to implement. Provide as much context as possible about the desired outcome.",
        input_type: :text,
        options: nil
      }
    ]
  end

  def total_steps, do: 1

  @phase_names %{
    1 => "Implementation"
  }

  def phase_name(phase) when is_map_key(@phase_names, phase) do
    @phase_names[phase]
  end

  def phase_name(_phase), do: nil

  def phase_columns do
    columns =
      1..total_steps()
      |> Enum.map(fn n -> {n, phase_name(n)} end)
      |> Enum.reject(fn {_, name} -> is_nil(name) end)

    columns ++ [{:done, "Done"}]
  end

  def default_title, do: "New Session"

  def completion_message do
    "Your implementation session is complete."
  end
end
