defmodule Symphony1.Project.Scaffold do
  alias Symphony1.Project.Template

  @spec generate(map()) :: {:ok, map()} | {:error, term()}
  def generate(%{project_name: project_name, root_path: root_path} = attrs) do
    project_path = Path.join(root_path, project_name)
    module_name = module_name(project_name)
    module_path = Macro.underscore(module_name)
    command_runner = Map.get(attrs, :command_runner, &System.cmd/3)
    source_root = Map.get(attrs, :source_root, File.cwd!())

    github_owner = Map.get(attrs, :github_owner) || "OWNER"

    assigns = %{
      github_repo: "#{github_owner}/#{project_name}",
      linear_team_key: Map.get(attrs, :linear_team_key, default_team_key(project_name)),
      linear_team_name: Map.get(attrs, :linear_team_name, module_name),
      module_name: module_name,
      module_path: module_path,
      project_name: project_name
    }

    with :ok <- File.mkdir_p(project_path),
         :ok <- copy_runtime(project_path, source_root),
         :ok <- write_files(project_path, Template.files(assigns)),
         {_, 0} <- System.cmd("mix", ["deps.get"], cd: project_path, stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["init", "-b", "main"], cd: project_path, stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["add", "."], cd: project_path, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd(
             "git",
             ["-c", "user.name=Symphony", "-c", "user.email=symphony@example.com", "commit", "-m", "Bootstrap project scaffold"],
             cd: project_path,
             stderr_to_stdout: true
           ),
         :ok <- maybe_create_github_repo(attrs, project_path, command_runner) do
      {:ok, %{project_path: project_path}}
    else
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, {:command_failed, "git", status, String.trim(output)}}
    end
  end

  defp write_files(project_path, files) do
    Enum.reduce_while(files, :ok, fn {relative_path, contents}, :ok ->
      path = Path.join(project_path, relative_path)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, contents) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp copy_runtime(project_path, source_root) do
    with :ok <- copy_file(Path.join(source_root, "mix.exs"), Path.join(project_path, "mix.exs")),
         :ok <- copy_file(Path.join(source_root, "mix.lock"), Path.join(project_path, "mix.lock")),
         :ok <- copy_file(Path.join(source_root, "config/config.exs"), Path.join(project_path, "config/config.exs")),
         :ok <- copy_directory(Path.join(source_root, "lib"), Path.join(project_path, "lib")) do
      :ok
    end
  end

  defp copy_file(source, destination) do
    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(source, destination) do
      :ok
    end
  end

  defp copy_directory(source, destination) do
    case File.cp_r(source, destination) do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp module_name(project_name) do
    project_name
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> Enum.map(&Macro.camelize/1)
    |> Enum.join()
  end

  defp maybe_create_github_repo(%{github: true, github_owner: owner} = attrs, project_path, command_runner) do
    visibility = if Map.get(attrs, :private, false), do: "--private", else: "--public"
    repo = "#{owner}/#{Path.basename(project_path)}"

    case command_runner.(
           "gh",
           ["repo", "create", repo, visibility, "--source", project_path, "--remote", "origin", "--push"],
           []
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:command_failed, "gh", status, String.trim(output)}}
    end
  end

  defp maybe_create_github_repo(_attrs, _project_path, _command_runner), do: :ok

  defp default_team_key(project_name) do
    project_name
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end
end
