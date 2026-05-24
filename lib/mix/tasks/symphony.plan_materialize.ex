defmodule Mix.Tasks.Symphony.PlanMaterialize do
  use Mix.Task

  alias Symphony1.Planning.{Graph, Materializer}
  alias Symphony1.RuntimeConfig

  @shortdoc "Materialize the ready batch from a planning graph into Linear"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_materialize --graph PATH --team-key KEY")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_materialize --graph PATH --team-key KEY")
        key -> key
      end

    issue_creator =
      Application.get_env(
        :symphony_1,
        :plan_materializer_issue_creator,
        &default_issue_creator/2
      )

    graph_writer =
      Application.get_env(
        :symphony_1,
        :plan_materializer_graph_writer,
        &Graph.write/2
      )

    linear_config =
      case RuntimeConfig.linear_config(team_key) do
        {:ok, config} -> config
        {:error, :missing_linear_api_key} -> Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    case Graph.load(graph_path) do
      {:ok, graph} ->
        case Materializer.materialize(graph, linear_config, issue_creator: issue_creator) do
          {:ok, result} ->
            persist_graph!(graph_writer, result.graph, graph_path, graph_path, result.materialized, result.skipped, nil)

            Mix.shell().info(
              "Materialized #{length(result.materialized)} task(s), skipped #{length(result.skipped)}"
            )

          {:error, error} ->
            persist_graph!(
              graph_writer,
              error.graph,
              graph_path,
              graph_path,
              error.materialized,
              error.skipped,
              %{failed_task_id: error.failed_task_id, reason: error.reason}
            )

            Mix.shell().info(
              "Partial: materialized #{length(error.materialized)} task(s) before failure"
            )

            Mix.raise(
              "materialization failed on task #{error.failed_task_id}: #{inspect(error.reason)}"
            )
        end

      {:error, reason} ->
        Mix.raise("failed to load graph: #{inspect(reason)}")
    end
  end

  defp default_issue_creator(config, attrs) do
    Symphony1.Core.Linear.create_issue(config, attrs)
  end

  defp persist_graph!(graph_writer, graph, write_path, graph_path, materialized, skipped, failure_context) do
    case graph_writer.(graph, write_path) do
      :ok ->
        :ok

      {:error, reason} ->
        raise_graph_write_failure!(graph_path, reason, materialized, skipped, failure_context)
    end
  end

  defp raise_graph_write_failure!(graph_path, reason, materialized, skipped, failure_context) do
    recovery_path = write_recovery_snapshot(graph_path, reason, materialized, skipped, failure_context)

    details =
      materialized
      |> Enum.map(& &1.linear_issue_identifier)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    materialized_suffix =
      if details == "" do
        ""
      else
        ". Materialized issues: #{details}"
      end

    Mix.raise(
      "materialization graph write failed: #{inspect(reason)}. " <>
        "A recovery snapshot written to #{recovery_path}#{materialized_suffix}"
    )
  end

  defp write_recovery_snapshot(graph_path, reason, materialized, skipped, failure_context) do
    recovery_dir =
      Application.get_env(
        :symphony_1,
        :plan_materializer_recovery_dir,
        System.tmp_dir!()
      )

    File.mkdir_p!(recovery_dir)

    recovery_path =
      Path.join(
        recovery_dir,
        "symphony-plan-materialize-recovery-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    payload = %{
      graph_path: graph_path,
      write_error: inspect(reason),
      materialized: materialized,
      skipped: skipped,
      failure_context: failure_context
    }

    File.write!(recovery_path, Jason.encode!(payload, pretty: true))
    recovery_path
  end
end
