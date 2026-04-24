defmodule Destila.WorkflowsMetadataTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Workflows

  defp create_session do
    {:ok, ws} =
      Workflows.insert_workflow_session(%{
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
        Workflows.upsert_metadata(ws.id, "creation", "example_step", %{
          "status" => "in_progress"
        })

      {:ok, updated} =
        Workflows.upsert_metadata(ws.id, "creation", "example_step", %{
          "status" => "completed"
        })

      assert updated.value == %{"status" => "completed"}

      # Only one row exists
      metadata = Workflows.get_metadata(ws.id)
      assert metadata == %{"example_step" => %{"status" => "completed"}}
    end

    test "different keys in the same phase create separate entries" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{
          "status" => "completed"
        })

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "example_step", %{
          "status" => "in_progress"
        })

      metadata = Workflows.get_metadata(ws.id)

      assert metadata == %{
               "title_gen" => %{"status" => "completed"},
               "example_step" => %{"status" => "in_progress"}
             }
    end

    test "same key in different phases creates separate entries" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "notes", %{"text" => "first"})

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "phase1", "notes", %{"text" => "second"})

      # Flat merge — last phase wins alphabetically (creation < phase1)
      metadata = Workflows.get_metadata(ws.id)
      assert metadata["notes"] == %{"text" => "second"}
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
      {:ok, _} = Workflows.upsert_metadata(ws.id, "creation", "notes", %{"text" => "my notes"})
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
        Workflows.upsert_metadata(ws.id, "z_phase", "gamma", %{"text" => "1"}, exported: true)

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "a_phase", "beta", %{"text" => "2"}, exported: true)

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "a_phase", "alpha", %{"text" => "3"}, exported: true)

      exported = Workflows.get_exported_metadata(ws.id)
      assert length(exported) == 3
      assert Enum.map(exported, & &1.phase_name) == ["a_phase", "a_phase", "z_phase"]
      assert Enum.map(exported, & &1.key) == ["alpha", "beta", "gamma"]
    end
  end

  describe "upsert_metadata/5 re-export across phase boundaries" do
    @tag feature: "exported_metadata",
         scenario: "Re-export from a later phase replaces the original artifact"
    test "re-export from a different phase name replaces the original row" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Extract Requirements",
          "requirements_doc",
          %{"markdown" => "original"},
          exported: true
        )

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Adjustments",
          "requirements_doc",
          %{"markdown" => "refined"},
          exported: true
        )

      exported = Workflows.get_exported_metadata(ws.id)
      assert length(exported) == 1
      [entry] = exported
      assert entry.key == "requirements_doc"
      assert entry.phase_name == "Adjustments"
      assert entry.value == %{"markdown" => "refined"}
    end

    @tag feature: "exported_metadata",
         scenario: "Re-export leaves other exported keys untouched"
    test "re-export of one key does not touch other exported keys" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Compare & Improve",
          "comparison_report",
          %{"markdown" => "report"},
          exported: true
        )

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Compare & Improve",
          "prompt_generated",
          %{"markdown" => "prompt"},
          exported: true
        )

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Adjustments",
          "comparison_report",
          %{"markdown" => "revised report"},
          exported: true
        )

      exported =
        ws.id
        |> Workflows.get_exported_metadata()
        |> Enum.sort_by(& &1.key)

      assert length(exported) == 2

      [comparison, prompt] = exported
      assert comparison.key == "comparison_report"
      assert comparison.phase_name == "Adjustments"
      assert comparison.value == %{"markdown" => "revised report"}

      assert prompt.key == "prompt_generated"
      assert prompt.phase_name == "Compare & Improve"
      assert prompt.value == %{"markdown" => "prompt"}
    end

    @tag feature: "exported_metadata",
         scenario: "Re-export leaves non-exported rows with the same key untouched"
    test "re-export leaves non-exported rows with the same key untouched" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(ws.id, "creation", "notes", %{"text" => "private"})

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Phase 1",
          "notes",
          %{"markdown" => "first export"},
          exported: true
        )

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Adjustments",
          "notes",
          %{"markdown" => "refined export"},
          exported: true
        )

      all =
        ws.id
        |> Workflows.get_all_metadata()
        |> Enum.sort_by(&{&1.exported, &1.phase_name})

      assert length(all) == 2

      [private, exported] = all
      assert private.exported == false
      assert private.phase_name == "creation"
      assert private.value == %{"text" => "private"}

      assert exported.exported == true
      assert exported.phase_name == "Adjustments"
      assert exported.value == %{"markdown" => "refined export"}
    end

    @tag feature: "exported_metadata",
         scenario: "Consecutive re-exports keep a single row"
    test "consecutive re-exports collapse to a single row" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Phase 1",
          "artifact",
          %{"markdown" => "v1"},
          exported: true
        )

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Adjustments",
          "artifact",
          %{"markdown" => "v2"},
          exported: true
        )

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Adjustments",
          "artifact",
          %{"markdown" => "v3"},
          exported: true
        )

      exported = Workflows.get_exported_metadata(ws.id)
      assert length(exported) == 1
      [entry] = exported
      assert entry.value == %{"markdown" => "v3"}
      assert entry.phase_name == "Adjustments"
    end

    @tag feature: "exported_metadata",
         scenario: "Re-export broadcasts a single metadata_updated event"
    test "re-export broadcasts exactly one metadata_updated event" do
      ws = create_session()

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Phase 1",
          "artifact",
          %{"markdown" => "v1"},
          exported: true
        )

      :ok = Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")

      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Adjustments",
          "artifact",
          %{"markdown" => "v2"},
          exported: true
        )

      assert_receive {:metadata_updated, _}, 100
      refute_receive {:metadata_updated, _}, 50
    end
  end

  describe "upsert_metadata/5 type validation for exported metadata" do
    test "accepts all valid metadata types" do
      ws = create_session()

      for type <- ~w(text markdown file) do
        assert {:ok, _} =
                 Workflows.upsert_metadata(
                   ws.id,
                   "phase",
                   "key_#{type}",
                   %{type => "value"},
                   exported: true
                 )
      end
    end

    test "rejects invalid type for exported metadata" do
      ws = create_session()

      assert {:error, :invalid_metadata_type} =
               Workflows.upsert_metadata(
                 ws.id,
                 "phase",
                 "key",
                 %{"html" => "<p>bad</p>"},
                 exported: true
               )
    end

    test "rejects legacy text_file type for exported metadata" do
      ws = create_session()

      assert {:error, :invalid_metadata_type} =
               Workflows.upsert_metadata(
                 ws.id,
                 "phase",
                 "key",
                 %{"text_file" => "/tmp/x.txt"},
                 exported: true
               )
    end

    test "rejects legacy video_file type for exported metadata" do
      ws = create_session()

      assert {:error, :invalid_metadata_type} =
               Workflows.upsert_metadata(
                 ws.id,
                 "phase",
                 "key",
                 %{"video_file" => "/tmp/x.mp4"},
                 exported: true
               )
    end

    test "rejects multi-key value maps for exported metadata" do
      ws = create_session()

      assert {:error, :invalid_metadata_type} =
               Workflows.upsert_metadata(
                 ws.id,
                 "phase",
                 "key",
                 %{"text" => "a", "extra" => "b"},
                 exported: true
               )
    end

    test "allows arbitrary value maps for non-exported metadata" do
      ws = create_session()

      assert {:ok, _} =
               Workflows.upsert_metadata(
                 ws.id,
                 "creation",
                 "config",
                 %{"id" => "some-uuid"}
               )
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

    test "returns value for non-text metadata types" do
      ws = create_session()
      {:ok, _} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})

      Workflows.upsert_metadata(
        ws.id,
        "phase",
        "my_doc",
        %{"markdown" => "# Hello"},
        exported: true
      )

      result = Workflows.list_sessions_with_exported_metadata("my_doc")
      assert [{session, text}] = result
      assert session.id == ws.id
      assert text == "# Hello"
    end
  end

  describe "list_follow_up_workflows/1" do
    test "returns empty list when session has no exported metadata" do
      ws = create_session()
      assert Workflows.list_follow_up_workflows(ws) == []
    end

    test "returns empty list when no exported key matches any workflow's source key" do
      ws = create_session()

      Workflows.upsert_metadata(
        ws.id,
        "some_phase",
        "random_key",
        %{"text" => "irrelevant"},
        exported: true
      )

      assert Workflows.list_follow_up_workflows(ws) == []
    end

    test "returns the matching workflow when an exported key matches a source key" do
      ws = create_session()

      Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"markdown" => "Build a login form"},
        exported: true
      )

      assert [
               %{
                 type: :implement_general_prompt,
                 label: "Implement a Prompt",
                 source_metadata_key: "prompt_generated",
                 description: description,
                 icon: icon,
                 icon_class: icon_class
               }
             ] = Workflows.list_follow_up_workflows(ws)

      assert is_binary(description) and description != ""
      assert is_binary(icon)
      assert is_binary(icon_class)
    end

    test "ignores non-exported metadata entries" do
      ws = create_session()

      Workflows.upsert_metadata(
        ws.id,
        "Prompt Generation",
        "prompt_generated",
        %{"markdown" => "Private prompt"}
      )

      assert Workflows.list_follow_up_workflows(ws) == []
    end

    test "never returns workflows whose source_metadata_key is nil" do
      ws = create_session()

      # Export any key that a nil-source workflow could conceivably claim.
      Workflows.upsert_metadata(ws.id, "p", "nil", %{"text" => "v"}, exported: true)

      nil_source_types =
        for type <- Workflows.workflow_types(),
            is_nil(Workflows.workflow_module(type).source_metadata_key()),
            do: type

      # Baseline assumption: at least one workflow has a nil source key today.
      assert nil_source_types != []

      returned_types = Enum.map(Workflows.list_follow_up_workflows(ws), & &1.type)

      for type <- nil_source_types do
        refute type in returned_types
      end
    end

    test "preserves registry insertion order of @workflow_modules" do
      ws = create_session()

      # Export every non-nil source_metadata_key the registry declares so every
      # eligible workflow is a candidate.
      for type <- Workflows.workflow_types() do
        if key = Workflows.workflow_module(type).source_metadata_key() do
          Workflows.upsert_metadata(ws.id, "p", key, %{"text" => "v"}, exported: true)
        end
      end

      registry_eligible =
        for type <- Workflows.workflow_types(),
            is_binary(Workflows.workflow_module(type).source_metadata_key()),
            do: type

      result_order = Enum.map(Workflows.list_follow_up_workflows(ws), & &1.type)
      assert result_order == registry_eligible
    end
  end

  describe "valid_metadata_types/0" do
    test "returns exactly text, markdown, file" do
      assert Workflows.valid_metadata_types() == ~w(text markdown file)
    end
  end

  describe "file_kind/1" do
    test "returns :markdown for .md paths" do
      assert Workflows.file_kind("plan.md") == :markdown
      assert Workflows.file_kind("/tmp/nested/plan.md") == :markdown
    end

    test "returns :markdown for .markdown paths" do
      assert Workflows.file_kind("README.markdown") == :markdown
    end

    test "returns :video for .mp4 paths" do
      assert Workflows.file_kind("/tmp/demo.mp4") == :video
    end

    test "returns :text for other extensions" do
      assert Workflows.file_kind("/tmp/build.log") == :text
      assert Workflows.file_kind("/tmp/output.txt") == :text
    end

    test "returns :text for extensionless paths" do
      assert Workflows.file_kind("Makefile") == :text
    end

    test "is case-insensitive" do
      assert Workflows.file_kind("README.MD") == :markdown
      assert Workflows.file_kind("CLIP.MP4") == :video
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
        Workflows.upsert_metadata(ws.id, "creation", "notes", %{
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
               "notes" => %{"text" => "Fix the login bug"},
               "title_gen" => %{"status" => "completed"},
               "worktree" => %{"status" => "completed", "worktree_path" => "/tmp/wt"}
             }
    end
  end
end
