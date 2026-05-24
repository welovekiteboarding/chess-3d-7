defmodule Symphony1.Application do
  use Application
  require Logger
  alias Symphony1.Core.{MergePoller, Policy, QueueLauncher, QueuePoller, QueueScheduler}

  @impl true
  def start(_type, _args) do
    children =
      [queue_poller_child(), merge_poller_child()]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Symphony1.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def queue_poller_child do
    runtime = Application.get_env(:symphony_1, :queue_runtime, %{})

    if Map.get(runtime, :enabled, false) do
      run_attrs = Map.fetch!(runtime, :run_attrs)
      workflow_path = Map.fetch!(run_attrs, :workflow_path)
      interval_ms = Map.get(runtime, :interval_ms, 1_000)

      {:ok, workflow} = Policy.load_workflow_config(workflow_path)

      queue_scheduler =
        QueueScheduler.new(
          max_concurrent_agents: get_in(workflow, ["agent", "max_concurrent_agents"]) || 1,
          launcher: &QueueLauncher.launch/1,
          error_reporter: &report_queue_scheduler_event/1
        )

      {QueuePoller,
       interval_ms: interval_ms,
       queue_scheduler: queue_scheduler,
       result_reporter: &report_queue_poller_event/1,
       run_attrs: run_attrs}
    end
  end

  def merge_poller_child do
    runtime = Application.get_env(:symphony_1, :merge_runtime, %{})

    if Map.get(runtime, :enabled, false) do
      merge_attrs = Map.fetch!(runtime, :merge_attrs)
      interval_ms = Map.get(runtime, :interval_ms, 1_000)

      {MergePoller,
       interval_ms: interval_ms,
       merge_attrs: merge_attrs,
       result_reporter: &report_merge_poller_event/1}
    end
  end

  defp report_queue_scheduler_event({:launch_failed, reason, attrs}) do
    Logger.warning("symphony runtime: queue launch failed reason=#{inspect(reason)} attrs=#{inspect(attrs)}")
  end

  defp report_queue_scheduler_event(event) do
    Logger.info("symphony runtime: queue scheduler event=#{inspect(event)}")
  end

  defp report_queue_poller_event({:run_finished, _ref, result, metadata}) do
    Logger.info(
      "symphony runtime: queue run finished issue=#{inspect(Map.get(metadata, :issue_identifier))} result=#{inspect(result)}"
    )
  end

  defp report_queue_poller_event({:run_down, _ref, reason, metadata}) do
    Logger.warning(
      "symphony runtime: queue run down issue=#{inspect(Map.get(metadata, :issue_identifier))} reason=#{inspect(reason)}"
    )
  end

  defp report_queue_poller_event(event) do
    Logger.info("symphony runtime: queue poller event=#{inspect(event)}")
  end

  defp report_merge_poller_event({:merge_failed, result}) do
    Logger.warning("symphony runtime: merge poll failed result=#{inspect(result)}")
  end

  defp report_merge_poller_event({:merge_completed, result}) do
    Logger.info("symphony runtime: merge poll completed result=#{inspect(result)}")
  end

  defp report_merge_poller_event(event) do
    Logger.info("symphony runtime: merge poller event=#{inspect(event)}")
  end
end
