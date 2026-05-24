defmodule Symphony1.Core.QueueScheduler do
  defstruct active_runs: %{}, launcher: nil, max_concurrent_agents: 1, error_reporter: nil

  @type t :: %__MODULE__{
          active_runs: %{reference() => %{task: Task.t(), metadata: map()}},
          launcher: (map() -> {:ok, Task.t()} | {:ok, Task.t(), map()} | :none | {:error, term()}),
          max_concurrent_agents: pos_integer(),
          error_reporter: (term() -> term())
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      active_runs: %{},
      launcher: Keyword.fetch!(opts, :launcher),
      max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 1),
      error_reporter: Keyword.get(opts, :error_reporter, fn _event -> :ok end)
    }
  end

  @spec drain_once(t(), map()) :: t()
  def drain_once(%__MODULE__{} = state, attrs) do
    state = prune_completed_runs(state)
    open_slots = max(state.max_concurrent_agents - map_size(state.active_runs), 0)

    if open_slots == 0 do
      state
    else
      Enum.reduce_while(1..open_slots, state, fn _, acc ->
        case acc.launcher.(attrs) do
          {:ok, %Task{} = task} ->
            entry = %{task: task, metadata: %{}}
            {:cont, %{acc | active_runs: Map.put(acc.active_runs, task.ref, entry)}}

          {:ok, %Task{} = task, metadata} when is_map(metadata) ->
            entry = %{task: task, metadata: metadata}
            {:cont, %{acc | active_runs: Map.put(acc.active_runs, task.ref, entry)}}

          :none ->
            {:halt, acc}

          {:error, reason} ->
            acc.error_reporter.({:launch_failed, reason, attrs})
            {:halt, acc}
        end
      end)
    end
  end

  defp prune_completed_runs(%__MODULE__{} = state) do
    active_runs =
      state.active_runs
      |> Enum.reject(fn {_ref, entry} -> entry.task.pid == nil or not Process.alive?(entry.task.pid) end)
      |> Map.new()

    %{state | active_runs: active_runs}
  end
end
