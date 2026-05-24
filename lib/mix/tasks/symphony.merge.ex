defmodule Mix.Tasks.Symphony.Merge do
  use Mix.Task

  alias Symphony1.MergeRuntime

  @shortdoc "Merge reviewed Symphony pull requests from the current repo"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [once: :boolean]
      )

    merge_runtime_runner =
      Application.get_env(:symphony_1, :merge_runtime_runner, &MergeRuntime.run/1)

    case merge_runtime_runner.(once: Keyword.get(opts, :once, false)) do
      {:ok, result} ->
        once? = Keyword.get(opts, :once, false)
        emit_merge_message(once?, result)
        maybe_wait_forever(once?)

      {:error, reason} ->
        Mix.raise("merge failed: #{inspect(reason)}")
    end
  end

  defp emit_merge_message(true, %{results: []}) do
    Mix.shell().info("No reviewable issues found")
  end

  defp emit_merge_message(true, %{results: results}) do
    Enum.each(results, fn result ->
      issue_identifier = get_in(result, [:issue, :identifier]) || "unknown-issue"
      issue_state = get_in(result, [:issue, :state]) || "unknown-state"
      pull_request_url = get_in(result, [:pull_request, :url]) || "no-pr"

      Mix.shell().info("Merged #{issue_identifier} -> #{issue_state} (#{pull_request_url})")
    end)
  end

  defp emit_merge_message(false, _result) do
    Mix.shell().info("Symphony merge runtime started")
  end

  defp maybe_wait_forever(true), do: :ok

  defp maybe_wait_forever(false) do
    waiter =
      Application.get_env(
        :symphony_1,
        :merge_runtime_waiter,
        fn ->
          receive do
          end
        end
      )

    waiter.()
  end
end
