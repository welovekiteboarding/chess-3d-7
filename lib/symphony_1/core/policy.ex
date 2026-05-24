defmodule Symphony1.Core.Policy do
  @type workflow_path :: String.t()

  @spec workflow_template_path() :: workflow_path()
  def workflow_template_path do
    "priv/workflows/WORKFLOW.example.md"
  end

  @spec load_workflow_config(workflow_path()) :: {:ok, map()} | {:error, term()}
  def load_workflow_config(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, front_matter} <- extract_front_matter(contents) do
      {:ok, parse_front_matter(front_matter)}
    end
  end

  defp extract_front_matter(contents) do
    case String.split(contents, ~r/^---\s*$/m, trim: true, parts: 3) do
      [front_matter, _body] -> {:ok, String.trim(front_matter)}
      _ -> {:error, :missing_front_matter}
    end
  end

  defp parse_front_matter(front_matter) do
    {config, _stack} =
      front_matter
      |> String.split("\n", trim: true)
      |> Enum.reduce({%{}, [{-2, %{}, nil}]}, fn line, {root, stack} ->
        indent = leading_spaces(line)
        trimmed = String.trim(line)

        [raw_key, raw_value] = String.split(trimmed, ":", parts: 2)
        key = String.trim(raw_key)
        value = String.trim(raw_value)

        stack = ascend_stack(stack, indent)

        case value do
          "" ->
            {updated_root, updated_stack} = put_nested(root, stack, key, %{}, indent)
            {updated_root, updated_stack}

          _ ->
            {put_nested_value(root, stack, key, cast_scalar(value)), stack}
        end
      end)

    config
  end

  defp leading_spaces(line) do
    line
    |> String.length()
    |> Kernel.-(String.length(String.trim_leading(line)))
  end

  defp ascend_stack([current | rest], indent) do
    if indent <= elem(current, 0) do
      ascend_stack(rest, indent)
    else
      [current | rest]
    end
  end

  defp ascend_stack([], _indent), do: []

  defp put_nested(root, stack, key, value, indent) do
    updated_root = put_nested_value(root, stack, key, value)
    updated_stack = [{indent, nested_map_at(updated_root, stack, key), key} | stack]
    {updated_root, updated_stack}
  end

  defp put_nested_value(root, [{_indent, _map, nil}], key, value) do
    Map.put(root, key, value)
  end

  defp put_nested_value(root, stack, key, value) do
    path =
      stack
      |> Enum.reverse()
      |> Enum.map(&elem(&1, 2))
      |> Enum.reject(&is_nil/1)

    update_in(root, Enum.map(path, &Access.key(&1, %{})), fn current ->
      Map.put(current || %{}, key, value)
    end)
  end

  defp nested_map_at(root, [{_indent, _map, nil}], key), do: Map.fetch!(root, key)

  defp nested_map_at(root, stack, key) do
    path =
      stack
      |> Enum.reverse()
      |> Enum.map(&elem(&1, 2))
      |> Enum.reject(&is_nil/1)
      |> Kernel.++([key])

    get_in(root, Enum.map(path, &Access.key(&1, %{})))
  end

  defp cast_scalar(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end
end
