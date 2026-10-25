defmodule HandbeanWeb.WorkspaceLive.ConversationState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4]

  require Logger

  alias HandbeanWeb.WorkspaceLive.ConversationState.{AutoTitle, EditorState, History}
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

    around_window? =
      Map.get(socket.assigns, :history_window) == :around and
        socket.assigns.current_conversation_id == conv_id and current_timeline != []

    {timeline, history_before, history_has_more?, history_after, history_has_newer?} =
      cond do
        around_window? ->
          {current_timeline, Map.get(socket.assigns, :history_before),
           Map.get(socket.assigns, :history_has_more?, false),
           Map.get(socket.assigns, :history_after),
           Map.get(socket.assigns, :history_has_newer?, false)}

        running_for_conversation?(socket, conv_id) and current_timeline != [] and
            not Keyword.get(opts, :force_transcript?, false) ->
          {current_timeline, Map.get(socket.assigns, :history_before),
           Map.get(socket.assigns, :history_has_more?, false), nil, false}

        true ->
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
            timeline = HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(entries, expanded)
            {timeline, before, has_more?, nil, false}
          end)
      end

    available_models = Map.get(socket.assigns, :available_models, [])
    selected_model = conversation_selected_model(socket, conv, available_models)
    token_usage = load_conversation_token_usage(conv_id)
    running_for_conversation? = running_for_conversation?(socket, conv_id)
    workspace_root = Map.get(socket.assigns, :workspace_root)
    {editor_files, active_file} = EditorState.normalize(socket, conv, workspace_root)

    socket =
      socket
      |> assign(:editor_files, editor_files)
      |> assign(:active_file, active_file)
      |> assign(
        :editor_state_key,
        {EditorState.state_key(conv, workspace_root), editor_files, active_file}
      )
      |> EditorState.refresh_preview(
        workspace_root,
        Keyword.get(opts, :refresh_preview?, false)
      )

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
      |> assign(:history_after, history_after)
      |> assign(:history_has_newer?, history_has_newer?)
      |> assign(:history_window, if(around_window?, do: :around, else: :latest))
      |> maybe_reset_timeline_stream(
        timeline,
        running_for_conversation?,
        timeline != current_timeline or not timeline_stream_initialized?(socket)
      )

    socket
    |> assign(:selected_model, selected_model)
    |> assign(:model_selection_revision, conv_value(conv, "model_selection_revision", 0))
    |> assign(:channel_binding, conv_value(conv, "channel_binding", nil))
    |> sync_reasoning_for_conversation(conv, selected_model, opts)
    |> maybe_update_status(status_overrides, opts)
    |> assign(:revert_confirm_change_id, nil)
    |> assign(:revert_message, nil)
    |> load_effective_settings(opts)
  end

  def sync_conv_to(socket, opts \\ []) do
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

    if Keyword.get(opts, :persist?, true), do: persist_current_conversation(socket)
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
    EditorState.select_file(socket, path, workspace_root, &sync_conv_to/1)
  end

  def select_editor_file(socket, path, workspace_root, _opts \\ []) do
    EditorState.select(socket, path, workspace_root, &sync_conv_to/1)
  end

  def open_editor_file(socket, path, workspace_root, source) do
    EditorState.open(socket, path, workspace_root, source, &sync_conv_to/1)
  end

  def close_file(socket, path, workspace_root, _opts \\ []) do
    EditorState.close(socket, path, workspace_root, &sync_conv_to/1)
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

  defdelegate load_transcript_entries(conversation_id, fallback), to: History

  def load_transcript_page(conversation_id, fallback, count \\ 100),
    do: History.load_transcript_page(conversation_id, fallback, count)

  defdelegate load_older_history(socket), to: History, as: :load_older

  defdelegate load_around_history(socket, page, anchor_id), to: History, as: :load_around

  defdelegate load_newer_history(socket), to: History, as: :load_newer

  def return_to_latest_history(socket) do
    socket
    |> History.prepare_latest()
    |> sync_conv_state(force_transcript?: true)
    |> Phoenix.LiveView.push_event("scroll_chat_to_bottom", %{})
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
    |> put_conversation_value(
      "model_selection_revision",
      socket.assigns[:model_selection_revision] || 0
    )
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

  def refresh_file_preview(socket, root, force? \\ false),
    do: EditorState.refresh_preview(socket, root, force?)

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

  def schedule_auto_title(socket, message) when is_binary(message),
    do: AutoTitle.schedule(socket, message, current_conv_map(socket))

  def schedule_auto_title(socket, _message), do: socket

  def maybe_auto_title(socket, :completed) do
    conversation_id = socket.assigns.current_conversation_id
    timeline = load_transcript_entries(conversation_id, socket.assigns.timeline)
    AutoTitle.maybe(socket, :completed, timeline, fn -> current_conv_map(socket) end)
  end

  def maybe_auto_title(socket, _not_completed), do: socket

  def trigger_auto_title(socket, message) when is_binary(message) do
    AutoTitle.trigger(socket, message, current_conv_map(socket))
  end

  defdelegate titled?(title, source), to: AutoTitle

  defdelegate show_provisional_title(socket, conversation_id, message),
    to: AutoTitle,
    as: :show_provisional

  defdelegate maybe_patch_page_title(socket, conv_id, title),
    to: AutoTitle,
    as: :patch_page_title

  defdelegate maybe_patch_current_page_title(socket, conv_id),
    to: AutoTitle,
    as: :patch_current_page_title
end
