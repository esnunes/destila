defmodule Destila.Git do
  @moduledoc """
  Encapsulates git CLI operations for repository management and worktree creation.
  """

  require Logger

  @doc """
  Pulls latest changes in the given local repository folder.
  """
  def pull(local_folder) do
    case System.cmd("git", ["pull"], cd: local_folder, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Clones a git repository from `url` into `target_dir`.
  Creates parent directories if they don't exist.
  """
  def clone(url, target_dir) do
    File.mkdir_p!(Path.dirname(target_dir))

    case System.cmd("git", ["clone", "--", url, target_dir], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Creates a git worktree at `worktree_path` with a new branch named `branch_name`.
  The `repo_path` is the main repository (or existing clone) directory.
  """
  def worktree_add(repo_path, worktree_path, branch_name) do
    File.mkdir_p!(Path.dirname(worktree_path))

    case System.cmd("git", ["worktree", "add", "-b", branch_name, "--", worktree_path],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Checks whether a worktree already exists at the given path.
  """
  def worktree_exists?(worktree_path) do
    File.dir?(worktree_path) and File.exists?(Path.join(worktree_path, ".git"))
  end

  @doc """
  Returns the effective local folder for a project, creating the cache directory
  and cloning if necessary for remote-only projects.
  """
  def effective_local_folder(project) do
    cond do
      project.local_folder && project.local_folder != "" ->
        {:ok, project.local_folder}

      project.git_repo_url && project.git_repo_url != "" ->
        cache_dir = cache_path(project.id)

        if File.dir?(cache_dir) do
          {:ok, cache_dir}
        else
          case clone(project.git_repo_url, cache_dir) do
            {:ok, _} -> {:ok, cache_dir}
            {:error, reason} -> {:error, reason}
          end
        end

      true ->
        {:error, "Project has no local folder or git repo URL"}
    end
  end

  defp cache_path(project_id) do
    cache_home = System.get_env("XDG_CACHE_HOME", Path.expand("~/.cache"))
    Path.join([cache_home, "destila", project_id])
  end

  @doc """
  Fetches refs from the default remote in the given local repository folder.
  """
  def fetch(local_folder) do
    case System.cmd("git", ["fetch", "--prune"], cd: local_folder, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Returns the configured default branch on the `origin` remote (e.g. "main").
  """
  def default_branch(local_folder) do
    case System.cmd("git", ["symbolic-ref", "refs/remotes/origin/HEAD"],
           cd: local_folder,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        branch =
          output
          |> String.trim()
          |> String.replace_prefix("refs/remotes/origin/", "")

        {:ok, branch}

      {output, _code} ->
        {:error, String.trim(output)}
    end
  end

  @doc """
  Returns true when the working tree (or index) has uncommitted changes.
  """
  def dirty?(local_folder) do
    case System.cmd("git", ["status", "--porcelain"],
           cd: local_folder,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output) != ""}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Returns true when there are commits on `origin/<default_branch>` that are
  not yet on the local HEAD.
  """
  def ahead?(local_folder) do
    with {:ok, branch} <- default_branch(local_folder) do
      case System.cmd(
             "git",
             ["rev-list", "--count", "HEAD..origin/" <> branch],
             cd: local_folder,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          case Integer.parse(String.trim(output)) do
            {count, _} -> {:ok, count > 0}
            :error -> {:error, "could not parse rev-list output: " <> String.trim(output)}
          end

        {output, _code} ->
          {:error, String.trim(output)}
      end
    end
  end

  @doc """
  Returns true when local HEAD has commits not on `origin/<default_branch>`
  AND `origin/<default_branch>` has commits not on local HEAD (i.e. a
  fast-forward is impossible).
  """
  def diverged?(local_folder) do
    with {:ok, branch} <- default_branch(local_folder) do
      case System.cmd(
             "git",
             [
               "rev-list",
               "--left-right",
               "--count",
               "HEAD...origin/" <> branch
             ],
             cd: local_folder,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          parts =
            output
            |> String.trim()
            |> String.split(~r/\s+/, trim: true)

          case parts do
            [left, right] ->
              with {l, _} <- Integer.parse(left),
                   {r, _} <- Integer.parse(right) do
                {:ok, l > 0 and r > 0}
              else
                _ ->
                  {:error, "could not parse rev-list output: " <> output}
              end

            _ ->
              {:error, "could not parse rev-list output: " <> output}
          end

        {output, _code} ->
          {:error, String.trim(output)}
      end
    end
  end

  @doc """
  Fast-forwards the local default branch to `origin/<default_branch>`.
  Returns `{:error, _}` if a fast-forward is not possible.
  """
  def fast_forward(local_folder) do
    with {:ok, branch} <- default_branch(local_folder) do
      case System.cmd("git", ["merge", "--ff-only", "origin/" <> branch],
             cd: local_folder,
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _code} -> {:error, String.trim(output)}
      end
    end
  end
end
