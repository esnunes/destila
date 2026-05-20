defmodule Destila.Agent.Tools.AskUserQuestionTool do
  @moduledoc """
  Handles `ask_user_question`. The tool returns immediately with an
  acknowledgement; the user's answer is delivered later, out-of-band.
  """

  alias Destila.Agent.Sessions

  require Logger

  def execute(args, state) do
    questions = Map.get(args, "questions", [])
    question_id = generate_id()

    case Sessions.record_event(state.session, "ask_user_question", %{
           tool_input: args,
           tool_result: %{"question_id" => question_id}
         }) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Sessions.record_event(ask_user_question) failed: #{inspect(changeset.errors)}"
        )
    end

    Sessions.broadcast_session(
      state.session.id,
      {:question_asked, %{question_id: question_id, questions: questions}}
    )

    {{:ok,
      %{
        "ok" => true,
        "question_id" => question_id,
        "content" => [%{"type" => "text", "text" => "Question presented to user."}],
        "isError" => false
      }}, state}
  end

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
