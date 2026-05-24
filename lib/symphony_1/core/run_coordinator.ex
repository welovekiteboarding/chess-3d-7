defmodule Symphony1.Core.RunCoordinator do
  require Logger

  alias Symphony1.Core.{GitHub, Linear, Tracker, Worker, Workspace}
  alias Symphony1.Planning.Graph
  alias Symphony1.Project.RepoAdapter

  @spec run_issue(map()) :: {:ok, map()} | :none | {:error, term()}
  def run_issue(%{
        issues: issues,
        workspace_root: workspace_root,
        workflow_path: workflow_path
      } = attrs) do
    with {:ok, issue} <- Tracker.poll_eligible_issue(issues),
         {:ok, in_progress_issue} <- Tracker.transition_issue(issue, "In Progress"),
         {:ok, workspace} <-
           Workspace.create(%{
             branch: Map.get(attrs, :branch, default_branch(issue.identifier)),
             issue_id: issue.identifier,
             root: workspace_root,
             source_repo: Map.get(attrs, :source_repo)
           }) do
      worker =
        Worker.local_run_spec(%{
          workspace: workspace,
          workflow_path: workflow_path
        })

      {:ok, %{issue: in_progress_issue, workspace: workspace, worker: worker}}
    end
  end

  def run_issue(%{
        linear_config: linear_config,
        workspace_root: workspace_root,
        workflow_path: workflow_path
      } = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)

    with {:ok, issue} <- Linear.poll_eligible_issue(linear_config, requester),
         {:ok, in_progress_issue} <-
           Linear.transition_issue(issue, "In Progress", linear_config, requester),
         {:ok, workspace} <-
           Workspace.create(%{
             branch: Map.get(attrs, :branch, default_branch(issue.identifier)),
             issue_id: issue.identifier,
             root: workspace_root,
             source_repo: Map.get(attrs, :source_repo)
           }) do
      worker =
        Worker.local_run_spec(%{
          workspace: workspace,
          workflow_path: workflow_path
        })

      {:ok, %{issue: in_progress_issue, workspace: workspace, worker: worker}}
    end
  end

  @spec run_full_issue(map()) :: {:ok, map()} | :none | {:error, term()}
  def run_full_issue(attrs) do
    with {:ok, run} <- run_issue(attrs) do
      finish_claimed_issue(run, attrs)
    else
      :none -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finish_claimed_issue(map(), map()) :: {:ok, map()} | {:error, term()}
  def finish_claimed_issue(run, attrs) do
    github_runner = Map.get(attrs, :github_runner, &System.cmd/3)
    repo_finalizer = Map.get(attrs, :repo_finalizer, &RepoAdapter.finalize_workspace/2)
    progress_reporter = Map.get(attrs, :progress_reporter, fn _message -> :ok end)
    worker_adapter = Map.get(attrs, :worker, Worker)
    issue_started_at = now_ms()
    worker_started_at = now_ms()

    task_context = resolve_task_context(run.issue, attrs)
    attrs = Map.put(attrs, :task_context, task_context)

    Logger.info("symphony.coordinator: executing worker for #{run.issue.identifier}")
    progress_reporter.("Running Codex for #{run.issue.identifier}")

    case execute_worker(run, attrs, worker_adapter) do
      {:ok, worker_result} ->
        worker_elapsed = format_elapsed(now_ms() - worker_started_at)
        Logger.info("symphony.coordinator: worker complete for #{run.issue.identifier}, finalizing")
        progress_reporter.("Codex finished for #{run.issue.identifier} in #{worker_elapsed}")

        case transition_to_finalizing(run.issue, attrs) do
          {:ok, finalizing_issue} ->
            Logger.info("symphony.coordinator: #{finalizing_issue.identifier} transitioned to Finalizing")
            progress_reporter.("Finalizing #{finalizing_issue.identifier}")

            case finalize_and_review(
                   %{run | issue: finalizing_issue},
                   attrs,
                   worker_result,
                   repo_finalizer,
                   github_runner,
                   progress_reporter,
                   issue_started_at
                 ) do
              result -> result
            end

          {:error, reason} ->
            Logger.warning("symphony.coordinator: Finalizing transition failed for #{run.issue.identifier}: #{inspect(reason)}")
            recover_failed_run(run.issue, attrs, :finalizing_transition, reason)
        end

      {:error, reason} ->
        Logger.warning("symphony.coordinator: worker failed for #{run.issue.identifier}: #{inspect(reason)}")
        recover_failed_run(run.issue, attrs, :worker_execution, reason)
    end
  end

  defp finalize_and_review(run, attrs, worker_result, repo_finalizer, github_runner, progress_reporter, issue_started_at) do
        case finalize_run(
               %{
                 base_branch: attrs.base_branch,
                 body: attrs.body,
                 issue: run.issue,
                 repo: attrs.repo,
                 task_context: Map.get(attrs, :task_context),
                 title: attrs.title,
                 workspace: run.workspace
               },
               repo_finalizer,
               github_runner
             ) do
          {:ok, review} ->
            progress_reporter.("Opening PR for #{review.issue.identifier}")
            Logger.info("symphony.coordinator: PR opened for #{review.issue.identifier} (#{review.pull_request.url})")
            progress_reporter.("Opened PR for #{review.issue.identifier} (#{review.pull_request.url})")

            case transition_to_review(review.issue, review.pull_request, attrs) do
              {:ok, issue} ->
                total_elapsed = format_elapsed(now_ms() - issue_started_at)
                Logger.info("symphony.coordinator: #{issue.identifier} transitioned to Human Review")
                progress_reporter.("Completed #{issue.identifier} -> Human Review (#{review.pull_request.url}) in #{total_elapsed}")

                {:ok,
                 %{
                   finalization: review.finalization,
                   issue: issue,
                   pull_request: review.pull_request,
                   worker_result: worker_result,
                   workspace: review.workspace
                 }}

              {:error, reason} ->
                Logger.warning("symphony.coordinator: review transition failed for #{review.issue.identifier}: #{inspect(reason)}")
                recover_failed_run(review.issue, attrs, :review_transition, reason)
            end

          {:error, reason} ->
            Logger.warning("symphony.coordinator: finalization failed for #{run.issue.identifier}: #{inspect(reason)}")
            recover_failed_run(run.issue, attrs, :review_preparation, reason)
        end
  end

  @spec open_review(map(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def open_review(%{workspace: workspace} = attrs, github_runner \\ &System.cmd/3) do
    title = Map.get(attrs, :title, default_pr_title(attrs.issue))
    body = Map.get(attrs, :body, default_pr_body(attrs.issue))

    with {:ok, branch} <- current_branch(workspace),
         {:ok, pull_request} <-
           GitHub.open_pull_request(
             %{
               base_branch: attrs.base_branch,
               body: body,
               branch: branch,
               cwd: workspace,
               repo: attrs.repo,
               title: title
             },
             github_runner
           ) do
      {:ok,
       %{
         issue: attrs.issue,
         finalization: Map.get(attrs, :finalization),
         pull_request: pull_request,
         workspace: workspace
       }}
    end
  end

  @spec finalize_run(map(), function(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def finalize_run(attrs, repo_boundary \\ &RepoAdapter.finalize_workspace/2, github_runner \\ &System.cmd/3)

  def finalize_run(attrs, validation_runner, github_runner) when is_function(validation_runner, 3) do
    repo_boundary = fn repo_attrs, _default_runner ->
      RepoAdapter.finalize_workspace(repo_attrs, validation_runner)
    end

    finalize_run(attrs, repo_boundary, github_runner)
  end

  def finalize_run(attrs, repo_boundary, github_runner) when is_function(repo_boundary, 2) do
    with {:ok, finalization} <- repo_boundary.(attrs, &System.cmd/3),
         {:ok, review} <- open_review(Map.put(attrs, :finalization, finalization), github_runner) do
      {:ok, review}
    end
  end

  @spec merge_review(map(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def merge_review(attrs, github_runner \\ &System.cmd/3) do
    cleanup = Map.get(attrs, :cleanup, &Workspace.cleanup/1)
    Logger.info("symphony.coordinator: starting merge for #{attrs.issue.identifier}")

    with {:ok, merging_issue, pull_request} <- merge_pull_request(attrs, github_runner),
         {:ok, done_issue} <- transition_to_done(merging_issue, attrs),
         :ok <- cleanup_workspace(attrs, cleanup) do
      Logger.info("symphony.coordinator: merge complete for #{done_issue.identifier} -> Done")

      {:ok,
       %{
         issue: done_issue,
         pull_request: pull_request,
         workspace: attrs.workspace
       }}
    end
  end

  defp merge_pull_request(%{issue: issue, pull_request: %{status: :merged} = pull_request}, _github_runner) do
    {:ok, issue, pull_request}
  end

  defp merge_pull_request(%{issue: issue, pull_request: pull_request} = attrs, github_runner) do
    with {:ok, merging_issue} <- transition_to_merging(issue, attrs),
         {:ok, merged_pull_request} <- GitHub.merge_pull_request(pull_request, github_runner) do
      {:ok, merging_issue, merged_pull_request}
    end
  end

  defp execute_worker(run, attrs, worker_adapter) do
    prompt = issue_prompt(run.issue, attrs)
    worker_opts = [timeout_ms: Map.get(attrs, :worker_timeout_ms, 60_000)]

    with {:ok, session} <- worker_start(worker_adapter, %{workspace: run.workspace, workflow_path: attrs.workflow_path}) do
      result = worker_run_prompt(worker_adapter, session, prompt, worker_opts)
      stop_result = worker_stop(worker_adapter, session)

      case {result, stop_result} do
        {{:ok, worker_result}, :ok} -> {:ok, worker_result}
        {{:error, _reason} = error, :ok} -> error
        {{:ok, _worker_result}, {:error, reason}} -> {:error, {:worker_stop_failed, reason}}
        {{:error, _reason} = error, {:error, _stop_reason}} -> error
      end
    end
  end

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  defp format_elapsed(ms) when ms >= 1000 do
    "#{div(ms, 1000)}s"
  end

  defp format_elapsed(ms) do
    "#{ms}ms"
  end

  defp transition_to_finalizing(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Finalizing", linear_config, requester)
  end

  defp transition_to_finalizing(issue, _attrs) do
    Tracker.transition_issue(issue, "Finalizing")
  end

  defp transition_to_review(issue, pull_request, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(
      issue,
      "Human Review",
      %{"description" => review_description(issue, pull_request.url)},
      linear_config,
      requester
    )
  end

  defp transition_to_review(issue, _pull_request, _attrs) do
    Tracker.transition_issue(issue, "Human Review")
  end

  defp review_description(issue, pull_request_url) do
    pr_note = pull_request_note(pull_request_url)

    case Map.get(issue, :description) do
      nil -> pr_note
      "" -> pr_note
      description when is_binary(description) ->
        if String.contains?(description, pull_request_url) do
          description
        else
          description <> "\n\n" <> pr_note
        end
    end
  end

  defp pull_request_note(pull_request_url) do
    case Regex.run(~r{/pull/(\d+)$}, pull_request_url) do
      [_, number] -> "GitHub PR: ##{number}\n#{pull_request_url}"
      _ -> "GitHub PR:\n#{pull_request_url}"
    end
  end

  defp transition_to_merging(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Merging", linear_config, requester)
  end

  defp transition_to_merging(issue, _attrs) do
    Tracker.transition_issue(issue, "Merging")
  end

  defp transition_to_done(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Done", linear_config, requester)
  end

  defp transition_to_done(issue, _attrs) do
    Tracker.transition_issue(issue, "Done")
  end

  defp cleanup_workspace(%{workspace: workspace}, cleanup) do
    case cleanup.(workspace) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_cleanup_failed, workspace, reason}}
    end
  end

  defp cleanup_workspace(_attrs, _cleanup), do: :ok

  defp recover_failed_run(issue, attrs, stage, reason) do
    Logger.warning("symphony.coordinator: recovering #{issue.identifier} to Rework (stage=#{stage})")

    graph_writeback_result = persist_graph_failure(issue, attrs, stage, reason)

    case transition_to_rework(issue, attrs) do
      {:ok, recovered_issue} ->
        case graph_writeback_result do
          :ok ->
            {:error, {:run_failed, stage, recovered_issue, reason}}

          {:error, writeback_reason} ->
            {:error, {:run_failed, stage, recovered_issue, reason, {:graph_writeback_failed, writeback_reason}}}
        end

      {:error, recovery_reason} ->
        {:error, {:run_failed, stage, issue, reason, {:recovery_failed, recovery_reason}}}
    end
  end

  defp persist_graph_failure(issue, attrs, stage, reason) do
    graph = Map.get(attrs, :graph)
    graph_path = Map.get(attrs, :graph_path)

    if graph && graph_path do
      failure_context = %{
        stage: to_string(stage),
        reason: format_failure_reason(reason),
        category: classify_failure(stage)
      }

      case Graph.record_task_failure(graph, issue.identifier, failure_context) do
        {:ok, updated_graph} ->
          case Graph.write(updated_graph, graph_path) do
            :ok ->
              Logger.info("symphony.coordinator: persisted failure context for #{issue.identifier} to #{graph_path}")
              :ok

            {:error, write_reason} ->
              Logger.warning("symphony.coordinator: failed to write graph after failure recording: #{inspect(write_reason)}")
              {:error, write_reason}
          end

        :none ->
          Logger.info("symphony.coordinator: no graph task found for #{issue.identifier}, skipping failure recording")
          :ok
      end
    else
      :ok
    end
  end

  defp format_failure_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_failure_reason({tag, detail}) when is_atom(tag), do: "#{tag}: #{inspect(detail)}"
  defp format_failure_reason(reason), do: inspect(reason)

  defp classify_failure(:worker_execution), do: "worker_execution"
  defp classify_failure(:review_preparation), do: "validation"
  defp classify_failure(:review_transition), do: "review"
  defp classify_failure(:finalizing_transition), do: "finalization"

  defp transition_to_rework(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Rework", linear_config, requester)
  end

  defp transition_to_rework(issue, _attrs) do
    Tracker.transition_issue(issue, "Rework")
  end

  defp issue_prompt(issue, attrs) do
    task_context = Map.get(attrs, :task_context)

    sections = [
      "Linear issue #{issue.identifier}: #{Map.get(issue, :title, "")}",
      issue_description(Map.get(issue, :description)),
      format_task_context(task_context),
      Map.get(attrs, :issue_prompt, "Implement the issue and leave the workspace ready for review.")
    ]

    sections
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp issue_description(nil), do: nil
  defp issue_description(""), do: nil
  defp issue_description(description), do: "Description: #{description}"

  defp resolve_task_context(issue, attrs) do
    graph = Map.get(attrs, :graph)

    if graph do
      case Graph.find_task_by_issue_identifier(graph, issue.identifier) do
        {:ok, task} ->
          Logger.info("symphony.coordinator: resolved graph task #{task.id} for #{issue.identifier}")
          task

        :none ->
          Logger.info("symphony.coordinator: no graph task found for #{issue.identifier}")
          nil
      end
    else
      nil
    end
  end

  defp format_task_context(nil), do: nil

  defp format_task_context(%Graph.Task{} = task) do
    sections = [
      if(task.kind, do: "Task kind: #{task.kind}"),
      if(task.id, do: "Graph task: #{task.id}"),
      format_criteria(task.acceptance_criteria),
      format_scope(task.scope),
      format_validation(task.validation),
      format_last_failure(task.last_failure)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp format_criteria(nil), do: nil
  defp format_criteria([]), do: nil

  defp format_criteria(criteria) do
    lines = Enum.map(criteria, &("- #{&1}"))
    "Acceptance criteria:\n#{Enum.join(lines, "\n")}"
  end

  defp format_scope(nil), do: nil

  defp format_scope(%Graph.Scope{include: include, exclude: exclude}) do
    parts = []

    parts =
      if include != [] do
        parts ++ ["In scope: #{Enum.join(include, ", ")}"]
      else
        parts
      end

    parts =
      if exclude != [] do
        parts ++ ["Out of scope: #{Enum.join(exclude, ", ")}"]
      else
        parts
      end

    case parts do
      [] -> nil
      _ -> Enum.join(parts, "\n")
    end
  end

  defp format_last_failure(nil), do: nil

  defp format_last_failure(lf) do
    parts =
      [
        if(lf.linear_issue_identifier, do: "Issue: #{lf.linear_issue_identifier}"),
        if(lf.category, do: "Category: #{lf.category}"),
        if(lf.stage, do: "Stage: #{lf.stage}"),
        if(lf.reason, do: "Reason: #{lf.reason}")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      nil
    else
      "Previous attempt failed:\n#{Enum.join(parts, "\n")}"
    end
  end

  defp format_validation(nil), do: nil

  defp format_validation(%Graph.Validation{commands: commands}) when commands != [] do
    "Validation: #{Enum.join(commands, ", ")}"
  end

  defp format_validation(_), do: nil

  defp default_branch(issue_identifier) do
    "issue-" <> String.downcase(issue_identifier)
  end

  defp default_pr_title(%{identifier: issue_identifier}), do: "Implement #{issue_identifier}"
  defp default_pr_body(%{identifier: issue_identifier}), do: "Implements #{issue_identifier}"

  defp worker_start(worker_adapter, attrs) when is_map(worker_adapter), do: worker_adapter.start_session.(attrs)
  defp worker_start(worker_adapter, attrs), do: apply(worker_adapter, :start_session, [attrs])

  defp worker_run_prompt(worker_adapter, session, prompt, opts) when is_map(worker_adapter) do
    case :erlang.fun_info(worker_adapter.run_prompt, :arity) do
      {:arity, 3} -> worker_adapter.run_prompt.(session, prompt, opts)
      {:arity, 2} -> worker_adapter.run_prompt.(session, prompt)
    end
  end

  defp worker_run_prompt(worker_adapter, session, prompt, opts) do
    if function_exported?(worker_adapter, :run_prompt, 3) do
      apply(worker_adapter, :run_prompt, [session, prompt, opts])
    else
      apply(worker_adapter, :run_prompt, [session, prompt])
    end
  end

  defp worker_stop(worker_adapter, session) when is_map(worker_adapter), do: worker_adapter.stop_session.(session)
  defp worker_stop(worker_adapter, session), do: apply(worker_adapter, :stop_session, [session])

  defp current_branch(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {output, exit_status} -> {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end
end
