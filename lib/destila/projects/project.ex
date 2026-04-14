defmodule Destila.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field(:name, :string)
    field(:git_repo_url, :string)
    field(:local_folder, :string)
    field(:run_command, :string)
    field(:port_definitions, {:array, :string}, default: [])

    has_many(:workflow_sessions, Destila.Workflows.Session)

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :git_repo_url, :local_folder, :run_command, :port_definitions])
    |> validate_required([:name])
    |> validate_at_least_one_location()
    |> validate_git_repo_url()
    |> validate_port_definitions()
  end

  defp validate_at_least_one_location(changeset) do
    git_repo_url = get_field(changeset, :git_repo_url)
    local_folder = get_field(changeset, :local_folder)

    if blank?(git_repo_url) and blank?(local_folder) do
      add_error(
        changeset,
        :git_repo_url,
        "provide at least one: git repository URL or local folder"
      )
    else
      changeset
    end
  end

  @allowed_git_schemes ~w(https:// http:// ssh:// git://)

  defp validate_git_repo_url(changeset) do
    case get_field(changeset, :git_repo_url) do
      nil ->
        changeset

      url ->
        url = String.trim(url)

        cond do
          String.starts_with?(url, "-") ->
            add_error(changeset, :git_repo_url, "invalid URL")

          not Enum.any?(@allowed_git_schemes, &String.starts_with?(url, &1)) ->
            add_error(
              changeset,
              :git_repo_url,
              "must start with https://, http://, ssh://, or git://"
            )

          true ->
            changeset
        end
    end
  end

  @denied_env_vars ~w(PATH HOME SHELL USER TERM LANG LD_PRELOAD LD_LIBRARY_PATH)
  @port_definition_pattern ~r/^[A-Z][A-Z0-9_]*$/

  defp validate_port_definitions(changeset) do
    definitions = get_field(changeset, :port_definitions)

    if definitions in [nil, []] do
      changeset
    else
      invalid =
        Enum.find(definitions, fn d ->
          d == "" or not Regex.match?(@port_definition_pattern, d) or d in @denied_env_vars
        end)

      case invalid do
        nil ->
          changeset

        "" ->
          add_error(changeset, :port_definitions, "port definition cannot be empty")

        name when name in @denied_env_vars ->
          add_error(
            changeset,
            :port_definitions,
            "#{name} is a reserved system environment variable"
          )

        name ->
          add_error(
            changeset,
            :port_definitions,
            "#{name} must start with A-Z and contain only uppercase letters, digits, and underscores"
          )
      end
    end
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false
end
