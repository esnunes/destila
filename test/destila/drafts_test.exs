defmodule Destila.DraftsTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Drafts
  alias Destila.Drafts.Draft
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

  describe "create_draft/1" do
    @tag feature: @feature, scenario: "Create a new draft from the drafts board"
    test "persists a draft with all required fields" do
      project = create_project!()

      {:ok, draft} =
        Drafts.create_draft(%{
          prompt: "Try this idea",
          priority: :high,
          project_id: project.id
        })

      assert draft.id
      assert draft.prompt == "Try this idea"
      assert draft.priority == :high
      assert is_float(draft.position)
      assert draft.project.id == project.id
    end

    test "broadcasts :draft_created" do
      project = create_project!()
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

      {:ok, draft} =
        Drafts.create_draft(%{
          prompt: "Hi",
          priority: :medium,
          project_id: project.id
        })

      id = draft.id
      assert_receive {:draft_created, %Draft{id: ^id}}
    end

    @tag feature: @feature, scenario: "Cannot create a draft without a priority"
    test "fails without a priority" do
      project = create_project!()

      assert {:error, changeset} =
               Drafts.create_draft(%{
                 prompt: "Hi",
                 priority: nil,
                 project_id: project.id
               })

      assert changeset.errors[:priority]
    end

    @tag feature: @feature, scenario: "Cannot create a draft without a project"
    test "fails without a project_id" do
      assert {:error, changeset} =
               Drafts.create_draft(%{
                 prompt: "Hi",
                 priority: :low,
                 project_id: nil
               })

      assert changeset.errors[:project_id]
    end

    test "fails for an archived project" do
      project = create_project!()
      {:ok, _} = Projects.archive_project(project)

      assert {:error, changeset} =
               Drafts.create_draft(%{
                 prompt: "Hi",
                 priority: :low,
                 project_id: project.id
               })

      assert changeset.errors[:project_id]
    end

    test "fails for a non-existent project" do
      assert {:error, changeset} =
               Drafts.create_draft(%{
                 prompt: "Hi",
                 priority: :low,
                 project_id: Ecto.UUID.generate()
               })

      assert changeset.errors[:project_id]
    end

    test "places new drafts at the tail of their priority column" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :low, project_id: project.id})
      {:ok, b} = Drafts.create_draft(%{prompt: "b", priority: :low, project_id: project.id})

      assert b.position > a.position
    end
  end

  describe "list_drafts_by_priority/1" do
    @tag feature: @feature, scenario: "View drafts grouped by priority columns"
    test "returns only non-archived drafts in the given priority ordered by position" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})
      {:ok, b} = Drafts.create_draft(%{prompt: "b", priority: :high, project_id: project.id})

      {:ok, _} = Drafts.create_draft(%{prompt: "low", priority: :low, project_id: project.id})

      result = Drafts.list_drafts_by_priority(:high)
      assert Enum.map(result, & &1.id) == [a.id, b.id]
    end

    test "excludes archived drafts" do
      project = create_project!()

      {:ok, draft} =
        Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})

      {:ok, _} = Drafts.archive_draft(draft)

      assert Drafts.list_drafts_by_priority(:high) == []
    end
  end

  describe "list_all_active/0" do
    @tag feature: @feature, scenario: "View drafts grouped by priority columns"
    test "groups active drafts by priority" do
      project = create_project!()

      {:ok, _} = Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})
      {:ok, _} = Drafts.create_draft(%{prompt: "b", priority: :medium, project_id: project.id})
      {:ok, _} = Drafts.create_draft(%{prompt: "c", priority: :low, project_id: project.id})

      result = Drafts.list_all_active()

      assert Map.keys(result) |> Enum.sort() == [:high, :low, :medium]
      assert length(result.high) == 1
      assert length(result.medium) == 1
      assert length(result.low) == 1
    end

    test "each column is ordered by ascending position" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})
      {:ok, b} = Drafts.create_draft(%{prompt: "b", priority: :high, project_id: project.id})
      {:ok, c} = Drafts.create_draft(%{prompt: "c", priority: :high, project_id: project.id})

      ids = Drafts.list_all_active().high |> Enum.map(& &1.id)
      assert ids == [a.id, b.id, c.id]
    end
  end

  describe "get_draft/1 and get_draft!/1" do
    test "returns nil / raises for archived drafts" do
      project = create_project!()

      {:ok, draft} =
        Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})

      assert Drafts.get_draft(draft.id)
      assert Drafts.get_draft!(draft.id)

      {:ok, _} = Drafts.archive_draft(draft)

      assert Drafts.get_draft(draft.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Drafts.get_draft!(draft.id) end
    end

    test "preloads project even when the project is archived" do
      project = create_project!()

      {:ok, draft} =
        Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})

      {:ok, _} = Projects.archive_project(project)

      loaded = Drafts.get_draft(draft.id)
      assert loaded.project.id == project.id
      assert loaded.project.archived_at
    end
  end

  describe "update_draft/2" do
    @tag feature: @feature,
         scenario: "Edit the prompt, project, and priority of an existing draft"
    test "updates prompt, project, and priority" do
      project1 = create_project!()
      project2 = create_project!()

      {:ok, draft} =
        Drafts.create_draft(%{prompt: "a", priority: :low, project_id: project1.id})

      {:ok, updated} =
        Drafts.update_draft(draft, %{
          prompt: "b",
          priority: :high,
          project_id: project2.id
        })

      assert updated.prompt == "b"
      assert updated.priority == :high
      assert updated.project_id == project2.id
    end

    test "moves draft to the tail of the new priority column when priority changes" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})
      {:ok, _b} = Drafts.create_draft(%{prompt: "b", priority: :high, project_id: project.id})

      {:ok, c_initial} =
        Drafts.create_draft(%{prompt: "c", priority: :low, project_id: project.id})

      {:ok, c_updated} = Drafts.update_draft(c_initial, %{priority: :high})

      assert c_updated.priority == :high
      assert c_updated.position > a.position
    end
  end

  describe "archive_draft/1" do
    @tag feature: @feature, scenario: "Discard a draft from its detail page"
    test "sets archived_at and removes the draft from list queries" do
      project = create_project!()

      {:ok, draft} =
        Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})

      {:ok, archived} = Drafts.archive_draft(draft)

      assert archived.archived_at
      assert Drafts.list_drafts_by_priority(:high) == []
      assert Drafts.list_all_active().high == []
    end
  end

  describe "reposition_draft/4" do
    @tag feature: @feature, scenario: "Reorder drafts within a priority column"
    test "empty column yields a default position" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :low, project_id: project.id})

      {:ok, repositioned} = Drafts.reposition_draft(a, :high, nil, nil)
      assert repositioned.priority == :high
      assert is_float(repositioned.position)
    end

    @tag feature: @feature, scenario: "Reorder drafts within a priority column"
    test "dropping at the top gives a lower position than the top neighbor" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})

      {:ok, b_initial} =
        Drafts.create_draft(%{prompt: "b", priority: :low, project_id: project.id})

      {:ok, b} = Drafts.reposition_draft(b_initial, :high, nil, a.id)
      assert b.position < a.position
    end

    test "dropping at the bottom gives a higher position than the last neighbor" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})

      {:ok, b_initial} =
        Drafts.create_draft(%{prompt: "b", priority: :low, project_id: project.id})

      {:ok, b} = Drafts.reposition_draft(b_initial, :high, a.id, nil)
      assert b.position > a.position
    end

    @tag feature: @feature,
         scenario: "Move a draft to a different priority column via drag-and-drop"
    test "dropping between two cards yields a midpoint position" do
      project = create_project!()

      {:ok, a} = Drafts.create_draft(%{prompt: "a", priority: :high, project_id: project.id})
      {:ok, b} = Drafts.create_draft(%{prompt: "b", priority: :high, project_id: project.id})

      {:ok, c_initial} =
        Drafts.create_draft(%{prompt: "c", priority: :low, project_id: project.id})

      {:ok, c} = Drafts.reposition_draft(c_initial, :high, a.id, b.id)

      assert c.priority == :high
      assert c.position > a.position
      assert c.position < b.position

      ordered = Drafts.list_drafts_by_priority(:high) |> Enum.map(& &1.id)
      assert ordered == [a.id, c.id, b.id]
    end
  end
end
