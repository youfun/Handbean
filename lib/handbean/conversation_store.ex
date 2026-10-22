defmodule Handbean.ConversationStore do
  @moduledoc """
  SQLite-backed conversation facade.

  Callers receive the existing string-key maps; Ecto structs and database
  representation stay private to this module.
  """

  alias Ecto.Changeset
  alias Handbean.ConversationStore.{Codec, Projection, Usage}
  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEditorState}

  @type conversation :: map()
  @title_max_length 80
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
    :permission_mode,
    :permission_revision,
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
                      :permission_mode,
                      :permission_revision,
                      :next_entry_sequence,
                      :created_at,
                      :updated_at
                    ]
  @owned_on_upsert ~w(collaboration visibility last_run_result parent_conversation_id parent_run_id parent_tool_call_id pinned_at)
  @usage_meta_keys ~w(token_usage run_usage usage_legacy run_usage_replace delegated_usage)

  @doc "List every persisted conversation."
  @spec list(keyword()) :: [conversation()]
  def list(opts \\ []) do
    opts
    |> Projection.list()
    |> attach_timelines(opts)
  end

  @doc "List conversations for a workspace id."
  def list_for_workspace(workspace_id),
    do: list_for_workspace(workspace_id, include_archived?: false)

  def list_for_workspace(workspace_id, opts) when is_binary(workspace_id) do
    workspace_id
    |> Projection.list_for_workspace(opts)
    |> attach_timelines(opts)
  end

  def list_metadata(workspace_id) when is_binary(workspace_id),
    do: Projection.list_metadata(workspace_id)

  @doc "List conversation summaries with aggregate transcript/run counts in one query."
  def list_conversation_summaries(workspace_id) when is_binary(workspace_id) do
    Handbean.ConversationStore.Trajectory.list_conversation_summaries(workspace_id)
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

  @doc "Read one consistent durable trajectory page. Authorization belongs to Handbean.Conversations."
  def trajectory_snapshot(conversation_id, opts),
    do: Handbean.ConversationStore.Trajectory.snapshot(conversation_id, opts)

  @doc "Search settled public entries in one authorized workspace query."
  def search_entries(workspace_id, opts),
    do: Handbean.ConversationStore.EntrySearch.search(workspace_id, opts)

  def list_free_metadata, do: Projection.list_free_metadata()
  def fetch_summaries, do: Projection.fetch_summaries()

  def list_summaries(workspace_id) when is_binary(workspace_id),
    do: Projection.list_summaries(workspace_id)

  def list_free_summaries, do: Projection.list_free_summaries()

  def list_free(opts \\ []) do
    opts
    |> Projection.list_free()
    |> attach_timelines(opts)
  end

  def get_metadata(id) when is_binary(id) do
    if valid_id?(id), do: Projection.get_metadata(id), else: {:error, :not_found}
  end

  def get_metadata(_id), do: {:error, :not_found}

  @doc """
  Read an active conversation summary, including internal visibility, without usage or content.

  Accepts persisted binary IDs, including custom IDs outside the metadata read API's
  restricted format. This storage lookup does not authorize transcript access.
  """
  @spec get_summary(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_summary(id) when is_binary(id), do: Projection.get_summary(id)

  def get_summary(_id), do: {:error, :not_found}

  @doc """
  Read titles for many conversations in one query.

  Active conversations that exist are keyed by id; missing and non-active
  conversations are absent, so callers keep their own fallback. A nil or blank
  stored title projects to `""`.
  """
  @spec titles_for_ids([String.t()]) :: %{String.t() => String.t()}
  def titles_for_ids(ids) when is_list(ids), do: Projection.titles_for_ids(ids)

  def titles_for_ids(_ids), do: %{}

  def transcript_empty?(id) when is_binary(id),
    do: valid_id?(id) and Projection.transcript_empty?(id)

  def transcript_empty?(_id), do: false

  def get(id, opts \\ []) when is_binary(id) do
    with {:ok, conversation} <- Projection.fetch_active_row(id),
         true <- accessible?(Codec.base_metadata(conversation), opts) do
      {:ok, conversation_map(conversation, opts)}
    else
      _ -> {:error, :not_found}
    end
  end

  def internal?(%{"visibility" => "internal"}), do: true
  def internal?(%{visibility: "internal"}), do: true

  def internal?(id) when is_binary(id), do: Projection.internal?(id)

  def internal?(_value), do: false

  @doc "Returns the conversation that created this one."
  def parent_conversation_id(conversation) when is_map(conversation),
    do: string_value(conversation, "parent_conversation_id")

  def parent_conversation_id(_conversation), do: nil

  def authorize_read(id, opts) do
    with true <- is_binary(id) and valid_id?(id),
         {:ok, meta} <- get_summary(id),
         true <- accessible?(meta, opts),
         do: :ok,
         else: (_ -> {:error, :not_found})
  end

  def get_meta(id) when is_binary(id), do: get_metadata(id)

  def exists?(id) when is_binary(id), do: Projection.exists?(id)

  def active?(id) when is_binary(id), do: exists?(id)
  def active?(_id), do: false

  def lifecycle_status(id) when is_binary(id), do: Projection.lifecycle_status(id)

  def lifecycle_status(_id), do: :missing

  def delete_preview(id), do: Handbean.ConversationStore.Deletion.preview(id)
  def request_delete(id), do: Handbean.ConversationStore.Deletion.request(id)

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

  def free?(id) when is_binary(id), do: Projection.free?(id)

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
    broadcast_updated(conversation_id)

    if present?(title) do
      Phoenix.PubSub.broadcast(
        Handbean.PubSub,
        "conversation:updated",
        {:conversation_title_ready, conversation_id, title}
      )
    end

    :ok
  end

  @doc "Broadcast that durable conversation state changed; subscribers must re-read its owner."
  def broadcast_updated(conversation_id) when is_binary(conversation_id) do
    Phoenix.PubSub.broadcast(
      Handbean.PubSub,
      "conversation:updated",
      {:conversation_updated, conversation_id}
    )

    :ok
  end

  @doc "Broadcast a durable entry update together with the owning conversation update."
  def broadcast_updated(conversation_id, entry)
      when is_binary(conversation_id) and is_map(entry) do
    :ok = broadcast_updated(conversation_id)

    Phoenix.PubSub.broadcast(
      Handbean.PubSub,
      "conversation:updated",
      {:conversation_entry_updated, conversation_id, entry}
    )

    :ok
  end

  def upsert(conversation) when is_map(conversation) do
    id = string_value(conversation, "id") || Ecto.UUID.generate()
    existing = Repo.get(Conversation, id)

    with false <- match?(%Conversation{status: "pending_delete"}, existing),
         :ok <- validate_upsert_checkout(existing, conversation),
         :ok <- validate_upsert_permission(existing, conversation) do
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
    else
      true -> {:error, :not_found}
      error -> error
    end
  rescue
    error in Ecto.ConstraintError -> {:error, constraint_reason(error)}
    _error in Exqlite.Error -> {:error, :constraint}
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

  def load_files(conversation_id) when is_binary(conversation_id),
    do: Projection.load_files(conversation_id)

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

    with false <- Enum.any?(updates, fn {key, _value} -> to_string(key) == "permission_mode" end),
         {:ok, row} <- fetch_row(id) do
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
    else
      true -> {:error, :permission_mode_owned}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :invalid_field}
  end

  def get_token_usage(conversation_id), do: Usage.get_token_usage(conversation_id)
  def add_token_usage(conversation_id, usage), do: Usage.add_token_usage(conversation_id, usage)

  def record_run_usage(conversation_id, run_id, usage),
    do: Usage.record_run_usage(conversation_id, run_id, usage)

  def rebuild_token_usage_from_events(conversation_id, events),
    do: Usage.rebuild_token_usage_from_events(conversation_id, events)

  def record_delegated_usage(conversation_id, child_run_id, usage),
    do: Usage.record_delegated_usage(conversation_id, child_run_id, usage)

  def delegated_usage(conversation_id), do: Usage.delegated_usage(conversation_id)

  defp create_conversation(scope, workspace_id, opts) do
    with {:ok, checkout_path} <- checkout_path_for_create(scope, workspace_id, opts),
         {:ok, permission_mode} <- permission_mode_for_create(scope, workspace_id, opts) do
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
        permission_mode: permission_mode,
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
    _error in Exqlite.Error -> {:error, :constraint}
  end

  defp permission_mode_for_create(scope, workspace_id, opts) do
    Handbean.Permissions.ConversationMode.mode_for_create(scope, workspace_id, opts)
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

  defp fetch_row(id), do: Projection.fetch_active_row(id)

  defp conversation_map(row, opts) do
    row
    |> Projection.detail()
    |> attach_timeline(opts)
  end

  defp new_conversation_map(row, editor_attrs), do: Projection.new_detail(row, editor_attrs)
  defp metadata_map(row), do: Projection.metadata(row)

  defp attach_timelines(conversations, opts),
    do: Enum.map(conversations, &attach_timeline(&1, opts))

  defp attach_timeline(conversation, opts) do
    timeline =
      if Keyword.get(opts, :include_timeline?, true),
        do: load_messages(conversation["id"]),
        else: []

    Map.put(conversation, "timeline", timeline)
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
      permission_mode:
        string_value(conversation, "permission_mode") ||
          if(scope == "free", do: "prompt", else: "auto_review"),
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

  defp validate_upsert_permission(%Conversation{} = existing, conversation) do
    case map_value(conversation, "permission_mode") do
      nil -> :ok
      mode when mode == existing.permission_mode -> :ok
      _other -> {:error, :permission_mode_owned}
    end
  end

  defp validate_upsert_permission(nil, conversation) do
    scope =
      string_value(conversation, "scope") ||
        if(string_value(conversation, "workspace_id"), do: "workspace", else: "free")

    requested =
      string_value(conversation, "permission_mode") ||
        if(scope == "free", do: "prompt", else: "auto_review")

    with {:ok, mode} <- Handbean.Permissions.ConversationMode.normalize(requested),
         true <- scope != "free" or mode == :prompt do
      :ok
    else
      _ -> {:error, :invalid_mode}
    end
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

  defp map_value(map, key), do: Codec.map_value(map, key)
  defp string_value(map, key), do: Codec.string_value(map, key)
  defp list_value(map, key), do: Codec.list_value(map, key)
  defp encode_json!(value), do: Codec.encode_json!(value)
  defp decode_list(value), do: Codec.decode_list(value)
  defp encode_nullable(value), do: Codec.encode_nullable(value)
  defp parse_time(value), do: Codec.parse_time(value)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp ensure_transaction!(:ok), do: :ok
  defp ensure_transaction!({:error, reason}), do: Repo.rollback(reason)

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
  defp constraint_reason(%{constraint: constraint}), do: {:constraint, constraint}
end
