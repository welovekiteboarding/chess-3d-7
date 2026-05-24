defmodule Symphony1.Project.RepoAdapter do
  require Logger

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  alias Symphony1.Planning.ScopeCheck

  @spec bootstrap_commands() :: [String.t()]
  def bootstrap_commands do
    [
      "git status --short",
      "mix deps.get"
    ]
  end

  @spec validation_commands() :: [String.t()]
  def validation_commands do
    [
      "mix test"
    ]
  end

  @spec finalize_workspace(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def finalize_workspace(attrs, runner \\ &System.cmd/3) do
    workspace = attrs.workspace
    issue_identifier = issue_identifier(attrs)
    commit_message = "Implement #{issue_identifier}"

    Logger.info("symphony.repo_adapter: finalize.start issue=#{issue_identifier} workspace=#{workspace}")

    with {:ok, branch} <- current_branch(workspace),
         :ok <- run_bootstrap_commands(workspace, runner, issue_identifier),
         :ok <- run_validation_commands(workspace, runner, attrs, issue_identifier),
         {:ok, scope_check} <- enforce_scope(workspace, attrs),
         :ok <- run_command("git", ["add", "-A"], workspace, issue_identifier),
         :ok <- ensure_staged_changes(workspace),
         :ok <- run_command("git", ["commit", "-m", commit_message], workspace, issue_identifier),
         :ok <- run_command("git", ["push", "-u", "origin", branch], workspace, issue_identifier) do
      {:ok,
       %{
         branch: branch,
         commit_message: commit_message,
         issue_identifier: issue_identifier,
         scope_check: scope_check,
         workspace: workspace
       }}
    end
  end

  defp issue_identifier(%{issue_identifier: issue_identifier}), do: issue_identifier
  defp issue_identifier(%{issue: %{identifier: issue_identifier}}), do: issue_identifier

  defp current_branch(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {output, exit_status} -> {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp run_validation_commands(workspace, runner, attrs, issue_identifier) do
    commands = task_validation_commands(attrs) || validation_commands()
    run_shell_commands(commands, workspace, runner, issue_identifier)
  end

  defp task_validation_commands(%{task_context: %{validation: %{commands: commands}}})
       when is_list(commands) and commands != [] do
    commands
  end

  defp task_validation_commands(_attrs), do: nil

  defp enforce_scope(workspace, attrs) do
    task_context = Map.get(attrs, :task_context)

    case changed_files(workspace) do
      {:ok, changed_files} ->
        result = ScopeCheck.evaluate(task_context || fallback_task(), changed_files)

        case result.status do
          :pass -> {:ok, result}
          :warn -> {:ok, result}
          :fail -> {:error, {:scope_violation, result}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_bootstrap_commands(workspace, runner, issue_identifier) do
    run_shell_commands(bootstrap_commands(), workspace, runner, issue_identifier)
  end

  defp run_shell_commands(commands, workspace, runner, issue_identifier) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case run_logged_command(runner, "zsh", ["-lc", command], workspace, issue_identifier, "finalize.shell") do
        {:ok, _output} -> {:cont, :ok}
        {:error, exit_status, output} -> {:halt, {:error, {:command_failed, "zsh", exit_status, output}}}
      end
    end)
  end

  defp ensure_staged_changes(workspace) do
    case System.cmd("git", ["diff", "--cached", "--quiet"], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> {:error, :no_changes}
      {_output, 1} -> :ok
      {output, exit_status} -> {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp run_command(command, args, workspace, issue_identifier) do
    case run_logged_command(&System.cmd/3, command, args, workspace, issue_identifier, "finalize.command") do
      {:ok, _output} -> :ok
      {:error, exit_status, output} -> {:error, {:command_failed, command, exit_status, output}}
    end
  end

  defp run_logged_command(runner, command, args, workspace, issue_identifier, stage) do
    command_string = Enum.join([command | args], " ")
    started_at = System.monotonic_time(:millisecond)

    Logger.info(
      "symphony.repo_adapter: #{stage} start issue=#{issue_identifier} cmd=#{inspect(command_string)} cwd=#{workspace}"
    )

    {output, exit_status} = runner.(command, args, cd: workspace, stderr_to_stdout: true)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    trimmed_output = String.trim(output)

    log_level = if exit_status == 0, do: :info, else: :warning

    Logger.log(
      log_level,
      "symphony.repo_adapter: #{stage} finish issue=#{issue_identifier} cmd=#{inspect(command_string)} exit=#{exit_status} elapsed_ms=#{elapsed_ms} output=#{inspect(trimmed_output)}"
    )

    if exit_status == 0 do
      {:ok, trimmed_output}
    else
      {:error, exit_status, trimmed_output}
    end
  end

  defp changed_files(workspace) do
    case System.cmd("git", ["status", "--porcelain"], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse_changed_files(output)}
      {output, exit_status} -> {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp parse_changed_files(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_changed_file/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_changed_file(<<"?? ", path::binary>>), do: path

  defp parse_changed_file(line) do
    path = String.slice(line, 3..-1//1)

    case String.split(path, " -> ") do
      [_old, new] -> new
      [single] -> single
    end
  end

  defp fallback_task do
    %Symphony1.Planning.Graph.Task{
      id: "unknown",
      title: "unknown",
      description: "",
      acceptance_criteria: [],
      dependencies: [],
      status: "pending",
      materialization: %Symphony1.Planning.Graph.Materialization{}
    }
  end
end
