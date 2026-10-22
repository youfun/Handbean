defmodule Handbean.ConversationStore.Archive do
  @moduledoc false

  import Ecto.Query

  alias Handbean.ConversationStore.Tree
  alias Handbean.Repo
  alias Handbean.Storage.Conversation

  @type preview :: %{
          id: String.t(),
          title: String.t(),
          scope: String.t(),
          workspace_id: String.t() | nil,
          descendant_count: non_neg_integer()
        }

  @spec preview(String.t()) :: {:ok, preview()} | {:error, :not_found | term()}
  def preview(id) when is_binary(id) do
    with %Conversation{} = conversation <- visible_active_conversation(id),
         {:ok, rows} <- Tree.subtree(id) do
      {:ok,
       %{
         id: conversation.id,
         title: conversation.title,
         scope: conversation.scope,
         workspace_id: conversation.workspace_id,
         descendant_count: count_unarchived_descendants(rows)
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def preview(_id), do: {:error, :not_found}

  @spec request(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def request(id), do: request(id, :confirmed)

  @spec request_if_leaf(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def request_if_leaf(id), do: request(id, :leaf_only)

  defp request(id, mode) when is_binary(id) do
    result =
      Repo.transaction(fn ->
        with {:ok, rows} <- Tree.subtree(id) do
          case rows do
            [%{id: ^id, status: "active"} | _] -> archive_rows(rows, mode)
            _ -> Repo.rollback(:not_found)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, ids} ->
        Enum.each(ids, &Handbean.ConversationStore.broadcast_updated/1)
        {:ok, ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(_id, _mode), do: {:error, :not_found}

  defp visible_active_conversation(id) do
    Repo.one(
      from conversation in Conversation,
        where:
          conversation.id == ^id and conversation.status == "active" and
            conversation.visibility != "internal"
    )
  end

  defp count_unarchived_descendants([_root | descendants]) do
    Enum.count(descendants, &(&1.status == "active" and not &1.archived?))
  end

  defp count_unarchived_descendants([]), do: 0

  defp archive_rows(rows, :leaf_only) do
    if count_unarchived_descendants(rows) > 0 do
      Repo.rollback(:confirmation_required)
    else
      archive_rows(rows, :confirmed)
    end
  end

  defp archive_rows(rows, :confirmed) do
    ids =
      for %{id: id, status: "active", archived?: false} <- rows,
          do: id

    if ids != [] do
      timestamp = DateTime.utc_now()

      Repo.update_all(
        from(conversation in Conversation,
          where:
            conversation.id in ^ids and conversation.status == "active" and
              is_nil(conversation.archived_at)
        ),
        set: [archived_at: timestamp, updated_at: timestamp]
      )
    end

    ids
  end
end
