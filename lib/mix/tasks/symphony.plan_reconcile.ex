defmodule Mix.Tasks.Symphony.PlanReconcile do
  use Mix.Task

  alias Symphony1.Planning.Graph
  alias Symphony1.RuntimeConfig

  @shortdoc "Reconcile stale in_progress graph tasks against current Linear state"

  @active_linear_states ["In Progress", "Finalizing", "Human Review", "Merging"]

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_reconcile --graph PATH --team-key KEY")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_reconcile --graph PATH --team-key KEY")
        key -> key
      end

    graph =
      case Graph.load(graph_path) do
        {:ok, g} -> g
        {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
      end

    candidates = Graph.stale_in_progress_tasks(graph)

    if candidates == [] do
      Mix.shell().info("reconcile: no stale in_progress tasks — nothing to do")
    else
      linear_config =
        case RuntimeConfig.linear_config(team_key) do
          {:ok, config} -> config
          {:error, :missing_linear_api_key} -> Mix.raise(RuntimeConfig.missing_linear_api_key_message())
        end

      issue_fetcher =
        Application.get_env(:symphony_1, :plan_reconcile_issue_fetcher)

      fetch_opts = if issue_fetcher, do: issue_fetcher, else: &default_issue_fetcher/1

      issue_state_map =
        case fetch_opts.(linear_config) do
          {:ok, issues} -> Map.new(issues, fn i -> {i.identifier, i.state} end)
          {:error, reason} -> Mix.raise("reconcile: failed to fetch Linear issues: #{inspect(reason)}")
        end

      {updated_graph, actions} =
        Enum.reduce(candidates, {graph, []}, fn task, {g, actions} ->
          identifier = task.materialization.linear_issue_identifier
          linear_state = Map.get(issue_state_map, identifier)
          outcome = classify(linear_state)

          case outcome do
            :active ->
              Mix.shell().info("reconcile: #{task.id} [#{identifier}] — active (#{linear_state})")
              {g, [{task.id, :active} | actions]}

            repair_outcome ->
              Mix.shell().info("reconcile: #{task.id} [#{identifier}] — #{repair_outcome} (Linear: #{linear_state || "not found"})")
              {:ok, repaired} = Graph.reconcile_task(g, task.id, repair_outcome)
              {repaired, [{task.id, repair_outcome} | actions]}
          end
        end)

      repairs = Enum.reject(actions, fn {_id, outcome} -> outcome == :active end)

      if repairs != [] do
        case Graph.write(updated_graph, graph_path) do
          :ok ->
            Mix.shell().info("reconcile: wrote #{length(repairs)} repair(s) to #{graph_path}")

          {:error, reason} ->
            Mix.raise("reconcile: failed to write graph: #{inspect(reason)}")
        end
      else
        Mix.shell().info("reconcile: all candidates are active — no repairs needed")
      end
    end
  end

  defp classify(nil), do: :missing
  defp classify("Todo"), do: :todo
  defp classify("Done"), do: :done
  defp classify("Rework"), do: :rework
  defp classify(state) when state in @active_linear_states, do: :active
  defp classify(_unknown), do: :active

  defp default_issue_fetcher(config) do
    case Symphony1.Core.Linear.list_team_issues(config) do
      {:ok, issues} ->
        {:ok, Enum.map(issues, fn issue -> %{identifier: issue.identifier, state: issue.state} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
