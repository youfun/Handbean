defmodule Handbean.Agent.Provider.Cursor do
  # credo:disable-for-this-file Credo.Check.Readability.Specs
  @moduledoc """
  Cursor subscription provider using a supervised HTTP/2 Connect session.

  Non-official protocol integration using a minimal interoperability codec.
  Usage/cost is unknown and never reported as zero. `provider_state` only
  carries the session id; the live connection belongs to
  `Handbean.Agent.Provider.Cursor.Session`.

  Context edits are applied by closing that session and replaying the edited
  transcript on a new one. While the old session is waiting for tool results
  it would otherwise keep the deleted text.
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Provider.Cursor.Session

  @impl true
  def complete(messages, tool_defs, config) do
    stream(messages, tool_defs, config, fn _ -> :ok end)
  end

  @impl true
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    with :ok <- require_cursor_model(config),
         {:ok, session_id} <- session_id(messages, config) do
      Session.complete(session_id, messages, tool_defs, config, on_chunk)
    end
  end

  def release(config) when is_map(config) do
    case session_id_from_state(config) do
      {:ok, id} -> Session.close(id)
      _ -> :ok
    end
  end

  defp require_cursor_model(%{model: model}) when is_binary(model) and model != "", do: :ok

  defp require_cursor_model(_),
    do: {:error, "Cursor model is required; refusing to fall back to another provider."}

  defp session_id(_messages, config) do
    case session_id_from_state(config) do
      {:ok, id} ->
        {:ok, id}

      :error ->
        cond do
          is_binary(config[:conversation_id]) -> {:ok, config[:conversation_id]}
          true -> {:ok, Ecto.UUID.generate()}
        end
    end
  end

  defp session_id_from_state(config) do
    case config[:provider_state] do
      %{cursor_session_id: id} when is_binary(id) -> {:ok, id}
      %{"cursor_session_id" => id} when is_binary(id) -> {:ok, id}
      _ -> :error
    end
  end
end
