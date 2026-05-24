defmodule Symphony1.Planning.Validator do
  @moduledoc """
  Read-only planning validation boundary for on-disk graph files.
  """

  alias Symphony1.Planning.Graph

  @spec validate_file(String.t()) :: :ok | {:error, term()}
  def validate_file(path) do
    with {:ok, graph} <- Graph.load(path),
         :ok <- Graph.validate(graph),
         :ok <- validate_task_admissions(graph.tasks) do
      :ok
    end
  end

  defp validate_task_admissions(tasks) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      case Graph.validate_task_admission(task) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
