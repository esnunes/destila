defmodule Destila.WorkflowsDeletionTest do
  @moduledoc """
  Context-level tests for soft-deleting workflow sessions.
  Feature: features/session_deletion.feature
  """
  use DestilaWeb.ConnCase, async: false

  alias Destila.Workflows
  alias Destila.Workflows.Session

  @feature "session_deletion"

  setup do
    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "destila",
        git_repo_url: "https://github.com/test/destila"
      })

    {:ok, project: project}
  end

  defp create_session(attrs) do
    defaults = %{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4,
      position: System.unique_integer([:positive])
    }

    {:ok, ws} = Workflows.insert_workflow_session(Map.merge(defaults, attrs))
    ws
  end

  describe "delete_workflow_session/1" do
    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "sets deleted_at and returns ok", %{project: project} do
      ws = create_session(%{project_id: project.id})

      assert {:ok, %Session{deleted_at: %DateTime{}}} = Workflows.delete_workflow_session(ws)
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "broadcasts workflow_session_updated", %{project: project} do
      ws = create_session(%{project_id: project.id})

      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

      {:ok, _ws} = Workflows.delete_workflow_session(ws)

      assert_receive {:workflow_session_updated, %Session{id: id, deleted_at: %DateTime{}}}
      assert id == ws.id
    end

    @tag feature: @feature,
         scenario: "Deleting a running session stops its service and AI sessions"
    test "does not raise when service_state is nil", %{project: project} do
      ws = create_session(%{project_id: project.id})
      assert is_nil(ws.service_state)

      assert {:ok, _ws} = Workflows.delete_workflow_session(ws)
    end

    @tag feature: @feature,
         scenario: "Deleting a running session stops its service and AI sessions"
    test "clears service_state when a session has an active service", %{project: project} do
      ws = create_session(%{project_id: project.id})

      {:ok, ws} =
        Workflows.update_workflow_session(ws, %{
          service_state: %{"status" => "running", "port" => 4712}
        })

      assert ws.service_state

      {:ok, _deleted} = Workflows.delete_workflow_session(ws)

      # Observe raw row bypassing soft-delete filter
      row = Destila.Repo.get(Session, ws.id)
      assert %DateTime{} = row.deleted_at
      assert is_nil(row.service_state)
    end
  end

  describe "read paths exclude deleted sessions" do
    @tag feature: @feature, scenario: "Deleted session is hidden from the crafting board"
    test "list_workflow_sessions/0 excludes deleted", %{project: project} do
      ws = create_session(%{title: "Visible", project_id: project.id})
      deleted = create_session(%{title: "Deleted", project_id: project.id})
      {:ok, _} = Workflows.delete_workflow_session(deleted)

      ids = Workflows.list_workflow_sessions() |> Enum.map(& &1.id)

      assert ws.id in ids
      refute deleted.id in ids
    end

    @tag feature: @feature, scenario: "Deleted session is hidden from the archived sessions page"
    test "list_archived_workflow_sessions/0 excludes deleted", %{project: project} do
      ws = create_session(%{title: "Archived", project_id: project.id})
      {:ok, archived} = Workflows.archive_workflow_session(ws)
      {:ok, _} = Workflows.delete_workflow_session(archived)

      ids = Workflows.list_archived_workflow_sessions() |> Enum.map(& &1.id)
      refute ws.id in ids
    end

    @tag feature: @feature, scenario: "Deleted session detail page is no longer accessible"
    test "get_workflow_session/1 returns nil for deleted", %{project: project} do
      ws = create_session(%{project_id: project.id})
      {:ok, _} = Workflows.delete_workflow_session(ws)

      assert Workflows.get_workflow_session(ws.id) == nil
    end

    @tag feature: @feature, scenario: "Deleted session detail page is no longer accessible"
    test "get_workflow_session!/1 raises for deleted", %{project: project} do
      ws = create_session(%{project_id: project.id})
      {:ok, _} = Workflows.delete_workflow_session(ws)

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_workflow_session!(ws.id)
      end
    end

    @tag feature: @feature, scenario: "Deleted session is hidden from the crafting board"
    test "list_sessions_with_exported_metadata/1 excludes deleted", %{project: project} do
      ws = create_session(%{project_id: project.id})
      {:ok, ws} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

      {:ok, _m} =
        Workflows.upsert_metadata(ws.id, "phase", "prompt_generated", %{"text" => "value"},
          exported: true
        )

      # Before delete: appears
      before_ids =
        Workflows.list_sessions_with_exported_metadata("prompt_generated")
        |> Enum.map(fn {s, _v} -> s.id end)

      assert ws.id in before_ids

      {:ok, _} = Workflows.delete_workflow_session(ws)

      after_ids =
        Workflows.list_sessions_with_exported_metadata("prompt_generated")
        |> Enum.map(fn {s, _v} -> s.id end)

      refute ws.id in after_ids
    end

    @tag feature: @feature, scenario: "Deleted session is hidden from the crafting board"
    test "list_source_sessions/1 excludes deleted", %{project: project} do
      ws = create_session(%{workflow_type: :brainstorm_idea, project_id: project.id})
      {:ok, ws} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

      {:ok, _m} =
        Workflows.upsert_metadata(ws.id, "phase", "prompt_generated", %{"text" => "the prompt"},
          exported: true
        )

      before_ids =
        Workflows.list_source_sessions(:implement_general_prompt)
        |> Enum.map(fn {s, _v} -> s.id end)

      assert ws.id in before_ids

      {:ok, _} = Workflows.delete_workflow_session(ws)

      after_ids =
        Workflows.list_source_sessions(:implement_general_prompt)
        |> Enum.map(fn {s, _v} -> s.id end)

      refute ws.id in after_ids
    end
  end

  describe "count helpers include deleted rows" do
    @tag feature: @feature, scenario: "Deleted sessions still block project deletion"
    test "count_by_project/1 includes deleted", %{project: project} do
      ws = create_session(%{project_id: project.id})
      {:ok, _} = Workflows.delete_workflow_session(ws)

      assert Workflows.count_by_project(project.id) == 1
    end

    @tag feature: @feature, scenario: "Deleted sessions still block project deletion"
    test "count_by_projects/0 includes deleted", %{project: project} do
      ws = create_session(%{project_id: project.id})
      {:ok, _} = Workflows.delete_workflow_session(ws)

      assert Workflows.count_by_projects() |> Map.get(project.id) == 1
    end

    @tag feature: @feature, scenario: "Deleted sessions still block project deletion"
    test "delete_project/1 is blocked when only linked session is soft-deleted", %{
      project: project
    } do
      ws = create_session(%{project_id: project.id})
      {:ok, _} = Workflows.delete_workflow_session(ws)

      assert {:error, :has_linked_sessions} = Destila.Projects.delete_project(project)
    end
  end
end
