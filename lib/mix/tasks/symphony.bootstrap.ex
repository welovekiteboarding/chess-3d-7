defmodule Mix.Tasks.Symphony.Bootstrap do
  use Mix.Task

  alias Symphony1.Project.Bootstrap

  @shortdoc "Run the full fresh bootstrap loop through merge and cleanup"

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [owner: :string, private: :boolean, public: :boolean, root: :string]
      )

    project_name =
      case positional do
        [name | _rest] -> name
        _ -> Mix.raise("usage: mix symphony.bootstrap PROJECT_NAME --owner GITHUB_OWNER")
      end

    github_owner =
      case Keyword.get(opts, :owner) do
        nil -> Mix.raise("usage: mix symphony.bootstrap PROJECT_NAME --owner GITHUB_OWNER")
        owner -> owner
      end

    validate_visibility_opts!(opts)

    bootstrap_runner = Application.get_env(:symphony_1, :bootstrap_runner, &Bootstrap.run/1)

    attrs = %{
      github_owner: github_owner,
      private: Keyword.get(opts, :private, false) and not Keyword.get(opts, :public, false),
      project_name: project_name,
      root_path: Keyword.get(opts, :root, File.cwd!())
    }

    case bootstrap_runner.(attrs) do
      {:ok, summary} ->
        Mix.shell().info("Bootstrapped #{project_name} at #{summary.project_path}")

        Mix.shell().info(
          "Proof issue #{summary.proof_issue_identifier} merged via #{summary.merged_pr_url}"
        )

      {:error, reason} ->
        Mix.raise("bootstrap failed: #{inspect(reason)}")
    end
  end

  defp validate_visibility_opts!(opts) do
    if Keyword.get(opts, :public, false) and Keyword.get(opts, :private, false) do
      Mix.raise("cannot pass both --public and --private")
    end
  end
end
