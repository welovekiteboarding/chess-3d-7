defmodule Mix.Tasks.Symphony.PlanStatus do
  use Mix.Task

  alias Symphony1.Planning.{Graph, Status}

  @shortdoc "Print the current planning graph status"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_status --graph PATH")
        path -> path
      end

    case Graph.load(graph_path) do
      {:ok, graph} ->
        summary = Status.summarize(graph)
        Mix.shell().info(Status.format(summary))

      {:error, reason} ->
        Mix.raise("failed to load graph: #{inspect(reason)}")
    end
  end
end
