defmodule Symphony1.ReviewRuntime do
  alias Symphony1.Core.{GitHub, Linear}
  alias Symphony1.MergeRuntime
  alias Symphony1.Planning.Graph
  alias Symphony1.Planning.ScopeCheck
  alias Symphony1.Review

  @graph_path "planning/graph.json"

  @spec run(keyword()) :: {:ok, %{results: [map()]}} | {:error, term()}
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    build_attrs = Keyword.get(opts, :build_attrs, &MergeRuntime.build_merge_attrs/1)
    linear_poller = Keyword.get(opts, :linear_poller, &poll_human_review_issue/1)
    github_resolver = Keyword.get(opts, :github_resolver, &resolve_pull_request/1)
    candidate_builder = Keyword.get(opts, :candidate_builder, &build_candidate/4)
    review_runner = Keyword.get(opts, :review_runner, &Review.review/1)
    transitioner = Keyword.get(opts, :transitioner, &transition_to_rework/3)

    with {:ok, review_attrs} <- build_attrs.(cwd) do
      case linear_poller.(review_attrs.linear_config) do
        :none ->
          {:ok, %{results: []}}

        {:ok, issue} ->
         case review_once(
                 issue,
                 cwd,
                 review_attrs,
                 github_resolver,
                 candidate_builder,
                 review_runner,
                 transitioner
               ) do
            {:ok, result} ->
            {:ok, %{results: [result]}}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_review_result(%{"outcome" => "approved", "issue_identifier" => issue_identifier}, _issue, _linear_config, _transitioner) do
    {:ok, %{issue_identifier: issue_identifier, outcome: "approved"}}
  end

  defp handle_review_result(%{"outcome" => "changes_requested", "issue_identifier" => issue_identifier}, issue, linear_config, transitioner) do
    with {:ok, _updated_issue} <- transitioner.(issue, "Rework", linear_config) do
      {:ok, %{issue_identifier: issue_identifier, outcome: "changes_requested"}}
    end
  end

  defp handle_review_result(artifact, _issue, _linear_config, _transitioner) do
    {:error, {:invalid_review_artifact, artifact}}
  end

  defp poll_human_review_issue(config), do: Linear.poll_issue_in_state(config, "Human Review")

  defp resolve_pull_request(attrs), do: GitHub.find_pull_request_by_branch(attrs)

  defp transition_to_rework(issue, new_state, linear_config) do
    Linear.transition_issue(issue, new_state, linear_config)
  end

  defp review_once(issue, cwd, review_attrs, github_resolver, candidate_builder, review_runner, transitioner) do
    branch = "issue-" <> String.downcase(issue.identifier)

    with {:ok, pull_request} <-
         github_resolver.(%{
             branch: branch,
             repo: review_attrs.repo,
             workspace: cwd,
             cwd: cwd
           }),
         {:ok, candidate} <- build_review_candidate(candidate_builder, issue, pull_request, cwd, review_attrs),
         {:ok, artifact} <- review_runner.(candidate),
         {:ok, result} <- handle_review_result(artifact, issue, review_attrs.linear_config, transitioner) do
      {:ok, result}
    else
      {:error, reason} ->
        recover_review_failure(issue, review_attrs.linear_config, transitioner, reason)
    end
  end

  defp recover_review_failure(issue, linear_config, transitioner, reason) do
    case transitioner.(issue, "Rework", linear_config) do
      {:ok, _updated_issue} -> {:error, reason}
      {:error, transition_reason} -> {:error, {:review_recovery_failed, reason, transition_reason}}
    end
  end

  defp build_review_candidate(candidate_builder, issue, pull_request, cwd, review_attrs) do
    case :erlang.fun_info(candidate_builder, :arity) do
      {:arity, 4} -> candidate_builder.(issue, pull_request, cwd, review_attrs)
      {:arity, 3} -> candidate_builder.(issue, pull_request, cwd)
    end
  end

  defp build_candidate(issue, pull_request, cwd, review_attrs) do
    graph = load_graph(cwd)

    task_context =
      case graph do
        {:ok, graph} ->
          case Graph.find_task_by_issue_identifier(graph, issue.identifier) do
            {:ok, task} -> task
            :none -> nil
          end

        {:error, _reason} ->
          nil
      end

    workspace_root = Map.get(review_attrs, :workspace_root, Path.join([cwd, "tmp", "workspaces"]))
    workspace = Path.join(workspace_root, issue.identifier)
    base_branch = Map.get(pull_request, :base_branch, "main")

    with {:ok, commit_sha} <- git_output(workspace, ["rev-parse", "HEAD"]),
         {:ok, changed_files_output} <- git_output(workspace, ["diff", "--name-only", "#{base_branch}...HEAD"]),
         {:ok, diff} <- git_output(workspace, ["diff", "--no-color", "#{base_branch}...HEAD"]) do
      changed_files = changed_files(changed_files_output)
      scope_check = if task_context, do: ScopeCheck.evaluate(task_context, changed_files), else: nil

      {:ok,
       %{
         repo_root: cwd,
         issue: issue,
         pull_request: pull_request,
         workspace: workspace,
         workflow_path: Path.join(cwd, "priv/workflows/WORKFLOW.md"),
         graph_task_id: if(task_context, do: task_context.id),
         task_context: task_context,
         commit_sha: commit_sha,
         changed_files: changed_files,
         scope_check: scope_check,
         diff: diff,
         validation_summary: validation_summary(task_context),
         supporting_docs: supporting_docs(cwd)
       }}
    end
  end

  defp load_graph(cwd) do
    Graph.load(Path.join(cwd, @graph_path))
  end

  defp supporting_docs(cwd) do
    [
      Path.join(cwd, "docs/project-orientation-and-source-of-truth.md"),
      Path.join(cwd, "docs/status.md")
    ]
  end

  defp validation_summary(nil), do: "Validation passed before PR open."

  defp validation_summary(task_context) do
    commands = validation_commands(task_context)

    case commands do
      [] -> "Validation passed before PR open."
      list -> "Validation passed before PR open with commands:\n" <> Enum.map_join(list, "\n", &"- #{&1}")
    end
  end

  defp validation_commands(task_context) when is_map(task_context) do
    validation = Map.get(task_context, :validation) || Map.get(task_context, "validation")

    case validation do
      nil -> []
      validation_map when is_map(validation_map) ->
        Map.get(validation_map, :commands) || Map.get(validation_map, "commands") || []
    end
  end

  defp changed_files(""), do: []
  defp changed_files(output), do: String.split(output, "\n", trim: true)

  defp git_output(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:command_failed, "git", status, String.trim(output)}}
    end
  end
end
