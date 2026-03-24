defmodule Destila.AI do
  @moduledoc """
  AI-powered utilities using the Claude Code SDK.
  """

  @doc """
  Generates a concise title for a workflow session based on the workflow type and the user's initial idea.

  Accepts an optional `Destila.AI.Session` pid as the first argument. When provided,
  the query runs through the existing session (preserving conversation context).
  When omitted, a one-off `ClaudeCode.query/2` call is used.

  Returns `{:ok, title}` on success or `{:error, reason}` on failure.
  """
  def generate_title(session \\ nil, workflow_type, idea) do
    type_label = workflow_type_label(workflow_type)

    prompt =
      "Generate a concise title (under 60 characters) for a #{type_label}. " <>
        "The user described their idea as: #{idea}\n\n" <>
        "Respond with only the title, no quotes, no punctuation at the end, no explanation."

    case do_query(session, prompt) do
      {:ok, text} ->
        title = String.trim(text)

        if title != "" do
          {:ok, title}
        else
          {:error, :empty_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_query(nil, prompt) do
    opts = [
      model: "haiku",
      system_prompt: system_prompt(),
      max_turns: 1
    ]

    case ClaudeCode.query(prompt, opts) do
      {:ok, result} -> {:ok, to_string(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_query(session, prompt) do
    case Destila.AI.Session.query(session, prompt) do
      {:ok, result} -> {:ok, result.result || ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp system_prompt do
    "You are a title generator. You produce short, descriptive titles. " <>
      "Respond with only the title text, nothing else."
  end

  defp workflow_type_label(:prompt_new_project), do: "project"
  defp workflow_type_label(:prompt_chore_task), do: "chore/task"
  defp workflow_type_label(:implement_generic_prompt), do: "implementation"
end
