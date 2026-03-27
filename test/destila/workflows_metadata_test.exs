defmodule Destila.WorkflowsMetadataTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Workflows

  defp create_session do
    {:ok, ws} =
      Workflows.create_workflow_session(%{
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
               Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{
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
        Workflows.upsert_metadata(ws.id, "setup", "repo_sync", %{
          "status" => "in_progress"
        })

      {:ok, updated} =
        Workflows.upsert_metadata(ws.id, "setup", "repo_sync", %{
          "status" => "completed"
        })

      assert updated.value == %{"status" => "completed"}

      # Only one row exists
      metadata = Workflows.get_metadata(ws.id)
      assert metadata == %{"repo_sync" => %{"status" => "completed"}}
    end

    test "different keys in the same phase create separate entries" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{
          "status" => "completed"
        })

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "setup", "repo_sync", %{
          "status" => "in_progress"
        })

      metadata = Workflows.get_metadata(ws.id)

      assert metadata == %{
               "title_gen" => %{"status" => "completed"},
               "repo_sync" => %{"status" => "in_progress"}
             }
    end

    test "same key in different phases creates separate entries" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "wizard", "idea", %{"text" => "first"})

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "setup", "idea", %{"text" => "second"})

      # Flat merge — last phase wins alphabetically (setup < wizard)
      metadata = Workflows.get_metadata(ws.id)
      assert metadata["idea"] == %{"text" => "first"}
    end
  end

  describe "get_metadata/1" do
    test "returns empty map when no metadata exists" do
      ws = create_session()
      assert Workflows.get_metadata(ws.id) == %{}
    end

    test "returns flat map merged across phases" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "wizard", "idea", %{
          "text" => "Fix the login bug"
        })

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{
          "status" => "completed"
        })

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "setup", "worktree", %{
          "status" => "completed",
          "worktree_path" => "/tmp/wt"
        })

      metadata = Workflows.get_metadata(ws.id)

      assert metadata == %{
               "idea" => %{"text" => "Fix the login bug"},
               "title_gen" => %{"status" => "completed"},
               "worktree" => %{"status" => "completed", "worktree_path" => "/tmp/wt"}
             }
    end
  end
end
