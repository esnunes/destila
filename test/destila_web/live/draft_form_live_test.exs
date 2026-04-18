defmodule DestilaWeb.DraftFormLiveTest do
  @moduledoc """
  Tests for DraftFormLive (new/edit/detail).
  Feature: features/drafts_board.feature
  """

  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Destila.Drafts
  alias Destila.Projects

  @feature "drafts_board"

  defp create_project!(attrs \\ %{}) do
    defaults = %{
      name: "Proj #{System.unique_integer([:positive])}",
      git_repo_url: "https://github.com/test/repo"
    }

    {:ok, project} = Projects.create_project(Map.merge(defaults, attrs))
    project
  end

  defp create_draft!(attrs) do
    project = attrs[:project] || create_project!()
    priority = attrs[:priority] || :low
    prompt = attrs[:prompt] || "prompt"

    {:ok, draft} =
      Drafts.create_draft(%{
        prompt: prompt,
        priority: priority,
        project_id: project.id
      })

    draft
  end

  describe "new draft" do
    @tag feature: @feature, scenario: "Create a new draft from the drafts board"
    test "creates a draft with prompt + priority + project", %{conn: conn} do
      project = create_project!()

      {:ok, view, _html} = live(conn, ~p"/drafts/new")

      view |> element("#project-#{project.id}") |> render_click()

      view
      |> form("#draft-form", %{prompt: "Hello draft", priority: "high"})
      |> render_submit()

      assert [draft] = Drafts.list_drafts_by_priority(:high)
      assert draft.prompt == "Hello draft"
      assert draft.project_id == project.id
    end

    @tag feature: @feature, scenario: "Cannot create a draft without a project"
    test "surfaces project validation error when none is picked", %{conn: conn} do
      _project = create_project!()

      {:ok, view, _html} = live(conn, ~p"/drafts/new")

      html =
        view
        |> form("#draft-form", %{prompt: "Hi", priority: "low"})
        |> render_submit()

      assert html =~ "Please select a project"
      assert Drafts.list_drafts_by_priority(:low) == []
    end

    @tag feature: @feature, scenario: "Cannot create a draft without a priority"
    test "surfaces priority validation error when none is picked", %{conn: conn} do
      project = create_project!()

      {:ok, view, _html} = live(conn, ~p"/drafts/new")

      view |> element("#project-#{project.id}") |> render_click()

      html =
        view
        |> form("#draft-form", %{prompt: "Hi", priority: ""})
        |> render_submit()

      assert html =~ "Please pick a priority"
      assert Drafts.list_drafts_by_priority(:low) == []
    end
  end

  describe "edit draft" do
    @tag feature: @feature, scenario: "Open a draft detail page"
    test "loads existing draft values into the form", %{conn: conn} do
      project = create_project!(%{name: "Edit Proj"})
      draft = create_draft!(project: project, prompt: "Original prompt", priority: :medium)

      {:ok, view, html} = live(conn, ~p"/drafts/#{draft.id}")

      assert html =~ "Original prompt"
      assert html =~ "Edit Proj"
      assert has_element?(view, "#start-workflow-btn")
      assert has_element?(view, "#discard-draft-btn")
    end

    @tag feature: @feature,
         scenario: "Edit the prompt, project, and priority of an existing draft"
    test "saves changes to an existing draft", %{conn: conn} do
      project1 = create_project!()
      project2 = create_project!(%{name: "Target Proj"})
      draft = create_draft!(project: project1, prompt: "A", priority: :low)

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}")

      view |> element("#project-#{project2.id}") |> render_click()

      view
      |> form("#draft-form", %{prompt: "Updated", priority: "high"})
      |> render_submit()

      updated = Drafts.get_draft(draft.id)
      assert updated.prompt == "Updated"
      assert updated.priority == :high
      assert updated.project_id == project2.id
    end

    @tag feature: @feature, scenario: "Discard a draft from its detail page"
    test "discard archives the draft and redirects to the board", %{conn: conn} do
      draft = create_draft!(%{})

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}")

      assert {:error, {:live_redirect, %{to: "/drafts"}}} =
               view |> element("#discard-draft-btn") |> render_click()

      assert Drafts.get_draft(draft.id) == nil
    end

    @tag feature: @feature,
         scenario: "Launch a workflow from a draft skips prompt and project selection"
    test "start workflow navigates to /workflows with draft_id", %{conn: conn} do
      draft = create_draft!(%{})

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}")

      expected_path = "/workflows?draft_id=#{draft.id}"

      assert {:error, {:live_redirect, %{to: ^expected_path}}} =
               view |> element("#start-workflow-btn") |> render_click()
    end

    test "loading an archived draft redirects with an error flash", %{conn: conn} do
      draft = create_draft!(%{})
      {:ok, _} = Drafts.archive_draft(draft)

      assert {:error, {:live_redirect, %{to: "/drafts", flash: flash}}} =
               live(conn, ~p"/drafts/#{draft.id}")

      assert flash["error"] == "Draft not found"
    end

    test "renders archived-project indicator when the linked project is archived", %{conn: conn} do
      project = create_project!()
      draft = create_draft!(project: project)

      {:ok, _} = Projects.archive_project(project)

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}")
      assert has_element?(view, "#archived-project-indicator")
    end
  end
end
