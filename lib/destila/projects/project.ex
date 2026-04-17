defmodule Destila.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset
  import Destila.StringHelper, only: [blank?: 1]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field(:name, :string)
    field(:git_repo_url, :string)
    field(:local_folder, :string)
    field(:run_command, :string)
    field(:setup_command, :string)
    field(:service_env_var, :string)
    field(:archived_at, :utc_datetime)

    has_many(:workflow_sessions, Destila.Workflows.Session)

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :git_repo_url,
      :local_folder,
      :run_command,
      :setup_command,
      :service_env_var,
      :archived_at
    ])
    |> validate_required([:name])
    |> validate_at_least_one_location()
    |> validate_git_repo_url()
    |> validate_service_env_var()
  end

  @doc """
  Returns true when the project is configured as a webservice, i.e. it has
  both a `run_command` and a non-blank `service_env_var`.
  """
  def webservice?(%__MODULE__{run_command: run_command, service_env_var: env_var}) do
    not blank?(run_command) and not blank?(env_var)
  end

  def webservice?(_), do: false

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
  @env_var_pattern ~r/^[A-Z][A-Z0-9_]*$/

  defp validate_service_env_var(changeset) do
    value = get_field(changeset, :service_env_var)

    cond do
      blank?(value) ->
        changeset

      value in @denied_env_vars ->
        add_error(
          changeset,
          :service_env_var,
          "#{value} is a reserved system environment variable"
        )

      not Regex.match?(@env_var_pattern, value) ->
        add_error(
          changeset,
          :service_env_var,
          "#{value} must start with A-Z and contain only uppercase letters, digits, and underscores"
        )

      true ->
        changeset
    end
  end
end
