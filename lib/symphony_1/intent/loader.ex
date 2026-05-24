defmodule Symphony1.Intent.Loader do
  @moduledoc """
  Pure loader and validator for the repo-local intent goal document.

  Reads a Markdown file from an explicit path, verifies the required section
  headings are present and non-empty, and returns a structured result.

  Does not parse semantic content, front matter, or generate graph tasks.
  """

  @required_headings [
    "# Goal",
    "## Project Mission",
    "## Current Active Focus",
    "## Hard Constraints",
    "## Strategic Sequencing Guidance",
    "## Out Of Scope For Now",
    "## Success Signals"
  ]

  @section_headings Enum.drop(@required_headings, 1)

  @doc """
  Load and validate a goal document from the given path.

  Returns `{:ok, %{path: path, sections: sections}}` where sections is a map
  from heading string (e.g. `"## Project Mission"`) to trimmed section body string.

  Returns `{:error, reason}` for:
  - `{:missing_file, path}` — file does not exist
  - `{:missing_heading, heading}` — a required heading is absent
  - `{:duplicate_heading, heading}` — a required heading appears more than once
  - `{:empty_section, heading}` — a required section contains only whitespace
  """
  def load(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:error, {:missing_file, path}}

      {:ok, content} ->
        with :ok <- check_headings(content),
             :ok <- check_duplicates(content),
             {:ok, sections} <- parse_sections(content) do
          {:ok, %{path: path, sections: sections}}
        end
    end
  end

  defp check_headings(content) do
    Enum.find_value(@required_headings, :ok, fn heading ->
      unless has_heading?(content, heading), do: {:error, {:missing_heading, heading}}
    end)
  end

  defp check_duplicates(content) do
    lines = String.split(content, "\n")

    Enum.find_value(@required_headings, :ok, fn heading ->
      count = Enum.count(lines, fn line -> String.trim(line) == heading end)
      if count > 1, do: {:error, {:duplicate_heading, heading}}
    end)
  end

  defp has_heading?(content, heading) do
    content
    |> String.split("\n")
    |> Enum.any?(fn line -> String.trim(line) == heading end)
  end

  defp parse_sections(content) do
    lines = String.split(content, "\n")

    sections =
      @section_headings
      |> Enum.map(fn heading -> {heading, extract_body(lines, heading)} end)
      |> Map.new()

    case Enum.find(@section_headings, fn h -> sections[h] == "" end) do
      nil -> {:ok, sections}
      empty -> {:error, {:empty_section, empty}}
    end
  end

  defp extract_body(lines, heading) do
    lines
    |> Enum.drop_while(fn line -> String.trim(line) != heading end)
    |> Enum.drop(1)
    |> Enum.take_while(fn line -> not next_heading?(line) end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp next_heading?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "## ") or (trimmed == String.trim(trimmed) and String.starts_with?(trimmed, "# "))
  end
end
