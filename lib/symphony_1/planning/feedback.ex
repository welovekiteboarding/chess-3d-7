defmodule Symphony1.Planning.Feedback do
  @moduledoc """
  Minimal feedback loop: syncs Linear issue outcomes back into the graph.

  For each materialized graph task with a stored Linear issue identifier,
  checks the current Linear issue state and updates the graph:

  - Linear `Done` -> graph status `done`
  - Linear `Rework` -> graph status `rework`
  - Linear `Todo` -> graph status `pending`, preserving materialization
  - All other known active states -> no change

  This is intentionally narrow for v1. Follow-up task generation and
  richer replanning are deferred.
  """

  require Logger

  alias Symphony1.Planning.Graph

  @type update_entry :: %{task_id: String.t(), old_status: String.t(), new_status: String.t()}

  @type result :: %{
          graph: Graph.t(),
          updated: [update_entry()]
        }

  @linear_to_graph_status %{
    "Done" => "done",
    "Rework" => "rework",
    "Todo" => "pending"
  }

  @spec sync(Graph.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def sync(%Graph{} = graph, linear_config, opts \\ []) do
    issue_fetcher = Keyword.get(opts, :issue_fetcher, &default_issue_fetcher/1)

    case issue_fetcher.(linear_config) do
      {:ok, issues} ->
        issue_state_map = Map.new(issues, fn i -> {i.identifier, i.state} end)
        apply_feedback(graph, issue_state_map)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_feedback(graph, issue_state_map) do
    {updated_graph, updates} =
      Enum.reduce(mapped_tasks(graph), {graph, []}, fn task, {g, updates} ->
        identifier = task.materialization.linear_issue_identifier
        linear_state = Map.get(issue_state_map, identifier)
        new_status = Map.get(@linear_to_graph_status, linear_state)

        if new_status && new_status != task.status do
          Logger.info("symphony.feedback: #{task.id} (#{identifier}) #{task.status} -> #{new_status}")

          {:ok, updated_g} = Graph.update_task(g, task.id, %{status: new_status})

          update = %{task_id: task.id, old_status: task.status, new_status: new_status}
          {updated_g, updates ++ [update]}
        else
          {g, updates}
        end
      end)

    {:ok, %{graph: updated_graph, updated: updates}}
  end

  defp mapped_tasks(%Graph{tasks: tasks}) do
    Enum.filter(tasks, fn task ->
      task.materialization.materialized &&
        task.materialization.linear_issue_identifier != nil
    end)
  end

  defp default_issue_fetcher(config) do
    case Symphony1.Core.Linear.list_team_issues(config) do
      {:ok, issues} ->
        {:ok, Enum.map(issues, fn issue -> %{identifier: issue.identifier, state: issue.state} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
