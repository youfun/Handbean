defmodule Handbean.Agent.Provider.Continuation do
  @moduledoc """
  Drops server-side continuation after the model-facing transcript changes.

  OpenAI Responses must not send the previous response id for the edited
  transcript. Cursor keeps history on the live session, so that session is
  closed and the next call replays the edited messages on a new session.
  """

  alias Handbean.Agent.Provider.Cursor.Session
  alias Handbean.Agent.State

  @spec fork(State.t(), pos_integer()) :: map()
  def fork(%State{} = state, generation) when is_integer(generation) and generation > 0 do
    provider_state = state.provider_state || %{}

    provider_state
    |> Map.drop([:response_id, "response_id", :context_generation, "context_generation"])
    |> fork_cursor(state, generation)
  end

  defp fork_cursor(provider_state, %State{config: %{provider: provider}} = state, generation)
       when provider == Handbean.Agent.Provider.Cursor do
    old = cursor_id(provider_state) || conversation_id(state)
    close_session(old)

    Map.put(
      provider_state,
      :cursor_session_id,
      "context-" <> Integer.to_string(generation) <> "-" <> Ecto.UUID.generate()
    )
  end

  defp fork_cursor(provider_state, _state, _generation) do
    Map.drop(provider_state, [:cursor_session_id, "cursor_session_id"])
  end

  defp cursor_id(provider_state) do
    Map.get(provider_state, :cursor_session_id) || Map.get(provider_state, "cursor_session_id")
  end

  defp conversation_id(%State{config: %{context: context}}) when is_map(context) do
    context[:conversation_id]
  end

  defp conversation_id(_state), do: nil

  defp close_session(id) when is_binary(id) and id != "" do
    if Process.whereis(Handbean.CursorSessionRegistry) do
      Session.close(id)
    else
      :ok
    end
  end

  defp close_session(_id), do: :ok
end
