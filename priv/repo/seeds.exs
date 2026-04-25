alias Destila.Projects
alias Destila.Projects.Project
alias Destila.Repo

destila_attrs = %{
  name: "destila",
  git_repo_url: "https://github.com/esnunes/destila",
  local_folder: Path.expand(File.cwd!()),
  setup_command: "mix setup",
  run_command: "elixir --sname destila-{PORT} -S mix phx.server",
  service_env_var: "PORT",
  mise_auto_trust: true
}

case Repo.get_by(Project, name: "destila") do
  nil ->
    case Projects.create_project(destila_attrs) do
      {:ok, _project} ->
        IO.puts("seeded destila project")

      {:error, changeset} ->
        Mix.raise("failed to seed destila project: #{inspect(changeset.errors)}")
    end

  %Project{} = existing ->
    case Projects.update_project(existing, %{local_folder: destila_attrs.local_folder}) do
      {:ok, _project} ->
        IO.puts("destila project already present — local_folder synced to cwd")

      {:error, changeset} ->
        Mix.raise("failed to update destila project local_folder: #{inspect(changeset.errors)}")
    end
end
