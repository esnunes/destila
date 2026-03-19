defmodule Destila.AI do
  @moduledoc """
  AI-powered utilities using the Claude Agent SDK.
  """

  alias ClaudeAgentSDK.Options

  @doc """
  Generates a concise title for a prompt based on the workflow type and the user's initial idea.

  Returns `{:ok, title}` on success or `{:error, reason}` on failure.
  """
  def generate_title(workflow_type, idea) do
    type_label = workflow_type_label(workflow_type)

    prompt =
      "Generate a concise title (under 60 characters) for a #{type_label}. " <>
        "The user described their idea as: #{idea}\n\n" <>
        "Respond with only the title, no quotes, no punctuation at the end, no explanation."

    opts = %Options{
      model: "haiku",
      system_prompt:
        "You are a title generator. You produce short, descriptive titles. " <>
          "Respond with only the title text, nothing else.",
      max_turns: 1
    }

    try do
      title =
        ClaudeAgentSDK.query(prompt, opts)
        |> Enum.reduce(nil, fn msg, acc ->
          case msg.type do
            :assistant ->
              ClaudeAgentSDK.ContentExtractor.extract_text(msg) || acc

            _ ->
              acc
          end
        end)

      if title && title != "" do
        {:ok, String.trim(title)}
      else
        {:error, :empty_response}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp workflow_type_label(:feature_request), do: "feature request"
  defp workflow_type_label(:project), do: "project"
end
