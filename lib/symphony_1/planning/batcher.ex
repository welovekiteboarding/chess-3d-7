defmodule Symphony1.Planning.Batcher do
  @moduledoc """
  Computes the ready batch from a planning graph.

  Takes a `Graph.t()` and returns a `Batch.t()` summary with tasks
  partitioned by status and readiness. Ready tasks are sorted by id
  for deterministic output.
  """

  alias Symphony1.Planning.Graph

  defmodule Batch do
    @moduledoc false

    @type t :: %__MODULE__{
            ready: [String.t()],
            blocked: [String.t()],
            done: [String.t()],
            in_progress: [String.t()],
            rework: [String.t()],
            ready_tasks: [Graph.Task.t()]
          }

    defstruct ready: [],
              blocked: [],
              done: [],
              in_progress: [],
              rework: [],
              ready_tasks: []
  end

  @spec compute(Graph.t()) :: Batch.t()
  def compute(%Graph{} = graph) do
    ready_tasks =
      graph
      |> Graph.ready_tasks()
      |> Enum.sort_by(& &1.id)

    ready_ids = MapSet.new(ready_tasks, & &1.id)

    {done, in_progress, rework, blocked} =
      Enum.reduce(graph.tasks, {[], [], [], []}, fn task, {d, ip, rw, bl} ->
        cond do
          task.status == "done" -> {[task.id | d], ip, rw, bl}
          task.status == "in_progress" -> {d, [task.id | ip], rw, bl}
          task.status == "rework" -> {d, ip, [task.id | rw], bl}
          MapSet.member?(ready_ids, task.id) -> {d, ip, rw, bl}
          true -> {d, ip, rw, [task.id | bl]}
        end
      end)

    %Batch{
      ready: Enum.map(ready_tasks, & &1.id),
      blocked: Enum.sort(Enum.reverse(blocked)),
      done: Enum.sort(Enum.reverse(done)),
      in_progress: Enum.sort(Enum.reverse(in_progress)),
      rework: Enum.sort(Enum.reverse(rework)),
      ready_tasks: ready_tasks
    }
  end
end
