defmodule Symphony1.Core.QueuePoller do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    state = %{
      drain_fun: Keyword.get(opts, :drain_fun, &Symphony1.Core.QueueScheduler.drain_once/2),
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      queue_scheduler: Keyword.fetch!(opts, :queue_scheduler),
      result_reporter: Keyword.get(opts, :result_reporter, fn _event -> :ok end),
      run_attrs: Keyword.get(opts, :run_attrs, %{})
    }

    send(self(), :drain)
    {:ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    queue_scheduler = state.drain_fun.(state.queue_scheduler, state.run_attrs)
    schedule_next_tick(state.interval_ms)
    {:noreply, %{state | queue_scheduler: queue_scheduler}}
  end

  def handle_info({ref, result}, %{queue_scheduler: %{active_runs: active_runs}} = state) when is_reference(ref) do
    if entry = Map.get(active_runs, ref) do
      Process.demonitor(ref, [:flush])
      state.result_reporter.({:run_finished, ref, result, entry.metadata})
    end

    {:noreply, %{state | queue_scheduler: %{state.queue_scheduler | active_runs: Map.delete(active_runs, ref)}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{queue_scheduler: %{active_runs: active_runs}} = state)
      when is_reference(ref) do
    if entry = Map.get(active_runs, ref) do
      state.result_reporter.({:run_down, ref, reason, entry.metadata})
    end

    {:noreply, %{state | queue_scheduler: %{state.queue_scheduler | active_runs: Map.delete(active_runs, ref)}}}
  end

  defp schedule_next_tick(interval_ms) do
    Process.send_after(self(), :drain, interval_ms)
  end
end
