defmodule TestHookModule do
  @moduledoc false
  @behaviour Handbean.Extension.Hook

  alias Handbean.Extension.Event

  @impl true
  def handle_event(%Event{}, _ctx) do
    :ok
  end
end
