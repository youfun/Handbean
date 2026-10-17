defmodule Handbean.Extension.Hook do
  @moduledoc """
  Behaviour for extension lifecycle hooks.

  Return values:
  - `:ok` — hook processed successfully, continue to next hook
  - `{:ok, state}` — hook processed successfully, pass state to next hook
  - `{:halt, reason}` — stop all subsequent hooks
  - `{:error, reason}` — hook failed but execution continues
  """

  alias Handbean.Extension.Event

  @callback handle_event(Event.t(), map()) ::
              :ok
              | {:ok, map()}
              | {:halt, term()}
              | {:error, term()}

  @optional_callbacks handle_event: 2
end
