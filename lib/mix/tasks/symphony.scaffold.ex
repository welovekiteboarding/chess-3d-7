defmodule Mix.Tasks.Symphony.Scaffold do
  use Mix.Task

  alias Symphony1.Project.Scaffold

  @shortdoc "Scaffold a new project repo with the Symphony harness shape"

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [github: :boolean, owner: :string, private: :boolean, public: :boolean, root: :string]
      )

    project_name =
      case positional do
        [name | _rest] -> name
        _ -> Mix.raise("usage: mix symphony.scaffold PROJECT_NAME [--root PATH]")
      end

    validate_visibility_opts!(opts)

    root_path = Keyword.get(opts, :root, File.cwd!())
    command_runner = Application.get_env(:symphony_1, :scaffold_command_runner, &System.cmd/3)

    attrs =
      %{
        command_runner: command_runner,
        github: Keyword.get(opts, :github, false),
        github_owner: Keyword.get(opts, :owner),
        private: not Keyword.get(opts, :public, false),
        project_name: project_name,
        root_path: root_path
      }

    case Scaffold.generate(attrs) do
      {:ok, %{project_path: project_path}} ->
        Mix.shell().info("Scaffolded #{project_name} at #{project_path}")

      {:error, reason} ->
        Mix.raise("scaffold failed: #{inspect(reason)}")
    end
  end

  defp validate_visibility_opts!(opts) do
    if Keyword.get(opts, :public, false) and Keyword.get(opts, :private, false) do
      Mix.raise("cannot pass both --public and --private")
    end
  end
end
