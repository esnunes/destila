defmodule Destila.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field(:name, :string)
    field(:git_repo_url, :string)
    field(:local_folder, :string)

    has_many(:prompts, Destila.Prompts.Prompt)

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :git_repo_url, :local_folder])
    |> validate_required([:name])
    |> validate_at_least_one_location()
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

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false
end
