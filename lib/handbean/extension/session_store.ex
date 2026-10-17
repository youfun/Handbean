defmodule Handbean.Extension.SessionStore do
  @moduledoc """
  Extension-specific session-local key-value store.

  Data is persisted in the session JSON snapshot under the
  `"extension_state"` key, organized by extension name.

  Extension state:
  - Is NOT sent to the LLM
  - Is NOT visible in conversation transcript
  - Survives session reconnection and snapshot restores
  """

  alias Handbean.PubSub.Session

  @type session_id :: String.t()
  @type extension_name :: String.t()
  @type key :: String.t()

  @doc "Write extension state (by extension_name + key)."
  @spec put(session_id, extension_name, key, term()) :: :ok
  def put(session_id, extension_name, key, value) do
    Session.update_extension_state(session_id, extension_name, key, value)
  end

  @doc "Read extension state. Returns `default` if key is absent."
  @spec get(session_id, extension_name, key, term()) :: term()
  def get(session_id, extension_name, key, default \\ nil) do
    case Session.snapshot(session_id) do
      %{extension_state: ext_state} ->
        ext_map = Map.get(ext_state, extension_name, %{})

        case Map.fetch(ext_map, key) do
          {:ok, value} -> value
          :error -> default
        end

      %{last_seq: _, events: _, meta: _} ->
        default
    end
  end

  @doc "Read all state for an extension."
  @spec get_all(session_id, extension_name) :: %{String.t() => term()}
  def get_all(session_id, extension_name) do
    case Session.snapshot(session_id) do
      %{extension_state: ext_state} ->
        Map.get(ext_state, extension_name, %{})

      _ ->
        %{}
    end
  end

  @doc "Delete a key from extension state."
  @spec delete(session_id, extension_name, key) :: :ok
  def delete(session_id, extension_name, key) do
    Session.delete_extension_state(session_id, extension_name, key)
  end
end
