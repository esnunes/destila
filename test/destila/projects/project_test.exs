defmodule Destila.Projects.ProjectTest do
  use DestilaWeb.ConnCase, async: false

  alias Destila.Projects.Project

  @valid_attrs %{name: "Test Project", git_repo_url: "https://github.com/test/repo"}

  describe "changeset/2 with run_command and service_env_var" do
    @tag feature: "project_management",
         scenario: "Create a project with run command and a service env var"
    test "accepts valid run_command and service_env_var" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{
            run_command: "mix phx.server",
            service_env_var: "PORT"
          })
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :service_env_var) == "PORT"
    end

    @tag feature: "project_management",
         scenario: "Create a project without a service env var name"
    test "accepts nil run_command and nil service_env_var" do
      changeset = Project.changeset(%Project{}, @valid_attrs)
      assert changeset.valid?
    end

    @tag feature: "project_management",
         scenario: "Create a project without a service env var name"
    test "accepts empty-string service_env_var" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{service_env_var: ""})
        )

      assert changeset.valid?
      refute changeset.errors[:service_env_var]
    end

    @tag feature: "project_management",
         scenario: "Service env var requires a valid environment variable name"
    test "rejects service_env_var with lowercase letters" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{service_env_var: "port"})
        )

      refute changeset.valid?

      assert {"port must start with A-Z and contain only uppercase letters, digits, and underscores",
              _} = changeset.errors[:service_env_var]
    end

    @tag feature: "project_management",
         scenario: "Service env var requires a valid environment variable name"
    test "rejects service_env_var starting with digit" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{service_env_var: "1PORT"})
        )

      refute changeset.valid?
      assert changeset.errors[:service_env_var]
    end

    @tag feature: "project_management",
         scenario: "Service env var requires a valid environment variable name"
    test "rejects service_env_var with special characters" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{service_env_var: "PORT-1"})
        )

      refute changeset.valid?
      assert changeset.errors[:service_env_var]
    end

    @tag feature: "project_management",
         scenario: "Service env var requires a valid environment variable name"
    test "accepts valid underscore names and multi-digit suffixes" do
      for name <- ~w(PORT API_PORT SERVICE_PORT_2 DB_PORT A PORT_3000) do
        changeset =
          Project.changeset(
            %Project{},
            Map.merge(@valid_attrs, %{service_env_var: name})
          )

        assert changeset.valid?, "expected #{name} to be valid"
      end
    end

    @tag feature: "project_management",
         scenario: "Service env var requires a valid environment variable name"
    test "rejects reserved system env var names" do
      for reserved <- ~w(PATH HOME SHELL USER TERM LANG LD_PRELOAD LD_LIBRARY_PATH) do
        changeset =
          Project.changeset(
            %Project{},
            Map.merge(@valid_attrs, %{service_env_var: reserved})
          )

        refute changeset.valid?, "expected #{reserved} to be rejected"

        {message, _} = changeset.errors[:service_env_var]
        assert message == "#{reserved} is a reserved system environment variable"
      end
    end

    test "existing validations still pass unchanged" do
      changeset = Project.changeset(%Project{}, %{name: "Test"})
      refute changeset.valid?
      assert changeset.errors[:git_repo_url]
    end
  end

  describe "webservice?/1" do
    test "true when project has run_command and service_env_var" do
      assert Project.webservice?(%Project{run_command: "run", service_env_var: "PORT"})
    end

    test "false when run_command is missing" do
      refute Project.webservice?(%Project{run_command: nil, service_env_var: "PORT"})
      refute Project.webservice?(%Project{run_command: "", service_env_var: "PORT"})
    end

    test "false when service_env_var is missing" do
      refute Project.webservice?(%Project{run_command: "run", service_env_var: nil})
      refute Project.webservice?(%Project{run_command: "run", service_env_var: ""})
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
