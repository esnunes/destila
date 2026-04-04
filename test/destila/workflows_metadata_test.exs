defmodule Destila.WorkflowsMetadataTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Workflows

  defp create_session do
    {:ok, ws} =
      Workflows.create_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    ws
  end

  describe "upsert_metadata/4" do
    test "inserts a new metadata entry" do
      ws = create_session()

      assert {:ok, metadata} =
               Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{
                 "status" => "completed"
               })

      assert metadata.workflow_session_id == ws.id
      assert metadata.phase_name == "creation"
      assert metadata.key == "title_gen"
      assert metadata.value == %{"status" => "completed"}
    end

    test "upserts on conflict — overwrites value" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "repo_sync", %{
          "status" => "in_progress"
        })

      {:ok, updated} =
        Workflows.upsert_metadata(ws.id, "creation", "repo_sync", %{
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
        Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{
          "status" => "completed"
        })

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "repo_sync", %{
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
        Workflows.upsert_metadata(ws.id, "creation", "idea", %{"text" => "first"})

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "phase1", "idea", %{"text" => "second"})

      # Flat merge — last phase wins alphabetically (creation < phase1)
      metadata = Workflows.get_metadata(ws.id)
      assert metadata["idea"] == %{"text" => "second"}
    end
  end

  describe "upsert_metadata/5 with exported flag" do
    @tag feature: "exported_metadata", scenario: "Metadata is private by default"
    test "defaults exported to false" do
      ws = create_session()

      {:ok, metadata} =
        Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "done"})

      assert metadata.exported == false
    end

    @tag feature: "exported_metadata", scenario: "Generated prompt is marked as exported"
    test "sets exported to true when passed" do
      ws = create_session()

      {:ok, metadata} =
        Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "Do X"},
          exported: true
        )

      assert metadata.exported == true
    end

    @tag feature: "exported_metadata",
         scenario: "Only exported metadata is returned when querying for external use"
    test "upsert replaces exported flag on conflict" do
      ws = create_session()
      {:ok, _} = Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "v1"})

      {:ok, updated} =
        Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "v2"},
          exported: true
        )

      assert updated.exported == true
      assert updated.value == %{"text" => "v2"}
    end
  end

  describe "get_exported_metadata/1" do
    @tag feature: "exported_metadata",
         scenario: "Only exported metadata is returned when querying for external use"
    test "returns empty list when no metadata exists" do
      ws = create_session()
      assert Workflows.get_exported_metadata(ws.id) == []
    end

    @tag feature: "exported_metadata",
         scenario: "Only exported metadata is returned when querying for external use"
    test "returns empty list when no metadata is exported" do
      ws = create_session()
      {:ok, _} = Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "done"})
      {:ok, _} = Workflows.upsert_metadata(ws.id, "creation", "idea", %{"text" => "my idea"})
      assert Workflows.get_exported_metadata(ws.id) == []
    end

    @tag feature: "exported_metadata",
         scenario: "Only exported metadata is returned when querying for external use"
    test "returns only exported entries as full structs" do
      ws = create_session()
      {:ok, _} = Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "done"})

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "phase6", "prompt_generated", %{"text" => "prompt"},
          exported: true
        )

      exported = Workflows.get_exported_metadata(ws.id)
      assert length(exported) == 1

      [entry] = exported
      assert %Destila.Workflows.SessionMetadata{} = entry
      assert entry.phase_name == "phase6"
      assert entry.key == "prompt_generated"
      assert entry.value == %{"text" => "prompt"}
      assert entry.exported == true
    end

    @tag feature: "exported_metadata",
         scenario: "Only exported metadata is returned when querying for external use"
    test "returns entries ordered by phase_name then key" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "z_phase", "alpha", %{"v" => "1"}, exported: true)

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "a_phase", "beta", %{"v" => "2"}, exported: true)

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "a_phase", "alpha", %{"v" => "3"}, exported: true)

      exported = Workflows.get_exported_metadata(ws.id)
      assert length(exported) == 3
      assert Enum.map(exported, & &1.phase_name) == ["a_phase", "a_phase", "z_phase"]
      assert Enum.map(exported, & &1.key) == ["alpha", "beta", "alpha"]
    end
  end

  describe "list_sessions_with_exported_metadata/1" do
    test "returns empty list when no sessions have the given key" do
      assert Workflows.list_sessions_with_exported_metadata("prompt_generated") == []
    end

    test "returns completed sessions with matching exported metadata" do
      ws = create_session()
      {:ok, _} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

      Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"text" => "Do the thing"},
        exported: true
      )

      result = Workflows.list_sessions_with_exported_metadata("prompt_generated")
      assert [{session, text}] = result
      assert session.id == ws.id
      assert text == "Do the thing"
    end

    test "excludes sessions that are not done" do
      ws = create_session()

      Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"text" => "Not done yet"},
        exported: true
      )

      assert Workflows.list_sessions_with_exported_metadata("prompt_generated") == []
    end

    test "excludes archived sessions" do
      ws = create_session()

      {:ok, _} =
        Workflows.update_workflow_session(ws, %{
          done_at: DateTime.utc_now(),
          archived_at: DateTime.utc_now()
        })

      Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"text" => "Archived"},
        exported: true
      )

      assert Workflows.list_sessions_with_exported_metadata("prompt_generated") == []
    end

    test "excludes non-exported metadata" do
      ws = create_session()
      {:ok, _} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

      Workflows.upsert_metadata(ws.id, "creation", "prompt_generated", %{"text" => "Private"})

      assert Workflows.list_sessions_with_exported_metadata("prompt_generated") == []
    end

    test "excludes entries with nil or empty text" do
      ws = create_session()
      {:ok, _} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

      Workflows.upsert_metadata(ws.id, "Prompt Generation", "prompt_generated", %{"text" => ""},
        exported: true
      )

      assert Workflows.list_sessions_with_exported_metadata("prompt_generated") == []
    end

    test "filters by metadata key" do
      ws = create_session()
      {:ok, _} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

      Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"text" => "A prompt"},
        exported: true
      )

      assert Workflows.list_sessions_with_exported_metadata("prompt_generated") != []
      assert Workflows.list_sessions_with_exported_metadata("other_key") == []
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
        Workflows.upsert_metadata(ws.id, "creation", "idea", %{
          "text" => "Fix the login bug"
        })

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{
          "status" => "completed"
        })

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "worktree", %{
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
