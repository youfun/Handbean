defmodule Handbean.SessionStore.SQLite do
  @moduledoc """
  SQLite-backed runtime session snapshots.

  A session id is the owning conversation id. Snapshots are projections for
  reconnect and may be replaced atomically; canonical conversation history is
  owned elsewhere.
  """

  @behaviour Handbean.SessionStore

  import Ecto.Query

  alias Handbean.Repo
  alias Handbean.Storage.SessionSnapshot

  @impl true
  def save(session_id, snapshot, _opts \\ []) when is_map(snapshot) do
    session_id = to_string(session_id)

    if Handbean.ConversationStore.exists?(session_id) do
      snapshot = Handbean.SessionStore.prepare_snapshot(snapshot)
      attrs = snapshot_attrs(session_id, snapshot)
      fields = Map.keys(attrs) -- [:conversation_id]

      SessionSnapshot
      |> struct(attrs)
      |> Ecto.Changeset.change()
      |> Repo.insert(
        conflict_target: [:conversation_id],
        on_conflict: {:replace, fields}
      )
      |> case do
        {:ok, _row} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @impl true
  def load(session_id, _opts \\ []) do
    case Repo.get(SessionSnapshot, to_string(session_id)) do
      nil -> {:error, :not_found}
      row -> {:ok, snapshot_from_row(row)}
    end
  end

  @impl true
  def delete(session_id, _opts \\ []) do
    from(snapshot in SessionSnapshot,
      where: snapshot.conversation_id == ^to_string(session_id)
    )
    |> Repo.delete_all()

    :ok
  end

  @impl true
  def list_active(_opts \\ []) do
    ids =
      from(snapshot in SessionSnapshot,
        order_by: [asc: snapshot.conversation_id],
        select: snapshot.conversation_id
      )
      |> Repo.all()

    {:ok, ids}
  end

  @impl true
  def update(session_id, updates, opts \\ []) when is_map(updates) do
    Repo.transaction(fn ->
      existing =
        case load(session_id, opts) do
          {:ok, snapshot} -> snapshot
          {:error, :not_found} -> %{}
        end

      case save(session_id, Map.merge(existing, updates), opts) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_attrs(session_id, snapshot) do
    %{
      conversation_id: to_string(session_id),
      seq: value(snapshot, "seq", 0),
      control_events: wrap_list(value(snapshot, "control_events", [])),
      next_turn_messages: wrap_list(value(snapshot, "next_turn_messages", [])),
      extension_state: value(snapshot, "extension_state", %{}),
      model: value(snapshot, "model", nil)
    }
    |> maybe_put_snapshot(snapshot)
  end

  defp maybe_put_snapshot(attrs, snapshot) do
    if :snapshot in SessionSnapshot.__schema__(:fields) do
      Map.put(attrs, :snapshot, snapshot)
    else
      attrs
    end
  end

  defp snapshot_from_row(row) do
    case Map.get(row, :snapshot) do
      snapshot when is_map(snapshot) -> snapshot
      _ -> materialized_snapshot(row)
    end
  end

  defp materialized_snapshot(row) do
    control_events = unwrap_list(row.control_events)

    %{
      "seq" => row.seq,
      "events" => control_events,
      "control_events" => control_events,
      "next_turn_messages" => unwrap_list(row.next_turn_messages),
      "extension_state" => row.extension_state || %{},
      "model" => row.model
    }
  end

  defp value(map, "seq", default), do: Map.get(map, "seq", Map.get(map, :seq, default))

  defp value(map, "control_events", default),
    do: Map.get(map, "control_events", Map.get(map, :control_events, default))

  defp value(map, "next_turn_messages", default),
    do: Map.get(map, "next_turn_messages", Map.get(map, :next_turn_messages, default))

  defp value(map, "extension_state", default),
    do: Map.get(map, "extension_state", Map.get(map, :extension_state, default))

  defp value(map, "model", default), do: Map.get(map, "model", Map.get(map, :model, default))
  defp wrap_list(items) when is_list(items), do: %{"items" => items}
  defp wrap_list(_items), do: %{"items" => []}
  defp unwrap_list(%{"items" => items}) when is_list(items), do: items
  defp unwrap_list(%{items: items}) when is_list(items), do: items
  defp unwrap_list(_items), do: []
end
