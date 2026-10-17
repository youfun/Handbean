defmodule Handbean.ErrorTrackerFilter do
  @moduledoc false

  @behaviour ErrorTracker.Filter

  alias Handbean.Log.Redactor

  @discarded_context_keys [
    "live_view.event_params",
    :"live_view.event_params",
    "request.params",
    :"request.params"
  ]

  @impl true
  def sanitize(context) do
    context
    |> Map.drop(@discarded_context_keys)
    |> Redactor.redact()
  end
end
