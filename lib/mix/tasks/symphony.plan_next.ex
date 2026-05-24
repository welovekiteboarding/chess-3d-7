defmodule Mix.Tasks.Symphony.PlanNext do
  use Mix.Task

  alias Symphony1.Planning.{Feedback, Graph, Materializer, Status}
  alias Symphony1.RuntimeConfig

  @shortdoc "Sync outcomes, show status, materialize the next ready wave"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_next --graph PATH --team-key KEY")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_next --graph PATH --team-key KEY")
        key -> key
      end

    linear_config =
      case RuntimeConfig.linear_config(team_key) do
        {:ok, config} -> config
        {:error, :missing_linear_api_key} -> Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    issue_fetcher = Application.get_env(:symphony_1, :plan_sync_issue_fetcher)
    issue_creator = Application.get_env(:symphony_1, :plan_materializer_issue_creator)

    sync_opts = if issue_fetcher, do: [issue_fetcher: issue_fetcher], else: []
    mat_opts = if issue_creator, do: [issue_creator: issue_creator], else: []

    # Step 1: Load graph
    graph =
      case Graph.load(graph_path) do
        {:ok, g} -> g
        {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
      end

    # Step 2: Sync
    graph =
      case Feedback.sync(graph, linear_config, sync_opts) do
        {:ok, result} ->
          if result.updated != [] do
            :ok = Graph.write(result.graph, graph_path)
            Mix.shell().info("Synced #{length(result.updated)} task(s)")
          end

          result.graph

        {:error, reason} ->
          Mix.raise("sync failed: #{inspect(reason)}")
      end

    # Step 3: Status
    summary = Status.summarize(graph)
    Mix.shell().info(Status.format(summary))

    # Step 4: Materialize (only if there are ready tasks)
    if summary.ready != [] do
      case Materializer.materialize(graph, linear_config, mat_opts) do
        {:ok, result} ->
          :ok = Graph.write(result.graph, graph_path)

          Mix.shell().info(
            "Materialized #{length(result.materialized)} task(s)"
          )

        {:error, error} ->
          :ok = Graph.write(error.graph, graph_path)

          Mix.shell().info(
            "Partial: materialized #{length(error.materialized)} task(s) before failure"
          )

          Mix.raise(
            "materialization failed on task #{error.failed_task_id}: #{inspect(error.reason)}"
          )
      end
    else
      Mix.shell().info("No ready tasks to materialize")
    end
  end
end
