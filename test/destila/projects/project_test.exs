defmodule Destila.Projects.ProjectTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Projects.Project

  @valid_attrs %{name: "Test Project", git_repo_url: "https://github.com/test/repo"}

  describe "changeset/2 with run_command and port_definitions" do
    test "accepts valid run_command and port_definitions" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            run_command: "mix phx.server",
            port_definitions: ["PORT", "API_PORT"]
          })
        )

      assert changeset.valid?
    end

    test "accepts nil run_command and empty port_definitions" do
      changeset = Project.changeset(%Project{}, @valid_attrs)
      assert changeset.valid?
    end

    test "rejects port definition with lowercase letters" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            port_definitions: ["my_port"]
          })
        )

      refute changeset.valid?

      assert {"my_port must start with A-Z and contain only uppercase letters, digits, and underscores",
              _} = changeset.errors[:port_definitions]
    end

    test "rejects port definition starting with digit" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            port_definitions: ["123"]
          })
        )

      refute changeset.valid?
    end

    test "rejects port definition with special characters" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            port_definitions: ["MY-PORT"]
          })
        )

      refute changeset.valid?
    end

    test "accepts valid underscore names" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            port_definitions: ["DB_PORT", "PORT_3000", "A"]
          })
        )

      assert changeset.valid?
    end

    test "rejects reserved system env var names" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            port_definitions: ["PATH"]
          })
        )

      refute changeset.valid?

      assert {"PATH is a reserved system environment variable", _} =
               changeset.errors[:port_definitions]
    end

    test "existing validations still pass unchanged" do
      changeset = Project.changeset(%Project{}, %{name: "Test"})
      refute changeset.valid?
      assert changeset.errors[:git_repo_url]
    end
  end

  describe "changeset/2 with setup_command" do
    test "accepts a valid setup_command alongside other attrs" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            setup_command: "mix deps.get",
            run_command: "mix phx.server"
          })
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :setup_command) == "mix deps.get"
    end

    test "accepts nil setup_command" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{setup_command: nil})
        )

      assert changeset.valid?
    end

    test "accepts empty-string setup_command" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{setup_command: ""})
        )

      assert changeset.valid?
    end

    test "accepts attrs without setup_command key" do
      changeset = Project.changeset(%Project{}, @valid_attrs)
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :setup_command)
    end

    test "round-trips setup_command through create_project and get_project" do
      {:ok, created} =
        Destila.Projects.create_project(
          Map.merge(@valid_attrs, %{
            name: "Setup Round Trip",
            setup_command: "mix deps.get"
          })
        )

      loaded = Destila.Projects.get_project(created.id)

      assert loaded.setup_command == "mix deps.get"
    end
  end
end
