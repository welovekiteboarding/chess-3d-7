defmodule Symphony1.Project.LinearBootstrap do
  alias Symphony1.Core.Linear

  @workflow_state_colors %{
    "Todo" => "#6b7280",
    "In Progress" => "#eab308",
    "Finalizing" => "#f97316",
    "Human Review" => "#3b82f6",
    "Rework" => "#ef4444",
    "Merging" => "#8b5cf6",
    "Done" => "#22c55e"
  }

  @spec ensure_ready(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_ready(config, intent, opts \\ []) do
    load_team = Keyword.get(opts, :load_team, &Linear.load_team(&1))
    create_team = Keyword.get(opts, :create_team, &Linear.create_team/2)
    create_workflow_state = Keyword.get(opts, :create_workflow_state, &Linear.create_workflow_state/2)
    update_workflow_state = Keyword.get(opts, :update_workflow_state, nil)

    with {:ok, team, team_created} <- ensure_team(config, intent, load_team, create_team),
         {:ok, created_workflow_states} <-
           ensure_workflow_states(config, team, intent, create_workflow_state),
         {:ok, repaired_workflow_states} <-
           repair_workflow_state_colors(config, team, intent, update_workflow_state) do
      {:ok,
       %{
         team_id: team.id,
         team_key: team.key,
         team_name: team.name,
         team_created: team_created,
         created_workflow_states: created_workflow_states,
         repaired_workflow_states: repaired_workflow_states
       }}
    end
  end

  def workflow_state_colors, do: @workflow_state_colors

  defp ensure_team(config, intent, load_team, create_team) do
    case load_team.(config) do
      {:ok, team} ->
        {:ok, team, false}

      {:error, {:team_not_found, _team_key}} ->
        case create_team.(config, %{"key" => config.team_key, "name" => intent["team_name"]}) do
          {:ok, team} -> {:ok, team, true}
          {:error, reason} -> {:error, {:team_create_failed, config.team_key, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_workflow_states(config, team, intent, create_workflow_state) do
    existing_names = MapSet.new(Enum.map(team.states, & &1.name))

    intent["workflow_states"]
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {state_name, position}, {:ok, created} ->
      if MapSet.member?(existing_names, state_name) do
        {:cont, {:ok, created}}
      else
        attrs = %{
          "color" => workflow_state_color(state_name),
          "name" => state_name,
          "position" => position,
          "teamId" => team.id,
          "type" => workflow_state_type(state_name)
        }

        case create_workflow_state.(config, attrs) do
          {:ok, _state} ->
            {:cont, {:ok, created ++ [state_name]}}

          {:error, reason} ->
            {:halt, {:error, {:workflow_state_create_failed, state_name, reason}}}
        end
      end
    end)
  end

  defp repair_workflow_state_colors(_config, _team, _intent, nil), do: {:ok, []}

  defp repair_workflow_state_colors(config, team, intent, update_fn) do
    required_names = MapSet.new(intent["workflow_states"])

    team.states
    |> Enum.filter(fn state -> MapSet.member?(required_names, state.name) end)
    |> Enum.filter(fn state ->
      expected = workflow_state_color(state.name)
      Map.get(state, :color) != expected
    end)
    |> Enum.reduce_while({:ok, []}, fn state, {:ok, repaired} ->
      expected_color = workflow_state_color(state.name)

      case update_fn.(config, %{"id" => state.id, "color" => expected_color}) do
        {:ok, _} ->
          {:cont, {:ok, repaired ++ [state.name]}}

        {:error, reason} ->
          {:halt, {:error, {:workflow_state_update_failed, state.name, reason}}}
      end
    end)
  end

  defp workflow_state_type("Todo"), do: "unstarted"
  defp workflow_state_type("Done"), do: "completed"
  defp workflow_state_type(_state_name), do: "started"

  defp workflow_state_color(state_name) do
    Map.get(@workflow_state_colors, state_name, "#6b7280")
  end
end
