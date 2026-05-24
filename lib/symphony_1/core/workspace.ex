defmodule Symphony1.Core.Workspace do
  @spec path_for_issue(String.t(), String.t()) :: String.t()
  def path_for_issue(root, issue_id) do
    Path.join(root, issue_id)
  end

  @spec create(map()) :: {:ok, String.t()} | {:error, term()}
  def create(%{root: root, issue_id: issue_id} = attrs) do
    workspace_path = path_for_issue(root, issue_id)

    with :ok <- File.mkdir_p(root),
         :ok <- materialize_workspace(workspace_path, attrs) do
      {:ok, workspace_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cleanup(String.t()) :: :ok | {:error, term()}
  def cleanup(path) do
    with :ok <- cleanup_worktree(path),
         {:ok, _paths} <- File.rm_rf(path) do
      :ok
    else
      {:error, :enoent, _path} -> :ok
      {:error, reason, _path} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_workspace(workspace_path, %{source_repo: source_repo, branch: branch}) do
    case System.cmd(
           "git",
           ["-C", source_repo, "worktree", "add", "-b", branch, workspace_path, "HEAD"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _exit_status} -> {:error, String.trim(output)}
    end
  end

  defp materialize_workspace(workspace_path, _attrs) do
    case File.mkdir_p(workspace_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_worktree(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--git-common-dir"], stderr_to_stdout: true) do
      {git_common_dir, 0} ->
        common_dir = git_common_dir |> String.trim() |> Path.expand(path)

        case System.cmd(
               "git",
               ["--git-dir", common_dir, "worktree", "remove", "--force", path],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, _exit_status} -> {:error, String.trim(output)}
        end

      {_output, _exit_status} ->
        :ok
    end
  end
end
