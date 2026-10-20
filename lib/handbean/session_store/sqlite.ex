defmodule Handbean.SessionStore.SQLite do
  @moduledoc """
  SQLite-backed runtime session snapshots.

  A session id is the owning conversation id. Snapshots are projections for
  reconnect and may be replaced atomically; canonical conversation history is
  owned elsewhere.
  """

  @behaviour Handbean.SessionStore

  import Ecto.Query

  alias Handbean.{Repo, SessionStore}
  alias Handbean.Storage.{Conversation, SessionSnapshot}

  @recovery_projection_key "__session_recovery_projection__"

  @impl true
  def save(session_id, snapshot, opts \\ []) when is_map(snapshot) do
    session_id = to_string(session_id)

    with {:ok, visibility} <- conversation_visibility(session_id) do
      {snapshot, control_events} =
        if opts[:recovery_projection?] == true and visibility != "internal" do
          SessionStore.prepare_recovery_projection(snapshot)
        else
          snapshot = SessionStore.prepare_snapshot(snapshot)
          {snapshot, value(snapshot, "control_events", [])}
        end

      attrs = snapshot_attrs(session_id, snapshot, control_events)
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
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp conversation_visibility(session_id) do
    from(conversation in Conversation,
      where: conversation.id == ^session_id and conversation.status == "active",
      select: conversation.visibility
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      visibility -> {:ok, visibility}
    end
  end

  @impl true
  def load(session_id, _opts \\ []) do
    case Repo.get(SessionSnapshot, to_string(session_id)) do
      nil ->
        {:error, :not_found}

      row ->
        snapshot = snapshot_from_row(row)
        references = SessionStore.tool_output_references(snapshot)

        if MapSet.size(references) > 0 do
          case load_tool_outputs(row.conversation_id, references) do
            {:ok, entries} ->
              {:ok, SessionStore.restore_tool_outputs(snapshot, entries)}

            {:error, _reason} ->
              # Keep recoverable controls; an unavailable transcript must not resurrect old output.
              {:ok, snapshot}
          end
        else
          {:ok, snapshot}
        end
    end
  end

  defp load_tool_outputs(conversation_id, references) do
    tool_use_ids =
      references
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    load_tool_outputs_by_id(conversation_id, tool_use_ids)
  end

  defp load_tool_outputs_by_id(_conversation_id, []), do: {:ok, []}

  defp load_tool_outputs_by_id(conversation_id, tool_use_ids) do
    Repo.query(
      """
      SELECT entry.run_id,
             json_extract(entry.payload, '$.tool_use_id'),
             entry.payload -> '$.output'
      FROM conversation_entries AS entry
      JOIN conversations AS conversation ON conversation.id = entry.conversation_id
      WHERE entry.conversation_id = ?
        AND entry.content_type = 'tool'
        AND conversation.status = 'active'
        AND conversation.visibility != 'internal'
        AND json_extract(entry.payload, '$.tool_use_id') IN (SELECT value FROM json_each(?))
      ORDER BY entry.sequence ASC
      """,
      [conversation_id, Handbean.JSON.encode!(tool_use_ids)]
    )
    |> case do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &tool_output_entry/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_output_entry([run_id, tool_use_id, output_json]) do
    entry = %{
      "content_type" => "tool",
      "run_id" => run_id,
      "tool_use_id" => tool_use_id
    }

    if is_nil(output_json),
      do: entry,
      else: Map.put(entry, "output", Handbean.JSON.decode!(output_json))
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

  defp snapshot_attrs(session_id, snapshot, control_events) do
    %{
      conversation_id: to_string(session_id),
      seq: value(snapshot, "seq", 0),
      control_events: wrap_list(control_events),
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
    control_events = unwrap_list(row.control_events)

    stored_snapshot =
      row
      |> Map.get(:snapshot)
      |> then(fn
        snapshot when is_map(snapshot) -> snapshot
        _ -> %{}
      end)

    case Map.pop(stored_snapshot, @recovery_projection_key) do
      {true, snapshot} ->
        snapshot
        |> Map.put_new("seq", row.seq)
        |> Map.put("events", control_events)
        |> Map.put("control_events", control_events)
        |> Map.put_new("next_turn_messages", unwrap_list(row.next_turn_messages))
        |> Map.put_new("extension_state", row.extension_state || %{})
        |> Map.put_new("model", row.model)

      {_marker, snapshot} when snapshot == %{} ->
        materialized_snapshot(row, control_events)

      {_marker, snapshot} ->
        snapshot
    end
  end

  defp materialized_snapshot(row, control_events) do
    %{}
    |> Map.put("events", control_events)
    |> Map.put("control_events", control_events)
    |> Map.put("seq", row.seq)
    |> Map.put("next_turn_messages", unwrap_list(row.next_turn_messages))
    |> Map.put("extension_state", row.extension_state || %{})
    |> Map.put("model", row.model)
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
