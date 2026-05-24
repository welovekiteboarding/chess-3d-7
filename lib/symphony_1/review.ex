defmodule Symphony1.Review do
  @moduledoc """
  Repo-local review boundary for PR approval artifacts.
  """

  alias Symphony1.Core.Worker

  @review_root_segments ["tmp", "reviews"]
  @default_review_timeout_ms 300_000
  @required_doc_paths [
    "docs/project-orientation-and-source-of-truth.md",
    "docs/status.md"
  ]

  @spec review(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def review(candidate, opts \\ []) do
    review_runner = Keyword.get_lazy(opts, :review_runner, fn -> fn review_candidate -> default_review_runner(review_candidate, opts) end end)
    artifact_writer = Keyword.get(opts, :artifact_writer, &write_artifact/2)

    with {:ok, decision} <- review_runner.(candidate),
         {:ok, artifact} <- build_artifact(candidate, decision),
         :ok <- artifact_writer.(artifact_path(candidate.repo_root, candidate.issue.identifier), artifact) do
      {:ok, artifact}
    end
  end

  @spec read_artifact(String.t(), String.t()) :: {:ok, map()} | :missing | {:error, term()}
  def read_artifact(repo_root, issue_identifier) do
    path = artifact_path(repo_root, issue_identifier)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, artifact} -> {:ok, artifact}
          {:error, reason} -> {:error, {:invalid_artifact, reason}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:artifact_read_failed, reason}}
    end
  end

  @spec artifact_path(String.t(), String.t()) :: String.t()
  def artifact_path(repo_root, issue_identifier) do
    Path.join([repo_root] ++ @review_root_segments ++ ["#{issue_identifier}.json"])
  end

  defp build_artifact(candidate, decision) when is_map(decision) do
    outcome = Map.get(decision, "outcome") || Map.get(decision, :outcome)
    findings = Map.get(decision, "findings") || Map.get(decision, :findings)

    cond do
      outcome in ["approved", "changes_requested"] and is_list(findings) ->
        {:ok,
         %{
           "issue_identifier" => candidate.issue.identifier,
           "graph_task_id" => Map.get(candidate, :graph_task_id),
           "pull_request_url" => candidate.pull_request.url,
           "commit_sha" => candidate.commit_sha,
           "outcome" => outcome,
           "findings" => findings,
           "reviewed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
           "model" => Map.get(decision, "model") || Map.get(decision, :model) || "gpt-5.4"
         }}

      is_binary(outcome) ->
        {:error, {:invalid_review_outcome, outcome}}

      true ->
        {:error, {:invalid_review_decision, decision}}
    end
  end

  defp build_artifact(_candidate, decision) do
    {:error, {:invalid_review_decision, decision}}
  end

  defp write_artifact(path, artifact) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, Jason.encode!(artifact, pretty: true))
  end

  defp default_review_runner(candidate, opts) do
    worker = Keyword.get(opts, :worker, Worker)
    review_timeout_ms = Keyword.get(opts, :review_timeout_ms, @default_review_timeout_ms)

    with {:ok, session} <- worker_start_session(worker, %{workspace: candidate.workspace, workflow_path: candidate.workflow_path}) do
      try do
        with {:ok, result} <- worker_run_prompt(worker, session, review_prompt(candidate), timeout_ms: review_timeout_ms),
             {:ok, decision} <- parse_review_output(result.output) do
          {:ok, decision}
        end
      after
        _ = worker_stop_session(worker, session)
      end
    end
  end

  defp parse_review_output(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, decision} -> {:ok, decision}
      {:error, _reason} -> {:error, :invalid_review_output}
    end
  end

  defp review_prompt(candidate) do
    """
    Review the implementation for issue #{candidate.issue.identifier}.

    Pull request: #{candidate.pull_request.url}
    Commit: #{candidate.commit_sha}

    Task context:
    #{format_task_context(Map.get(candidate, :task_context))}

    Scope check:
    #{format_scope_check(Map.get(candidate, :scope_check))}

    Changed files:
    #{Enum.join(Map.get(candidate, :changed_files, []), "\n")}

    Validation summary:
    #{Map.get(candidate, :validation_summary, "Validation passed before PR open.")}

    Relevant docs to read first:
    #{Enum.join(Map.get(candidate, :supporting_docs, @required_doc_paths), "\n")}

    Diff under review:
    #{Map.get(candidate, :diff, "")}

    Pay special attention to scope:
    - approve only if the changed files stay within the declared scope, or any scope expansion is clearly necessary for correctness
    - request changes if excluded files were touched
    - request changes if scope expansion looks like task drift or unnecessary spillover

    Return strict JSON only in this exact shape:
    {"outcome":"approved","findings":[]}
    or
    {"outcome":"changes_requested","findings":["blocking issue 1","blocking issue 2"]}
    """
  end

  defp format_task_context(nil), do: "No graph task context available."

  defp format_task_context(task_context) do
    [
      "Title: #{get_field(task_context, :title)}",
      "Description: #{get_field(task_context, :description)}",
      "Acceptance criteria:",
      format_list(get_field_list(task_context, :acceptance_criteria)),
      "Scope:",
      format_scope(get_field_map(task_context, :scope)),
      "Validation commands:",
      format_list(get_nested_list(task_context, :validation, :commands))
    ]
    |> Enum.join("\n")
  end

  defp format_scope(nil), do: "None provided."

  defp format_scope(scope) do
    include = get_field_list(scope, :include)
    exclude = get_field_list(scope, :exclude)

    [
      "Include:",
      format_list(include),
      "Exclude:",
      format_list(exclude)
    ]
    |> Enum.join("\n")
  end

  defp format_list(nil), do: "- none"
  defp format_list([]), do: "- none"
  defp format_list(items), do: Enum.map_join(items, "\n", &"- #{&1}")

  defp format_scope_check(nil), do: "No scope check available."

  defp format_scope_check(scope_check) do
    status = Map.get(scope_check, :status) || Map.get(scope_check, "status")
    in_scope = Map.get(scope_check, :in_scope) || Map.get(scope_check, "in_scope") || []
    expanded = Map.get(scope_check, :expanded) || Map.get(scope_check, "expanded") || []
    excluded = Map.get(scope_check, :excluded) || Map.get(scope_check, "excluded") || []

    [
      "Status: #{status}",
      "In scope:",
      format_list(in_scope),
      "Expanded:",
      format_list(expanded),
      "Excluded:",
      format_list(excluded)
    ]
    |> Enum.join("\n")
  end

  defp get_field(task_context, key) do
    Map.get(task_context, key) || Map.get(task_context, Atom.to_string(key)) || "None provided."
  end

  defp get_field_list(task_context, key) do
    Map.get(task_context, key) || Map.get(task_context, Atom.to_string(key)) || []
  end

  defp get_field_map(task_context, key) do
    Map.get(task_context, key) || Map.get(task_context, Atom.to_string(key))
  end

  defp get_nested_list(task_context, parent_key, child_key) do
    parent = get_field_map(task_context, parent_key)

    case parent do
      nil -> []
      map when is_map(map) -> get_field_list(map, child_key)
    end
  end

  defp worker_start_session(worker, attrs) when is_map(worker), do: worker.start_session.(attrs)
  defp worker_start_session(worker, attrs), do: worker.start_session(attrs)

  defp worker_run_prompt(worker, session, prompt, opts) when is_map(worker) do
    case :erlang.fun_info(worker.run_prompt, :arity) do
      {:arity, 3} -> worker.run_prompt.(session, prompt, opts)
      {:arity, 2} -> worker.run_prompt.(session, prompt)
    end
  end

  defp worker_run_prompt(worker, session, prompt, opts), do: worker.run_prompt(session, prompt, opts)

  defp worker_stop_session(worker, session) when is_map(worker), do: worker.stop_session.(session)
  defp worker_stop_session(worker, session), do: worker.stop_session(session)
end
