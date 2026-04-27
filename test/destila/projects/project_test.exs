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

  describe "changeset/2 with domain" do
    @tag feature: "project_management",
         scenario: "Project domain accepts a valid hostname"
    test "accepts a valid fully qualified hostname" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "app.example.com"})
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :domain) == "app.example.com"
    end

    @tag feature: "project_management",
         scenario: "Project domain is optional"
    test "blank domain is valid and persisted as nil" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: ""})
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :domain) == nil
    end

    test "nil domain is valid" do
      changeset = Project.changeset(%Project{}, @valid_attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :domain) == nil
    end

    @tag feature: "project_management",
         scenario: "Project domain trims trailing dots"
    test "trailing dot is trimmed before persistence" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "app.example.com."})
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :domain) == "app.example.com"
    end

    @tag feature: "project_management",
         scenario: "Project domain accepts single-label hostnames"
    test "single-label hostname is accepted" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "localhost"})
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :domain) == "localhost"
    end

    @tag feature: "project_management",
         scenario: "Project domain enforces RFC 1123 length limits"
    test "domain of exactly 253 chars is accepted" do
      domain =
        String.duplicate("a", 63) <>
          "." <>
          String.duplicate("b", 63) <>
          "." <>
          String.duplicate("c", 63) <>
          "." <>
          String.duplicate("d", 61)

      assert String.length(domain) == 253

      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: domain})
        )

      assert changeset.valid?
    end

    test "domain of 254 chars is rejected" do
      label = String.duplicate("a", 63)
      domain = label <> "." <> label <> "." <> label <> "." <> String.duplicate("a", 62)
      assert String.length(domain) == 254

      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: domain})
        )

      refute changeset.valid?
      assert {"must be at most 253 characters", _} = changeset.errors[:domain]
    end

    test "label of exactly 63 chars is accepted" do
      label = String.duplicate("a", 63)

      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: label <> ".com"})
        )

      assert changeset.valid?
    end

    test "label of 64 chars is rejected" do
      label = String.duplicate("a", 64)

      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: label <> ".com"})
        )

      refute changeset.valid?
      assert changeset.errors[:domain]
    end

    @tag feature: "project_management",
         scenario: "Project domain rejects malformed hostnames"
    test "rejects empty label (consecutive dots)" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "app..example.com"})
        )

      refute changeset.valid?
      assert changeset.errors[:domain]
    end

    test "rejects leading hyphen in a label" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "-app.example.com"})
        )

      refute changeset.valid?
    end

    test "rejects trailing hyphen in a label" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "app-.example.com"})
        )

      refute changeset.valid?
    end

    test "rejects underscore in a label" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "app_x.example.com"})
        )

      refute changeset.valid?
    end

    test "rejects whitespace in a label" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{domain: "app x.example.com"})
        )

      refute changeset.valid?
    end

    @tag feature: "project_management",
         scenario: "Project domain has no uniqueness constraint"
    test "two changesets with the same domain both validate cleanly" do
      attrs = Map.merge(@valid_attrs, %{domain: "shared.example.com"})

      assert Project.changeset(%Project{}, attrs).valid?
      assert Project.changeset(%Project{}, attrs).valid?
    end
  end

  describe "changeset/2 with basic_auth_enabled" do
    @tag feature: "project_management",
         scenario: "Project basic_auth_enabled defaults to false"
    test "defaults to false" do
      changeset = Project.changeset(%Project{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :basic_auth_enabled) == false
    end

    @tag feature: "project_management",
         scenario: "Project basic_auth_enabled can be enabled regardless of domain"
    test "accepts true regardless of domain" do
      changeset =
        Project.changeset(
          %Project{},
          Map.merge(@valid_attrs, %{basic_auth_enabled: true})
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :basic_auth_enabled) == true
    end
  end
end
