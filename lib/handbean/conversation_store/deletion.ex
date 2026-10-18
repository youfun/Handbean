defmodule Handbean.ConversationStore.Deletion do
  @moduledoc false

  import Ecto.Query

  alias Handbean.Repo
  alias Handbean.Schedule.Entry, as: Schedule
  alias Handbean.Storage.{Conversation, ConversationMedia, OperationReceipt}

  @type preview :: %{
          id: String.t(),
          title: String.t(),
          scope: String.t(),
          workspace_id: String.t() | nil,
          descendant_count: non_neg_integer()
        }

  @spec preview(String.t()) :: {:ok, preview()} | {:error, :not_found}
  def preview(id) when is_binary(id) do
    case Repo.one(
           from conversation in Conversation,
             where:
               conversation.id == ^id and conversation.status == "active" and
                 conversation.visibility != "internal"
         ) do
      %Conversation{} = conversation ->
        {:ok,
         %{
           id: conversation.id,
           title: conversation.title,
           scope: conversation.scope,
           workspace_id: conversation.workspace_id,
           descendant_count: max(length(subtree(conversation.id)) - 1, 0)
         }}

      nil ->
        {:error, :not_found}
    end
  end

  def preview(_id), do: {:error, :not_found}

  @spec request(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def request(id) when is_binary(id) do
    result =
      Repo.transaction(fn ->
        rows = subtree(id)

        case rows do
          [%{id: ^id, visibility: visibility, status: "active"} | _]
          when visibility != "internal" ->
            ids = Enum.map(rows, & &1.id)
            timestamp = DateTime.utc_now()

            Repo.update_all(
              from(conversation in Conversation,
                where: conversation.id in ^ids and conversation.status == "active"
              ),
              set: [
                status: "pending_delete",
                pending_delete_at: timestamp,
                pinned_at: nil,
                updated_at: timestamp
              ]
            )

            Repo.update_all(
              from(media in ConversationMedia,
                where: media.conversation_id in ^ids and media.status != "pending_delete"
              ),
              set: [status: "pending_delete", updated_at: timestamp]
            )

            Repo.update_all(
              from(schedule in Schedule,
                where: schedule.conversation_id in ^ids and schedule.status == "active"
              ),
              set: [
                status: "disabled",
                next_run_at: nil,
                updated_at: DateTime.truncate(timestamp, :second)
              ],
              inc: [version: 1]
            )

            {ids, true}

          [%{id: ^id, visibility: visibility, status: "pending_delete"} | _]
          when visibility != "internal" ->
            {Enum.map(rows, & &1.id), false}

          _ ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, {ids, changed?}} ->
        quiesce(ids)

        if changed? do
          broadcast(ids)
          Handbean.Media.Cleaner.schedule_pending_delete()
        end

        {:ok, ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def request(_id), do: {:error, :not_found}

  @doc false
  def pending_groups(before, opts \\ []) when is_struct(before, DateTime) do
    limit = opts |> Keyword.get(:limit, 100) |> min(500) |> max(1)

    conversations =
      Repo.all(
        from conversation in Conversation,
          where: conversation.status == "pending_delete"
      )

    by_id = Map.new(conversations, &{&1.id, &1})

    conversations
    |> Enum.group_by(&pending_root_id(&1, by_id))
    |> Enum.map(fn {root_id, rows} ->
      %{root_id: root_id, conversations: Enum.sort_by(rows, &depth(&1, by_id), :desc)}
    end)
    |> Enum.filter(fn group ->
      case Map.fetch(by_id, group.root_id) do
        {:ok, root} -> DateTime.compare(root.pending_delete_at, before) == :lt
        :error -> false
      end
    end)
    |> Enum.sort_by(fn group -> Map.fetch!(by_id, group.root_id).pending_delete_at end)
    |> Enum.take(limit)
  end

  @doc false
  def runtime_active?(conversation_ids) when is_list(conversation_ids) do
    Enum.any?(conversation_ids, fn id ->
      Registry.lookup(Handbean.AgentRunSupervisorRegistry, id) != [] or
        Registry.lookup(Handbean.AgentRunRegistry, id) != []
    end)
  end

  @doc false
  def force_quiesce(conversation_ids) when is_list(conversation_ids) do
    Enum.each(conversation_ids, fn id ->
      _ = Handbean.Agent.Runner.cancel(id)
      _ = Handbean.AgentRunSupervisor.stop_run(id)

      Enum.each(Registry.lookup(Handbean.AgentRunRegistry, id), fn {pid, _metadata} ->
        _ = Handbean.AgentRunSupervisor.stop_run(pid)
      end)

      _ = Handbean.SessionSupervisor.stop_session(id)
    end)

    :ok
  end

  @doc false
  def finalize(root_id, conversation_ids, media_ids)
      when is_binary(root_id) and is_list(conversation_ids) and is_list(media_ids) do
    Repo.transaction(fn ->
      current_rows = subtree(root_id)
      current_ids = Enum.map(current_rows, & &1.id)

      root_has_pending_parent? =
        case current_rows do
          [%{parent_conversation_id: parent_id} | _] when is_binary(parent_id) ->
            Repo.exists?(
              from parent in Conversation,
                where: parent.id == ^parent_id and parent.status == "pending_delete"
            )

          _ ->
            false
        end

      current_media_ids =
        Repo.all(
          from media in ConversationMedia,
            where: media.conversation_id in ^conversation_ids,
            select: media.id
        )

      if root_has_pending_parent? or
           Enum.any?(current_rows, &(&1.status != "pending_delete")) or
           MapSet.new(current_ids) != MapSet.new(conversation_ids) or
           MapSet.new(current_media_ids) != MapSet.new(media_ids) do
        Repo.rollback(:delete_set_changed)
      end

      Repo.delete_all(from media in ConversationMedia, where: media.id in ^media_ids)

      Repo.delete_all(
        from receipt in OperationReceipt,
          where: receipt.scope_id in ^conversation_ids
      )

      by_id = Map.new(current_rows, &{&1.id, &1})

      current_rows
      |> Enum.sort_by(&depth(&1, by_id), :desc)
      |> Enum.each(fn conversation ->
        {count, _} =
          Repo.delete_all(
            from row in Conversation,
              where: row.id == ^conversation.id and row.status == "pending_delete"
          )

        if count != 1, do: Repo.rollback(:delete_set_changed)
      end)

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError -> {:error, {:constraint, error.constraint}}
  end

  defp subtree(id) do
    sql = """
    WITH RECURSIVE subtree(id, visibility, status, parent_conversation_id, depth) AS (
      SELECT id, visibility, status, parent_conversation_id, 0
      FROM conversations
      WHERE id = ?
      UNION ALL
      SELECT child.id, child.visibility, child.status, child.parent_conversation_id,
             subtree.depth + 1
      FROM conversations AS child
      JOIN subtree ON child.parent_conversation_id = subtree.id
    )
    SELECT id, visibility, status, parent_conversation_id, depth
    FROM subtree
    ORDER BY depth ASC, id ASC
    """

    case Repo.query(sql, [id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [row_id, visibility, status, parent_conversation_id, depth] ->
          %{
            id: row_id,
            visibility: visibility,
            status: status,
            parent_conversation_id: parent_conversation_id,
            depth: depth
          }
        end)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp pending_root_id(conversation, by_id) do
    do_pending_root_id(conversation, by_id, MapSet.new())
  end

  defp do_pending_root_id(conversation, by_id, seen) do
    cond do
      MapSet.member?(seen, conversation.id) ->
        conversation.id

      is_nil(conversation.parent_conversation_id) ->
        conversation.id

      true ->
        case Map.fetch(by_id, conversation.parent_conversation_id) do
          {:ok, parent} ->
            do_pending_root_id(parent, by_id, MapSet.put(seen, conversation.id))

          :error ->
            conversation.id
        end
    end
  end

  defp depth(conversation, by_id), do: do_depth(conversation, by_id, MapSet.new(), 0)

  defp do_depth(conversation, by_id, seen, depth) do
    cond do
      MapSet.member?(seen, conversation.id) ->
        depth

      true ->
        case Map.fetch(by_id, conversation.parent_conversation_id) do
          {:ok, parent} -> do_depth(parent, by_id, MapSet.put(seen, conversation.id), depth + 1)
          :error -> depth
        end
    end
  end

  defp quiesce(ids) do
    Enum.each(ids, fn id ->
      _ = Handbean.Agent.Runner.cancel(id)
      _ = Handbean.SessionSupervisor.stop_session(id)
    end)
  end

  defp broadcast(ids) do
    Phoenix.PubSub.broadcast(
      Handbean.PubSub,
      "conversation:updated",
      {:conversations_pending_delete, ids}
    )
  end
end
