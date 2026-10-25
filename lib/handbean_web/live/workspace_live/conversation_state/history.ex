defmodule HandbeanWeb.WorkspaceLive.ConversationState.History do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4]

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

  def load_older(socket) do
    conv_id = socket.assigns.current_conversation_id
    before = Map.get(socket.assigns, :history_before)

    with true <- is_binary(conv_id) and is_binary(before),
         {:ok, %{entries: entries, before: next_before, has_more?: has_more?}} <-
           Handbean.ConversationTranscriptStore.page(conv_id, limit: 100, before: before) do
      entries = Handbean.PubSub.Projection.visible_entries(entries)
      loaded_ids = MapSet.new(socket.assigns.timeline, &entry_value(&1, "id", nil))
      entries = Enum.reject(entries, &MapSet.member?(loaded_ids, entry_value(&1, "id", nil)))

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

      timeline =
        if Map.get(socket.assigns, :history_window) == :around,
          do: timeline,
          else: Handbean.Agent.PendingMessages.pin_pending(timeline, pending)

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

  def load_around(socket, page, anchor_id) when is_map(page) and is_binary(anchor_id) do
    entries = Handbean.PubSub.Projection.visible_entries(page.entries)

    timeline =
      HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(
        entries,
        Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())
      )

    pending =
      Handbean.Agent.PendingMessages.reconcile(
        socket.assigns.pending_messages,
        HandbeanWeb.WorkspaceLive.RuntimeProjection.session_pending_messages(
          socket.assigns.current_conversation_id
        ),
        socket.assigns.running,
        timeline
      )

    socket
    |> assign(:timeline, timeline)
    |> assign(:pending_messages, pending)
    |> assign(:history_before, page.before)
    |> assign(:history_has_more?, page.has_more_before?)
    |> assign(:history_after, page.after)
    |> assign(:history_has_newer?, page.has_more_after?)
    |> assign(:history_window, :around)
    |> assign(:history_anchor_entry_id, anchor_id)
    |> stream(:timeline, timeline, reset: true)
    |> Phoenix.LiveView.push_event("focus-conversation-entry", %{id: anchor_id})
  end

  def load_newer(socket) do
    conv_id = socket.assigns.current_conversation_id
    after_cursor = Map.get(socket.assigns, :history_after)

    with true <- is_binary(conv_id) and is_binary(after_cursor),
         {:ok, %{entries: entries, after: next_after, has_more?: has_more?}} <-
           Handbean.ConversationTranscriptStore.page(conv_id, limit: 100, after: after_cursor) do
      entries = Handbean.PubSub.Projection.visible_entries(entries)
      loaded_ids = MapSet.new(socket.assigns.timeline, &entry_value(&1, "id", nil))
      entries = Enum.reject(entries, &MapSet.member?(loaded_ids, entry_value(&1, "id", nil)))

      timeline =
        socket.assigns.timeline
        |> Kernel.++(entries)
        |> deduplicate_entries()
        |> HandbeanWeb.WorkspaceHelper.apply_tool_work_collapse(
          Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())
        )

      socket
      |> assign(:timeline, timeline)
      |> assign(:history_after, next_after)
      |> assign(:history_has_newer?, has_more?)
      |> stream(:timeline, timeline, reset: true)
    else
      _ -> socket
    end
  end

  def prepare_latest(socket) do
    socket
    |> assign(:history_window, :latest)
    |> assign(:history_anchor_entry_id, nil)
  end

  defp deduplicate_entries(entries) do
    Enum.uniq_by(entries, &entry_value(&1, "id", nil))
  end

  defp entry_value(entry, key, default) do
    Handbean.Utils.SafeMap.get(entry, key, default)
  end
end
