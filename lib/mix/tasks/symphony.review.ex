defmodule Mix.Tasks.Symphony.Review do
  use Mix.Task

  alias Symphony1.ReviewRuntime

  @shortdoc "Review one Symphony pull request from Human Review"
  @usage "usage: mix symphony.review --once"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [once: :boolean]
      )

    if positional != [] or invalid != [] or Keyword.get(opts, :once) != true do
      Mix.raise(@usage)
    end

    cwd = File.cwd!()
    runtime_runner = Application.get_env(:symphony_1, :review_runtime_runner, &ReviewRuntime.run/1)

    case runtime_runner.(once: true, cwd: cwd) do
      {:ok, %{results: []}} ->
        Mix.shell().info("No reviewable issues found")

      {:ok, %{results: [result | _]}} ->
        case result.outcome do
          "approved" ->
            Mix.shell().info("Reviewed #{result.issue_identifier} -> approved")

          "changes_requested" ->
            Mix.shell().info("Reviewed #{result.issue_identifier} -> changes_requested")
        end

      {:error, reason} ->
        Mix.raise("review failed: #{inspect(reason)}")
    end
  end
end
