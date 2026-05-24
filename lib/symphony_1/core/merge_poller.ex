defmodule Symphony1.Core.MergePoller do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      merge_attrs: Keyword.fetch!(opts, :merge_attrs),
      merge_fun: Keyword.get(opts, :merge_fun, &Symphony1.MergeRuntime.run/1),
      result_reporter: Keyword.get(opts, :result_reporter, fn _event -> :ok end)
    }

    send(self(), :merge)
    {:ok, state}
  end

  @impl true
  def handle_info(:merge, state) do
    result =
      state.merge_fun.(
        once: true,
        cwd: state.merge_attrs.workspace
      )

    report_merge_result(state.result_reporter, result)
    schedule_next_tick(state.interval_ms)
    {:noreply, state}
  end

  defp report_merge_result(reporter, {:error, _reason} = result), do: reporter.({:merge_failed, result})
  defp report_merge_result(reporter, result), do: reporter.({:merge_completed, result})

  defp schedule_next_tick(interval_ms) do
    Process.send_after(self(), :merge, interval_ms)
  end
end
