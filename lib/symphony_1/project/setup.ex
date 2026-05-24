defmodule Symphony1.Project.Setup do
  require Logger

  alias Symphony1.Core.Linear
  alias Symphony1.Project.{LinearBootstrap, SetupIntent, SetupState}
  alias Symphony1.RuntimeConfig

  @intent_path "config/symphony_setup.json"
  @state_path "config/symphony_setup.state.json"

  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    with {:ok, intent} <- SetupIntent.load(@intent_path),
         :ok <- SetupState.write(@state_path, verified_state(intent)),
         :ok <- provision_linear_and_proof_issue(intent),
         {:ok, state} <- SetupState.read(@state_path) do
      {:ok, state}
    end
  end

  defp verified_state(intent) do
    env_blockers = missing_env_blockers(intent)
    github_blockers = github_blockers(intent)
    blockers = env_blockers ++ github_blockers

    %{
      "project" => %{
        "name" => get_in(intent, ["project", "name"])
      },
      "linear" => %{
        "created_workflow_states" => [],
        "missing_workflow_states" => []
      },
      "steps" => %{
        "intent_loaded" => true,
        "env_verified" => env_blockers == [],
        "github_verified" => github_blockers == []
      },
      "blockers" => blockers
    }
  end

  defp missing_env_blockers(intent) do
    intent
    |> get_in(["env", "required"])
    |> Enum.reject(&System.get_env/1)
    |> Enum.map(fn env_var -> "missing_#{String.downcase(env_var)}" end)
  end

  defp github_blockers(intent) do
    expected_repo = get_in(intent, ["github", "repo"])

    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} ->
        normalized_url = String.trim(url)

        if String.contains?(normalized_url, expected_repo) do
          []
        else
          ["origin_remote_mismatch"]
        end

      {_output, _status} ->
        ["missing_origin_remote"]
    end
  end

  # Replaces the old `maybe_create_proof_issue/1` with explicit control flow.
  # Each path returns exactly :ok or {:error, reason}.
  defp provision_linear_and_proof_issue(intent) do
    with {:ok, state} <- SetupState.read(@state_path) do
      if state["blockers"] != [] do
        Logger.info("symphony.setup: blockers present, skipping Linear provisioning")
        record_skipped_linear_steps()
      else
        do_provision_linear_and_proof_issue(intent)
      end
    end
  end

  defp do_provision_linear_and_proof_issue(intent) do
    case ensure_linear_ready(intent) do
      {:ok, metadata} ->
        Logger.info("symphony.setup: Linear ready (team=#{metadata.team_key}, created=#{metadata.team_created})")
        :ok = record_linear_metadata(metadata)
        create_and_record_proof_issue(intent)

      {:error, reason} ->
        Logger.warning("symphony.setup: Linear bootstrap failed: #{inspect(reason)}")
        :ok = record_linear_failure(reason)
        {:error, reason}
    end
  end

  defp create_and_record_proof_issue(intent) do
    case create_proof_issue(intent) do
      {:ok, proof_issue} ->
        Logger.info("symphony.setup: proof issue created (#{proof_issue.identifier})")

        SetupState.update(@state_path, fn current ->
          current
          |> put_in(["steps", "proof_issue_created"], true)
          |> put_in(["steps", "linear_verified"], true)
          |> put_in(["steps", "linear_browser_fallback_used"], false)
          |> Map.put("proof_issue", %{"identifier" => proof_issue.identifier})
        end)

      {:error, reason} ->
        Logger.warning("symphony.setup: proof issue creation failed: #{inspect(reason)}")

        SetupState.update(@state_path, fn current ->
          current
          |> put_in(["steps", "proof_issue_created"], false)
          |> put_in(["steps", "linear_verified"], false)
          |> put_in(["steps", "linear_browser_fallback_used"], false)
          |> Map.update("blockers", [blocker_for(reason)], fn blockers ->
            Enum.uniq(blockers ++ [blocker_for(reason)])
          end)
        end)

        {:error, reason}
    end
  end

  defp record_linear_metadata(metadata) do
    SetupState.update(@state_path, fn current ->
      current
      |> put_in(["steps", "linear_verified"], true)
      |> put_in(["steps", "linear_browser_fallback_used"], false)
      |> put_in(["linear", "team_id"], metadata.team_id)
      |> put_in(["linear", "team_key"], metadata.team_key)
      |> put_in(["linear", "team_name"], metadata.team_name)
      |> put_in(["linear", "team_created"], metadata.team_created)
      |> put_in(["linear", "created_workflow_states"], metadata.created_workflow_states)
      |> put_in(["linear", "missing_workflow_states"], [])
    end)
  end

  defp record_linear_failure(reason) do
    SetupState.update(@state_path, fn current ->
      current
      |> put_in(["steps", "proof_issue_created"], false)
      |> put_in(["steps", "linear_verified"], false)
      |> put_in(["steps", "linear_browser_fallback_used"], false)
      |> put_in(["linear", "bootstrap_error"], inspect(reason))
      |> Map.update("blockers", [blocker_for(reason)], fn blockers ->
        Enum.uniq(blockers ++ [blocker_for(reason)])
      end)
    end)
  end

  defp record_skipped_linear_steps do
    SetupState.update(@state_path, fn current ->
      current
      |> put_in(["steps", "proof_issue_created"], false)
      |> put_in(["steps", "linear_verified"], false)
      |> put_in(["steps", "linear_browser_fallback_used"], false)
    end)
  end

  defp create_proof_issue(intent) do
    requester = Application.get_env(:symphony_1, :setup_linear_requester, &Linear.request/3)

    issue_attrs = %{
      "description" => get_in(intent, ["proof_issue", "description"]),
      "state" => get_in(intent, ["proof_issue", "state"]),
      "title" => get_in(intent, ["proof_issue", "title"])
    }

    with {:ok, linear_config} <- RuntimeConfig.linear_config(get_in(intent, ["linear", "team_key"])) do
      Linear.create_issue(linear_config, issue_attrs, requester)
    end
  end

  defp ensure_linear_ready(intent) do
    requester = Application.get_env(:symphony_1, :setup_linear_requester, &Linear.request/3)
    bootstrap = Application.get_env(:symphony_1, :setup_linear_bootstrap, &LinearBootstrap.ensure_ready/3)

    with {:ok, linear_config} <- RuntimeConfig.linear_config(get_in(intent, ["linear", "team_key"])) do
      bootstrap.(
        linear_config,
        %{
          "team_name" => get_in(intent, ["linear", "team_name"]),
          "workflow_states" => get_in(intent, ["linear", "workflow_states"])
        },
        load_team: fn config -> Linear.load_team(config, requester) end,
        create_team: fn config, attrs -> Linear.create_team(config, attrs, requester) end,
        create_workflow_state: fn config, attrs -> Linear.create_workflow_state(config, attrs, requester) end,
        update_workflow_state: fn config, attrs -> Linear.update_workflow_state(config, attrs, requester) end
      )
    end
  end

  defp blocker_for(:linear_missing_workflow_states), do: "linear_missing_workflow_states"
  defp blocker_for({:team_not_found, _team_key}), do: "linear_team_not_found"
  defp blocker_for({:team_create_failed, _team_key, _reason}), do: "linear_team_create_failed"

  defp blocker_for({:workflow_state_create_failed, _state_name, _reason}),
    do: "linear_workflow_state_create_failed"

  defp blocker_for(reason), do: "setup_error:#{inspect(reason)}"
end
