defmodule Mix.Tasks.Symphony.ServiceStop do
  use Mix.Task

  alias Symphony1.Service.Launchd

  @shortdoc "Stop the symphony operate launchd service"

  @impl true
  def run(_args) do
    runner = launchctl_runner()
    uid = uid()
    plist_path = Launchd.plist_path()

    case runner.("launchctl", ["bootout", "gui/#{uid}", plist_path]) do
      {_output, 0} ->
        Mix.shell().info("service_stop: stopped #{Launchd.label()}")

      {output, _status} ->
        Mix.raise("service_stop: failed — #{String.trim(output)}")
    end
  end

  defp launchctl_runner do
    Application.get_env(:symphony_1, :service_launchctl_runner, &System.cmd/2)
  end

  defp uid, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim()
end
