defmodule Symphony1.Core.QueueLauncher do
  alias Symphony1.Core.RunCoordinator

  @spec launch(map()) :: {:ok, Task.t(), %{issue_identifier: String.t()}} | :none | {:error, term()}
  def launch(attrs) do
    progress_reporter = Map.get(attrs, :progress_reporter, fn _message -> :ok end)

    with {:ok, run} <- RunCoordinator.run_issue(attrs) do
      progress_reporter.("Claimed #{run.issue.identifier} -> #{run.issue.state}")
      {:ok,
       Task.async(fn -> RunCoordinator.finish_claimed_issue(run, attrs) end),
       %{issue_identifier: run.issue.identifier}}
    end
  end
end
