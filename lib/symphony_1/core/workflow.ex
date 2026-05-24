defmodule Symphony1.Core.Workflow do
  @issue_states [
    "Todo",
    "In Progress",
    "Finalizing",
    "Human Review",
    "Rework",
    "Merging",
    "Done"
  ]

  def issue_states do
    @issue_states
  end

  @allowed_transitions %{
    "Todo" => MapSet.new(["In Progress"]),
    "In Progress" => MapSet.new(["Finalizing", "Rework"]),
    "Finalizing" => MapSet.new(["Human Review", "Rework"]),
    "Human Review" => MapSet.new(["Rework", "Merging"]),
    "Rework" => MapSet.new(["In Progress"]),
    "Merging" => MapSet.new(["Done"]),
    "Done" => MapSet.new()
  }

  def validate_transition(from, to) do
    allowed = Map.get(@allowed_transitions, from, MapSet.new())

    if MapSet.member?(allowed, to) do
      :ok
    else
      {:error, {:invalid_transition, from, to}}
    end
  end
end
