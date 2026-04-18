defmodule DestilaWeb.DraftLaunchLiveTest do
  @moduledoc """
  Tests for launching a workflow from a draft via CreateSessionLive.
  Feature: features/drafts_board.feature
  """

  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Destila.Drafts
  alias Destila.Projects

  @feature "drafts_board"

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    {:ok, conn: conn}
  end

  defp create_project! do
    {:ok, project} =
      Projects.create_project(%{
        name: "Launch Proj #{System.unique_integer([:positive])}",
        git_repo_url: "https://github.com/test/repo"
      })

    project
  end

  defp create_draft!(attrs \\ %{}) do
    project = attrs[:project] || create_project!()

    {:ok, draft} =
      Drafts.create_draft(%{
        prompt: attrs[:prompt] || "Draft prompt",
        priority: attrs[:priority] || :low,
        project_id: project.id
      })

    draft
  end

  describe "type picker threads draft_id" do
    test "clicking a workflow type on /workflows?draft_id navigates to /workflows/<type>?draft_id",
         %{conn: conn} do
      draft = create_draft!()

      {:ok, view, _html} = live(conn, ~p"/workflows?draft_id=#{draft.id}")

      view |> element("#type-brainstorm_idea") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path == "/workflows/brainstorm_idea?draft_id=#{draft.id}"
    end
  end

  describe "launch from draft" do
    @tag feature: @feature,
         scenario: "Launch a workflow from a draft skips prompt and project selection"
    test "creates a session with the draft's prompt + project and redirects to the runner",
         %{conn: conn} do
      project = create_project!()
      draft = create_draft!(project: project, prompt: "Launch me", priority: :high)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/workflows/brainstorm_idea?draft_id=#{draft.id}")

      assert String.starts_with?(to, "/sessions/")
      session_id = String.replace_prefix(to, "/sessions/", "")

      session = Destila.Workflows.get_workflow_session!(session_id)
      assert session.user_prompt == "Launch me"
      assert session.project_id == project.id
      assert session.workflow_type == :brainstorm_idea
    end

    @tag feature: @feature, scenario: "Launching a workflow auto-archives the draft"
    test "successful launch archives the draft so it no longer appears on the board",
         %{conn: conn} do
      draft = create_draft!(%{prompt: "Archive me"})

      {:error, {:live_redirect, _}} =
        live(conn, ~p"/workflows/brainstorm_idea?draft_id=#{draft.id}")

      assert Drafts.get_draft(draft.id) == nil
    end

    test "unknown draft_id redirects to /drafts with an error flash", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/drafts", flash: flash}}} =
               live(conn, ~p"/workflows/brainstorm_idea?draft_id=#{fake_id}")

      assert flash["error"] == "Draft not found"
    end

    test "unknown workflow type redirects to /workflows with an error flash", %{conn: conn} do
      draft = create_draft!()

      assert {:error, {:live_redirect, %{to: "/workflows", flash: flash}}} =
               live(conn, ~p"/workflows/not_a_real_type?draft_id=#{draft.id}")

      assert flash["error"] == "Unknown workflow type"
    end
  end
end
