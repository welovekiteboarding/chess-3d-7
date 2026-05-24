defmodule Mix.Tasks.Symphony.PlanRetry do
  use Mix.Task

  alias Symphony1.Planning.Graph

  @shortdoc "Retry a rework graph task — clears mapping, preserves failure history"

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_retry TASK_ID --graph PATH")
        path -> path
      end

    task_id =
      case positional do
        [id | _] -> id
        [] -> Mix.raise("usage: mix symphony.plan_retry TASK_ID --graph PATH")
      end

    case Graph.load(graph_path) do
      {:ok, graph} ->
        case Graph.retry_task(graph, task_id) do
          {:ok, updated} ->
            :ok = Graph.write(updated, graph_path)
            Mix.shell().info("Retried #{task_id} — moved to pending, failure history preserved")

          {:error, {:task_not_found, id}} ->
            Mix.raise("task #{id} not found in graph")

          {:error, {:not_rework, id, status}} ->
            Mix.raise("task #{id} is not in rework (current: #{status})")
        end

      {:error, reason} ->
        Mix.raise("failed to load graph: #{inspect(reason)}")
    end
  end
end
