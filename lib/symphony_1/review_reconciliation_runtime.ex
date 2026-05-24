defmodule Symphony1.ReviewReconciliationRuntime do
  @moduledoc """
  One-shot reconciliation runtime for orphaned Linear issues stranded in Human Review.

  Scans all Human Review issues, classifies each as active, orphaned, or unmapped
  based on graph ownership, and transitions orphaned issues to Done or Rework.

  Does not mutate the graph or close PRs.
  """

  alias Symphony1.Core.Linear
  alias Symphony1.Planning.Graph

  @spec summarize(keyword()) :: {:ok, %{counts: map()}} | {:error, term()}
  def summarize(opts) do
    graph_path = Keyword.fetch!(opts, :graph_path)
    linear_config = Keyword.fetch!(opts, :linear_config)
    issue_poller = Keyword.get(opts, :issue_poller, &poll_human_review_issues/1)
    graph_loader = Keyword.get(opts, :graph_loader, &Graph.load/1)

    with {:ok, graph} <- graph_loader.(graph_path) do
      case issue_poller.(linear_config) do
        {:ok, issues} when is_list(issues) ->
          {:ok, %{counts: count_classifications(issues, graph)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec run(keyword()) :: {:ok, %{results: [map()]}} | {:error, term()}
  def run(opts) do
    graph_path = Keyword.fetch!(opts, :graph_path)
    linear_config = Keyword.fetch!(opts, :linear_config)
    issue_poller = Keyword.get(opts, :issue_poller, &poll_human_review_issues/1)
    graph_loader = Keyword.get(opts, :graph_loader, &Graph.load/1)
    issue_transitioner = Keyword.get(opts, :issue_transitioner, &transition_issue/3)

    with {:ok, graph} <- graph_loader.(graph_path) do
      case issue_poller.(linear_config) do
        {:ok, []} ->
          {:ok, %{results: []}}

        {:ok, issues} when is_list(issues) ->
          reconcile_all(issues, graph, linear_config, issue_transitioner)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp reconcile_all(issues, graph, linear_config, transitioner) do
    results =
      Enum.reduce_while(issues, [], fn issue, acc ->
        case classify_and_reconcile_one(issue, graph, linear_config, transitioner) do
          {:ok, result} -> {:cont, [result | acc]}
          {:error, _reason} = error -> {:halt, {:error_with_acc, error, acc}}
        end
      end)

    case results do
      {:error_with_acc, error, _acc} -> error
      completed when is_list(completed) -> {:ok, %{results: Enum.reverse(completed)}}
    end
  end

  defp classify_and_reconcile_one(issue, graph, linear_config, transitioner) do
    case classify(issue.identifier, graph) do
      :active ->
        {:ok, %{issue_identifier: issue.identifier, outcome: "skipped", reason: "active"}}

      :unmapped ->
        {:ok, %{issue_identifier: issue.identifier, outcome: "skipped", reason: "unmapped"}}

      {:orphaned, task} ->
        target_state = if task.status == "done", do: "Done", else: "Rework"

        case transitioner.(issue, target_state, linear_config) do
          {:ok, _updated_issue} ->
            {:ok,
             %{
               issue_identifier: issue.identifier,
               outcome: "reconciled",
               target_state: target_state,
               task_id: task.id
             }}

          {:error, reason} ->
            {:error, {:reconciliation_failed, issue.identifier, target_state, reason}}
        end
    end
  end

  defp classify(issue_identifier, %Graph{tasks: tasks}) do
    case find_task_by_active_materialization(tasks, issue_identifier) do
      {:ok, _task} ->
        :active

      :none ->
        case find_task_by_last_failure(tasks, issue_identifier) do
          {:ok, task} -> {:orphaned, task}
          :none -> :unmapped
        end
    end
  end

  defp count_classifications(issues, graph) do
    base = %{active: 0, orphaned: 0, unmapped: 0, total: length(issues)}

    Enum.reduce(issues, base, fn issue, counts ->
      case classify(issue.identifier, graph) do
        :active -> %{counts | active: counts.active + 1}
        :unmapped -> %{counts | unmapped: counts.unmapped + 1}
        {:orphaned, _task} -> %{counts | orphaned: counts.orphaned + 1}
      end
    end)
  end

  defp find_task_by_active_materialization(tasks, identifier) do
    case Enum.find(tasks, fn t ->
           t.materialization && t.materialization.linear_issue_identifier == identifier
         end) do
      nil -> :none
      task -> {:ok, task}
    end
  end

  defp find_task_by_last_failure(tasks, identifier) do
    case Enum.find(tasks, fn t ->
           t.last_failure && t.last_failure.linear_issue_identifier == identifier
         end) do
      nil -> :none
      task -> {:ok, task}
    end
  end

  defp poll_human_review_issues(config) do
    # Reuse existing poll_issue_in_state infrastructure but collect all matching issues
    Linear.poll_issues_in_state(config, "Human Review")
  end

  defp transition_issue(issue, state, config), do: Linear.transition_issue(issue, state, config)
end
