defmodule Symphony1.Project.LinearBrowserFallback do
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(config) do
    runner = Application.get_env(:symphony_1, :linear_browser_fallback_runner, &run_command/1)
    runner.(config)
  end

  defp run_command(config) do
    case configured_command_argv() do
      :unavailable ->
        {:error, :linear_browser_fallback_unavailable}

      :unsafe ->
        {:error, :unsafe_linear_browser_fallback_command}

      [executable | args] ->
        payload =
          config
          |> Enum.into(%{})
          |> Jason.encode!()

        system_cmd = Application.get_env(:symphony_1, :linear_browser_fallback_system_cmd, System)

        case system_cmd.cmd(executable, args,
               stderr_to_stdout: true,
               env: [{"SYMPHONY_LINEAR_BROWSER_FALLBACK_PAYLOAD", payload}]
             ) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, {:linear_browser_fallback_command_failed, String.trim(output)}}
        end
    end
  end

  defp configured_command_argv do
    case Application.get_env(:symphony_1, :linear_browser_fallback_command) ||
           System.get_env("SYMPHONY_LINEAR_BROWSER_FALLBACK_COMMAND") do
      nil ->
        :unavailable

      command when is_list(command) and command != [] ->
        if Enum.all?(command, &is_binary/1), do: command, else: :unsafe

      _unsafe ->
        :unsafe
    end
  end
end
