defmodule Mix.Tasks.Symphony.PlanValidate do
  use Mix.Task

  alias Symphony1.Planning.Validator

  @shortdoc "Validate a planning graph file"
  @usage "usage: mix symphony.plan_validate --graph PATH"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [graph: :string]
      )

    if positional != [] or invalid != [] do
      Mix.raise(@usage)
    end

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise(@usage)
        path -> path
      end

    case Validator.validate_file(graph_path) do
      :ok ->
        Mix.shell().info("Plan: valid")
        Mix.shell().info("Path: #{graph_path}")

      {:error, reason} ->
        Mix.raise("""
        Plan: invalid
        Path: #{graph_path}
        Error: #{inspect(reason)}
        """)
    end
  end
end
