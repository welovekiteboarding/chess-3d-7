defmodule Symphony1.Project.Template do
  @spec files(map()) :: [{String.t(), String.t()}]
  def files(assigns) do
    [
      {"README.md", readme(assigns)},
      {"AGENTS.md", agents(assigns)},
      {".gitignore", gitignore()},
      {"config/symphony_setup.json", setup_intent(assigns)},
      {"docs/status.md", status(assigns)},
      {"docs/architecture.md", architecture(assigns)},
      {"docs/recovery-cleanup-policy.md", recovery_policy(assigns)},
      {"docs/linear-setup.md", linear_setup(assigns)},
      {"priv/workflows/WORKFLOW.example.md", workflow(assigns)},
      {"priv/workflows/WORKFLOW.md", workflow(assigns)},
      {".env.example", env_example(assigns)},
      {"lib/#{assigns.module_path}.ex", source_placeholder(assigns)},
      {"test/test_helper.exs", test_helper()},
      {"test/#{assigns.module_path}_test.exs", test_placeholder(assigns)}
    ]
  end

  defp readme(assigns) do
    """
    # #{assigns.project_name}

    `#{assigns.project_name}` is scaffolded from the Symphony harness shape.

    ## Control Surface

    - Linear team key: `#{assigns.linear_team_key}`
    - GitHub repo: `#{assigns.github_repo}`

    ## Workflow

    - `Todo`
    - `In Progress`
    - `Human Review`
    - `Rework`
    - `Merging`
    - `Done`
    """
  end

  defp agents(assigns) do
    """
    # AGENTS.md

    This repo embeds the Symphony harness for `#{assigns.project_name}`.

    Read first:

    1. `README.md`
    2. `docs/status.md`
    3. `docs/architecture.md`
    4. `docs/recovery-cleanup-policy.md`
    5. `priv/workflows/WORKFLOW.md`
    """
  end

  defp status(assigns) do
    """
    # #{assigns.project_name} Status

    ## Goal

    Build `#{assigns.project_name}` through the Symphony Linear -> Codex -> GitHub loop.
    """
  end

  defp setup_intent(assigns) do
    Jason.encode!(%{
      project: %{
        name: assigns.project_name
      },
      github: %{
        repo: assigns.github_repo
      },
      linear: %{
        team_key: assigns.linear_team_key,
        team_name: assigns.linear_team_name,
        workflow_states: ["Todo", "In Progress", "Finalizing", "Human Review", "Rework", "Merging", "Done"]
      },
      env: %{
        required: ["LINEAR_API_KEY"]
      },
      proof_issue: %{
        state: "Todo",
        title: "Create deterministic live-proof artifact",
        description:
          "Add a new file at docs/live-proof-setup-run-merge.md. Record only facts you can directly observe while working in this issue workspace. Use this exact structure:\n\n# Live Proof Setup Run Merge\n- Proof issue: <issue identifier>\n- Branch: <current git branch>\n- Commit evidence: <the current issue-specific git commit SHA and subject from local git history>\n- File evidence: <state that this proof artifact file was created for the deterministic live-proof issue>\n- Current scope: <state only what this issue actually proves at authoring time>\n\nRules:\n- Before writing the proof note, inspect the local git history for the current issue branch and record the issue-specific commit SHA and subject that already exist there.\n- Use only facts visible in the issue prompt, workspace files, current branch name, or local git history.\n- Do not claim a PR, review result, merge result, or Linear workflow state unless that fact is already visible from local git data in the workspace.\n- Do not say evidence is missing if local git history already shows it."
      }
    }, pretty: true)
  end

  defp architecture(assigns) do
    """
    # #{assigns.project_name} Architecture

    This repo embeds the Symphony harness shape for `#{assigns.project_name}`.
    """
  end

  defp recovery_policy(assigns) do
    """
    # #{assigns.project_name} Recovery And Cleanup Policy

    Failed claimed issues should move from `In Progress` to `Rework` before PR creation.
    """
  end

  defp linear_setup(assigns) do
    """
    # Linear Setup For #{assigns.project_name}

    ## Team

    - team name: `#{assigns.linear_team_name}`
    - team key: `#{assigns.linear_team_key}`
    - GitHub repo: `#{assigns.github_repo}`

    ## Workflow States

    - `Todo`
    - `In Progress`
    - `Human Review`
    - `Rework`
    - `Merging`
    - `Done`

    ## Environment Checklist

    - set `LINEAR_API_KEY`
    - confirm GitHub auth for `gh`
    - confirm Codex is installed and available on the path

    ## Create The First Proof Issue

    Create the first proof issue in Linear with:

    - state: `Todo`
    - title: `Create deterministic live-proof artifact`
    - description: `Add a new file at docs/live-proof-setup-run-merge.md. Record only facts you can directly observe while working in this issue workspace. Use this exact structure:

      # Live Proof Setup Run Merge
      - Proof issue: <issue identifier>
      - Branch: <current git branch>
      - Commit evidence: <the current issue-specific git commit SHA and subject from local git history>
      - File evidence: <state that this proof artifact file was created for the deterministic live-proof issue>
      - Current scope: <state only what this issue actually proves at authoring time>

      Rules:
      - Before writing the proof note, inspect the local git history for the current issue branch and record the issue-specific commit SHA and subject that already exist there.
      - Use only facts visible in the issue prompt, workspace files, current branch name, or local git history.
      - Do not claim a PR, review result, merge result, or Linear workflow state unless that fact is already visible from local git data in the workspace.
      - Do not say evidence is missing if local git history already shows it.`

    ## Manual Notes

    - `mix symphony.setup` will create the first proof issue through the Linear API after team and workflow bootstrap succeeds
    - GitHub repo creation can be automated by `mix symphony.scaffold ... --github`
    - run one queue cycle with `mix symphony.run --once`
    - run the foreground queue with `mix symphony.run`
    """
  end

  defp workflow(assigns) do
    """
    ---
    tracker:
      kind: linear
    workspace:
      root: ./tmp/workspaces
    agent:
      max_concurrent_agents: 1
    codex:
      command: codex app-server
      turn_timeout_ms: 300000
    ---

    You are working on a Linear issue for #{assigns.project_name}.
    """
  end

  defp env_example(_assigns) do
    """
    LINEAR_API_KEY=
    GITHUB_OWNER=
    GITHUB_REPO=
    """
  end

  defp gitignore do
    """
    /_build/
    /deps/
    /cover/
    erl_crash.dump
    .DS_Store
    """
  end

  defp source_placeholder(assigns) do
    """
    defmodule #{assigns.module_name} do
      def hello do
        :world
      end
    end
    """
  end

  defp test_placeholder(assigns) do
    """
    defmodule #{assigns.module_name}Test do
      use ExUnit.Case

      test "hello/0 returns :world" do
        assert #{assigns.module_name}.hello() == :world
      end
    end
    """
  end

  defp test_helper do
    """
    ExUnit.start()
    """
  end
end
