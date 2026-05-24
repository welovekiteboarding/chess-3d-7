defmodule Symphony1.Core.Linear do
  alias Symphony1.Core.Workflow

  @http_timeout_ms 15_000
  @http_connect_timeout_ms 5_000
  @max_issue_pages 100

  @type config :: %{
          api_key: String.t(),
          team_key: String.t()
        }

  @type requester :: (String.t(), map(), String.t() -> {:ok, map()} | {:error, term()})

  @teams_query """
  query {
    teams {
      nodes {
        id
        key
        name
        states {
          nodes {
            id
            name
            type
            color
          }
        }
      }
    }
  }
  """

  @team_issues_query """
  query TeamIssues($teamId: String!, $after: String) {
    team(id: $teamId) {
      id
      key
      name
      issues(first: 50, after: $after) {
        nodes {
          id
          identifier
          title
          description
          state {
            id
            name
            type
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @transition_issue_mutation """
  mutation TransitionIssue($id: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $id, input: $input) {
      success
      issue {
        id
        identifier
        title
        description
        state {
          id
          name
          type
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation CreateIssue($teamId: String!, $title: String!, $description: String!, $stateId: String!) {
    issueCreate(
      input: {
        teamId: $teamId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        state {
          id
          name
          type
        }
      }
    }
  }
  """

  @create_team_mutation """
  mutation CreateTeam($input: TeamCreateInput!) {
    teamCreate(input: $input) {
      success
      team {
        id
        key
        name
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @create_workflow_state_mutation """
  mutation CreateWorkflowState($input: WorkflowStateCreateInput!) {
    workflowStateCreate(input: $input) {
      success
      workflowState {
        id
        name
        type
      }
    }
  }
  """

  @spec load_team(config(), requester()) :: {:ok, map()} | {:error, term()}
  def load_team(config, requester \\ &request/3) do
    with {:ok, response} <- requester.(@teams_query, %{}, config.api_key),
         {:ok, team} <- find_team(response, config.team_key) do
      {:ok,
       %{
         id: team["id"],
         key: team["key"],
         name: team["name"],
         states: Enum.map(team["states"]["nodes"], &normalize_state/1)
       }}
    end
  end

  @spec poll_eligible_issue(config(), requester()) :: {:ok, map()} | :none | {:error, term()}
  def poll_eligible_issue(config, requester \\ &request/3) do
    poll_issue_in_state(config, "Todo", requester)
  end

  @spec poll_issue_in_state(config(), String.t(), requester()) ::
          {:ok, map()} | :none | {:error, term()}
  def poll_issue_in_state(config, state_name, requester \\ &request/3) do
    with {:ok, issues} <- list_team_issues(config, requester) do
      issues
      |> find_issue_in_state(state_name)
    end
  end

  @spec poll_issues_in_state(config(), String.t(), requester()) ::
          {:ok, [map()]} | {:error, term()}
  def poll_issues_in_state(config, state_name, requester \\ &request/3) do
    with {:ok, issues} <- list_team_issues(config, requester) do
      matching =
        issues
        |> Enum.filter(&(&1.state == state_name))

      {:ok, matching}
    end
  end

  @spec list_team_issues(config(), requester()) :: {:ok, [map()]} | {:error, term()}
  def list_team_issues(config, requester \\ &request/3) do
    with {:ok, team} <- load_team(config, requester),
         {:ok, issues} <- fetch_team_issues(team.id, config.api_key, requester) do
      {:ok,
       issues
       |> Enum.map(&normalize_issue/1)
       |> Enum.map(&Map.put(&1, :team_id, team.id))}
    end
  end

  @spec transition_issue(map(), String.t(), config(), requester()) :: {:ok, map()} | {:error, term()}
  def transition_issue(issue, new_state, config, requester \\ &request/3) do
    transition_issue(issue, new_state, %{}, config, requester)
  end

  @spec transition_issue(map(), String.t(), map(), config(), requester()) ::
          {:ok, map()} | {:error, term()}
  def transition_issue(issue, new_state, attrs, config, requester) do
    with :ok <- Workflow.validate_transition(issue.state, new_state),
         {:ok, team} <- load_team(config, requester),
         {:ok, target_state} <- find_state(team.states, new_state),
         {:ok, response} <-
           requester.(
             @transition_issue_mutation,
             %{
               "id" => issue.id,
               "input" =>
                 attrs
                 |> Map.put("stateId", target_state.id)
             },
             config.api_key
           ),
         {:ok, updated_issue} <- extract_updated_issue(response) do
      {:ok, merge_issue_fields(issue, normalize_issue(updated_issue))}
    end
  end

  @spec create_issue(config(), map(), requester()) :: {:ok, map()} | {:error, term()}
  def create_issue(config, attrs, requester \\ &request/3) do
    with {:ok, team} <- load_team(config, requester),
         {:ok, target_state} <- find_state(team.states, attrs["state"]),
         {:ok, response} <-
           requester.(
             @create_issue_mutation,
             %{
               "teamId" => team.id,
               "title" => attrs["title"],
               "description" => attrs["description"],
               "stateId" => target_state.id
             },
             config.api_key
           ),
         {:ok, issue} <- extract_created_issue(response) do
      {:ok, Map.put(normalize_issue(issue), :team_id, team.id)}
    end
  end

  @spec create_team(map(), map(), requester()) :: {:ok, map()} | {:error, term()}
  def create_team(config, attrs, requester \\ &request/3) do
    with {:ok, response} <-
           requester.(
             @create_team_mutation,
             %{
               "input" => %{
                 "key" => attrs["key"],
                 "name" => attrs["name"]
               }
             },
             config.api_key
           ),
         {:ok, team} <- extract_created_team(response) do
      {:ok,
       %{
         id: team["id"],
         key: team["key"],
         name: team["name"],
         states: Enum.map(team["states"]["nodes"], &normalize_state/1)
       }}
    end
  end

  @spec create_workflow_state(map(), map(), requester()) :: {:ok, map()} | {:error, term()}
  def create_workflow_state(config, attrs, requester \\ &request/3) do
    with {:ok, response} <-
           requester.(
             @create_workflow_state_mutation,
             %{
               "input" => %{
                 "color" => attrs["color"],
                 "name" => attrs["name"],
                 "position" => attrs["position"],
                 "teamId" => attrs["teamId"],
                 "type" => attrs["type"]
               }
             },
             config.api_key
           ),
         {:ok, state} <- extract_created_workflow_state(response) do
      {:ok, normalize_state(state)}
    end
  end

  @update_workflow_state_mutation """
  mutation UpdateWorkflowState($id: String!, $input: WorkflowStateUpdateInput!) {
    workflowStateUpdate(id: $id, input: $input) {
      success
      workflowState {
        id
        name
        type
      }
    }
  }
  """

  @spec update_workflow_state(map(), map(), requester()) :: {:ok, map()} | {:error, term()}
  def update_workflow_state(config, attrs, requester \\ &request/3) do
    with {:ok, response} <-
           requester.(
             @update_workflow_state_mutation,
             %{
               "id" => attrs["id"],
               "input" => Map.drop(attrs, ["id"])
             },
             config.api_key
           ) do
      case response do
        %{"data" => %{"workflowStateUpdate" => %{"success" => true, "workflowState" => state}}} ->
          {:ok, normalize_state(state)}

        %{"data" => %{"workflowStateUpdate" => %{"success" => false}}} ->
          {:error, :update_failed}

        %{"errors" => errors} ->
          {:error, {:graphql_error, errors}}
      end
    end
  end

  @spec request(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def request(query, variables, api_key) do
    :inets.start()
    :ssl.start()

    payload = Jason.encode!(%{query: query, variables: variables})

    headers = [
      {~c"Content-Type", ~c"application/json"},
      {~c"Authorization", String.to_charlist(api_key)}
    ]

    request = {~c"https://api.linear.app/graphql", headers, ~c"application/json", payload}
    http_client = http_client_module()
    http_options = [timeout: @http_timeout_ms, connect_timeout: @http_connect_timeout_ms]

    with {:ok, {{_http_version, 200, _reason_phrase}, _headers, body}} <-
           http_client.request(:post, request, http_options, []),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:ok, {{_http_version, status, _reason_phrase}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_client_module do
    Application.get_env(:symphony_1, :linear_http_client, :httpc)
  end

  defp find_team(%{"data" => %{"teams" => %{"nodes" => teams}}}, team_key) do
    case Enum.find(teams, &(&1["key"] == team_key)) do
      nil -> {:error, {:team_not_found, team_key}}
      team -> {:ok, team}
    end
  end

  defp find_team(%{"errors" => errors}, _team_key), do: {:error, {:graphql_error, errors}}
  defp find_team(_response, team_key), do: {:error, {:team_not_found, team_key}}

  defp fetch_team_issues(team_id, api_key, requester, after_cursor \\ nil, acc \\ [], page_count \\ 0)

  defp fetch_team_issues(_team_id, _api_key, _requester, _after_cursor, _acc, page_count)
       when page_count >= @max_issue_pages do
    {:error, {:too_many_issue_pages, @max_issue_pages}}
  end

  defp fetch_team_issues(team_id, api_key, requester, after_cursor, acc, page_count) do
    with {:ok, response} <- requester.(@team_issues_query, %{"teamId" => team_id, "after" => after_cursor}, api_key),
         {:ok, issues, page_info} <- extract_issues_page(response) do
      combined = acc ++ issues

      if page_info["hasNextPage"] do
        fetch_team_issues(team_id, api_key, requester, page_info["endCursor"], combined, page_count + 1)
      else
        {:ok, combined}
      end
    end
  end

  defp extract_issues_page(%{"data" => %{"team" => %{"issues" => %{"nodes" => issues, "pageInfo" => page_info}}}}),
    do: {:ok, issues, page_info}

  defp extract_issues_page(%{"data" => %{"team" => %{"issues" => %{"nodes" => issues}}}}),
    do: {:ok, issues, %{"hasNextPage" => false, "endCursor" => nil}}

  defp extract_issues_page(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_issues_page(_response), do: {:ok, [], %{"hasNextPage" => false, "endCursor" => nil}}

  defp extract_updated_issue(%{"data" => %{"issueUpdate" => %{"success" => true, "issue" => issue}}}),
    do: {:ok, issue}

  defp extract_updated_issue(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_updated_issue(_response), do: {:error, :issue_update_failed}

  defp extract_created_issue(%{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}),
    do: {:ok, issue}

  defp extract_created_issue(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_created_issue(_response), do: {:error, :issue_create_failed}

  defp extract_created_team(%{"data" => %{"teamCreate" => %{"success" => true, "team" => team}}}),
    do: {:ok, team}

  defp extract_created_team(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_created_team(_response), do: {:error, :team_create_failed}

  defp extract_created_workflow_state(%{
         "data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => state}}
       }),
       do: {:ok, state}

  defp extract_created_workflow_state(%{"errors" => errors}), do: {:error, {:graphql_error, errors}}
  defp extract_created_workflow_state(_response), do: {:error, :workflow_state_create_failed}

  defp find_issue_in_state(issues, state_name) do
    case Enum.find(issues, &(&1.state == state_name)) do
      nil -> :none
      issue -> {:ok, issue}
    end
  end

  defp find_state(states, state_name) do
    case Enum.find(states, &(&1.name == state_name)) do
      nil -> {:error, {:state_not_found, state_name}}
      state -> {:ok, state}
    end
  end

  defp normalize_issue(issue) do
    %{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      state: issue["state"]["name"],
      state_id: issue["state"]["id"],
      state_type: issue["state"]["type"]
    }
  end

  defp merge_issue_fields(existing_issue, updated_issue) do
    Enum.reduce(updated_issue, existing_issue, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_state(state) do
    %{
      id: state["id"],
      name: state["name"],
      type: state["type"],
      color: state["color"]
    }
  end
end
