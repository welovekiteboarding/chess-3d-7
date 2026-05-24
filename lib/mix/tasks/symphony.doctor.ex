defmodule Mix.Tasks.Symphony.Doctor do
  use Mix.Task

  alias Symphony1.Project.Doctor

  @shortdoc "Check whether this machine is ready for local and live Symphony work"
  @usage "usage: mix symphony.doctor"

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [])

    if opts != [] or positional != [] or invalid != [] do
      Mix.raise(@usage)
    end

    checks = doctor_checks()
    counts = count_statuses(checks)

    lines =
      [
        "Symphony Doctor",
        ""
      ] ++
        Enum.map(checks, &format_check/1) ++
        [
          "",
          "Summary: #{counts.pass} pass, #{counts.warn} warn, #{counts.fail} fail",
          summary_line(counts),
          "Local tests can run when all required local checks pass.",
          "Live Linear/Codex/GitHub automation needs the live-runtime checks too."
        ]

    Mix.shell().info(Enum.join(lines, "\n"))
  end

  defp doctor_checks do
    case Application.get_env(:symphony_1, :doctor_checks) do
      nil -> Doctor.checks()
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp format_check(%{status: status, label: label, detail: detail}) do
    "#{status |> Atom.to_string() |> String.upcase()} #{label}: #{detail}"
  end

  defp count_statuses(checks) do
    Enum.reduce(checks, %{pass: 0, warn: 0, fail: 0}, fn %{status: status}, acc ->
      Map.update!(acc, status, &(&1 + 1))
    end)
  end

  defp summary_line(%{fail: 0}), do: "Doctor result: ready for local development."
  defp summary_line(_counts), do: "Doctor result: fix FAIL items first, then review WARN items for live runs."
end
