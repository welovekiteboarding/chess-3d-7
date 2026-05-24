defmodule Mix.Tasks.Symphony.Setup do
  use Mix.Task

  alias Symphony1.Project.Setup

  @shortdoc "Initialize and run project setup from the scaffold intent manifest"

  @impl true
  def run(_args) do
    case Setup.run() do
      {:ok, _state} ->
        Mix.shell().info("Setup state initialized")

      {:error, reason} ->
        Mix.raise("setup failed: #{inspect(reason)}")
    end
  end
end
