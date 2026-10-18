defmodule Handbean.Extension.UI do
  @moduledoc """
  Extension→UI communication channel.

  Extensions broadcast UI update instructions via PubSub.
  LiveView subscribes and renders accordingly.

  ## Topic

  Messages are broadcast on per-session topics:
  `"extension:ui:<session_id>"`

  This ensures widget/status messages only reach the LiveView
  that is viewing the relevant conversation.

  ## Message format

      {:ext_ui, %{event: String.t(), session_id: String.t(), ...}}

  Events:
  - `"status"` — footer status text update
  - `"notify"` — user notification (info/warning/error)
  - custom events — extension-defined schema, LiveView interprets
  """

  @doc "Build the PubSub topic for a session. Falls back to global topic when session_id is nil."
  @spec topic(String.t() | nil) :: String.t()
  def topic(session_id \\ nil)
  def topic(nil), do: "extension:ui"
  def topic(session_id), do: "extension:ui:#{session_id}"

  @doc """
  Update footer status text. Pass `nil` to clear.

  Broadcasts on the per-session topic so only the
  LiveView viewing this conversation receives the update.
  """
  @spec set_status(String.t(), String.t() | nil, keyword()) :: :ok
  def set_status(session_id, text, _opts \\ []) do
    Phoenix.PubSub.broadcast(Handbean.PubSub, topic(session_id), {
      :ext_ui,
      %{event: "status", text: text, session_id: session_id}
    })

    :ok
  end

  @doc """
  Show a notification. `type` is \"info\" | \"warning\" | \"error\".

  Broadcasts on the per-session topic.
  """
  @spec notify(String.t(), String.t(), String.t(), keyword()) :: :ok
  def notify(session_id, type, text, _opts \\ []) do
    Phoenix.PubSub.broadcast(Handbean.PubSub, topic(session_id), {
      :ext_ui,
      %{event: "notify", type: type, text: text, session_id: session_id}
    })

    :ok
  end

  @doc """
  Broadcast a custom UI event (extension defines schema, LiveView interprets).

  Broadcasts on the per-session topic.
  """
  @spec broadcast(String.t(), String.t(), map(), keyword()) :: :ok
  def broadcast(session_id, event, data \\ %{}, _opts \\ []) do
    Phoenix.PubSub.broadcast(Handbean.PubSub, topic(session_id), {
      :ext_ui,
      %{event: event, data: data, session_id: session_id}
    })

    :ok
  end
end
