defmodule DestilaWeb.DraftsBoardLiveTest do
  @moduledoc """
  Tests for DraftsBoardLive (the /drafts kanban board).
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

  describe "board layout" do
    @tag feature: @feature, scenario: "View drafts grouped by priority columns"
    test "renders three priority columns, one per priority", %{conn: conn} do
      project = create_project!()
      create_draft!(project: project, priority: :high, prompt: "High idea")
      create_draft!(project: project, priority: :medium, prompt: "Medium idea")
      create_draft!(project: project, priority: :low, prompt: "Low idea")

      {:ok, view, _html} = live(conn, ~p"/drafts")

      assert has_element?(view, "#column-high")
      assert has_element?(view, "#column-medium")
      assert has_element?(view, "#column-low")

      assert view |> element("#column-high") |> render() =~ "High idea"
      assert view |> element("#column-medium") |> render() =~ "Medium idea"
      assert view |> element("#column-low") |> render() =~ "Low idea"
    end

    @tag feature: @feature, scenario: "Draft card shows the prompt"
    test "card surface shows the prompt", %{conn: conn} do
      create_draft!(prompt: "Refactor session archiving", priority: :high)

      {:ok, _view, html} = live(conn, ~p"/drafts")
      assert html =~ "Refactor session archiving"
    end

    @tag feature: @feature, scenario: "Empty board shows guidance to create the first draft"
    test "empty state is rendered when no drafts exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/drafts")
      assert has_element?(view, "#drafts-board-empty")
      assert has_element?(view, "#create-first-draft-btn")
    end

    test "new draft button links to /drafts/new", %{conn: conn} do
      create_draft!(%{})
      {:ok, view, _html} = live(conn, ~p"/drafts")
      assert has_element?(view, "#new-draft-btn")
    end

    test "cards render with the archived indicator when the project is archived", %{conn: conn} do
      project = create_project!()
      _draft = create_draft!(project: project, priority: :high)
      {:ok, _} = Projects.archive_project(project)

      {:ok, _view, html} = live(conn, ~p"/drafts")
      assert html =~ "(archived)"
    end
  end

  describe "sidebar" do
    @tag feature: @feature, scenario: "Sidebar has a Drafts entry next to Crafting Board"
    test "sidebar exposes a Drafts entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/drafts")
      assert view |> render() =~ "Drafts"
      assert view |> has_element?("a[href=\"/drafts\"]")
    end
  end

  describe "pubsub refresh" do
    test "new draft appears after a :draft_created broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/drafts")

      assert has_element?(view, "#drafts-board-empty")

      project = create_project!()

      {:ok, _draft} =
        Drafts.create_draft(%{
          prompt: "Fresh idea",
          priority: :medium,
          project_id: project.id
        })

      # Broadcast already sent by create_draft; allow LiveView to process it
      _ = render(view)

      assert view |> element("#column-medium") |> render() =~ "Fresh idea"
    end
  end

  describe "project filter" do
    @tag feature: @feature, scenario: "Filter drafts by project"
    test "selecting a project hides drafts from other projects", %{conn: conn} do
      project_a = create_project!(%{name: "Project A"})
      project_b = create_project!(%{name: "Project B"})

      create_draft!(project: project_a, priority: :high, prompt: "Alpha idea")
      create_draft!(project: project_b, priority: :high, prompt: "Bravo idea")

      {:ok, view, _html} = live(conn, ~p"/drafts")

      html =
        view
        |> form("#project-filter-form", %{project: project_a.id})
        |> render_change()

      assert html =~ "Alpha idea"
      refute html =~ "Bravo idea"
      assert_patched(view, ~p"/drafts?project=#{project_a.id}")
    end

    @tag feature: @feature, scenario: "Filter drafts by project"
    test "clearing the filter restores drafts from all projects", %{conn: conn} do
      project_a = create_project!(%{name: "Project A"})
      project_b = create_project!(%{name: "Project B"})

      create_draft!(project: project_a, priority: :high, prompt: "Alpha idea")
      create_draft!(project: project_b, priority: :high, prompt: "Bravo idea")

      {:ok, view, _html} = live(conn, ~p"/drafts?project=#{project_a.id}")

      html =
        view
        |> form("#project-filter-form", %{project: ""})
        |> render_change()

      assert html =~ "Alpha idea"
      assert html =~ "Bravo idea"
      assert_patched(view, ~p"/drafts")
    end

    @tag feature: @feature, scenario: "Filter with no matching drafts shows a no-matches state"
    test "no-matches state renders when filter yields nothing", %{conn: conn} do
      project_a = create_project!(%{name: "Project A"})
      project_b = create_project!(%{name: "Project B"})

      create_draft!(project: project_a, priority: :high, prompt: "Alpha idea")

      {:ok, view, _html} = live(conn, ~p"/drafts?project=#{project_b.id}")

      assert has_element?(view, "#drafts-board-no-matches")
      refute has_element?(view, "#column-high")
    end

    test "filter dropdown lists projects that have drafts", %{conn: conn} do
      project_a = create_project!(%{name: "Visible Proj"})
      _project_unused = create_project!(%{name: "Hidden Proj"})

      create_draft!(project: project_a, priority: :low)

      {:ok, view, _html} = live(conn, ~p"/drafts")
      html = view |> element("#project-filter") |> render()

      assert html =~ "Visible Proj"
      refute html =~ "Hidden Proj"
    end
  end

  describe "reorder events" do
    @tag feature: @feature, scenario: "Reorder drafts within a priority column"
    test "reorder_draft within the same column updates position", %{conn: conn} do
      project = create_project!()

      a = create_draft!(project: project, priority: :high, prompt: "first")
      b = create_draft!(project: project, priority: :high, prompt: "second")

      {:ok, view, _html} = live(conn, ~p"/drafts")

      # Move b to the top: before=nil, after=a
      render_hook(view, "reorder_draft", %{
        "draft_id" => b.id,
        "priority" => "high",
        "before_id" => nil,
        "after_id" => a.id
      })

      ids = Drafts.list_drafts_by_priority(:high) |> Enum.map(& &1.id)
      assert ids == [b.id, a.id]
    end

    @tag feature: @feature,
         scenario: "Move a draft to a different priority column via drag-and-drop"
    test "reorder_draft across priorities changes the priority", %{conn: conn} do
      project = create_project!()
      d = create_draft!(project: project, priority: :low)

      {:ok, view, _html} = live(conn, ~p"/drafts")

      render_hook(view, "reorder_draft", %{
        "draft_id" => d.id,
        "priority" => "high",
        "before_id" => nil,
        "after_id" => nil
      })

      reloaded = Drafts.get_draft(d.id)
      assert reloaded.priority == :high
    end

    test "unknown draft_id is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/drafts")

      render_hook(view, "reorder_draft", %{
        "draft_id" => Ecto.UUID.generate(),
        "priority" => "high",
        "before_id" => nil,
        "after_id" => nil
      })
    end

    test "invalid priority is a no-op", %{conn: conn} do
      project = create_project!()
      d = create_draft!(project: project, priority: :low)

      {:ok, view, _html} = live(conn, ~p"/drafts")

      render_hook(view, "reorder_draft", %{
        "draft_id" => d.id,
        "priority" => "banana",
        "before_id" => nil,
        "after_id" => nil
      })

      assert Drafts.get_draft(d.id).priority == :low
    end
  end
end
