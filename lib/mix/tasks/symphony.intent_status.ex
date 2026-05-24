defmodule Mix.Tasks.Symphony.IntentStatus do
  use Mix.Task

  alias Symphony1.Intent.Loader

  @shortdoc "Validate and display intent goal document status"

  @default_goal_path "planning/goals/GOAL.md"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [goal: :string])

    if invalid != [] or positional != [] do
      Mix.raise("usage: mix symphony.intent_status [--goal PATH]")
    end

    goal_path = Keyword.get(opts, :goal, @default_goal_path)

    case Loader.load(goal_path) do
      {:ok, intent} ->
        sections =
          ["# Goal" | Map.keys(intent.sections)]
          |> Enum.sort_by(&section_order/1)

        lines = [
          "Intent: valid",
          "Path: #{intent.path}",
          "Sections:"
          | Enum.map(sections, fn h -> "- #{h}" end)
        ]

        Mix.shell().info(Enum.join(lines, "\n"))

      {:error, reason} ->
        Mix.raise(format_error(goal_path, reason))
    end
  end

  @section_order ~w(
    #\ Goal
    ##\ Project\ Mission
    ##\ Current\ Active\ Focus
    ##\ Hard\ Constraints
    ##\ Strategic\ Sequencing\ Guidance
    ##\ Out\ Of\ Scope\ For\ Now
    ##\ Success\ Signals
  )

  defp section_order(heading) do
    Enum.find_index(@section_order, &(&1 == heading)) || 999
  end

  defp format_error(path, {:missing_file, _}),
    do: "Intent: invalid\nPath: #{path}\nError: missing file"

  defp format_error(path, {:missing_heading, heading}),
    do: "Intent: invalid\nPath: #{path}\nError: missing heading #{heading}"

  defp format_error(path, {:duplicate_heading, heading}),
    do: "Intent: invalid\nPath: #{path}\nError: duplicate heading #{heading}"

  defp format_error(path, {:empty_section, heading}),
    do: "Intent: invalid\nPath: #{path}\nError: empty section #{heading}"

  defp format_error(path, reason),
    do: "Intent: invalid\nPath: #{path}\nError: #{inspect(reason)}"
end
