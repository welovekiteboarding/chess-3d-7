defmodule Symphony1.RuntimeConfig do
  @moduledoc false

  @missing_linear_api_key_message """
  LINEAR_API_KEY is required for this command. Set it in your shell or environment before running Symphony against Linear.
  """

  @spec linear_api_key() :: {:ok, String.t()} | {:error, :missing_linear_api_key}
  def linear_api_key do
    case System.get_env("LINEAR_API_KEY") do
      nil -> {:error, :missing_linear_api_key}
      "" -> {:error, :missing_linear_api_key}
      value -> {:ok, value}
    end
  end

  @spec linear_api_key!() :: String.t()
  def linear_api_key! do
    case linear_api_key() do
      {:ok, value} -> value
      {:error, :missing_linear_api_key} -> raise @missing_linear_api_key_message
    end
  end

  @spec linear_config(String.t()) :: {:ok, %{api_key: String.t(), team_key: String.t()}} | {:error, :missing_linear_api_key}
  def linear_config(team_key) when is_binary(team_key) do
    with {:ok, api_key} <- linear_api_key() do
      {:ok, %{api_key: api_key, team_key: team_key}}
    end
  end

  @spec linear_config!(String.t()) :: %{api_key: String.t(), team_key: String.t()}
  def linear_config!(team_key) when is_binary(team_key) do
    case linear_config(team_key) do
      {:ok, config} -> config
      {:error, :missing_linear_api_key} -> raise @missing_linear_api_key_message
    end
  end

  @spec missing_linear_api_key_message() :: String.t()
  def missing_linear_api_key_message do
    @missing_linear_api_key_message |> String.trim()
  end
end
