defmodule Symphony1.Planning.ScopeCheck do
  @moduledoc """
  Pure diff-vs-scope evaluator for graph tasks.
  """

  alias Symphony1.Planning.Graph

  @type result :: %{
          status: :pass | :warn | :fail,
          in_scope: [String.t()],
          expanded: [String.t()],
          excluded: [String.t()]
        }

  @spec evaluate(Graph.Task.t(), [String.t()]) :: result()
  def evaluate(%Graph.Task{} = task, changed_files) when is_list(changed_files) do
    scope = task.scope

    cond do
      is_nil(scope) ->
        %{
          status: :pass,
          in_scope: changed_files,
          expanded: [],
          excluded: []
        }

      true ->
        included = scope.include || []
        excluded = scope.exclude || []

        excluded_files = Enum.filter(changed_files, &matches_any?(&1, excluded))

        expanded_files =
          Enum.filter(changed_files, fn path ->
            not matches_any?(path, excluded) and included != [] and not matches_any?(path, included)
          end)

        in_scope_files =
          Enum.filter(changed_files, fn path ->
            not matches_any?(path, excluded) and path not in expanded_files
          end)

        %{
          status: status_for(excluded_files, expanded_files),
          in_scope: in_scope_files,
          expanded: expanded_files,
          excluded: excluded_files
        }
    end
  end

  defp status_for([_ | _], _expanded), do: :fail
  defp status_for([], [_ | _]), do: :warn
  defp status_for([], []), do: :pass

  defp matches_any?(path, patterns) do
    Enum.any?(patterns, &matches_scope?(&1, path))
  end

  defp matches_scope?(pattern, path) do
    normalized = String.trim_trailing(pattern, "/")
    path == normalized or String.starts_with?(path, normalized <> "/")
  end
end
