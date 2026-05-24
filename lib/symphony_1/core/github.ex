defmodule Symphony1.Core.GitHub do
  require Logger

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec find_pull_request_by_branch(map(), command_runner()) :: {:ok, map()} | :none | {:error, term()}
  def find_pull_request_by_branch(attrs, runner \\ &System.cmd/3) do
    args =
      [
        "pr",
        "list"
      ] ++
        repo_args(attrs) ++
        [
          "--head",
          attrs.branch,
          "--state",
          "open",
          "--json",
          "url,title,state,headRefName,baseRefName"
        ]

    case runner.("gh", args, command_options(attrs.cwd)) do
      {output, 0} ->
        output
        |> Jason.decode()
        |> decode_pull_request(attrs)

      {output, exit_status} ->
        {:error, {:command_failed, "gh", exit_status, String.trim(output)}}
    end
  end

  @spec open_pull_request(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def open_pull_request(attrs, runner \\ &System.cmd/3) do
    args = [
      "pr",
      "create",
      "--base",
      attrs.base_branch,
      "--head",
      attrs.branch,
      "--title",
      attrs.title,
      "--body",
      attrs.body
    ]

    started_at = System.monotonic_time(:millisecond)
    Logger.info(
      "symphony.github: pr_create start issue=#{issue_identifier(attrs)} repo=#{inspect(attrs.repo)} branch=#{attrs.branch} base=#{attrs.base_branch} cwd=#{attrs.cwd}"
    )

    case runner.("gh", args, command_options(attrs.cwd)) do
      {output, 0} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        Logger.info(
          "symphony.github: pr_create finish issue=#{issue_identifier(attrs)} repo=#{inspect(attrs.repo)} branch=#{attrs.branch} exit=0 elapsed_ms=#{elapsed_ms} output=#{inspect(String.trim(output))}"
        )

        {:ok,
         %{
           base_branch: attrs.base_branch,
           body: attrs.body,
           branch: attrs.branch,
           cwd: attrs.cwd,
           repo: attrs.repo,
           status: :open,
           title: attrs.title,
           url: String.trim(output)
         }}

      {output, exit_status} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        Logger.warning(
          "symphony.github: pr_create finish issue=#{issue_identifier(attrs)} repo=#{inspect(attrs.repo)} branch=#{attrs.branch} exit=#{exit_status} elapsed_ms=#{elapsed_ms} output=#{inspect(String.trim(output))}"
        )

        {:error, {:command_failed, "gh", exit_status, String.trim(output)}}
    end
  end

  @spec merge_pull_request(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def merge_pull_request(pull_request, runner \\ &System.cmd/3)

  def merge_pull_request(%{status: :open} = pull_request, runner) do
    args = ["pr", "merge", pull_request.url, "--merge"]

    case runner.("gh", args, command_options(pull_request.cwd)) do
      {_output, 0} -> {:ok, %{pull_request | status: :merged}}
      {output, exit_status} -> {:error, {:command_failed, "gh", exit_status, String.trim(output)}}
    end
  end

  def merge_pull_request(pull_request, _runner) do
    {:error, {:invalid_pull_request_status, pull_request.status}}
  end

  defp decode_pull_request({:ok, [%{} = pull_request | _rest]}, attrs) do
    {:ok,
     %{
       base_branch: pull_request["baseRefName"],
       branch: pull_request["headRefName"] || attrs.branch,
       cwd: attrs.cwd,
       repo: attrs.repo,
       status: normalize_pull_request_status(pull_request["state"]),
       title: pull_request["title"],
       url: pull_request["url"]
     }}
  end

  defp decode_pull_request({:ok, []}, _attrs), do: :none
  defp decode_pull_request({:error, reason}, _attrs), do: {:error, reason}

  defp normalize_pull_request_status("OPEN"), do: :open
  defp normalize_pull_request_status("MERGED"), do: :merged
  defp normalize_pull_request_status("CLOSED"), do: :closed
  defp normalize_pull_request_status(_status), do: :unknown

  defp repo_args(%{repo: repo}) when is_binary(repo), do: ["--repo", repo]
  defp repo_args(_attrs), do: []

  defp issue_identifier(%{issue_identifier: issue_identifier}) when is_binary(issue_identifier), do: issue_identifier
  defp issue_identifier(%{issue: %{identifier: issue_identifier}}) when is_binary(issue_identifier), do: issue_identifier
  defp issue_identifier(_attrs), do: "unknown-issue"

  defp command_options(cwd) do
    [cd: cwd, stderr_to_stdout: true]
  end
end
