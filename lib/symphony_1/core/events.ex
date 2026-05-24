defmodule Symphony1.Core.Events do
  defstruct [:name, :timestamp, :issue_id, :run_id, payload: %{}]

  @type event_name :: atom()
  @type payload :: map()

  @type t :: %__MODULE__{
          name: event_name(),
          timestamp: DateTime.t(),
          issue_id: String.t() | nil,
          run_id: String.t() | nil,
          payload: payload()
        }

  @spec new(event_name(), map()) :: t()
  def new(event_name, attrs) do
    %__MODULE__{
      name: event_name,
      timestamp: DateTime.utc_now(),
      issue_id: Map.get(attrs, :issue_id),
      run_id: Map.get(attrs, :run_id),
      payload: Map.get(attrs, :payload, %{})
    }
  end

  @spec emit(event_name(), payload()) :: :ok
  def emit(_event_name, _payload) do
    :ok
  end
end
