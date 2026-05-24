defmodule Mix.Tasks.Symphony.PlanSync do
  use Mix.Task

  alias Symphony1.Planning.{Feedback, Graph}
  alias Symphony1.RuntimeConfig

  @shortdoc "Sync Linear issue outcomes back into the planning graph"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_sync --graph PATH --team-key KEY")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_sync --graph PATH --team-key KEY")
        key -> key
      end

    issue_fetcher =
      Application.get_env(:symphony_1, :plan_sync_issue_fetcher)

    linear_config =
      case RuntimeConfig.linear_config(team_key) do
        {:ok, config} -> config
        {:error, :missing_linear_api_key} -> Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    opts = if issue_fetcher, do: [issue_fetcher: issue_fetcher], else: []

    case Graph.load(graph_path) do
      {:ok, graph} ->
        case Feedback.sync(graph, linear_config, opts) do
          {:ok, result} ->
            :ok = Graph.write(result.graph, graph_path)

            Mix.shell().info(
              "Synced #{length(result.updated)} task(s)"
            )

          {:error, reason} ->
            Mix.raise("sync failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("failed to load graph: #{inspect(reason)}")
    end
  end
end
