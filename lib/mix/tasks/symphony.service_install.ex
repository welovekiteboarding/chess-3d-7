defmodule Mix.Tasks.Symphony.ServiceInstall do
  use Mix.Task

  alias Symphony1.RuntimeConfig
  alias Symphony1.Service.Launchd

  @shortdoc "Generate and install a launchd plist for mix symphony.operate"

  @label "com.symphony1.operate"
  @default_repo_local_dir "tmp/service"
  @default_launch_agents_dir Path.expand("~/Library/LaunchAgents")

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.service_install --graph PATH --team-key KEY")
        path -> Path.expand(path)
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.service_install --graph PATH --team-key KEY")
        key -> key
      end

    api_key =
      case RuntimeConfig.linear_api_key() do
        {:ok, key} -> key
        {:error, :missing_linear_api_key} -> Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    config = override_config()

    mix_resolver = Map.get(config, :mix_resolver, &System.find_executable/1)

    mix_path =
      case mix_resolver.("mix") do
        nil -> Mix.raise("could not resolve absolute path to mix")
        path -> path
      end

    working_directory = Map.get(config, :working_directory, File.cwd!())
    repo_local_dir = Map.get(config, :repo_local_dir, @default_repo_local_dir)
    launch_agents_dir = Map.get(config, :launch_agents_dir, @default_launch_agents_dir)
    file_writer = Map.get(config, :file_writer, &File.write/2)
    file_copier = Map.get(config, :file_copier, &File.cp/2)

    plist_config = %{
      label: @label,
      mix_path: mix_path,
      graph_path: graph_path,
      team_key: team_key,
      working_directory: working_directory,
      stdout_log: Path.join(working_directory, "log/operate.stdout.log"),
      stderr_log: Path.join(working_directory, "log/operate.stderr.log"),
      env: %{
        "LINEAR_API_KEY" => api_key,
        "PATH" => System.get_env("PATH") || "/usr/bin:/bin"
      }
    }

    plist_content = Launchd.generate_plist(plist_config)

    File.mkdir_p!(repo_local_dir)
    repo_local_path = Path.join(repo_local_dir, "#{@label}.plist")

    case file_writer.(repo_local_path, plist_content) do
      :ok ->
        Mix.shell().info("service_install: wrote #{repo_local_path}")

      {:error, reason} ->
        Mix.raise("service_install: failed to write repo-local plist: #{inspect(reason)}")
    end

    File.mkdir_p!(launch_agents_dir)
    install_path = Path.join(launch_agents_dir, "#{@label}.plist")

    case file_copier.(repo_local_path, install_path) do
      :ok ->
        Mix.shell().info("service_install: installed #{install_path}")

      {:error, reason} ->
        Mix.raise("service_install: failed to install plist to LaunchAgents: #{inspect(reason)}")
    end

    Mix.shell().info("service_install: next step — run mix symphony.service_start")
  end

  defp override_config do
    Application.get_env(:symphony_1, :service_install_config, %{})
  end
end
