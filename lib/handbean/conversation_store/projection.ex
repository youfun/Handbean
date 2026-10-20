defmodule Handbean.ConversationStore.Projection do
  @moduledoc false

  import Ecto.Query

  alias Handbean.ConversationStore.{Codec, Usage}
  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEditorState, ConversationEntry}

  def list(opts) do
    include_internal? = Keyword.get(opts, :include_internal?, false)

    Conversation
    |> where([conversation], conversation.status == "active")
    |> maybe_exclude_internal(include_internal?)
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
    |> Repo.all()
    |> details()
  end

  def list_for_workspace(workspace_id, opts) when is_binary(workspace_id) do
    opts
    |> metadata_query()
    |> where([conversation], conversation.scope == "workspace")
    |> where([conversation], conversation.workspace_id == ^workspace_id)
    |> Repo.all()
    |> details()
  end

  def list_metadata(workspace_id) when is_binary(workspace_id) do
    Conversation
    |> where([conversation], conversation.status == "active")
    |> where([conversation], conversation.scope == "workspace")
    |> where([conversation], conversation.workspace_id == ^workspace_id)
    |> where([conversation], conversation.visibility != "internal")
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
    |> Repo.all()
    |> metadata_many()
  end

  def list_free_metadata do
    Conversation
    |> where([conversation], conversation.status == "active")
    |> where([conversation], conversation.scope == "free")
    |> where([conversation], conversation.visibility != "internal")
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
    |> Repo.all()
    |> metadata_many()
  end

  def fetch_summaries do
    summaries =
      Conversation
      |> where([conversation], conversation.status == "active")
      |> where([conversation], conversation.visibility != "internal")
      |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
      |> Repo.all()
      |> Enum.map(&Codec.summary/1)

    {:ok, summaries}
  rescue
    error -> {:error, error}
  end

  def list_summaries(workspace_id) when is_binary(workspace_id) do
    with {:ok, summaries} <- fetch_summaries() do
      Enum.filter(summaries, &(&1["scope"] == "workspace" and &1["workspace_id"] == workspace_id))
    else
      _ -> []
    end
  end

  def list_free_summaries do
    with {:ok, summaries} <- fetch_summaries() do
      Enum.filter(summaries, &(&1["scope"] == "free"))
    else
      _ -> []
    end
  end

  def list_free(opts) do
    opts
    |> metadata_query()
    |> where([conversation], conversation.scope == "free")
    |> Repo.all()
    |> details()
  end

  def get_metadata(id) when is_binary(id) do
    with {:ok, row} <- fetch_active_row(id), do: {:ok, metadata(row)}
  end

  def get_summary(id) when is_binary(id) do
    with {:ok, row} <- fetch_active_row(id), do: {:ok, Codec.summary(row)}
  end

  def titles_for_ids(ids) when is_list(ids) do
    case ids |> Enum.filter(&present?/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        from(conversation in Conversation,
          where: conversation.id in ^ids and conversation.status == "active",
          select: {conversation.id, conversation.title}
        )
        |> Repo.all()
        |> Map.new(fn {id, title} -> {id, Codec.title_text(title)} end)
    end
  end

  def internal?(id) when is_binary(id) do
    case Repo.one(
           from conversation in Conversation,
             where: conversation.id == ^id and conversation.status == "active"
         ) do
      %Conversation{visibility: "internal"} -> true
      _ -> false
    end
  end

  def free?(id) when is_binary(id) do
    case Repo.one(
           from conversation in Conversation,
             where: conversation.id == ^id and conversation.status == "active"
         ) do
      %Conversation{scope: "free"} -> true
      _ -> false
    end
  end

  def exists?(id) when is_binary(id) do
    Repo.exists?(
      from conversation in Conversation,
        where: conversation.id == ^id and conversation.status == "active"
    )
  end

  def lifecycle_status(id) when is_binary(id) do
    case Repo.one(
           from conversation in Conversation,
             where: conversation.id == ^id,
             select: conversation.status
         ) do
      "active" -> :active
      "pending_delete" -> :pending_delete
      nil -> :missing
    end
  end

  def transcript_empty?(id) when is_binary(id) do
    exists?(id) and
      Repo.aggregate(
        from(entry in ConversationEntry, where: entry.conversation_id == ^id),
        :count
      ) ==
        0
  end

  def load_files(conversation_id) when is_binary(conversation_id) do
    case Repo.get(ConversationEditorState, conversation_id) do
      nil -> Codec.empty_files()
      state -> Codec.editor(state)
    end
  end

  def fetch_active_row(id) when is_binary(id) do
    case Repo.one(
           from conversation in Conversation,
             where: conversation.id == ^id and conversation.status == "active"
         ) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def detail(row) do
    files = load_files(row.id)

    row
    |> metadata()
    |> Map.merge(files)
    |> Map.put("timeline", [])
  end

  def new_detail(row, editor_attrs) do
    row
    |> Codec.base_metadata()
    |> Map.merge(Usage.empty_metadata())
    |> Map.merge(Codec.editor(editor_attrs))
    |> Map.put("timeline", [])
  end

  def metadata(row) do
    row
    |> Codec.base_metadata()
    |> Map.merge(Usage.metadata(row.id))
  end

  defp details([]), do: []

  defp details(rows) do
    ids = Enum.map(rows, & &1.id)

    editors =
      from(state in ConversationEditorState, where: state.conversation_id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.conversation_id, Codec.editor(&1)})

    rows
    |> metadata_many()
    |> Enum.map(fn metadata ->
      metadata
      |> Map.merge(Map.get(editors, metadata["id"], Codec.empty_files()))
      |> Map.put("timeline", [])
    end)
  end

  defp metadata_many([]), do: []

  defp metadata_many(rows) do
    usage_by_id = rows |> Enum.map(& &1.id) |> Usage.metadata_for_ids()

    Enum.map(rows, fn row ->
      row
      |> Codec.base_metadata()
      |> Map.merge(Map.fetch!(usage_by_id, row.id))
    end)
  end

  defp metadata_query(opts) do
    include_archived? = Keyword.get(opts, :include_archived?, false)
    include_internal? = Keyword.get(opts, :include_internal?, false)

    Conversation
    |> where([conversation], conversation.status == "active")
    |> maybe_exclude_internal(include_internal?)
    |> maybe_exclude_archived(include_archived?)
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
  end

  defp maybe_exclude_internal(query, true), do: query

  defp maybe_exclude_internal(query, false),
    do: where(query, [conversation], conversation.visibility != "internal")

  defp maybe_exclude_archived(query, true), do: query

  defp maybe_exclude_archived(query, false),
    do: where(query, [conversation], is_nil(conversation.archived_at))

  defp present?(value), do: is_binary(value) and value != ""
end
