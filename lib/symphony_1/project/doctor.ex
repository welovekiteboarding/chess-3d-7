defmodule Symphony1.Project.Doctor do
  @moduledoc false

  @type check :: %{
          status: :pass | :warn | :fail,
          label: String.t(),
          detail: String.t()
        }

  @type opts :: keyword()

  @spec checks(opts()) :: [check()]
  def checks(opts \\ []) do
    [
      check_runtime_manager(opts),
      check_erlang(opts),
      check_elixir(opts),
      check_mix(opts),
      check_git(opts),
      check_github_cli(opts),
      check_github_auth(opts),
      check_codex(opts),
      check_linear_api_key(opts)
    ]
  end

  defp check_runtime_manager(opts) do
    if File.exists?(tool_versions_path(opts)) do
      binary_check(opts, "asdf", "Runtime manager (asdf)", :warn, "Install asdf to use .tool-versions automatically")
    else
      %{status: :warn, label: "Runtime manager", detail: "No .tool-versions file found"}
    end
  end

  defp check_erlang(opts) do
    expected = expected_version(opts, "erlang")

    case executable_path(opts, "erl") do
      nil ->
        %{status: :fail, label: "Erlang", detail: missing_runtime_detail("Erlang", expected)}

      _path ->
        case run_command(opts, "erl", ["-eval", "erlang:display(erlang:system_info(otp_release)), halt().", "-noshell"], stderr_to_stdout: true) do
          {output, 0} ->
            actual = normalize_version_output(output)

            if erlang_version_matches?(expected, actual) do
              %{status: :pass, label: "Erlang", detail: actual}
            else
              %{status: :fail, label: "Erlang", detail: "Expected #{expected}, but this shell is using #{actual}"}
            end

          {_output, _status} ->
            %{status: :fail, label: "Erlang", detail: runtime_failure_detail(opts, "erlang", "Erlang", expected)}
        end
    end
  end

  defp check_elixir(opts) do
    expected = expected_version(opts, "elixir")

    try do
      case run_command(opts, "elixir", ["--version"], stderr_to_stdout: true) do
        {output, 0} ->
          version =
            output
            |> String.split("\n")
            |> Enum.find("installed", &String.starts_with?(&1, "Elixir "))
            |> String.trim()

          if expected == nil or String.contains?(version, elixir_display_version(expected)) do
            %{status: :pass, label: "Elixir", detail: version}
          else
            %{status: :fail, label: "Elixir", detail: "Expected #{expected}, but this shell is using #{version}"}
          end

        _ ->
          %{status: :fail, label: "Elixir", detail: missing_runtime_detail("Elixir", expected)}
      end
    rescue
      _ ->
        %{status: :fail, label: "Elixir", detail: missing_runtime_detail("Elixir", expected)}
    end
  end

  defp check_mix(opts) do
    binary_check(opts, "mix", "Mix", :fail, "Install Elixir so mix is available")
  end

  defp check_git(opts) do
    binary_check(opts, "git", "Git", :fail, "Install git before working in this repo")
  end

  defp check_github_cli(opts) do
    binary_check(opts, "gh", "GitHub CLI", :warn, "Install gh for GitHub-backed setup and merge commands")
  end

  defp check_github_auth(opts) do
    if executable_path(opts, "gh") do
      case run_command(opts, "gh", ["auth", "status"], stderr_to_stdout: true) do
        {_output, 0} ->
          %{status: :pass, label: "GitHub CLI auth", detail: "Authenticated"}

        _ ->
          %{status: :warn, label: "GitHub CLI auth", detail: "Run gh auth login before live GitHub operations"}
      end
    else
      %{status: :warn, label: "GitHub CLI auth", detail: "Skipped until gh is installed"}
    end
  rescue
    _ ->
      %{status: :warn, label: "GitHub CLI auth", detail: "Run gh auth login before live GitHub operations"}
  end

  defp check_codex(opts) do
    binary_check(opts, "codex", "Codex CLI", :warn, "Install codex for live worker execution")
  end

  defp check_linear_api_key(opts) do
    case env(opts, "LINEAR_API_KEY") do
      nil -> %{status: :warn, label: "LINEAR_API_KEY", detail: "Set LINEAR_API_KEY before live Linear runs"}
      "" -> %{status: :warn, label: "LINEAR_API_KEY", detail: "Set LINEAR_API_KEY before live Linear runs"}
      _value -> %{status: :pass, label: "LINEAR_API_KEY", detail: "Set"}
    end
  end

  defp binary_check(opts, binary, label, missing_status, missing_detail) do
    if executable_path(opts, binary) do
      %{status: :pass, label: label, detail: "Found"}
    else
      %{status: missing_status, label: label, detail: missing_detail}
    end
  end

  defp normalize_version_output(output) do
    output
    |> String.trim()
    |> String.replace(~r/^"+|"+$/, "")
  end

  defp erlang_version_matches?(nil, _actual), do: true
  defp erlang_version_matches?(expected, actual) when expected == actual, do: true

  defp erlang_version_matches?(expected, actual) do
    case String.trim(expected) do
      "ref:OTP-" <> release ->
        String.starts_with?(release, actual)

      release ->
        String.starts_with?(release, actual)
    end
  end

  defp tool_versions_path(opts), do: Keyword.get(opts, :tool_versions_path, ".tool-versions")

  defp expected_version(opts, tool) do
    case File.read(tool_versions_path(opts)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, ~r/\s+/, parts: 2, trim: true) do
            [^tool, version] -> version
            _ -> nil
          end
        end)

      {:error, _reason} ->
        nil
    end
  end

  defp executable_path(opts, binary) do
    finder = Keyword.get(opts, :find_executable, &System.find_executable/1)
    finder.(binary)
  end

  defp run_command(opts, command, args, run_opts) do
    runner = Keyword.get(opts, :cmd_runner, &System.cmd/3)
    runner.(command, args, run_opts)
  end

  defp env(opts, key) do
    getter = Keyword.get(opts, :env_getter, &System.get_env/1)
    getter.(key)
  end

  defp missing_runtime_detail(name, nil), do: "#{name} is not usable in this shell"
  defp missing_runtime_detail(name, expected), do: "Expected #{expected}; #{name} is not usable in this shell"

  defp runtime_failure_detail(opts, tool, name, expected) do
    expected_text =
      case expected do
        nil -> "#{name} is not usable in this shell"
        version -> "Expected #{version}; #{name} is not usable in this shell"
      end

    case asdf_current_entry(opts, tool) do
      {:installed_false, version} ->
        "#{expected_text}. asdf reports it is not installed: #{tool} #{version}"

      {:installed_true, version} ->
        "#{expected_text}. asdf reports #{tool} #{version} is selected, so your shell setup may be incomplete"

      :unknown ->
        expected_text
    end
  end

  defp asdf_current_entry(opts, tool) do
    if executable_path(opts, "asdf") do
      case run_command(opts, "asdf", ["current"], stderr_to_stdout: true) do
        {output, 0} -> parse_asdf_current(output, tool)
        _ -> :unknown
      end
    else
      :unknown
    end
  end

  defp parse_asdf_current(output, tool) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(:unknown, fn line ->
      tokens = String.split(line, ~r/\s+/, trim: true)

      case tokens do
        [^tool, version | rest] ->
          installed = Enum.member?(rest, "true")

          cond do
            installed -> {:installed_true, version}
            String.contains?(line, "false") -> {:installed_false, version}
            true -> :unknown
          end

        _ ->
          nil
      end
    end)
  end

  defp elixir_display_version(version) do
    version
    |> String.split("-otp-")
    |> hd()
  end
end
