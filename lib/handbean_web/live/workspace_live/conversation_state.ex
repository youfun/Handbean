defmodule HandbeanWeb.WorkspaceLive.ConversationState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4]

  require Logger

  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.ModelSelection

  def sync_conv_state(socket, opts \\ []) do
    conv =
      if Keyword.get(opts, :reload?, false) do
        load_current_conversation_from_store(socket) || current_conv_map(socket)
      else
        current_conv_map(socket)
      end

    socket
    |> maybe_replace_current_conversation(conv)
    |> sync_conv_from(conv, opts)
  end

  def sync_conv_from(socket, conv, opts \\ []) do
    current_timeline = Map.get(socket.assigns, :timeline, [])

    fallback =
      if current_timeline != [],
        do: current_timeline,
        else: conv_value(conv, "timeline", [])

    conv_id = conversation_id(conv)

    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    {timeline, history_before, history_has_more?} =
      if running_for_conversation?(socket, conv_id) and current_timeline != [] and
           not Keyword.get(opts, :force_transcript?, false) do
        {current_timeline, Map.get(socket.assigns, :history_before),
         Map.get(socket.assigns, :history_has_more?, false)}
      else
        page = Keyword.get(opts, :transcript_page)

        history =
          if page do
            {page.entries, page.before, page.has_more?}
          else
            load_transcript_page(
              conv_id,
              fallback,
              if(Keyword.get(opts, :force_transcript?, false),
                do: length(current_timeline),
                else: 100
              )
            )
          end

        history
        |> then(fn {entries, before, has_more?} ->
          {HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(entries, expanded), before,
           has_more?}
        end)
      end

    available_models = Map.get(socket.assigns, :available_models, [])
    selected_model = conversation_selected_model(socket, conv, available_models)
    token_usage = load_conversation_token_usage(conv_id)
    running_for_conversation? = running_for_conversation?(socket, conv_id)
    workspace_root = Map.get(socket.assigns, :workspace_root)
    {editor_files, active_file} = normalize_editor_state(socket, conv, workspace_root)

    socket =
      socket
      |> assign(:editor_files, editor_files)
      |> assign(:active_file, active_file)
      |> assign(
        :editor_state_key,
        {editor_state_key(conv, workspace_root), editor_files, active_file}
      )
      |> refresh_file_preview(workspace_root, Keyword.get(opts, :refresh_preview?, false))

    status_overrides =
      %{model: model_display_name(selected_model, available_models, opts)}
      |> then(fn base ->
        if running_for_conversation?,
          do: base,
          else: Map.merge(Map.put(base, :turns, 0), token_usage)
      end)

    socket =
      socket
      |> assign(:timeline, timeline)
      |> assign(:history_before, history_before)
      |> assign(:history_has_more?, history_has_more?)
      |> maybe_reset_timeline_stream(
        timeline,
        running_for_conversation?,
        timeline != current_timeline or not timeline_stream_initialized?(socket)
      )

    socket
    |> assign(:selected_model, selected_model)
    |> sync_reasoning_for_conversation(conv, selected_model, opts)
    |> maybe_update_status(status_overrides, opts)
    |> assign(:revert_confirm_change_id, nil)
    |> assign(:revert_message, nil)
    |> load_effective_settings(opts)
  end

  def sync_conv_to(socket) do
    conv_id = socket.assigns.current_conversation_id
    ws_id = conversation_bucket(socket)
    convs = socket.assigns.conversations_by_workspace
    current_convs = Map.get(convs, ws_id, [])

    updated =
      Enum.map(current_convs, fn c ->
        if conversation_id(c) == conv_id do
          merge_conversation_state(c, socket)
        else
          c
        end
      end)

    socket =
      socket
      |> assign(:conversations_by_workspace, Map.put(convs, ws_id, updated))

    persist_current_conversation(socket)
    socket
  end

  def update_conv(socket, conv) do
    conv_id = socket.assigns.current_conversation_id
    ws_id = conversation_bucket(socket)
    convs = socket.assigns.conversations_by_workspace
    current_convs = Map.get(convs, ws_id, [])

    updated =
      Enum.map(current_convs, fn c ->
        if conversation_id(c) == conv_id, do: conv, else: c
      end)

    socket =
      socket
      |> assign(:conversations_by_workspace, Map.put(convs, ws_id, updated))
      |> ConversationSwitching.reload_conversation_stream()

    persist_current_conversation(socket)
    socket
  end

  def select_file(socket, path, workspace_root, _opts \\ []) do
    open_editor_file(socket, path, workspace_root, :user)
  end

  def select_editor_file(socket, path, workspace_root, _opts \\ []) do
    with true <- editor_available?(socket),
         true <- is_binary(path) and Path.type(path) == :relative,
         {:ok, relative} <- relative_editor_path(path, workspace_root),
         true <- Enum.any?(socket.assigns.editor_files, &(file_path_value(&1) == relative)) do
      socket
      |> assign(:active_file, relative)
      |> refresh_file_preview(workspace_root, true)
      |> sync_conv_to()
    else
      _ -> socket
    end
  end

  def open_editor_file(socket, path, workspace_root, source) do
    if editor_available?(socket) do
      case resolve_editor_file(path, workspace_root) do
        {:ok, relative} ->
          files = socket.assigns.editor_files
          active = socket.assigns.active_file

          exists? = Enum.any?(files, &(file_path_value(&1) == relative))

          if not exists? and length(files) >= 20 do
            if source == :user,
              do:
                Phoenix.LiveView.put_flash(
                  socket,
                  :error,
                  "You can open up to 20 files. Close a tab first."
                ),
              else: socket
          else
            files = if exists?, do: files, else: files ++ [%{path: relative, name: relative}]
            active = if source == :user or is_nil(active), do: relative, else: active

            if source == :user,
              do: Handbean.Search.touch(workspace_root, Path.expand(relative, workspace_root))

            socket
            |> assign(:editor_files, files)
            |> assign(:active_file, active)
            |> refresh_file_preview(workspace_root, active == relative)
            |> sync_conv_to()
          end

        {:error, reason} ->
          if source == :user do
            Phoenix.LiveView.put_flash(socket, :error, error_text(reason))
          else
            case relative_editor_path(path, workspace_root) do
              {:ok, relative} when relative == socket.assigns.active_file ->
                refresh_file_preview(socket, workspace_root, true)

              _ ->
                socket
            end
          end
      end
    else
      socket
    end
  end

  def close_file(socket, path, workspace_root, _opts \\ []) do
    with true <- editor_available?(socket),
         {:ok, relative} <- relative_editor_path(path, workspace_root),
         files = socket.assigns.editor_files,
         index when is_integer(index) <-
           Enum.find_index(files, &(file_path_value(&1) == relative)) do
      remaining = List.delete_at(files, index)

      active =
        if socket.assigns.active_file == relative,
          do: file_path_value(Enum.at(remaining, index) || List.last(remaining)),
          else: socket.assigns.active_file

      socket
      |> assign(:editor_files, remaining)
      |> assign(:active_file, active)
      |> refresh_file_preview(workspace_root)
      |> sync_conv_to()
    else
      _ -> socket
    end
  end

  def current_conv_map(socket) do
    conv_id = socket.assigns.current_conversation_id
    ws_id = conversation_bucket(socket)
    convs = Map.get(socket.assigns.conversations_by_workspace, ws_id, [])

    conv = Enum.find(convs, &(conversation_id(&1) == conv_id))

    cond do
      is_nil(conv) ->
        load_or_build_current_conversation(conv_id, ws_id)

      conv_value(conv, "editor_files", :not_loaded) == :not_loaded ->
        # Sidebar summaries omit editor state; missing fields are not empty tabs.
        load_current_conversation_from_store(socket) || conv

      true ->
        conv
    end
  end

  def load_current_conversation_from_store(socket) do
    conv_id = socket.assigns.current_conversation_id

    if is_binary(conv_id) do
      case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
        {:ok, conversation} ->
          Logger.debug(
            "[WorkspaceLive] loaded conversation from store conversation=#{conv_id} " <>
              "metadata_only=true"
          )

          conversation

        {:error, :not_found} ->
          nil
      end
    end
  end

  def load_transcript_entries(conversation_id, fallback) when is_binary(conversation_id) do
    case Handbean.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} -> Handbean.PubSub.Projection.visible_entries(entries)
      {:error, _reason} -> fallback
    end
  end

  def load_transcript_entries(_conversation_id, fallback), do: fallback

  def load_transcript_page(conversation_id, fallback, count \\ 100)

  def load_transcript_page(conversation_id, fallback, count) when is_binary(conversation_id) do
    case Handbean.PubSub.Projection.history(conversation_id, count) do
      {:ok, %{entries: entries, before: before, has_more?: has_more?}} ->
        {entries, before, has_more?}

      {:error, _reason} ->
        {fallback, nil, false}
    end
  end

  def load_transcript_page(_conversation_id, fallback, _count), do: {fallback, nil, false}

  def load_older_history(socket) do
    conv_id = socket.assigns.current_conversation_id
    before = Map.get(socket.assigns, :history_before)

    with true <- is_binary(conv_id) and is_binary(before),
         {:ok, %{entries: entries, before: next_before, has_more?: has_more?}} <-
           Handbean.ConversationTranscriptStore.page(conv_id, limit: 100, before: before) do
      entries = Handbean.PubSub.Projection.visible_entries(entries)
      loaded_ids = MapSet.new(socket.assigns.timeline, &conv_value(&1, "id", nil))
      entries = Enum.reject(entries, &MapSet.member?(loaded_ids, conv_value(&1, "id", nil)))

      timeline =
        entries
        |> Kernel.++(socket.assigns.timeline)
        |> deduplicate_entries()
        |> HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(
          Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())
        )

      pending =
        Handbean.Agent.PendingMessages.reconcile(
          socket.assigns.pending_messages,
          HandbeanWeb.WorkspaceLive.RuntimeProjection.session_pending_messages(conv_id),
          socket.assigns.running,
          timeline
        )

      timeline = Handbean.Agent.PendingMessages.pin_pending(timeline, pending)

      socket
      |> assign(:timeline, timeline)
      |> assign(:pending_messages, pending)
      |> assign(:history_before, next_before)
      |> assign(:history_has_more?, has_more?)
      |> stream(:timeline, timeline, reset: true)
    else
      _ -> socket
    end
  end

  def maybe_replace_current_conversation(socket, conv) do
    if is_binary(socket.assigns.current_conversation_id) do
      replace_current_conversation(socket, conv)
    else
      socket
    end
  end

  def replace_current_conversation(socket, conv) do
    conv_id = conversation_id(conv)
    ws_id = bucket_for(conv, socket)
    convs = socket.assigns.conversations_by_workspace
    current_convs = Map.get(convs, ws_id, [])

    updated =
      if Enum.any?(current_convs, &(conversation_id(&1) == conv_id)) do
        Enum.map(current_convs, fn existing ->
          if conversation_id(existing) == conv_id,
            do: preserve_sidebar_sort_key(conv, existing),
            else: existing
        end)
      else
        current_convs ++ [conv]
      end

    assign(socket, :conversations_by_workspace, Map.put(convs, ws_id, updated))
  end

  # Selecting a chat reloads its metadata. Keep the sidebar timestamps so a
  # view, or a newer disk copy, does not move the row.
  defp preserve_sidebar_sort_key(incoming, existing) do
    Enum.reduce(["updated_at", "created_at"], incoming, fn key, acc ->
      case conv_value(existing, key, nil) do
        nil -> acc
        value -> put_conversation_value(acc, key, value)
      end
    end)
  end

  def merge_conversation_state(conversation, socket) do
    conversation
    |> put_conversation_value("editor_files", socket.assigns.editor_files)
    |> put_conversation_value("active_file", socket.assigns.active_file)
    |> put_conversation_value("selected_model", socket.assigns.selected_model)
    |> put_conversation_value("selected_reasoning_level", socket.assigns.selected_reasoning_level)
  end

  def put_conversation_value(conversation, key, value)
      when is_map(conversation) and is_binary(key) do
    Map.put(conversation, stored_key(conversation, key), value)
  end

  def conv_value(conversation, key, default) do
    Handbean.Utils.SafeMap.get(conversation, key, default)
  end

  defp stored_key(conversation, key) do
    cond do
      Map.has_key?(conversation, key) -> key
      atom = existing_atom(key) -> if Map.has_key?(conversation, atom), do: atom, else: key
      true -> key
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  def conversation_id(conversation), do: conv_value(conversation, "id", nil)

  def conversation_bucket(socket) do
    if Map.get(socket.assigns, :chat_scope) == :free,
      do: ConversationSwitching.free_key(),
      else: socket.assigns.current_workspace_id
  end

  def bucket_for(conv, socket) do
    cond do
      Handbean.ConversationStore.free?(conv) -> ConversationSwitching.free_key()
      is_binary(conv_value(conv, "workspace_id", nil)) -> conv_value(conv, "workspace_id", nil)
      true -> conversation_bucket(socket)
    end
  end

  def build_memory_conversation(workspace_id, num) do
    now = DateTime.utc_now()

    %{
      "id" => Ecto.UUID.generate(),
      "workspace_id" => workspace_id,
      "title" => conversation_title(num),
      "title_source" => "manual",
      "timeline" => [],
      "editor_files" => [],
      "active_file" => nil,
      "created_at" => now,
      "updated_at" => now
    }
  end

  def persist_current_conversation(socket) do
    conv_id = socket.assigns.current_conversation_id

    if is_binary(conv_id) do
      _ =
        Handbean.ConversationStore.save_files(conv_id, %{
          "editor_files" => socket.assigns.editor_files,
          "active_file" => socket.assigns.active_file
        })

      _ =
        Handbean.ConversationStore.update_meta(conv_id,
          selected_model: socket.assigns.selected_model,
          selected_reasoning_level: socket.assigns.selected_reasoning_level,
          touch: false
        )

      :ok
    else
      :ok
    end
  end

  def load_conversation_token_usage(conv_id) do
    case Handbean.ConversationStore.get_token_usage(conv_id) do
      {:ok, tokens} ->
        tokens

      {:error, _} ->
        empty_token_usage()
    end
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

  def running_for_current_conversation?(socket) do
    running_for_conversation?(socket, Map.get(socket.assigns, :current_conversation_id))
  end

  defp maybe_reset_timeline_stream(socket, timeline, true, changed?) do
    maybe_reset_changed_timeline(socket, timeline, changed?)
  end

  defp maybe_reset_timeline_stream(socket, timeline, false, changed?) do
    socket
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:tools_active, %{})
    |> assign(:current_assistant_entry_id, nil)
    |> assign(:stream_suppressed, false)
    |> assign(:thinking_active, false)
    |> assign(:thinking_content, "")
    |> assign(:think_buffer, "")
    |> maybe_assign_idle_status()
    |> maybe_reset_changed_timeline(timeline, changed?)
  end

  defp maybe_reset_changed_timeline(socket, timeline, true),
    do: stream(socket, :timeline, timeline, reset: true)

  defp maybe_reset_changed_timeline(socket, _timeline, false), do: socket

  defp timeline_stream_initialized?(socket) do
    case Map.get(socket.assigns, :streams) do
      %{} = streams -> Map.has_key?(streams, :timeline)
      _ -> false
    end
  end

  defp running_for_conversation?(socket, conv_id) when is_binary(conv_id) do
    Map.get(socket.assigns, :running, false) and
      Map.get(socket.assigns, :running_conversation_id) == conv_id
  end

  defp running_for_conversation?(_socket, _conv_id), do: false

  defp maybe_assign_idle_status(socket) do
    if Map.has_key?(socket.assigns, :status_info) do
      assign(socket, :status_info, Map.merge(socket.assigns.status_info, %{status: :idle}))
    else
      socket
    end
  end

  defp load_or_build_current_conversation(conv_id, ws_id) when is_binary(conv_id) do
    case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, conversation} ->
        conversation

      {:error, :not_found} ->
        build_memory_conversation(ws_id, 1)
    end
  end

  defp load_or_build_current_conversation(_conv_id, ws_id),
    do: build_memory_conversation(ws_id, 1)

  defp editor_available?(socket) do
    Map.get(socket.assigns, :chat_scope) != :free and
      is_binary(Map.get(socket.assigns, :current_conversation_id))
  end

  defp editor_state_key(conv, root) do
    {conversation_id(conv), root, conv_value(conv, "editor_files", []),
     conv_value(conv, "active_file", nil)}
  end

  defp normalize_editor_state(socket, conv, root) do
    editor_files = Map.get(socket.assigns, :editor_files, [])
    active_file = Map.get(socket.assigns, :active_file)

    cond do
      not editor_available?(socket) ->
        {[], nil}

      Map.get(socket.assigns, :editor_state_key) ==
          {editor_state_key(conv, root), editor_files, active_file} ->
        {editor_files, active_file}

      true ->
        normalize_stored_editor_state(conv, root)
    end
  end

  defp normalize_stored_editor_state(conv, root) do
    files =
      (conv_value(conv, "editor_files", []) || [])
      |> Enum.flat_map(fn file ->
        case normalize_stored_path(file_path_value(file), root) do
          {:ok, relative} -> [%{path: relative, name: relative}]
          _ -> []
        end
      end)
      |> Enum.uniq_by(& &1.path)
      |> Enum.take(20)

    active =
      case normalize_stored_path(conv_value(conv, "active_file", nil), root) do
        {:ok, relative} -> relative
        _ -> nil
      end

    cond do
      is_nil(active) -> {files, nil}
      Enum.any?(files, &(&1.path == active)) -> {files, active}
      true -> {Enum.take(files, 19) ++ [%{path: active, name: active}], active}
    end
  end

  defp relative_editor_path(path, root) when is_binary(path) and is_binary(root) do
    absolute = Path.expand(path, root)
    relative = Path.relative_to(absolute, Path.expand(root))

    if path != "" and not String.contains?(path, <<0>>) and
         ".." not in Path.split(path) and Path.type(relative) == :relative and relative != "." do
      {:ok, relative}
    else
      {:error, :invalid_path}
    end
  end

  defp relative_editor_path(_, _), do: {:error, :invalid_path}

  defp resolve_editor_file(path, root) do
    with {:ok, relative} <- relative_editor_path(path, root),
         :ok <- Handbean.Security.PathValidator.reject_resolved(Path.expand(relative, root)),
         {:ok, _absolute} <- Handbean.WorkspaceFiles.resolve(root, relative, :file) do
      {:ok, relative}
    end
  end

  defp normalize_stored_path(path, root) when is_binary(path) do
    if Path.type(path) == :relative do
      with {:ok, relative} <- relative_editor_path(path, root),
           :ok <- Handbean.Security.PathValidator.reject_resolved(Path.expand(relative, root)) do
        case Handbean.WorkspaceFiles.resolve(root, relative, :file) do
          {:ok, _} -> {:ok, relative}
          {:error, :enoent} -> {:ok, relative}
          error -> error
        end
      end
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_stored_path(_path, _root), do: {:error, :invalid_path}

  def refresh_file_preview(socket, root, force? \\ false) do
    active = Map.get(socket.assigns, :active_file)
    key = {root, active}

    if force? or Map.get(socket.assigns, :file_preview_key) != key or
         (is_binary(active) and is_nil(Map.get(socket.assigns, :file_preview))) do
      preview = load_file_preview(active, root)

      socket
      |> assign(:file_preview_key, key)
      |> assign(:file_preview, preview)
      |> assign(:file_preview_error, preview_error(preview))
    else
      socket
    end
  end

  defp load_file_preview(nil, _workspace_root), do: nil

  defp load_file_preview(path, workspace_root)
       when is_binary(path) and is_binary(workspace_root) do
    with {:ok, relative} <- resolve_editor_file(path, workspace_root),
         {:ok, preview} <- Handbean.WorkspaceFiles.preview(workspace_root, relative) do
      preview
    else
      {:error, reason} -> {:error, error_text(reason)}
    end
  end

  defp load_file_preview(_, _), do: {:error, "Invalid file path"}

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(:enoent), do: "File no longer exists"
  defp error_text(:symlink), do: "Symbolic links cannot be previewed"
  defp error_text(:invalid_path), do: "Invalid file path"
  defp error_text(reason), do: "Unable to preview file: #{inspect(reason)}"

  defp preview_error({:error, reason}), do: error_text(reason)
  defp preview_error(_), do: nil

  defp file_path_value(nil), do: nil
  defp file_path_value(file) when is_map(file), do: conv_value(file, "path", nil)
  defp file_path_value(_), do: nil

  defp deduplicate_entries(entries) do
    Enum.uniq_by(entries, &conv_value(&1, "id", nil))
  end

  defp conversation_selected_model(_socket, conv, available) do
    pinned_model = collaboration_model(conv)
    stored_model = conv_value(conv, "selected_model", nil)

    selected_model =
      Enum.find([pinned_model, stored_model], fn model ->
        is_binary(model) and Enum.any?(available, &(&1.id == model))
      end)

    cond do
      selected_model ->
        selected_model

      match?([_ | _], available) ->
        first = List.first(available)
        first && first.id

      true ->
        nil
    end
  end

  defp collaboration_model(conv) do
    provider = get_in(conv || %{}, ["collaboration", "provider"])
    model = get_in(conv || %{}, ["collaboration", "model"])

    if is_binary(provider) and is_binary(model), do: "#{provider}/#{model}"
  end

  defp sync_reasoning_for_conversation(socket, conv, selected_model, opts) do
    case Keyword.get(opts, :sync_reasoning_for_conversation) do
      fun when is_function(fun, 3) -> fun.(socket, conv, selected_model)
      _ -> ModelSelection.sync_reasoning_for_conversation(socket, conv, selected_model)
    end
  end

  defp model_display_name(selected_model, available_models, opts) do
    case Keyword.get(opts, :model_display_name) do
      fun when is_function(fun, 2) -> fun.(selected_model, available_models)
      _ -> ModelSelection.model_display_name(selected_model, available_models)
    end
  end

  defp maybe_update_status(socket, overrides, opts) do
    case Keyword.get(opts, :update_status) do
      fun when is_function(fun, 2) ->
        fun.(socket, overrides)

      _ ->
        if Map.has_key?(socket.assigns, :status_info) do
          assign(socket, :status_info, Map.merge(socket.assigns.status_info, overrides))
        else
          socket
        end
    end
  end

  defp load_effective_settings(socket, opts) do
    case Keyword.get(opts, :load_effective_settings) do
      fun when is_function(fun, 1) -> fun.(socket)
      _ -> ModelSelection.load_effective_settings(socket)
    end
  end

  def free_chat?(socket), do: socket.assigns[:chat_scope] == :free

  def current_workspace_path(socket) do
    if free_chat?(socket) do
      nil
    else
      case socket.assigns[:workspace_path] do
        path when is_binary(path) and path != "" ->
          path

        _ ->
          case Handbean.WorkspaceStore.get(socket.assigns.current_workspace_id) do
            {:ok, ws} -> ws["path"]
            {:error, _} -> nil
          end
      end
    end
  end

  def current_checkout_path(socket) do
    if free_chat?(socket) do
      nil
    else
      case socket.assigns[:workspace_root] do
        path when is_binary(path) and path != "" ->
          path

        _ ->
          case Handbean.ConversationStore.effective_checkout_path(
                 socket.assigns[:current_conversation_id]
               ) do
            {:ok, path} -> path
            {:error, _reason} -> nil
          end
      end
    end
  end

  defp conversation_title(1), do: "New chat"
  defp conversation_title(num), do: "New chat ##{num}"

  def schedule_auto_title(socket, message) when is_binary(message) do
    trigger_auto_title(socket, message)
  end

  def schedule_auto_title(socket, _message), do: socket

  def maybe_auto_title(socket, :completed) do
    conversation_id = socket.assigns.current_conversation_id

    timeline =
      conversation_id
      |> load_transcript_entries(socket.assigns.timeline)

    first_user_msg =
      Enum.find_value(timeline, fn entry ->
        if entry["role"] == "user" and not is_nil(entry["content"]) do
          entry["content"]
        end
      end)

    if first_user_msg do
      trigger_auto_title(socket, first_user_msg)
    else
      Logger.debug(
        "[WorkspaceLive] maybe_auto_title skip — no user message found in timeline conv_id=#{conversation_id}"
      )

      socket
    end
  end

  def maybe_auto_title(socket, _not_completed), do: socket

  def trigger_auto_title(socket, message) when is_binary(message) do
    conv = current_conv_map(socket)
    title = conv_value(conv, "title", "")
    title_source = conv_value(conv, "title_source", nil)
    conversation_id = socket.assigns.current_conversation_id

    Logger.debug(
      "[WorkspaceLive] maybe_auto_title entry conv_id=#{conversation_id} title=#{inspect(title)} title_source=#{inspect(title_source)}"
    )

    cond do
      titled?(title, title_source) ->
        Logger.debug(
          "[WorkspaceLive] maybe_auto_title skip — title already set conv_id=#{conversation_id} title=#{inspect(title)} title_source=#{inspect(title_source)}"
        )

        socket

      String.trim(message) == "" ->
        socket

      true ->
        socket = show_provisional_title(socket, conversation_id, message)

        case ModelSelection.resolve_auto_title_model(socket, conv) do
          {:ok, provider_config, selected_model} ->
            provider_config = Map.put(provider_config, :notify_pid, self())

            case Handbean.ConversationTitleGenerator.maybe_generate(
                   conversation_id,
                   message,
                   provider_config
                 ) do
              {:ok, pid} ->
                Logger.debug(
                  "[WorkspaceLive] Triggered auto-title generation conv_id=#{conversation_id} model=#{inspect(selected_model)} task_pid=#{inspect(pid)}"
                )

              :skip ->
                Logger.debug(
                  "[WorkspaceLive] TitleGenerator.maybe_generate returned :skip conv_id=#{conversation_id}"
                )

              other ->
                Logger.debug(
                  "[WorkspaceLive] TitleGenerator.maybe_generate failed conv_id=#{conversation_id} result=#{inspect(other)}"
                )
            end

            socket

          {:error, reason, selected_model} ->
            Logger.debug(
              "[WorkspaceLive] Skipped model title model=#{inspect(selected_model)} reason=#{inspect(reason)}"
            )

            socket
        end
    end
  end

  def titled?(title, source) do
    not Handbean.ConversationTitleGenerator.default_title?(title) and source != "fallback"
  end

  def show_provisional_title(socket, conversation_id, message) do
    case Handbean.ConversationTitleGenerator.publish_provisional(conversation_id, message) do
      {:ok, title} ->
        socket
        |> ConversationSwitching.apply_sidebar_title(conversation_id, title, "fallback")
        |> maybe_patch_page_title(conversation_id, title)

      :skip ->
        socket
    end
  end

  def maybe_patch_page_title(socket, conv_id, title) do
    if socket.assigns.current_conversation_id == conv_id and is_binary(title) and title != "" do
      assign(socket, :page_title, title)
    else
      socket
    end
  end

  def maybe_patch_current_page_title(socket, conv_id) do
    title =
      socket.assigns.conversations_by_workspace
      |> Map.values()
      |> List.flatten()
      |> Enum.find_value(fn conv ->
        if conversation_id(conv) == conv_id do
          conv_value(conv, "title", nil)
        end
      end)

    maybe_patch_page_title(socket, conv_id, title)
  end
end
