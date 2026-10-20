defmodule Handbean.PubSub.Session.SnapshotCodec do
  @moduledoc false

  alias Handbean.Agent.Message
  alias Handbean.PubSub.AgentEvent

  @spec events(term()) :: [AgentEvent.t()]
  def events(events) when is_list(events) do
    events
    |> Enum.map(fn
      %AgentEvent{} = event -> event
      %{} = event -> struct(AgentEvent, atomize_known_keys(event))
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def events(_events), do: []

  @spec messages(term()) :: [Message.t()]
  def messages(messages) when is_list(messages) do
    messages
    |> Enum.map(fn
      %Message{} = message -> message
      %{} = message -> struct(Message, atomize_known_keys(message))
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def messages(_messages), do: []

  @spec encode(map()) :: map()
  def encode(state) do
    %{
      "seq" => state.seq,
      "events" => Enum.map(state.events, &Map.from_struct/1),
      "control_events" => Enum.map(state.control_events, &Map.from_struct/1),
      "running?" => state.meta.running?,
      "model" => state.model,
      "next_turn_messages" => Enum.map(state.next_turn_messages, &Map.from_struct/1),
      "extension_state" => state.extension_state
    }
  end

  defp atomize_known_keys(map) do
    Map.new(map, fn
      {"seq", value} -> {:seq, value}
      {"epoch", value} -> {:epoch, value}
      {"topic", value} -> {:topic, value}
      {"kind", value} -> {:kind, maybe_existing_atom(value)}
      {"payload", value} -> {:payload, value}
      {"ts_ms", value} -> {:ts_ms, value}
      {"role", value} -> {:role, maybe_existing_atom(value)}
      {"content", value} -> {:content, value}
      {key, value} when is_atom(key) -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  defp maybe_existing_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end
  end

  defp maybe_existing_atom(value), do: value
end
