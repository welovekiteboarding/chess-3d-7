defmodule Symphony1.Planning.Materializer do
  @moduledoc """
  Materializes the ready batch from a planning graph into Linear issues.

  For each ready task that is not already materialized, creates a Linear
  issue and writes the mapping (linear_issue_id, linear_issue_identifier)
  back into the graph. Already-materialized tasks are skipped.

  The updated graph (with mappings) is returned so the caller can persist it.
  """

  require Logger

  alias Symphony1.Planning.{Batcher, Graph}

  @type materialized_entry :: %{
          task_id: String.t(),
          linear_issue_id: String.t(),
          linear_issue_identifier: String.t()
        }

  @type result :: %{
          graph: Graph.t(),
          materialized: [materialized_entry()],
          skipped: [String.t()]
        }

  @type error_result :: %{
          graph: Graph.t(),
          materialized: [materialized_entry()],
          skipped: [String.t()],
          failed_task_id: String.t(),
          reason: term()
        }

  @spec materialize(Graph.t(), map(), keyword()) :: {:ok, result()} | {:error, error_result()}
  def materialize(%Graph{} = graph, linear_config, opts \\ []) do
    issue_creator = Keyword.get(opts, :issue_creator, &default_issue_creator/2)

    batch = Batcher.compute(graph)
    {to_create, skipped} = partition_ready(batch.ready_tasks)
    skipped_ids = Enum.map(skipped, & &1.id)

    with :ok <- prevalidate_tasks(to_create),
         {:ok, graph, materialized} <- create_issues(to_create, graph, linear_config, issue_creator) do
      {:ok, %{graph: graph, materialized: materialized, skipped: skipped_ids}}
    else
      {:error, failed_task_id, reason} ->
        {:error,
         %{
           graph: graph,
           materialized: [],
            skipped: skipped_ids,
            failed_task_id: failed_task_id,
            reason: reason
         }}

      {:error, graph, materialized, failed_task_id, reason} ->
        {:error,
         %{
           graph: graph,
           materialized: materialized,
           skipped: skipped_ids,
           failed_task_id: failed_task_id,
           reason: reason
         }}
    end
  end

  defp partition_ready(ready_tasks) do
    Enum.split_with(ready_tasks, fn task ->
      not task.materialization.materialized
    end)
  end

  defp create_issues(tasks, graph, config, issue_creator) do
    Enum.reduce_while(tasks, {:ok, graph, []}, fn task, {:ok, g, results} ->
      case create_one(task, config, issue_creator) do
        {:ok, issue} ->
          Logger.info("symphony.materializer: created #{issue.identifier} for graph task #{task.id}")

          {:ok, updated_graph} =
            Graph.update_task(g, task.id, %{
              status: "in_progress",
              materialization: %{
                materialized: true,
                linear_issue_id: issue.id,
                linear_issue_identifier: issue.identifier
              }
            })

          result = %{
            task_id: task.id,
            linear_issue_id: issue.id,
            linear_issue_identifier: issue.identifier
          }

          {:cont, {:ok, updated_graph, results ++ [result]}}

        {:error, reason} ->
          Logger.warning("symphony.materializer: failed to create issue for #{task.id}: #{inspect(reason)}")
          {:halt, {:error, g, results, task.id, reason}}
      end
    end)
  end

  defp prevalidate_tasks(tasks) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      case Graph.validate_task_admission(task) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          Logger.warning("symphony.materializer: admission failed for #{task.id}: #{inspect(reason)}")
          {:halt, {:error, task.id, reason}}
      end
    end)
  end

  defp create_one(task, config, issue_creator) do
    attrs = %{
      "title" => task.title,
      "description" => build_description(task),
      "state" => "Todo"
    }

    issue_creator.(config, attrs)
  end

  defp build_description(task) do
    sections = [
      "Graph task: #{task.id}",
      if(task.kind, do: "Kind: #{task.kind}"),
      task.description,
      format_criteria(task.acceptance_criteria),
      format_scope(task.scope),
      format_validation(task.validation),
      format_last_failure(task.last_failure)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_criteria(nil), do: nil
  defp format_criteria([]), do: nil

  defp format_criteria(criteria) do
    lines = Enum.map(criteria, &("- #{&1}"))
    "Acceptance criteria:\n#{Enum.join(lines, "\n")}"
  end

  defp format_scope(nil), do: nil

  defp format_scope(%Graph.Scope{include: include, exclude: exclude}) do
    parts = []
    parts = if include != [], do: parts ++ ["In scope: #{Enum.join(include, ", ")}"], else: parts
    parts = if exclude != [], do: parts ++ ["Out of scope: #{Enum.join(exclude, ", ")}"], else: parts
    if parts == [], do: nil, else: Enum.join(parts, "\n")
  end

  defp format_validation(nil), do: nil

  defp format_validation(%Graph.Validation{commands: commands}) when commands != [] do
    "Validation: #{Enum.join(commands, ", ")}"
  end

  defp format_validation(_), do: nil

  defp format_last_failure(nil), do: nil

  defp format_last_failure(lf) do
    parts =
      [
        if(lf.linear_issue_identifier, do: "Issue: #{lf.linear_issue_identifier}"),
        if(lf.category, do: "Category: #{lf.category}"),
        if(lf.stage, do: "Stage: #{lf.stage}"),
        if(lf.reason, do: "Reason: #{lf.reason}")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      nil
    else
      "Previous attempt failed:\n#{Enum.join(parts, "\n")}"
    end
  end

  defp default_issue_creator(config, attrs) do
    Symphony1.Core.Linear.create_issue(config, attrs)
  end
end
