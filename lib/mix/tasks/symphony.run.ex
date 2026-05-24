defmodule Mix.Tasks.Symphony.Run do
  use Mix.Task

  alias Symphony1.Runtime

  @shortdoc "Run the Symphony queue from the current repo"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [once: :boolean, interval_ms: :integer]
      )

    runtime_runner = Application.get_env(:symphony_1, :runtime_runner, &Runtime.run/1)
    once? = Keyword.get(opts, :once, false)
    progress_reporter = build_progress_reporter(once?)

    case runtime_runner.(
           once: once?,
           interval_ms: Keyword.get(opts, :interval_ms, 1_000),
           progress_reporter: progress_reporter
         ) do
      {:ok, result} ->
        emit_runtime_message(once?, result)
        maybe_wait_forever(once?)

      {:error, reason} ->
        Mix.raise("run failed: #{inspect(reason)}")
    end
  end

  defp emit_runtime_message(true, %{results: []}) do
    Mix.shell().info("No claimable issues found")
  end

  defp emit_runtime_message(true, %{results: results}) do
    Enum.each(results, fn result ->
      issue_identifier = get_in(result, [:issue, :identifier]) || "unknown-issue"
      issue_state = get_in(result, [:issue, :state]) || "unknown-state"
      pull_request_url = get_in(result, [:pull_request, :url]) || "no-pr"

      Mix.shell().info("Completed #{issue_identifier} -> #{issue_state} (#{pull_request_url})")
    end)
  end

  defp emit_runtime_message(false, _result) do
    Mix.shell().info("Symphony runtime started")
  end

  defp build_progress_reporter(true) do
    fn message -> Mix.shell().info(message) end
  end

  defp build_progress_reporter(false) do
    fn _message -> :ok end
  end

  defp maybe_wait_forever(true), do: :ok

  defp maybe_wait_forever(false) do
    waiter =
      Application.get_env(
        :symphony_1,
        :runtime_waiter,
        fn ->
          receive do
          end
        end
      )

    waiter.()
  end
end
