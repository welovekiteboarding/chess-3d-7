defmodule Mix.Tasks.Symphony.ServiceRestart do
  use Mix.Task

  @shortdoc "Restart the symphony operate launchd service (stop then start)"

  @impl true
  def run(args) do
    Mix.Tasks.Symphony.ServiceStop.run(args)
    Mix.Tasks.Symphony.ServiceStart.run(args)
  end
end
