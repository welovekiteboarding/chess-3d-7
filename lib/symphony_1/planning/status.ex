defmodule Symphony1.Planning.Status do
  @moduledoc """
  Builds an operator-facing summary from the current planning graph.

  Partitions tasks by status and readiness using the existing Batcher,
  and includes Linear issue identifiers where mappings exist.
  """

  alias Symphony1.Planning.{Batcher, Graph}

  @type task_entry :: %{
          id: String.t(),
          title: String.t(),
          linear: String.t() | nil,
          last_failure: Graph.LastFailure.t() | nil,
          kind: String.t() | nil,
          has_validation: boolean()
        }

  @type summary :: %{
          total: non_neg_integer(),
          ready: [task_entry()],
          blocked: [task_entry()],
          done: [task_entry()],
          in_progress: [task_entry()],
          rework: [task_entry()]
        }

  @spec summarize(Graph.t()) :: summary()
  def summarize(%Graph{} = graph) do
    batch = Batcher.compute(graph)
    task_map = Map.new(graph.tasks, fn t -> {t.id, t} end)

    %{
      total: length(graph.tasks),
      ready: to_entries(batch.ready, task_map),
      blocked: to_entries(batch.blocked, task_map),
      done: to_entries(batch.done, task_map),
      in_progress: to_entries(batch.in_progress, task_map),
      rework: to_entries(batch.rework, task_map)
    }
  end

  @spec format(summary(), map()) :: String.t()
  def format(summary, findings \\ %{}) do
    sections = [
      format_section("Ready", summary.ready),
      format_section("In Progress", summary.in_progress, findings),
      format_section("Blocked", summary.blocked),
      format_section("Rework", summary.rework),
      format_section("Done", summary.done)
    ]

    body = Enum.join(sections, "\n")
    "#{body}\n#{summary.total} total"
  end

  defp to_entries(ids, task_map) do
    Enum.map(ids, fn id ->
      task = Map.fetch!(task_map, id)

      %{
        id: task.id,
        title: task.title,
        linear: task.materialization.linear_issue_identifier,
        last_failure: task.last_failure,
        kind: task.kind,
        has_validation: task.validation != nil && task.validation.commands != []
      }
    end)
  end

  defp format_section(label, entries, findings \\ %{}) do
    header = "#{label} (#{length(entries)})"

    if entries == [] do
      header
    else
      lines = Enum.map(entries, &format_entry(&1, findings))
      Enum.join([header | lines], "\n")
    end
  end

  defp format_entry(e, findings) do
    linear_suffix = if e.linear, do: " [#{e.linear}]", else: ""
    retry_suffix = format_retry(e.last_failure)
    context_suffix = format_context(e.kind, e.has_validation)
    stale_suffix = format_stale(Map.get(findings, e.id))
    "  #{e.id}: #{e.title}#{linear_suffix}#{retry_suffix}#{context_suffix}#{stale_suffix}"
  end

  defp format_stale(nil), do: ""
  defp format_stale(outcome), do: " [stale: #{outcome}]"

  defp format_context(nil, _), do: ""
  defp format_context(kind, true), do: " {#{kind}, validated}"
  defp format_context(kind, _), do: " {#{kind}}"

  defp format_retry(nil), do: ""

  defp format_retry(lf) do
    parts =
      [
        if(lf.linear_issue_identifier, do: "prev: #{lf.linear_issue_identifier}"),
        if(lf.category, do: "category: #{lf.category}"),
        if(lf.stage, do: "stage: #{lf.stage}"),
        if(lf.reason, do: "reason: #{lf.reason}")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      ""
    else
      " (retry, #{Enum.join(parts, ", ")})"
    end
  end
end
