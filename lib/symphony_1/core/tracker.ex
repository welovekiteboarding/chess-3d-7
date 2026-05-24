defmodule Symphony1.Core.Tracker do
  alias Symphony1.Core.Workflow

  @spec poll_eligible_issue([map()]) :: {:ok, map()} | :none
  def poll_eligible_issue(issues) do
    case Enum.find(issues, &(&1.state == "Todo")) do
      nil -> :none
      issue -> {:ok, issue}
    end
  end

  @spec transition_issue(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def transition_issue(issue, new_state) do
    with :ok <- Workflow.validate_transition(issue.state, new_state) do
      {:ok, %{issue | state: new_state}}
    end
  end
end
