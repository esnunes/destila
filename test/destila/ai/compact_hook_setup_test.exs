defmodule Destila.AI.CompactHookSetupTest do
  use ExUnit.Case, async: true

  alias Destila.AI.CompactHookSetup

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "compact_hook_setup_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{worktree: tmp}
  end

  describe "install/2" do
    test "writes wrapped prompt to .claude/destila/initial_prompt.txt", %{worktree: tmp} do
      wrapped = "<initial-prompt>\nDescribe your idea\n</initial-prompt>"

      assert :ok = CompactHookSetup.install(tmp, wrapped)

      path = Path.join(tmp, ".claude/destila/initial_prompt.txt")
      assert File.exists?(path)
      assert File.read!(path) == wrapped
    end

    test "second call overwrites prompt file with latest phase prompt", %{worktree: tmp} do
      first = "<initial-prompt>\nphase 1\n</initial-prompt>"
      second = "<initial-prompt>\nphase 2\n</initial-prompt>"

      :ok = CompactHookSetup.install(tmp, first)
      :ok = CompactHookSetup.install(tmp, second)

      path = Path.join(tmp, ".claude/destila/initial_prompt.txt")
      assert File.read!(path) == second
    end

    test "returns :ok and writes nothing when worktree_path is nil" do
      assert :ok = CompactHookSetup.install(nil, "<initial-prompt>x</initial-prompt>")
    end

    test "creates .claude/destila directory when missing", %{worktree: tmp} do
      refute File.exists?(Path.join(tmp, ".claude"))

      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      assert File.dir?(Path.join(tmp, ".claude/destila"))
    end

    test "installs hook script as executable", %{worktree: tmp} do
      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      path = Path.join(tmp, ".claude/hooks/reinject_initial_prompt.sh")
      assert File.exists?(path)

      %File.Stat{mode: mode} = File.stat!(path)
      # Check the owner-executable bit is set (0o100 in the mode)
      assert Bitwise.band(mode, 0o100) == 0o100
    end

    test "hook script prints prompt contents followed by reference sentence when file present",
         %{worktree: tmp} do
      wrapped = "<initial-prompt>\nhello phase\n</initial-prompt>"

      :ok = CompactHookSetup.install(tmp, wrapped)

      script = Path.join(tmp, ".claude/hooks/reinject_initial_prompt.sh")

      {output, 0} =
        System.cmd("sh", [script], env: [{"CLAUDE_PROJECT_DIR", tmp}])

      assert output =~ "<initial-prompt>"
      assert output =~ "hello phase"
      assert output =~ "</initial-prompt>"
      assert output =~ "In the `<initial-prompt>` tag above"
    end

    test "hook script exits 0 with empty output when prompt file is absent", %{worktree: tmp} do
      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      File.rm!(Path.join(tmp, ".claude/destila/initial_prompt.txt"))

      script = Path.join(tmp, ".claude/hooks/reinject_initial_prompt.sh")

      {output, status} =
        System.cmd("sh", [script], env: [{"CLAUDE_PROJECT_DIR", tmp}])

      assert status == 0
      assert output == ""
    end

    test "second install overwrites the hook script", %{worktree: tmp} do
      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      script = Path.join(tmp, ".claude/hooks/reinject_initial_prompt.sh")
      File.write!(script, "#!/bin/sh\necho mutated\n")

      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      contents = File.read!(script)
      refute contents =~ "mutated"
      assert contents =~ "CLAUDE_PROJECT_DIR"
    end

    test "writes a valid settings.json declaring SessionStart compact hook", %{worktree: tmp} do
      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      settings = read_settings(tmp)

      assert %{"hooks" => %{"SessionStart" => [entry]}} = settings
      assert entry["matcher"] == "compact"
      assert [%{"type" => "command", "command" => command}] = entry["hooks"]
      assert command == ".claude/hooks/reinject_initial_prompt.sh"
    end

    test "merging preserves pre-existing unrelated hook events", %{worktree: tmp} do
      settings_path = Path.join(tmp, ".claude/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))

      existing = %{
        "hooks" => %{
          "PreToolUse" => [
            %{
              "matcher" => "Bash",
              "hooks" => [%{"type" => "command", "command" => "echo before"}]
            }
          ]
        }
      }

      File.write!(settings_path, Jason.encode!(existing))

      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      settings = read_settings(tmp)

      assert settings["hooks"]["PreToolUse"] == existing["hooks"]["PreToolUse"]
      assert [entry] = settings["hooks"]["SessionStart"]
      assert entry["matcher"] == "compact"
    end

    test "does not duplicate the compact hook entry on repeated installs", %{worktree: tmp} do
      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")
      :ok = CompactHookSetup.install(tmp, "<initial-prompt>y</initial-prompt>")

      settings = read_settings(tmp)

      assert length(settings["hooks"]["SessionStart"]) == 1
    end

    test "overwrites invalid JSON settings without crashing", %{worktree: tmp} do
      settings_path = Path.join(tmp, ".claude/settings.json")
      File.mkdir_p!(Path.dirname(settings_path))
      File.write!(settings_path, "{ not valid json")

      :ok = CompactHookSetup.install(tmp, "<initial-prompt>x</initial-prompt>")

      settings = read_settings(tmp)
      assert [%{"matcher" => "compact"}] = settings["hooks"]["SessionStart"]
    end
  end

  describe "merge_settings/2" do
    test "returns default settings when existing is not a map" do
      assert %{"hooks" => %{"SessionStart" => [_]}} =
               CompactHookSetup.merge_settings(nil)
    end

    test "preserves sibling hook events" do
      existing = %{
        "hooks" => %{
          "PreToolUse" => [%{"matcher" => "Bash"}]
        }
      }

      merged = CompactHookSetup.merge_settings(existing)

      assert merged["hooks"]["PreToolUse"] == existing["hooks"]["PreToolUse"]
      assert [%{"matcher" => "compact"}] = merged["hooks"]["SessionStart"]
    end

    test "is idempotent when our entry already exists" do
      existing = CompactHookSetup.default_settings()

      assert CompactHookSetup.merge_settings(existing) == existing
    end
  end

  defp read_settings(tmp) do
    tmp
    |> Path.join(".claude/settings.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
