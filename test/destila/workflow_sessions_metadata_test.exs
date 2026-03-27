defmodule Destila.WorkflowSessionsMetadataTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.WorkflowSessions

  defp create_session do
    {:ok, ws} =
      WorkflowSessions.create_workflow_session(%{
        title: "Test Session",
        workflow_type: :prompt_chore_task,
        current_phase: 2,
        total_phases: 6
      })

    ws
  end

  describe "upsert_metadata/4" do
    test "inserts a new metadata entry" do
      ws = create_session()

      assert {:ok, metadata} =
               WorkflowSessions.upsert_metadata(ws.id, "setup", "title_gen", %{
                 "status" => "completed"
               })

      assert metadata.workflow_session_id == ws.id
      assert metadata.phase_name == "setup"
      assert metadata.key == "title_gen"
      assert metadata.value == %{"status" => "completed"}
    end

    test "upserts on conflict — overwrites value" do
      ws = create_session()

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "setup", "repo_sync", %{
          "status" => "in_progress"
        })

      {:ok, updated} =
        WorkflowSessions.upsert_metadata(ws.id, "setup", "repo_sync", %{
          "status" => "completed"
        })

      assert updated.value == %{"status" => "completed"}

      # Only one row exists
      metadata = WorkflowSessions.get_metadata(ws.id)
      assert metadata == %{"repo_sync" => %{"status" => "completed"}}
    end

    test "different keys in the same phase create separate entries" do
      ws = create_session()

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "setup", "title_gen", %{
          "status" => "completed"
        })

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "setup", "repo_sync", %{
          "status" => "in_progress"
        })

      metadata = WorkflowSessions.get_metadata(ws.id)

      assert metadata == %{
               "title_gen" => %{"status" => "completed"},
               "repo_sync" => %{"status" => "in_progress"}
             }
    end

    test "same key in different phases creates separate entries" do
      ws = create_session()

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "wizard", "idea", %{"text" => "first"})

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "setup", "idea", %{"text" => "second"})

      # Flat merge — last phase wins alphabetically (setup < wizard)
      metadata = WorkflowSessions.get_metadata(ws.id)
      assert metadata["idea"] == %{"text" => "first"}
    end
  end

  describe "get_metadata/1" do
    test "returns empty map when no metadata exists" do
      ws = create_session()
      assert WorkflowSessions.get_metadata(ws.id) == %{}
    end

    test "returns flat map merged across phases" do
      ws = create_session()

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "wizard", "idea", %{
          "text" => "Fix the login bug"
        })

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "setup", "title_gen", %{
          "status" => "completed"
        })

      {:ok, _} =
        WorkflowSessions.upsert_metadata(ws.id, "setup", "worktree", %{
          "status" => "completed",
          "worktree_path" => "/tmp/wt"
        })

      metadata = WorkflowSessions.get_metadata(ws.id)

      assert metadata == %{
               "idea" => %{"text" => "Fix the login bug"},
               "title_gen" => %{"status" => "completed"},
               "worktree" => %{"status" => "completed", "worktree_path" => "/tmp/wt"}
             }
    end
  end
end
