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
    field(:mise_auto_trust, :boolean, default: false)
    field(:domain, :string)
    field(:basic_auth_enabled, :boolean, default: false)
    field(:archived_at, :utc_datetime)
    field(:service_state, :map)

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
      :mise_auto_trust,
      :domain,
      :basic_auth_enabled,
      :archived_at,
      :service_state
    ])
    |> validate_required([:name])
    |> validate_at_least_one_location()
    |> validate_git_repo_url()
    |> validate_service_env_var()
    |> validate_domain()
  end

  @doc """
  Returns true when the project is configured as a webservice, i.e. it has
  both a `run_command` and a non-blank `service_env_var`.
  """
  def webservice?(%__MODULE__{run_command: run_command, service_env_var: env_var}) do
    not blank?(run_command) and not blank?(env_var)
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

  @label_pattern ~r/^[A-Za-z0-9-]+$/

  defp validate_domain(changeset) do
    case get_field(changeset, :domain) do
      nil ->
        changeset

      value when is_binary(value) ->
        case normalize_domain(value) do
          "" ->
            put_change(changeset, :domain, nil)

          normalized ->
            cond do
              String.length(normalized) > 253 ->
                add_error(changeset, :domain, "must be at most 253 characters")

              not valid_labels?(normalized) ->
                add_error(
                  changeset,
                  :domain,
                  "must be a valid hostname (RFC 1123): letters, digits and hyphens, no empty labels, no leading/trailing hyphens, labels up to 63 chars"
                )

              true ->
                put_change(changeset, :domain, normalized)
            end
        end
    end
  end

  defp normalize_domain(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp valid_labels?(domain) do
    labels = String.split(domain, ".")

    Enum.all?(labels, fn label ->
      byte_size(label) > 0 and
        byte_size(label) <= 63 and
        Regex.match?(@label_pattern, label) and
        not String.starts_with?(label, "-") and
        not String.ends_with?(label, "-")
    end)
  end
end
