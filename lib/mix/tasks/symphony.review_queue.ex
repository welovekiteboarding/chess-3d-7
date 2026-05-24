defmodule Mix.Tasks.Symphony.ReviewQueue do
  use Mix.Task

  alias Symphony1.ReviewReconciliationRuntime
  alias Symphony1.RuntimeConfig

  @shortdoc "Print a deterministic Human Review queue summary"
  @usage "usage: mix symphony.review_queue --graph PATH --team-key KEY"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path = Keyword.get(opts, :graph)
    team_key = Keyword.get(opts, :team_key)

    if positional != [] or invalid != [] or graph_path == nil or team_key == nil do
      Mix.raise(@usage)
    end

    linear_config =
      case RuntimeConfig.linear_config(team_key) do
        {:ok, config} -> config
        {:error, :missing_linear_api_key} -> Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    runner = Application.get_env(:symphony_1, :review_queue_runner, &ReviewReconciliationRuntime.summarize/1)

    case runner.(graph_path: graph_path, linear_config: linear_config) do
      {:ok, %{counts: counts}} ->
        Mix.shell().info(format_counts(counts))

      {:error, reason} ->
        Mix.raise("review queue failed: #{inspect(reason)}")
    end
  end

  defp format_counts(counts) do
    "Human Review queue: active=#{Map.fetch!(counts, :active)} " <>
      "orphaned=#{Map.fetch!(counts, :orphaned)} " <>
      "unmapped=#{Map.fetch!(counts, :unmapped)} " <>
      "total=#{Map.fetch!(counts, :total)}"
  end
end
