defmodule Mix.Tasks.Symphony.ServiceStatus do
  use Mix.Task

  alias Symphony1.Service.Launchd

  @shortdoc "Show status of the symphony operate launchd service"

  @impl true
  def run(_args) do
    runner = launchctl_runner()
    label = Launchd.label()
    installed_plist_path = installed_plist_path()

    loaded =
      case runner.("launchctl", ["print", "gui/#{uid()}/#{label}"]) do
        {_output, 0} -> true
        {_output, _status} -> false
      end

    Mix.shell().info("Service: #{label}")
    Mix.shell().info("Plist: #{installed_plist_path}")

    if File.exists?(installed_plist_path) do
      content = File.read!(installed_plist_path)
      config = Launchd.parse_plist(content)

      Mix.shell().info("Stdout: #{config.stdout_log || "unknown"}")
      Mix.shell().info("Stderr: #{config.stderr_log || "unknown"}")

      command =
        if config.graph_path && config.team_key do
          "mix symphony.operate --graph #{config.graph_path} --team-key #{config.team_key}"
        else
          "mix symphony.operate (see plist for args)"
        end

      Mix.shell().info("Command: #{command}")
    else
      Mix.shell().info("Stdout: unknown (plist not installed)")
      Mix.shell().info("Stderr: unknown (plist not installed)")
      Mix.shell().info("Command: mix symphony.operate (plist not installed at #{installed_plist_path})")
    end

    Mix.shell().info("Status: #{if loaded, do: "loaded", else: "not loaded"}")
  end

  defp installed_plist_path do
    Application.get_env(:symphony_1, :service_installed_plist_path, Launchd.plist_path())
  end

  defp launchctl_runner do
    Application.get_env(:symphony_1, :service_launchctl_runner, &System.cmd/2)
  end

  defp uid, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim()
end
