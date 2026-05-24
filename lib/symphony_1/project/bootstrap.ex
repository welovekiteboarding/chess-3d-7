defmodule Symphony1.Project.Bootstrap do
  alias Symphony1.{MergeRuntime, Runtime}
  alias Symphony1.Project.{Scaffold, Setup}

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(attrs, opts \\ []) do
    scaffold_runner = Keyword.get(opts, :scaffold_runner, &Scaffold.generate/1)
    setup_runner = Keyword.get(opts, :setup_runner, &run_setup_in_project/1)
    runtime_runner = Keyword.get(opts, :runtime_runner, &Runtime.run/1)
    merge_runtime_runner = Keyword.get(opts, :merge_runtime_runner, &MergeRuntime.run/1)

    scaffold_attrs =
      attrs
      |> Map.put(:github, true)
      |> Map.put(:private, Map.get(attrs, :private, false))

    with {:ok, %{project_path: project_path}} <- scaffold_runner.(scaffold_attrs),
         {:ok, setup_state} <- setup_runner.(project_path),
         {:ok, _runtime_result} <- runtime_runner.([cwd: project_path, once: true]),
         {:ok, merge_result} <- merge_runtime_runner.([cwd: project_path, once: true]),
         {:ok, merged_pr_url} <- merged_pr_url(merge_result) do
      {:ok,
       %{
         github_repo: "#{Map.fetch!(attrs, :github_owner)}/#{Map.fetch!(attrs, :project_name)}",
         merged_pr_url: merged_pr_url,
         project_path: project_path,
         proof_issue_identifier: get_in(setup_state, ["proof_issue", "identifier"])
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_setup_in_project(project_path) do
    File.cd!(project_path, fn -> Setup.run() end)
  end

  defp merged_pr_url(%{results: [%{pull_request: %{url: url}} | _rest]}), do: {:ok, url}
  defp merged_pr_url(_result), do: {:error, :merge_result_missing_pull_request}
end
