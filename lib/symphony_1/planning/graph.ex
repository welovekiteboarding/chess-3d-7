defmodule Symphony1.Planning.Graph do
  @moduledoc """
  Repo-local planning graph — the system of record for task planning.

  Stores tasks, dependencies, statuses, and materialization metadata
  (task-to-Linear mappings) in a single JSON artifact. Validates graph
  integrity (missing deps, cycles, status values) and answers readiness queries.

  ## On-Disk Schema (JSON, version 1)

      {
        "version": 1,
        "tasks": [
          {
            "id":                  "task-1",
            "title":               "Short task name",
            "description":         "What the task requires",
            "acceptance_criteria":  ["Criterion 1", "Criterion 2"],
            "dependencies":        ["task-0"],
            "status":              "pending",
            "materialization": {
              "materialized":            false,
              "linear_issue_id":         null,
              "linear_issue_identifier": null
            }
          }
        ]
      }

  ### Status values

  | Status        | Meaning                                       |
  |---------------|-----------------------------------------------|
  | `pending`     | Not yet started or materialized                |
  | `in_progress` | Materialized into Linear and being worked on   |
  | `done`        | Completed — unlocks dependents                 |
  | `rework`      | Failed execution — needs manual attention      |

  ### Materialization metadata

  Task-to-Linear mappings live inside each task node, not in a sidecar file.
  When a task is materialized into Linear, `materialized` is set to `true` and
  `linear_issue_id` / `linear_issue_identifier` are populated. Reruns skip
  already-materialized tasks.

  ### Retry and failure history

  When a task reaches `rework`, `retry_task/2` re-queues it:

  - copies `linear_issue_id` and `linear_issue_identifier` from the current
    materialization into `last_failure`
  - clears the active materialization mapping
  - sets status to `pending`

  `last_failure` is optional. It preserves the identity of the prior failed
  Linear issue so the operator can trace what happened. The `reason` and
  `stage` fields exist in the struct but are **not populated automatically**
  by `retry_task/2` — they are available for manual annotation or future
  integration with execution-layer error reporting.

  ### Readiness

  A task is "ready" when its status is `pending` and every dependency has
  status `done`. Tasks with status `in_progress`, `done`, or `rework` are
  never ready.
  """

  alias __MODULE__

  @valid_statuses ~w(pending in_progress done rework)
  @allowed_update_keys [:status, :materialization]

  defmodule Materialization do
    @moduledoc false

    @type t :: %__MODULE__{
            materialized: boolean(),
            linear_issue_id: String.t() | nil,
            linear_issue_identifier: String.t() | nil
          }

    defstruct materialized: false,
              linear_issue_id: nil,
              linear_issue_identifier: nil
  end

  defmodule LastFailure do
    @moduledoc false

    @type t :: %__MODULE__{
            linear_issue_id: String.t() | nil,
            linear_issue_identifier: String.t() | nil,
            reason: String.t() | nil,
            stage: String.t() | nil,
            category: String.t() | nil
          }

    defstruct linear_issue_id: nil,
              linear_issue_identifier: nil,
              reason: nil,
              stage: nil,
              category: nil
  end

  defmodule Scope do
    @moduledoc false

    @type t :: %__MODULE__{
            include: [String.t()],
            exclude: [String.t()]
          }

    defstruct include: [], exclude: []
  end

  defmodule Validation do
    @moduledoc false

    @type t :: %__MODULE__{
            commands: [String.t()],
            required: boolean()
          }

    defstruct commands: [], required: false
  end

  defmodule Task do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            description: String.t(),
            acceptance_criteria: [String.t()],
            dependencies: [String.t()],
            status: String.t(),
            materialization: Symphony1.Planning.Graph.Materialization.t(),
            last_failure: Symphony1.Planning.Graph.LastFailure.t() | nil,
            kind: String.t() | nil,
            scope: Symphony1.Planning.Graph.Scope.t() | nil,
            validation: Symphony1.Planning.Graph.Validation.t() | nil
          }

    defstruct [
      :id,
      :title,
      :description,
      :acceptance_criteria,
      :dependencies,
      :status,
      :materialization,
      :last_failure,
      :kind,
      :scope,
      :validation
    ]
  end

  @type t :: %Graph{version: integer(), tasks: [Task.t()]}
  defstruct version: nil, tasks: []

  @required_task_fields ~w(id title description acceptance_criteria dependencies status materialization)

  # -- Load / Write --

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  @spec write(t(), String.t()) :: :ok | {:error, term()}
  def write(%Graph{} = graph, path) do
    with :ok <- validate(graph) do
      json =
        %{
          "version" => graph.version,
          "tasks" => Enum.map(graph.tasks, &task_to_map/1)
        }
        |> Jason.encode!(pretty: true)

      atomic_write(path, json)
    end
  end

  # -- Validation --

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%Graph{} = graph) do
    with :ok <- validate_statuses(graph),
         :ok <- validate_dependencies(graph),
         :ok <- validate_no_cycles(graph) do
      :ok
    end
  end

  @doc "Returns the list of valid task status values."
  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  @doc """
  Validates that a task meets the minimum planning quality contract for
  admission into execution (materialization).

  Legacy tasks without kind/scope/validation pass — enforcement only
  applies when execution context fields are present. This keeps old
  graphs loadable while ensuring new rich tasks are well-formed.

  Rules:
  - If `scope` or `validation` is present, `kind` must also be present.
  - If `kind` is present, `acceptance_criteria` must be non-empty.
  - If `validation.required` is true, `validation.commands` must be non-empty.
  """
  @spec validate_task_admission(Task.t()) :: :ok | {:error, term()}
  def validate_task_admission(%Task{} = task) do
    has_context = task.kind != nil || task.scope != nil || task.validation != nil

    cond do
      not has_context ->
        :ok

      task.kind == nil ->
        {:error, {:admission_failed, task.id, "missing kind"}}

      task.acceptance_criteria in [nil, []] ->
        {:error, {:admission_failed, task.id, "missing acceptance_criteria"}}

      task.validation != nil && task.validation.required && task.validation.commands in [nil, []] ->
        {:error, {:admission_failed, task.id, "validation required but no commands"}}

      true ->
        :ok
    end
  end

  # -- Queries --

  @spec find_task_by_issue_identifier(t(), String.t()) :: {:ok, Task.t()} | :none
  def find_task_by_issue_identifier(%Graph{tasks: tasks}, identifier) do
    case Enum.find(tasks, fn t ->
           t.materialization && t.materialization.linear_issue_identifier == identifier
         end) do
      nil -> :none
      task -> {:ok, task}
    end
  end

  @doc """
  Returns in_progress tasks with a stored linear_issue_identifier.
  These are candidates for stale-state reconciliation.
  """
  @spec stale_in_progress_tasks(t()) :: [Task.t()]
  def stale_in_progress_tasks(%Graph{tasks: tasks}) do
    Enum.filter(tasks, fn t ->
      t.status == "in_progress" &&
        t.materialization &&
        t.materialization.linear_issue_identifier != nil
    end)
  end

  @doc """
  Applies a reconciliation outcome to a task by id.

  Outcomes:
  - `:done` — sets status to "done", preserves materialization
  - `:rework` — sets status to "rework", preserves materialization
  - `:missing` — sets status to "pending", clears materialization
  - `:todo` — sets status to "pending", preserves materialization
  """
  @spec reconcile_task(t(), String.t(), :done | :rework | :missing | :todo) :: {:ok, t()} | {:error, term()}
  def reconcile_task(%Graph{} = graph, task_id, outcome) do
    case Enum.find_index(graph.tasks, &(&1.id == task_id)) do
      nil ->
        {:error, {:task_not_found, task_id}}

      index ->
        task = Enum.at(graph.tasks, index)
        updated = apply_reconciliation(task, outcome)
        {:ok, %{graph | tasks: List.replace_at(graph.tasks, index, updated)}}
    end
  end

  defp apply_reconciliation(task, :done), do: %{task | status: "done"}
  defp apply_reconciliation(task, :rework), do: %{task | status: "rework"}
  defp apply_reconciliation(task, :todo), do: %{task | status: "pending"}

  defp apply_reconciliation(task, :missing) do
    %{task | status: "pending", materialization: %Materialization{}}
  end

  @spec ready_tasks(t()) :: [Task.t()]
  def ready_tasks(%Graph{} = graph) do
    done_ids = done_task_ids(graph)

    Enum.filter(graph.tasks, fn task ->
      task.status == "pending" &&
        Enum.all?(task.dependencies, &MapSet.member?(done_ids, &1))
    end)
  end

  # -- Mutations --

  @spec update_task(t(), String.t(), map()) :: {:ok, t()} | {:error, term()}
  def update_task(%Graph{} = graph, task_id, updates) do
    with :ok <- validate_update_keys(updates),
         :ok <- validate_update_status(updates) do
      case Enum.find_index(graph.tasks, &(&1.id == task_id)) do
        nil ->
          {:error, {:task_not_found, task_id}}

        index ->
          updated_task = apply_updates(Enum.at(graph.tasks, index), updates)
          {:ok, %{graph | tasks: List.replace_at(graph.tasks, index, updated_task)}}
      end
    end
  end

  @doc """
  Records a structured execution failure for the task matched by
  `linear_issue_identifier`. Sets status to `rework` and populates
  `last_failure` with the issue identity, failure stage, and reason.

  Returns `:none` if no task matches the identifier.
  Pure graph update — does not perform disk IO.
  """
  @spec record_task_failure(t(), String.t(), map()) :: {:ok, t()} | :none
  def record_task_failure(%Graph{} = graph, issue_identifier, failure_context) do
    case Enum.find_index(graph.tasks, fn t ->
           t.materialization && t.materialization.linear_issue_identifier == issue_identifier
         end) do
      nil ->
        :none

      index ->
        task = Enum.at(graph.tasks, index)

        updated = %{
          task
          | status: "rework",
            last_failure: %LastFailure{
              linear_issue_id: task.materialization.linear_issue_id,
              linear_issue_identifier: task.materialization.linear_issue_identifier,
              stage: Map.get(failure_context, :stage),
              reason: Map.get(failure_context, :reason),
              category: Map.get(failure_context, :category)
            }
        }

        {:ok, %{graph | tasks: List.replace_at(graph.tasks, index, updated)}}
    end
  end

  @spec retry_task(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def retry_task(%Graph{} = graph, task_id) do
    case Enum.find_index(graph.tasks, &(&1.id == task_id)) do
      nil ->
        {:error, {:task_not_found, task_id}}

      index ->
        task = Enum.at(graph.tasks, index)

        if task.status != "rework" do
          {:error, {:not_rework, task_id, task.status}}
        else
          existing_failure = task.last_failure

          retried = %{
            task
            | status: "pending",
              last_failure: %LastFailure{
                linear_issue_id: task.materialization.linear_issue_id,
                linear_issue_identifier: task.materialization.linear_issue_identifier,
                stage: if(existing_failure, do: existing_failure.stage),
                reason: if(existing_failure, do: existing_failure.reason),
                category: if(existing_failure, do: existing_failure.category)
              },
              materialization: %Materialization{}
          }

          {:ok, %{graph | tasks: List.replace_at(graph.tasks, index, retried)}}
        end
    end
  end

  # -- Private: Parsing --

  defp parse(contents) do
    case Jason.decode(contents) do
      {:ok, data} -> normalize(data)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp normalize(data) do
    with :ok <- require_key(data, "version", "missing version"),
         :ok <- require_key(data, "tasks", "missing tasks"),
         {:ok, tasks} <- normalize_tasks(data["tasks"]),
         :ok <- check_duplicate_ids(tasks) do
      graph = %Graph{version: data["version"], tasks: tasks}

      case validate(graph) do
        :ok -> {:ok, graph}
        error -> error
      end
    end
  end

  defp require_key(data, key, message) do
    if Map.has_key?(data, key), do: :ok, else: {:error, {:invalid_schema, message}}
  end

  defp normalize_tasks(tasks) do
    tasks
    |> Enum.reduce_while({:ok, []}, fn raw_task, {:ok, acc} ->
      case normalize_task(raw_task) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      error -> error
    end
  end

  defp normalize_task(raw) do
    id = raw["id"] || "unknown"
    missing = Enum.filter(@required_task_fields, &(not Map.has_key?(raw, &1)))

    cond do
      missing != [] ->
        {:error, {:invalid_task, id, "missing fields: #{Enum.join(missing, ", ")}"}}

      raw["status"] not in @valid_statuses ->
        {:error, {:invalid_task, id, "invalid status: #{raw["status"]}"}}

      true ->
        mat = raw["materialization"] || %{}
        lf = raw["last_failure"]

        {:ok,
         %Task{
           id: raw["id"],
           title: raw["title"],
           description: raw["description"],
           acceptance_criteria: raw["acceptance_criteria"],
           dependencies: raw["dependencies"],
           status: raw["status"],
           materialization: %Materialization{
             materialized: mat["materialized"] || false,
             linear_issue_id: mat["linear_issue_id"],
             linear_issue_identifier: mat["linear_issue_identifier"]
           },
           last_failure: normalize_last_failure(lf),
           kind: raw["kind"],
           scope: normalize_scope(raw["scope"]),
           validation: normalize_validation(raw["validation"])
         }}
    end
  end

  defp normalize_last_failure(nil), do: nil

  defp normalize_last_failure(lf) do
    %LastFailure{
      linear_issue_id: lf["linear_issue_id"],
      linear_issue_identifier: lf["linear_issue_identifier"],
      reason: lf["reason"],
      stage: lf["stage"],
      category: lf["category"]
    }
  end

  defp normalize_scope(nil), do: nil

  defp normalize_scope(s) do
    %Scope{
      include: s["include"] || [],
      exclude: s["exclude"] || []
    }
  end

  defp normalize_validation(nil), do: nil

  defp normalize_validation(v) do
    %Validation{
      commands: v["commands"] || [],
      required: v["required"] || false
    }
  end

  defp check_duplicate_ids(tasks) do
    ids = Enum.map(tasks, & &1.id)
    dupes = ids -- Enum.uniq(ids)

    if dupes == [] do
      :ok
    else
      {:error, {:duplicate_task_ids, Enum.uniq(dupes)}}
    end
  end

  # -- Private: Validation --

  defp validate_statuses(%Graph{tasks: tasks}) do
    bad =
      Enum.reject(tasks, fn task -> task.status in @valid_statuses end)

    if bad == [] do
      :ok
    else
      first = hd(bad)
      {:error, {:invalid_task, first.id, "invalid status: #{first.status}"}}
    end
  end

  defp validate_dependencies(%Graph{tasks: tasks}) do
    all_ids = MapSet.new(tasks, & &1.id)

    missing =
      tasks
      |> Enum.map(fn task ->
        bad_deps = Enum.reject(task.dependencies, &MapSet.member?(all_ids, &1))
        {task.id, bad_deps}
      end)
      |> Enum.reject(fn {_id, bad} -> bad == [] end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_dependencies, missing}}
    end
  end

  defp validate_no_cycles(%Graph{tasks: tasks}) do
    adj = Map.new(tasks, fn t -> {t.id, t.dependencies} end)
    ids = Enum.map(tasks, & &1.id)

    case topological_sort(ids, adj) do
      {:ok, _order} -> :ok
      {:error, cycle} -> {:error, {:cycle_detected, cycle}}
    end
  end

  defp validate_update_keys(updates) do
    unknown = Map.keys(updates) -- @allowed_update_keys

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_update_keys, unknown}}
    end
  end

  defp validate_update_status(%{status: status}) when status not in @valid_statuses do
    {:error, {:invalid_status, status}}
  end

  defp validate_update_status(_updates), do: :ok

  # Kahn's algorithm for topological sort / cycle detection.
  defp topological_sort(ids, adj) do
    # adj[id] = list of ids that `id` depends on. So id's in-degree = length(adj[id]).
    in_degree =
      Map.new(ids, fn id -> {id, length(Map.get(adj, id, []))} end)

    queue = Enum.filter(ids, fn id -> Map.get(in_degree, id) == 0 end)
    process_queue(queue, in_degree, adj, ids, [])
  end

  defp process_queue([], in_degree, _adj, all_ids, sorted) do
    remaining = Enum.filter(all_ids, fn id -> Map.get(in_degree, id, 0) > 0 end)

    if remaining == [] do
      {:ok, Enum.reverse(sorted)}
    else
      {:error, remaining}
    end
  end

  defp process_queue([node | rest], in_degree, adj, all_ids, sorted) do
    dependents =
      Enum.filter(all_ids, fn id ->
        id != node && node in Map.get(adj, id, [])
      end)

    in_degree =
      Enum.reduce(dependents, in_degree, fn dep, deg ->
        Map.update!(deg, dep, &(&1 - 1))
      end)

    new_ready =
      Enum.filter(dependents, fn dep -> Map.get(in_degree, dep) == 0 end)

    in_degree = Map.put(in_degree, node, -1)
    process_queue(rest ++ new_ready, in_degree, adj, all_ids, [node | sorted])
  end

  # -- Private: Queries --

  defp done_task_ids(%Graph{tasks: tasks}) do
    tasks
    |> Enum.filter(&(&1.status == "done"))
    |> MapSet.new(& &1.id)
  end

  # -- Private: Mutations --

  defp apply_updates(task, updates) do
    task
    |> maybe_update_status(updates)
    |> maybe_update_materialization(updates)
  end

  defp maybe_update_status(task, %{status: status}), do: %{task | status: status}
  defp maybe_update_status(task, _), do: task

  defp maybe_update_materialization(task, %{materialization: mat}) do
    case normalize_materialization_update(mat) do
      {:ok, normalized} ->
        %{
          task
          | materialization: %Materialization{
              materialized: normalized.materialized,
              linear_issue_id: normalized.linear_issue_id,
              linear_issue_identifier: normalized.linear_issue_identifier
            }
        }

      {:error, :invalid_materialization} ->
        raise ArgumentError, "materialization update must be a map or Materialization struct"
    end
  end

  defp maybe_update_materialization(task, _), do: task

  defp normalize_materialization_update(%Materialization{} = mat), do: {:ok, mat}

  defp normalize_materialization_update(mat) when is_map(mat) do
    {:ok,
     %Materialization{
       materialized: materialization_value(mat, :materialized, false),
       linear_issue_id: materialization_value(mat, :linear_issue_id),
       linear_issue_identifier: materialization_value(mat, :linear_issue_identifier)
     }}
  end

  defp normalize_materialization_update(_), do: {:error, :invalid_materialization}

  defp materialization_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp atomic_write(path, contents) do
    temp_path = "#{path}.#{System.unique_integer([:positive, :monotonic])}.tmp"
    file_ops = file_ops_module()
    temp_device = {:temp_device, temp_path}

    with {:ok, device} <- wrap_atomic_open(file_ops.open(temp_path, [:write, :binary, :raw])),
         :ok <- wrap_atomic_stage(:write, file_ops.file_write(device, contents)),
         :ok <- wrap_atomic_stage(:sync, file_ops.datasync(device)),
         :ok <- wrap_atomic_stage(:close, file_ops.close(device)),
         :ok <- wrap_atomic_stage(:rename, file_ops.rename(temp_path, path)) do
      :ok
    else
      {:error, {:atomic_write_failed, _stage, _reason}} = error ->
        _ = safe_close_temp(file_ops, temp_device)
        _ = safe_delete_temp(file_ops, temp_path)
        error

      error ->
        _ = safe_close_temp(file_ops, temp_device)
        _ = safe_delete_temp(file_ops, temp_path)
        wrap_unexpected_atomic_error(error)
    end
  end

  defp file_ops_module do
    Application.get_env(:symphony_1, :graph_file_ops, __MODULE__)
  end

  defp safe_delete_temp(file_ops, temp_path) do
    if function_exported?(file_ops, :rm, 1) do
      file_ops.rm(temp_path)
    else
      :ok
    end
  end

  defp safe_close_temp(file_ops, {:temp_device, temp_path}) do
    if function_exported?(file_ops, :open, 2) and function_exported?(file_ops, :close, 1) do
      case file_ops.open(temp_path, [:read, :raw]) do
        {:ok, device} -> file_ops.close(device)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp wrap_atomic_open({:ok, device}), do: {:ok, device}
  defp wrap_atomic_open({:error, reason}), do: {:error, {:atomic_write_failed, :open, reason}}
  defp wrap_atomic_open(other), do: {:error, {:atomic_write_failed, :open, other}}

  defp wrap_atomic_stage(_stage, :ok), do: :ok
  defp wrap_atomic_stage(stage, {:error, reason}), do: {:error, {:atomic_write_failed, stage, reason}}
  defp wrap_atomic_stage(stage, other), do: {:error, {:atomic_write_failed, stage, other}}

  defp wrap_unexpected_atomic_error({:error, {:atomic_write_failed, _stage, _reason}} = error), do: error
  defp wrap_unexpected_atomic_error(error), do: {:error, {:atomic_write_failed, :unknown, error}}

  @doc false
  def open(path, modes), do: File.open(path, modes)

  @doc false
  def file_write(device, contents) do
    case IO.binwrite(device, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def datasync(device), do: :file.datasync(device)

  @doc false
  def close(device), do: File.close(device)

  @doc false
  def rename(source, destination), do: File.rename(source, destination)

  @doc false
  def rm(path), do: File.rm(path)

  # -- Private: Serialization --

  defp task_to_map(%Task{} = task) do
    base = %{
      "id" => task.id,
      "title" => task.title,
      "description" => task.description,
      "acceptance_criteria" => task.acceptance_criteria,
      "dependencies" => task.dependencies,
      "status" => task.status,
      "materialization" => %{
        "materialized" => task.materialization.materialized,
        "linear_issue_id" => task.materialization.linear_issue_id,
        "linear_issue_identifier" => task.materialization.linear_issue_identifier
      }
    }

    base
    |> maybe_put("last_failure", serialize_last_failure(task.last_failure))
    |> maybe_put("kind", task.kind)
    |> maybe_put("scope", serialize_scope(task.scope))
    |> maybe_put("validation", serialize_validation(task.validation))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp serialize_last_failure(nil), do: nil

  defp serialize_last_failure(lf) do
    base = %{
      "linear_issue_id" => lf.linear_issue_id,
      "linear_issue_identifier" => lf.linear_issue_identifier,
      "reason" => lf.reason,
      "stage" => lf.stage
    }

    maybe_put(base, "category", lf.category)
  end

  defp serialize_scope(nil), do: nil
  defp serialize_scope(s), do: %{"include" => s.include, "exclude" => s.exclude}

  defp serialize_validation(nil), do: nil
  defp serialize_validation(v), do: %{"commands" => v.commands, "required" => v.required}
end
