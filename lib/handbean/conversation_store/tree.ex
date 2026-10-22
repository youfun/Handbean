defmodule Handbean.ConversationStore.Tree do
  @moduledoc false

  alias Handbean.Repo

  @type row :: %{
          id: String.t(),
          visibility: String.t(),
          status: String.t(),
          parent_conversation_id: String.t() | nil,
          archived?: boolean(),
          depth: non_neg_integer()
        }

  @spec subtree(String.t()) :: {:ok, [row()]} | {:error, term()}
  def subtree(id) when is_binary(id) do
    sql = """
    WITH RECURSIVE subtree(
      id,
      visibility,
      status,
      parent_conversation_id,
      archived,
      depth
    ) AS (
      SELECT id, visibility, status, parent_conversation_id,
             archived_at IS NOT NULL, 0
      FROM conversations
      WHERE id = ?
      UNION ALL
      SELECT child.id, child.visibility, child.status, child.parent_conversation_id,
             child.archived_at IS NOT NULL, subtree.depth + 1
      FROM conversations AS child
      JOIN subtree ON child.parent_conversation_id = subtree.id
    )
    SELECT id, visibility, status, parent_conversation_id, archived, depth
    FROM subtree
    ORDER BY depth ASC, id ASC
    """

    case Repo.query(sql, [id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row([id, visibility, status, parent_conversation_id, archived, depth]) do
    %{
      id: id,
      visibility: visibility,
      status: status,
      parent_conversation_id: parent_conversation_id,
      archived?: archived == 1,
      depth: depth
    }
  end
end
