defmodule Handbean.ConversationStore do
  @moduledoc """
  SQLite-backed conversation facade.

  Callers receive the existing string-key maps; Ecto structs and database
  representation stay private to this module.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEditorState, ConversationRunUsage}

  @type conversation :: map()
  @title_max_length 80
  @unkeyed_run_id "__unkeyed__"
  @metadata_fields [
    :scope,
    :workspace_id,
    :checkout_path,
    :visibility,
    :parent_conversation_id,
    :parent_run_id,
    :parent_tool_call_id,
    :title,
    :title_source,
    :selected_model,
    :selected_reasoning_level,
    :collaboration,
    :last_run_result,
    :loaded_tools,
    :archived_at,
    :pinned_at,
    :next_entry_sequence,
    :created_at,
    :updated_at
  ]
  @mutable_fields @metadata_fields --
                    [
                      :scope,
                      :workspace_id,
                      :checkout_path,
                      :next_entry_sequence,
                      :created_at,
                      :updated_at
                    ]
  @owned_on_upsert ~w(collaboration visibility last_run_result parent_conversation_id parent_run_id parent_tool_call_id pinned_at)
  @usage_meta_keys ~w(token_usage run_usage usage_legacy run_usage_replace delegated_usage)

  @doc "List every persisted conversation."
  @spec list(keyword()) :: [conversation()]
  def list(opts \\ []) do
    include_internal? = Keyword.get(opts, :include_internal?, false)

    Conversation
    |> maybe_exclude_internal(include_internal?)
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
    |> Repo.all()
    |> Enum.map(&conversation_map(&1, opts))
  end

  @doc "List conversations for a workspace id."
  def list_for_workspace(workspace_id),
    do: list_for_workspace(workspace_id, include_archived?: false)

  def list_for_workspace(workspace_id, opts) when is_binary(workspace_id) do
    metadata_query(opts)
    |> where([conversation], conversation.scope == "workspace")
    |> where([conversation], conversation.workspace_id == ^workspace_id)
    |> Repo.all()
    |> Enum.map(&conversation_map(&1, opts))
  end

  def list_metadata(workspace_id) when is_binary(workspace_id) do
    Conversation
    |> where([conversation], conversation.scope == "workspace")
    |> where([conversation], conversation.workspace_id == ^workspace_id)
    |> where([conversation], conversation.visibility != "internal")
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
    |> Repo.all()
    |> Enum.map(&metadata_map/1)
  end

  @doc "List thread summaries with aggregate transcript/run counts in one query."
  def list_thread_summaries(workspace_id) when is_binary(workspace_id) do
    Handbean.ConversationStore.Trajectory.list_thread_summaries(workspace_id)
  end

  @doc false
  def record_run_start(conversation_id, attrs),
    do: Handbean.ConversationStore.Trajectory.record_run_start(conversation_id, attrs)

  @doc false
  def record_run_end(conversation_id, attrs),
    do: Handbean.ConversationStore.Trajectory.record_run_end(conversation_id, attrs)

  @doc false
  def record_turn_start(conversation_id, attrs),
    do: Handbean.ConversationStore.Trajectory.record_turn_start(conversation_id, attrs)

  @doc false
  def record_turn_end(conversation_id, attrs),
    do: Handbean.ConversationStore.Trajectory.record_turn_end(conversation_id, attrs)

  @doc "Read one consistent durable trajectory page. Authorization belongs to Handbean.Threads."
  def trajectory_snapshot(conversation_id, opts),
    do: Handbean.ConversationStore.Trajectory.snapshot(conversation_id, opts)

  def list_free_metadata do
    Conversation
    |> where([conversation], conversation.scope == "free")
    |> where([conversation], conversation.visibility != "internal")
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
    |> Repo.all()
    |> Enum.map(&metadata_map/1)
  end

  def fetch_summaries do
    summaries =
      Conversation
      |> where([conversation], conversation.visibility != "internal")
      |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
      |> Repo.all()
      |> Enum.map(&summary_map/1)

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

  def list_free(opts \\ []) do
    metadata_query(opts)
    |> where([conversation], conversation.scope == "free")
    |> Repo.all()
    |> Enum.map(&conversation_map(&1, opts))
  end

  def get_metadata(id) when is_binary(id) do
    if valid_id?(id), do: fetch_metadata(id), else: {:error, :not_found}
  end

  def get_metadata(_id), do: {:error, :not_found}

  def transcript_empty?(id) when is_binary(id) do
    valid_id?(id) and exists?(id) and
      Repo.aggregate(
        from(entry in Handbean.Storage.ConversationEntry, where: entry.conversation_id == ^id),
        :count
      ) == 0
  end

  def transcript_empty?(_id), do: false

  def get(id, opts \\ []) when is_binary(id) do
    with {:ok, conversation} <- fetch_row(id),
         true <- accessible?(metadata_map(conversation), opts) do
      {:ok, conversation_map(conversation, opts)}
    else
      _ -> {:error, :not_found}
    end
  end

  def internal?(%{"visibility" => "internal"}), do: true
  def internal?(%{visibility: "internal"}), do: true

  def internal?(id) when is_binary(id) do
    case Repo.get(Conversation, id) do
      %Conversation{visibility: "internal"} -> true
      _ -> false
    end
  end

  def internal?(_value), do: false

  @doc "Returns the conversation that created this one."
  def parent_conversation_id(conversation) when is_map(conversation),
    do: string_value(conversation, "parent_conversation_id")

  def parent_conversation_id(_conversation), do: nil

  def authorize_read(id, opts) do
    with {:ok, meta} <- get_metadata(id),
         true <- accessible?(meta, opts),
         do: :ok,
         else: (_ -> {:error, :not_found})
  end

  def get_meta(id) when is_binary(id), do: get_metadata(id)

  def exists?(id) when is_binary(id),
    do: Repo.exists?(from conversation in Conversation, where: conversation.id == ^id)

  def create(workspace_id, opts \\ []) when is_binary(workspace_id) do
    create_conversation("workspace", workspace_id, opts)
  end

  def create_free(opts \\ []), do: create_conversation("free", nil, opts)

  @doc "Resolve a conversation's immutable checkout without falling back to a workspace default."
  @spec effective_checkout_path(map() | String.t()) :: {:ok, String.t()} | {:error, atom()}
  def effective_checkout_path(id) when is_binary(id) do
    with {:ok, conversation} <- get_metadata(id) do
      effective_checkout_path(conversation)
    end
  end

  def effective_checkout_path(conversation) when is_map(conversation) do
    case map_value(conversation, "checkout_path") do
      path when is_binary(path) and path != "" ->
        case Handbean.RepoIdentity.canonical_directory(path) do
          {:ok, canonical} -> {:ok, canonical}
          {:error, _reason} -> {:error, :checkout_unavailable}
        end

      _missing ->
        {:error, :checkout_path_missing}
    end
  end

  def effective_checkout_path(_conversation), do: {:error, :checkout_path_missing}

  def free?(%{"scope" => "free"}), do: true
  def free?(%{scope: scope}) when scope in ["free", :free], do: true

  def free?(id) when is_binary(id) do
    case Repo.get(Conversation, id) do
      %Conversation{scope: "free"} -> true
      _ -> false
    end
  end

  def free?(_value), do: false

  def archive(id) when is_binary(id), do: update_and_get(id, archived_at: now(), touch: true)

  def archive_for_workspace(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> list_for_workspace(include_archived?: true, include_timeline?: false)
    |> Enum.reject(&archived_conversation?/1)
    |> Enum.reduce_while({:ok, []}, fn conversation, {:ok, archived} ->
      case archive(conversation["id"]) do
        {:ok, updated} -> {:cont, {:ok, [updated | archived]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, archived} -> {:ok, Enum.reverse(archived)}
      error -> error
    end
  end

  def archived_conversation?(conversation) when is_map(conversation),
    do: present?(map_value(conversation, "archived_at"))

  def unarchive(id) when is_binary(id), do: update_and_get(id, archived_at: nil, touch: true)
  def pin(id) when is_binary(id), do: update_meta(id, pinned_at: now())
  def unpin(id) when is_binary(id), do: update_meta(id, pinned_at: nil)

  def pinned_conversation?(conversation) when is_map(conversation),
    do: present?(map_value(conversation, "pinned_at"))

  def pinned_conversation?(_value), do: false

  def rename(id, title) when is_binary(id) and is_binary(title) do
    with {:ok, normalized} <- normalize_title(title),
         {:ok, meta} <- update_meta(id, title: normalized, title_source: "manual") do
      broadcast_title_updated(id, normalized)
      {:ok, meta}
    end
  end

  def normalize_title(title) when is_binary(title) do
    normalized =
      title
      |> String.replace(~r/[\r\n\t]+/u, " ")
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    cond do
      normalized == "" -> {:error, :empty}
      String.length(normalized) > @title_max_length -> {:error, :too_long}
      true -> {:ok, normalized}
    end
  end

  def broadcast_title_updated(conversation_id, title \\ nil) when is_binary(conversation_id) do
    Phoenix.PubSub.broadcast(
      Handbean.PubSub,
      "conversation:updated",
      {:conversation_updated, conversation_id}
    )

    if present?(title) do
      Phoenix.PubSub.broadcast(
        Handbean.PubSub,
        "conversation:updated",
        {:conversation_title_ready, conversation_id, title}
      )
    end

    :ok
  end

  def upsert(conversation) when is_map(conversation) do
    id = string_value(conversation, "id") || Ecto.UUID.generate()
    existing = Repo.get(Conversation, id)

    with :ok <- validate_upsert_checkout(existing, conversation) do
      normalized = normalize_conversation(conversation, id, existing)

      Repo.transaction(fn ->
        row = persist_conversation(existing, normalized)
        persist_editor(row.id, conversation)

        ensure_transaction!(
          maybe_replace_timeline(row.id, list_value(conversation, "timeline"), existing)
        )

        conversation_map(row, include_timeline?: true)
      end)
      |> unwrap_transaction()
    end
  rescue
    error in Ecto.ConstraintError -> {:error, constraint_reason(error)}
  end

  def ensure_for_workspaces(workspaces) do
    Map.new(workspaces, fn workspace ->
      id = workspace["id"]

      conversations =
        case list_for_workspace(id) do
          [] ->
            {:ok, conversation} = create(id, checkout_path: workspace["default_checkout_path"])
            [conversation]

          existing ->
            existing
        end

      {id, conversations}
    end)
  end

  def append_message(conversation_id, entry) when is_map(entry) do
    case Handbean.ConversationTranscriptStore.append(conversation_id, entry) do
      {:ok, _entry} -> :ok
      error -> error
    end
  end

  def load_messages(conversation_id) when is_binary(conversation_id) do
    case load_messages_result(conversation_id) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  def load_messages_result(conversation_id) when is_binary(conversation_id) do
    Handbean.ConversationTranscriptStore.list(conversation_id)
  end

  def replace_messages(conversation_id, entries) when is_list(entries) do
    Handbean.ConversationTranscriptStore.replace_all(conversation_id, entries)
  end

  def load_files(conversation_id) when is_binary(conversation_id) do
    case Repo.get(ConversationEditorState, conversation_id) do
      nil -> empty_files()
      state -> editor_map(state)
    end
  end

  def save_files(conversation_id, files_data) when is_map(files_data) do
    if exists?(conversation_id) do
      attrs = editor_attrs(conversation_id, files_data)

      %ConversationEditorState{}
      |> Changeset.cast(attrs, [
        :conversation_id,
        :editor_files,
        :active_file,
        :file_preview_error
      ])
      |> Repo.insert(
        on_conflict: {:replace, [:editor_files, :active_file, :file_preview_error, :updated_at]},
        conflict_target: [:conversation_id]
      )
      |> case do
        {:ok, _state} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def append_loaded_tools(id, names) when is_binary(id) and is_list(names) do
    with {:ok, row} <- fetch_row(id) do
      current = decode_list(row.loaded_tools)
      incoming = Enum.filter(names, &is_binary/1)
      loaded_tools = current ++ Enum.reject(incoming, &(&1 in current))

      row
      |> Changeset.change(loaded_tools: encode_json!(loaded_tools))
      |> Repo.update()
      |> case do
        {:ok, _row} -> {:ok, loaded_tools}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def update_meta(id, updates) when is_binary(id) and is_list(updates) do
    {touch?, updates} = Keyword.pop(updates, :touch, true)

    with {:ok, row} <- fetch_row(id) do
      attrs =
        updates
        |> Enum.reject(fn {key, _value} -> to_string(key) in @usage_meta_keys end)
        |> Map.new(fn {key, value} ->
          {String.to_existing_atom(to_string(key)), normalize_field(key, value)}
        end)
        |> then(fn attrs -> if touch?, do: Map.put(attrs, :updated_at, now()), else: attrs end)

      row
      |> Changeset.cast(attrs, @mutable_fields)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, metadata_map(updated)}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_field}
  end

  def get_token_usage(conversation_id)
      when is_binary(conversation_id) and conversation_id != "" do
    if exists?(conversation_id),
      do: {:ok, aggregate_usage(conversation_id)},
      else: {:error, :not_found}
  end

  def get_token_usage(_conversation_id), do: {:ok, empty_token_usage()}

  def add_token_usage(conversation_id, usage)
      when is_binary(conversation_id) and conversation_id != "" and is_map(usage) do
    normalized = normalize_usage(usage)

    if exists?(conversation_id) do
      sql = """
      INSERT INTO conversation_run_usage
        (conversation_id, run_id, source, input_tokens, output_tokens, cache_read_tokens,
         cache_write_tokens, total_input_tokens, usage_incomplete, inserted_at, updated_at)
      VALUES (?, ?, 'unkeyed', ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(conversation_id, source, run_id) DO UPDATE SET
        input_tokens = input_tokens + excluded.input_tokens,
        output_tokens = output_tokens + excluded.output_tokens,
        cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
        cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens,
        total_input_tokens = total_input_tokens + excluded.total_input_tokens,
        usage_incomplete = usage_incomplete OR excluded.usage_incomplete,
        updated_at = excluded.updated_at
      """

      timestamp = now_naive()

      params = [
        conversation_id,
        @unkeyed_run_id,
        normalized.input_tokens,
        normalized.output_tokens,
        normalized.cache_read_tokens,
        normalized.cache_write_tokens,
        normalized.total_input_tokens,
        if(normalized.usage_incomplete, do: 1, else: 0),
        timestamp,
        timestamp
      ]

      case Repo.query(sql, params) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def record_run_usage(conversation_id, run_id, usage)
      when is_binary(conversation_id) and conversation_id != "" and is_binary(run_id) and
             run_id != "" and is_map(usage) do
    put_usage_once(conversation_id, "parent", run_id, usage)
  end

  def rebuild_token_usage_from_events(conversation_id, events)
      when is_binary(conversation_id) and conversation_id != "" and is_list(events) do
    if exists?(conversation_id) do
      Repo.transaction(fn ->
        Repo.delete_all(
          from usage in ConversationRunUsage,
            where:
              usage.conversation_id == ^conversation_id and usage.source in ["parent", "unkeyed"]
        )

        events
        |> Enum.with_index()
        |> Enum.filter(fn {event, _index} -> terminal_usage_event?(event) end)
        |> Enum.each(fn {event, index} ->
          run_id = event_run_key(event, index)
          insert_usage!(conversation_id, "parent", run_id, event_usage(event))
        end)
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def record_delegated_usage(conversation_id, child_run_id, usage) do
    put_usage_once(conversation_id, "delegated", to_string(child_run_id), usage)
  end

  def delegated_usage(conversation_id) do
    usage_rows(conversation_id, "delegated")
    |> Map.new(fn row -> {row.run_id, usage_string_map(row)} end)
  end

  defp create_conversation(scope, workspace_id, opts) do
    with {:ok, checkout_path} <- checkout_path_for_create(scope, workspace_id, opts) do
      id = Keyword.get(opts, :id, Ecto.UUID.generate())
      timestamp = now()

      attrs = %{
        id: id,
        scope: scope,
        workspace_id: workspace_id,
        checkout_path: checkout_path,
        visibility: Keyword.get(opts, :visibility, "user"),
        parent_conversation_id: Keyword.get(opts, :parent_conversation_id),
        parent_run_id: Keyword.get(opts, :parent_run_id),
        parent_tool_call_id: Keyword.get(opts, :parent_tool_call_id),
        title: Keyword.get(opts, :title, "New chat"),
        title_source: Keyword.get(opts, :title_source, "manual"),
        selected_model: Keyword.get(opts, :selected_model),
        selected_reasoning_level: Keyword.get(opts, :selected_reasoning_level),
        collaboration: Keyword.get(opts, :collaboration),
        last_run_result: Keyword.get(opts, :last_run_result),
        loaded_tools: encode_json!(Keyword.get(opts, :loaded_tools, [])),
        archived_at: parse_time(Keyword.get(opts, :archived_at)),
        pinned_at: parse_time(Keyword.get(opts, :pinned_at)),
        next_entry_sequence: 1,
        created_at: timestamp,
        updated_at: timestamp
      }

      result =
        Repo.transaction(fn ->
          row =
            %Conversation{}
            |> Changeset.cast(attrs, [:id | @metadata_fields])
            |> Repo.insert!()

          editor = %{
            "editor_files" => Keyword.get(opts, :editor_files, []),
            "active_file" => Keyword.get(opts, :active_file),
            "file_preview_error" => Keyword.get(opts, :file_preview_error)
          }

          editor_attrs = insert_initial_editor_state!(row.id, editor)
          timeline = Keyword.get(opts, :timeline, [])

          if timeline != [] do
            ensure_transaction!(
              Handbean.ConversationTranscriptStore.replace_all(row.id, timeline)
            )
          end

          {row, editor_attrs, timeline == []}
        end)
        |> unwrap_transaction()

      case result do
        {:ok, {row, editor_attrs, true}} ->
          {:ok, new_conversation_map(row, editor_attrs)}

        {:ok, {row, _editor_attrs, false}} ->
          {:ok, conversation_map(row, include_timeline?: true)}

        {:error, _reason} = error ->
          error
      end
    end
  rescue
    error in Ecto.ConstraintError -> {:error, constraint_reason(error)}
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp checkout_path_for_create("free", _workspace_id, _opts), do: {:ok, nil}

  defp checkout_path_for_create("workspace", workspace_id, opts) do
    case Keyword.get(opts, :checkout_path) do
      path when is_binary(path) and path != "" -> canonical_checkout_path(path)
      _missing -> default_workspace_checkout(workspace_id)
    end
  end

  defp default_workspace_checkout(workspace_id) do
    case Handbean.WorkspaceStore.get(workspace_id) do
      {:ok, workspace} ->
        canonical_checkout_path(workspace["default_checkout_path"])

      {:error, reason} ->
        if allow_unbound_test_conversation?(),
          do: {:ok, nil},
          else: {:error, {:invalid_checkout_path, reason}}
    end
  end

  defp allow_unbound_test_conversation? do
    Application.get_env(:handbean, :allow_unbound_test_conversations, false) == true
  end

  defp canonical_checkout_path(path) when is_binary(path) do
    case Handbean.RepoIdentity.resolve(path) do
      {:ok, identity} -> {:ok, identity.checkout_path}
      {:error, reason} -> {:error, {:invalid_checkout_path, reason}}
    end
  end

  defp canonical_checkout_path(_path), do: {:error, {:invalid_checkout_path, :missing}}

  defp persist_conversation(nil, attrs) do
    %Conversation{}
    |> Changeset.cast(attrs, [:id | @metadata_fields])
    |> Repo.insert!()
  end

  defp persist_conversation(existing, attrs) do
    attrs =
      Enum.reduce(@owned_on_upsert, attrs, fn key, acc ->
        Map.put(
          acc,
          String.to_existing_atom(key),
          Map.get(existing, String.to_existing_atom(key))
        )
      end)

    existing
    |> Changeset.cast(attrs, @mutable_fields)
    |> Repo.update!()
  end

  defp persist_editor(id, conversation) do
    :ok =
      save_files(id, %{
        "editor_files" => list_value(conversation, "editor_files"),
        "active_file" => map_value(conversation, "active_file"),
        "file_preview_error" => map_value(conversation, "file_preview_error")
      })
  end

  defp maybe_replace_timeline(id, [], %Conversation{}) do
    if transcript_empty?(id),
      do: Handbean.ConversationTranscriptStore.replace_all(id, []),
      else: :ok
  end

  defp maybe_replace_timeline(id, timeline, _existing),
    do: Handbean.ConversationTranscriptStore.replace_all(id, timeline)

  defp update_and_get(id, updates) do
    with {:ok, _meta} <- update_meta(id, updates), do: get(id)
  end

  defp metadata_query(opts) do
    include_archived? = Keyword.get(opts, :include_archived?, false)
    include_internal? = Keyword.get(opts, :include_internal?, false)

    Conversation
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

  defp fetch_row(id) do
    case Repo.get(Conversation, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp fetch_metadata(id) do
    with {:ok, row} <- fetch_row(id), do: {:ok, metadata_map(row)}
  end

  defp conversation_map(row, opts) do
    files = load_files(row.id)
    timeline = if Keyword.get(opts, :include_timeline?, true), do: load_messages(row.id), else: []

    metadata_map(row)
    |> Map.merge(files)
    |> Map.put("timeline", timeline)
  end

  defp new_conversation_map(row, editor_attrs) do
    row
    |> base_metadata_map()
    |> Map.merge(empty_usage_metadata())
    |> Map.merge(editor_map(editor_attrs))
    |> Map.put("timeline", [])
  end

  defp metadata_map(row) do
    row
    |> base_metadata_map()
    |> Map.merge(usage_metadata(row.id))
  end

  defp base_metadata_map(row) do
    %{
      "id" => row.id,
      "scope" => row.scope,
      "workspace_id" => row.workspace_id,
      "checkout_path" => row.checkout_path,
      "visibility" => row.visibility,
      "parent_conversation_id" => parent_conversation_id(row),
      "parent_run_id" => row.parent_run_id,
      "parent_tool_call_id" => row.parent_tool_call_id,
      "title" => row.title,
      "title_source" => row.title_source,
      "selected_model" => row.selected_model,
      "selected_reasoning_level" => row.selected_reasoning_level,
      "collaboration" => row.collaboration,
      "last_run_result" => row.last_run_result,
      "loaded_tools" => decode_list(row.loaded_tools),
      "archived_at" => iso8601(row.archived_at),
      "pinned_at" => iso8601(row.pinned_at),
      "created_at" => iso8601(row.created_at),
      "updated_at" => iso8601(row.updated_at)
    }
  end

  defp summary_map(row) do
    metadata_map(row)
    |> Map.take(
      ~w(id visibility parent_conversation_id parent_run_id parent_tool_call_id scope workspace_id checkout_path title title_source archived_at pinned_at created_at updated_at)
    )
  end

  defp accessible?(conversation, opts) do
    context = Keyword.get(opts, :access_context, %{})

    not internal?(conversation) or
      (conversation["parent_conversation_id"] == context[:conversation_id] and
         conversation["parent_run_id"] == context[:run_id] and
         conversation["workspace_id"] == context[:workspace_id] and
         Handbean.Agent.Delegation.Policy.live_parent?(context))
  end

  defp normalize_conversation(conversation, id, existing) do
    timestamp = now()

    scope =
      string_value(conversation, "scope") ||
        if(string_value(conversation, "workspace_id"), do: "workspace", else: "free")

    %{
      id: id,
      scope: scope,
      workspace_id: string_value(conversation, "workspace_id"),
      checkout_path:
        immutable_checkout_path(existing, string_value(conversation, "checkout_path"), scope),
      visibility: string_value(conversation, "visibility") || "user",
      parent_conversation_id: string_value(conversation, "parent_conversation_id"),
      parent_run_id: string_value(conversation, "parent_run_id"),
      parent_tool_call_id: string_value(conversation, "parent_tool_call_id"),
      title: string_value(conversation, "title") || "New chat",
      title_source: string_value(conversation, "title_source") || "manual",
      selected_model: string_value(conversation, "selected_model"),
      selected_reasoning_level: string_value(conversation, "selected_reasoning_level"),
      collaboration: map_value(conversation, "collaboration"),
      last_run_result: string_value(conversation, "last_run_result"),
      loaded_tools: encode_json!(map_value(conversation, "loaded_tools") || []),
      archived_at: parse_time(map_value(conversation, "archived_at")),
      pinned_at: parse_time(map_value(conversation, "pinned_at")),
      next_entry_sequence: if(existing, do: existing.next_entry_sequence, else: 1),
      created_at:
        if(existing,
          do: existing.created_at,
          else: parse_time(map_value(conversation, "created_at")) || timestamp
        ),
      updated_at: timestamp
    }
  end

  defp validate_upsert_checkout(%Conversation{}, _conversation), do: :ok

  defp validate_upsert_checkout(nil, conversation) do
    scope =
      string_value(conversation, "scope") ||
        if(string_value(conversation, "workspace_id"), do: "workspace", else: "free")

    case {scope, string_value(conversation, "checkout_path")} do
      {"free", _path} ->
        :ok

      {"workspace", path} when is_binary(path) and path != "" ->
        case canonical_checkout_path(path) do
          {:ok, _canonical} -> :ok
          {:error, _reason} = error -> error
        end

      {"workspace", _missing} ->
        if allow_unbound_test_conversation?(),
          do: :ok,
          else: {:error, {:invalid_checkout_path, :missing}}
    end
  end

  defp immutable_checkout_path(%Conversation{} = existing, _incoming, _scope),
    do: existing.checkout_path

  defp immutable_checkout_path(nil, _incoming, "free"), do: nil

  defp immutable_checkout_path(nil, incoming, "workspace") when is_binary(incoming) do
    case canonical_checkout_path(incoming) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp immutable_checkout_path(_existing, _incoming, _scope), do: nil

  defp insert_initial_editor_state!(conversation_id, files_data) do
    attrs = editor_attrs(conversation_id, files_data)

    %ConversationEditorState{}
    |> Changeset.cast(attrs, [
      :conversation_id,
      :editor_files,
      :active_file,
      :file_preview_error,
      :inserted_at,
      :updated_at
    ])
    |> Repo.insert!()

    attrs
  end

  defp editor_attrs(id, files_data) do
    %{
      conversation_id: id,
      editor_files: encode_json!(list_value(files_data, "editor_files")),
      active_file: string_value(files_data, "active_file"),
      file_preview_error: encode_nullable(map_value(files_data, "file_preview_error")),
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp editor_map(state) do
    %{
      "editor_files" => decode_list(state.editor_files),
      "active_file" => state.active_file,
      "file_preview_error" => decode_nullable(state.file_preview_error)
    }
  end

  defp empty_files, do: %{"editor_files" => [], "active_file" => nil, "file_preview_error" => nil}

  defp put_usage_once(conversation_id, source, run_id, usage) do
    if exists?(conversation_id) do
      attrs = usage_attrs(conversation_id, source, run_id, usage)

      Repo.insert_all(ConversationRunUsage, [attrs],
        on_conflict: :nothing,
        conflict_target: [:conversation_id, :source, :run_id]
      )

      :ok
    else
      {:error, :not_found}
    end
  end

  defp insert_usage!(conversation_id, source, run_id, usage) do
    Repo.insert_all(ConversationRunUsage, [usage_attrs(conversation_id, source, run_id, usage)],
      on_conflict: :nothing,
      conflict_target: [:conversation_id, :source, :run_id]
    )
  end

  defp usage_attrs(conversation_id, source, run_id, usage) do
    normalized = normalize_usage(usage)
    timestamp = now()

    normalized
    |> Map.from_struct()
    |> Map.take([
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :total_input_tokens,
      :usage_incomplete
    ])
    |> Map.merge(%{
      conversation_id: conversation_id,
      source: source,
      run_id: run_id,
      inserted_at: timestamp,
      updated_at: timestamp
    })
  end

  defp usage_rows(conversation_id, source) do
    Repo.all(
      from usage in ConversationRunUsage,
        where: usage.conversation_id == ^conversation_id and usage.source == ^source
    )
  end

  defp empty_usage_metadata do
    %{
      "token_usage" => atom_usage_to_string(empty_token_usage()),
      "run_usage" => %{},
      "usage_legacy" => atom_usage_to_string(empty_token_usage()),
      "delegated_usage" => %{}
    }
  end

  defp usage_metadata(conversation_id) do
    parent = usage_rows(conversation_id, "parent")
    unkeyed = usage_rows(conversation_id, "unkeyed")
    delegated = usage_rows(conversation_id, "delegated")
    total = Enum.reduce(parent ++ unkeyed, empty_token_usage(), &sum_usage/2)

    %{
      "token_usage" => atom_usage_to_string(total),
      "run_usage" => Map.new(parent, &{&1.run_id, usage_string_map(&1)}),
      "usage_legacy" =>
        unkeyed |> Enum.reduce(empty_token_usage(), &sum_usage/2) |> atom_usage_to_string(),
      "delegated_usage" => Map.new(delegated, &{&1.run_id, usage_string_map(&1)})
    }
  end

  defp aggregate_usage(conversation_id) do
    conversation_id
    |> then(fn id -> usage_rows(id, "parent") ++ usage_rows(id, "unkeyed") end)
    |> Enum.reduce(empty_token_usage(), &sum_usage/2)
  end

  defp sum_usage(row, acc) do
    %{
      input_tokens: acc.input_tokens + row.input_tokens,
      output_tokens: acc.output_tokens + row.output_tokens,
      cache_read_tokens: acc.cache_read_tokens + row.cache_read_tokens,
      cache_write_tokens: acc.cache_write_tokens + row.cache_write_tokens,
      total_input_tokens: acc.total_input_tokens + row.total_input_tokens,
      usage_incomplete: acc.usage_incomplete or row.usage_incomplete
    }
  end

  defp normalize_usage(usage) do
    input = usage_number(usage, [:input_tokens, "input_tokens"])
    output = usage_number(usage, [:output_tokens, "output_tokens"])

    read =
      usage_number(usage, [
        :cache_read_input_tokens,
        "cache_read_input_tokens",
        :cache_read_tokens,
        "cache_read_tokens"
      ])

    write =
      usage_number(usage, [
        :cache_creation_input_tokens,
        "cache_creation_input_tokens",
        :cache_write_tokens,
        "cache_write_tokens"
      ])

    total =
      case usage_fetch(usage, [:total_input_tokens, "total_input_tokens"]) do
        number when is_number(number) -> round(number)
        _ -> input + read + write
      end

    %ConversationRunUsage{
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: read,
      cache_write_tokens: write,
      total_input_tokens: total,
      usage_incomplete:
        usage_fetch(usage, [:unknown?, "unknown?", :unknown, "unknown"]) in [true, "true"]
    }
  end

  defp usage_number(usage, keys) do
    case usage_fetch(usage, keys) do
      number when is_number(number) -> round(number)
      _ -> 0
    end
  end

  defp usage_fetch(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(usage, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp empty_token_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      total_input_tokens: 0,
      usage_incomplete: false
    }
  end

  defp usage_string_map(row) do
    %{
      "input_tokens" => row.input_tokens,
      "output_tokens" => row.output_tokens,
      "cache_read_tokens" => row.cache_read_tokens,
      "cache_write_tokens" => row.cache_write_tokens,
      "total_input_tokens" => row.total_input_tokens,
      "unknown" => row.usage_incomplete
    }
  end

  defp atom_usage_to_string(usage) do
    %{
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cache_read_tokens" => usage.cache_read_tokens,
      "cache_write_tokens" => usage.cache_write_tokens,
      "total_input_tokens" => usage.total_input_tokens,
      "unknown" => usage.usage_incomplete
    }
  end

  defp terminal_usage_event?(event) when is_map(event) do
    kind = usage_fetch(event, [:kind, "kind"])
    payload = usage_fetch(event, [:payload, "payload"]) || %{}
    status = usage_fetch(payload, [:status, "status"])
    kind in [:run_end, "run_end"] and status not in [:interrupted, "interrupted", nil]
  end

  defp terminal_usage_event?(_event), do: false

  defp event_usage(event),
    do: usage_fetch(usage_fetch(event, [:payload, "payload"]) || %{}, [:usage, "usage"]) || %{}

  defp event_run_key(event, index) do
    payload = usage_fetch(event, [:payload, "payload"]) || %{}

    usage_fetch(payload, [:run_id, "run_id"]) || usage_fetch(event, [:run_id, "run_id"]) ||
      "event-#{index}"
  end

  defp normalize_field(key, value) when key in [:loaded_tools, "loaded_tools"],
    do: encode_json!(value || [])

  defp normalize_field(key, value)
       when key in [
              :archived_at,
              "archived_at",
              :pinned_at,
              "pinned_at",
              :created_at,
              "created_at",
              :updated_at,
              "updated_at"
            ],
       do: parse_time(value)

  defp normalize_field(_key, value), do: value

  defp valid_id?(id), do: byte_size(id) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)
  defp present?(value), do: is_binary(value) and value != ""
  defp map_value(map, key), do: Handbean.Utils.SafeMap.get(map, key)

  defp string_value(map, key) do
    case map_value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp list_value(map, key) do
    case map_value(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp encode_json!(value), do: value |> Handbean.JsonSafe.normalize() |> Handbean.JSON.encode!()

  defp decode_list(nil), do: []

  defp decode_list(value) when is_binary(value) do
    case Handbean.JSON.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp encode_nullable(nil), do: nil
  defp encode_nullable(value), do: encode_json!(value)

  defp decode_nullable(nil), do: nil

  defp decode_nullable(value) do
    case Handbean.JSON.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp parse_time(nil), do: nil
  defp parse_time(%DateTime{} = value), do: microsecond_precision(value)

  defp parse_time(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> microsecond_precision()

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> microsecond_precision(timestamp)
      _ -> nil
    end
  end

  defp microsecond_precision(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  defp iso8601(nil), do: nil

  defp iso8601(%DateTime{microsecond: {0, _precision}} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp now_naive,
    do: DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)

  defp ensure_transaction!(:ok), do: :ok
  defp ensure_transaction!({:error, reason}), do: Repo.rollback(reason)

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp constraint_reason(%{constraint: constraint}), do: {:constraint, constraint}
end
