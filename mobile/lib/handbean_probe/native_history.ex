defmodule HandbeanProbe.NativeHistory do
  @moduledoc "Cross-workspace conversation history: pinned, free chats, then each workspace."
  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias Handbean.ConversationStore
  alias Mob.Canvas

  def load(now \\ DateTime.utc_now()) do
    project(Handbean.ConversationStore.list(), Handbean.WorkspaceStore.list(), now)
  end

  def project(conversations, workspaces, _now) do
    workspace_map = Map.new(workspaces, &{&1["id"], &1})

    listed =
      conversations
      |> Enum.filter(&listed?(&1, workspace_map))
      |> Enum.sort_by(&{timestamp(&1), &1["id"] || ""}, :desc)

    {pinned, unpinned} = Enum.split_with(listed, &ConversationStore.pinned_conversation?/1)
    {free, rest} = Enum.split_with(unpinned, &ConversationStore.free?/1)

    %{
      pinned: Enum.sort_by(pinned, &{&1["pinned_at"] || "", &1["id"] || ""}, :desc),
      free: free,
      workspaces: workspace_groups(workspaces, rest)
    }
  end

  def render(history, opts) when is_map(opts) do
    ctx = %{
      selected_id: Map.get(opts, :selected_id),
      collapsed: Map.get(opts, :collapsed, MapSet.new()),
      activities: Map.get(opts, :activities, %{}),
      running_ids: Map.get(opts, :running_ids, MapSet.new()),
      bean_frame: Map.get(opts, :bean_frame, 0),
      menu_id: Map.get(opts, :menu_id),
      rename: Map.get(opts, :rename)
    }

    pinned = Map.get(history, :pinned, [])
    free = Map.get(history, :free, [])
    workspaces = Map.get(history, :workspaces, [])

    pinned_nodes =
      if pinned == [] do
        []
      else
        group("pinned", gettext("已置顶"), pinned, ctx, nil)
      end

    free_nodes = group("free", gettext("自由对话"), free, ctx, icon("add", {:new_free_chat}))

    workspace_nodes =
      Enum.flat_map(workspaces, fn %{workspace: workspace, conversations: conversations} ->
        group(
          workspace["id"],
          workspace["name"] || workspace["id"],
          conversations,
          ctx,
          icon("add", {:new_workspace_conversation, workspace["id"]}),
          true
        )
      end)

    pinned_nodes ++ free_nodes ++ workspace_nodes
  end

  defp workspace_groups(workspaces, conversations) do
    Enum.map(workspaces, fn workspace ->
      %{
        workspace: workspace,
        conversations: Enum.filter(conversations, &(&1["workspace_id"] == workspace["id"]))
      }
    end)
  end

  defp listed?(conversation, workspaces) do
    conversation["archived_at"] in [nil, ""] and
      (ConversationStore.free?(conversation) or
         Map.has_key?(workspaces, conversation["workspace_id"]))
  end

  defp group(id, label, conversations, ctx, action, folder? \\ false) do
    header(id, label, length(conversations), ctx.collapsed, action, folder?) ++
      if(MapSet.member?(ctx.collapsed, id), do: [], else: conversation_rows(conversations, ctx))
  end

  defp header(id, label, count, collapsed, action, folder?) do
    toggle = {:toggle_history_group, id}
    chevron = if(MapSet.member?(collapsed, id), do: "chevron_right", else: "chevron_down")

    [
      row(
        [
          if(folder?, do: folder_icon(id, toggle)),
          button(label, toggle,
            id: "history-group-#{id}",
            fill_width: false,
            background: color(:surface),
            text_color: color(:muted),
            text_size: 12,
            padding_top: 4,
            padding_bottom: 4,
            padding_left: if(folder?, do: 0, else: 4),
            padding_right: 4
          ),
          node(:box, weight: 1, height: 1, background: color(:separator)),
          action,
          button(to_string(count), toggle,
            id: "history-group-toggle-#{id}",
            fill_width: false,
            background: color(:surface),
            text_color: color(:muted),
            text_size: 12,
            padding: 4
          ),
          node(:icon,
            name: chevron,
            text: "",
            text_size: 14,
            padding: 0,
            text_color: color(:muted),
            on_tap: {self(), toggle},
            id: "history-chevron-#{id}"
          )
        ]
        |> Enum.reject(&is_nil/1),
        padding_top: 12,
        padding_bottom: 4
      )
    ]
  end

  # Same canvas as the conversation bean. Android does not scale a
  # smaller canvas around the 24×24 stroke, so this box is 24 wide and
  # the path is drawn in that space. Both left edges then share x = 0.
  @folder_width 24
  @folder_height 26

  defp folder_icon(id, tag) do
    node(:canvas,
      id: "history-folder-#{id}",
      width: @folder_width,
      height: @folder_height,
      padding_right: 4,
      on_tap: {self(), tag},
      draw: folder_stroke()
    )
  end

  defp folder_stroke do
    ink = color(:muted)

    folder_outline()
    |> Enum.map(fn {x, y} -> {x, y + 1} end)
    |> then(&Canvas.path(&1, color: ink, width: 1.4, closed: true, cap: :round, join: :round))
    |> List.wrap()
  end

  # SVG `M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z`
  # sampled so both hosts draw the web sidebar folder, not a pixel box.
  defp folder_outline do
    [
      {3.0, 7.0},
      {3.04, 6.61},
      {3.15, 6.23},
      {3.34, 5.89},
      {3.59, 5.59},
      {3.89, 5.34},
      {4.23, 5.15},
      {4.61, 5.04},
      {5.0, 5.0},
      {9.0, 5.0},
      {11.0, 7.0},
      {19.0, 7.0},
      {19.39, 7.04},
      {19.77, 7.15},
      {20.11, 7.34},
      {20.41, 7.59},
      {20.66, 7.89},
      {20.85, 8.23},
      {20.96, 8.61},
      {21.0, 9.0},
      {21.0, 17.0},
      {20.96, 17.39},
      {20.85, 17.77},
      {20.66, 18.11},
      {20.41, 18.41},
      {20.11, 18.66},
      {19.77, 18.85},
      {19.39, 18.96},
      {19.0, 19.0},
      {5.0, 19.0},
      {4.61, 18.96},
      {4.23, 18.85},
      {3.89, 18.66},
      {3.59, 18.41},
      {3.34, 18.11},
      {3.15, 17.77},
      {3.04, 17.39},
      {3.0, 17.0}
    ]
  end

  defp conversation_rows(conversations, ctx) do
    Enum.flat_map(conversations, fn conversation ->
      conversation_nodes(conversation,
        selected?: conversation["id"] == ctx.selected_id,
        activity: activity(conversation["id"], ctx),
        bean_frame: ctx.bean_frame,
        menu_open?: ctx.menu_id != nil and conversation["id"] == ctx.menu_id,
        rename: ctx.rename
      )
    end)
  end

  defp activity(id, ctx) do
    case Map.get(ctx.activities, id) do
      status when status in [:running, :waiting] ->
        status

      _ ->
        if MapSet.member?(ctx.running_ids, id), do: :running, else: :idle
    end
  end

  defp conversation_nodes(conversation, opts) do
    nodes =
      if Code.ensure_loaded?(HandbeanProbe.NativeConversationRow) do
        apply(HandbeanProbe.NativeConversationRow, :nodes, [conversation, opts])
      else
        title_button(conversation, opts)
      end

    nodes |> List.wrap() |> Enum.reject(&is_nil/1)
  end

  defp title_button(conversation, opts) do
    selected? = Keyword.get(opts, :selected?, false)

    button(
      conversation["title"] || gettext("New conversation"),
      {:conversation, conversation["id"]},
      fill_width: true,
      background: if(selected?, do: color(:control), else: color(:surface)),
      text_size: 13,
      max_lines: 1,
      ellipsize: "end"
    )
  end

  defp timestamp(conversation) do
    case DateTime.from_iso8601(conversation["updated_at"] || conversation["created_at"] || "") do
      {:ok, datetime, _} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end
end
