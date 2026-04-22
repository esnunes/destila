alias Destila.Projects
alias Destila.Projects.Project
alias Destila.Repo

case Repo.get_by(Project, name: "destila") do
  nil ->
    case Projects.create_project(%{
           name: "destila",
           git_repo_url: "https://github.com/esnunes/destila",
           setup_command: "mise trust -y && mix setup",
           run_command: "elixir --sname destila-{PORT} -S mix phx.server",
           service_env_var: "PORT"
         }) do
      {:ok, _project} ->
        IO.puts("seeded destila project")

      {:error, changeset} ->
        Mix.raise("failed to seed destila project: #{inspect(changeset.errors)}")
    end

  %Project{} ->
    IO.puts("destila project already present — skipping")
end
