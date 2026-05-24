defmodule Mix.Tasks.Symphony.ReconcileReview do
  use Mix.Task

  alias Symphony1.ReviewReconciliationRuntime
  alias Symphony1.RuntimeConfig

  @shortdoc "Reconcile orphaned Human Review issues based on graph truth"
  @usage "usage: mix symphony.reconcile_review --once --graph PATH --team-key KEY"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [once: :boolean, graph: :string, team_key: :string]
      )

    graph_path = Keyword.get(opts, :graph)
    team_key = Keyword.get(opts, :team_key)
    once = Keyword.get(opts, :once)

    if positional != [] or invalid != [] or once != true or graph_path == nil or team_key == nil do
      Mix.raise(@usage)
    end

    config_loader =
      Application.get_env(
        :symphony_1,
        :reconcile_review_linear_config_loader,
        &RuntimeConfig.linear_config!/1
      )

    linear_config = config_loader.(team_key)

    runner = Application.get_env(:symphony_1, :reconcile_review_runner, &ReviewReconciliationRuntime.run/1)

    case runner.(once: true, graph_path: graph_path, linear_config: linear_config) do
      {:ok, %{results: []}} ->
        Mix.shell().info("No orphaned Human Review issues found")

      {:ok, %{results: results}} ->
        Enum.each(results, &format_result/1)

      {:error, reason} ->
        Mix.raise("reconciliation failed: #{inspect(reason)}")
    end
  end

  defp format_result(%{outcome: "skipped", reason: reason} = result) do
    Mix.shell().info("#{result.issue_identifier}: skipped (#{reason})")
  end

  defp format_result(%{outcome: "reconciled"} = result) do
    Mix.shell().info("#{result.issue_identifier}: reconciled -> #{result.target_state} (task: #{result.task_id})")
  end
end
