defmodule Mix.Tasks.Symphony.PlanCycle do
  use Mix.Task

  alias Symphony1.Planning.{Feedback, Graph, Materializer, Status}
  alias Symphony1.RuntimeConfig

  @shortdoc "Run one full graph-driven happy-path cycle: sync -> materialize -> run -> review -> merge -> resync"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string, once: :boolean]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_cycle --graph PATH --team-key KEY --once")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_cycle --graph PATH --team-key KEY --once")
        key -> key
      end

    unless Keyword.get(opts, :once, false) do
      Mix.raise("--once is required in the current version of plan_cycle")
    end

    # Validate the graph path before touching live config so local input errors
    # remain testable without exported credentials.
    case Graph.load(graph_path) do
      {:ok, _graph} -> :ok
      {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
    end

    issue_fetcher = Application.get_env(:symphony_1, :plan_sync_issue_fetcher)
    issue_creator = Application.get_env(:symphony_1, :plan_materializer_issue_creator)

    sync_opts = if issue_fetcher, do: [issue_fetcher: issue_fetcher], else: []
    mat_opts = if issue_creator, do: [issue_creator: issue_creator], else: []

    config_loader =
      Application.get_env(
        :symphony_1,
        :plan_cycle_linear_config_loader,
        &RuntimeConfig.linear_config!/1
      )

    linear_config = config_loader.(team_key)

    run_cycle(graph_path, linear_config, sync_opts, mat_opts)
  end

  @doc """
  Runs one full happy-path cycle. Callable from other commands (e.g. operate).
  """
  def run_cycle(graph_path, linear_config, sync_opts \\ [], mat_opts \\ []) do
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
            Mix.shell().info("plan_cycle: synced #{length(result.updated)} task(s)")
          end

          result.graph

        {:error, reason} ->
          Mix.raise("plan_cycle: sync failed: #{inspect(reason)}")
      end

    # Step 3: Pre-cycle status
    summary = Status.summarize(graph)
    Mix.shell().info(Status.format(summary))

    # Step 4: Materialize (only if there are ready tasks)
    if summary.ready == [] do
      Mix.shell().info("plan_cycle: no ready work — stopping")
    else
      case Materializer.materialize(graph, linear_config, mat_opts) do
        {:ok, result} ->
          :ok = Graph.write(result.graph, graph_path)
          Mix.shell().info("plan_cycle: materialized #{length(result.materialized)} task(s)")

        {:error, error} ->
          :ok = Graph.write(error.graph, graph_path)

          Mix.raise(
            "plan_cycle: materialization failed on #{error.failed_task_id}: #{inspect(error.reason)}"
          )
      end

      # Step 5: Run once
      runtime_runner =
        Application.get_env(:symphony_1, :plan_cycle_runtime_runner, &Symphony1.Runtime.run/1)

      run_result =
        case runtime_runner.(once: true) do
          {:ok, result} ->
            Mix.shell().info("plan_cycle: run complete (#{length(result.results)} result(s))")
            result

          {:error, reason} ->
            Mix.raise("plan_cycle: run failed: #{inspect(reason)}")
        end

      # Step 6: Review once and merge once (only if run produced results)
      if run_result.results != [] do
        review_runner =
          Application.get_env(:symphony_1, :plan_cycle_review_runner, &Symphony1.ReviewRuntime.run/1)

        case review_runner.(once: true, cwd: File.cwd!()) do
          {:ok, result} ->
            Mix.shell().info("plan_cycle: review complete (#{length(result.results)} result(s))")

          {:error, reason} ->
            handle_review_failure(graph_path, linear_config, sync_opts, reason)
        end

        merge_runner =
          Application.get_env(:symphony_1, :plan_cycle_merge_runner, &Symphony1.MergeRuntime.run/1)

        case merge_runner.(once: true) do
          {:ok, result} ->
            Mix.shell().info("plan_cycle: merge complete (#{length(result.results)} result(s))")

          {:error, reason} ->
            Mix.raise("plan_cycle: merge failed: #{inspect(reason)}")
        end
      else
        Mix.shell().info("plan_cycle: run produced no results — skipping merge")
      end

      # Step 7: Final sync
      fresh_graph =
        case Graph.load(graph_path) do
          {:ok, g} -> g
          {:error, reason} -> Mix.raise("plan_cycle: final sync failed — could not reload graph: #{inspect(reason)}")
        end

      case Feedback.sync(fresh_graph, linear_config, sync_opts) do
        {:ok, result} ->
          if result.updated != [] do
            :ok = Graph.write(result.graph, graph_path)
            Mix.shell().info("plan_cycle: final sync updated #{length(result.updated)} task(s)")
          end

          # Step 8: Final status
          final_summary = Status.summarize(result.graph)
          Mix.shell().info(Status.format(final_summary))

        {:error, reason} ->
          Mix.raise("plan_cycle: final sync failed: #{inspect(reason)}")
      end
    end
  end

  defp handle_review_failure(graph_path, linear_config, sync_opts, reason) do
    case sync_graph(graph_path, linear_config, sync_opts) do
      {:ok, _graph} ->
        Mix.raise("plan_cycle: review failed: #{inspect(reason)}")

      {:error, sync_reason} ->
        Mix.raise(
          "plan_cycle: review failed: #{inspect(reason)} (recovery sync failed: #{inspect(sync_reason)})"
        )
    end
  end

  defp sync_graph(graph_path, linear_config, sync_opts) do
    with {:ok, fresh_graph} <- Graph.load(graph_path),
         {:ok, result} <- Feedback.sync(fresh_graph, linear_config, sync_opts) do
      if result.updated != [] do
        case Graph.write(result.graph, graph_path) do
          :ok -> {:ok, result.graph}
          {:error, reason} -> {:error, {:graph_write_failed, reason}}
        end
      else
        {:ok, result.graph}
      end
    end
  end
end
