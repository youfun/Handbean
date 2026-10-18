defmodule HandbeanProbe.NativeChanges do
  @moduledoc false

  alias Handbean.ChangeReverter
  alias Handbean.Utils.SafeMap
  alias HandbeanProbe.{NativeTimeline, NativeUI, NativeWorkspaceTree}
  alias HandbeanWeb.{ChangeHelper, FileChangeCard}

  @row_fill NativeUI.color(:change_row)
  @active_tab_fill NativeUI.color(:change_tab)
  @muted NativeUI.color(:change_ink)
  @danger NativeUI.color(:change_danger)
  @success NativeUI.color(:change_success)
  @diff_background NativeUI.color(:change_diff)

  def render_tabs(state) when is_map(state) do
    tab = Map.get(state, :workspace_panel_tab, :files)
    count = state_changes(state) |> length()
    label = if count > 0, do: "Changes #{count}", else: "Changes"

    NativeUI.row(
      [
        NativeUI.button(label, {:workspace_panel_tab, :changes},
          style: :plain,
          size: :small,
          fill: tab_fill(tab, :changes),
          text_color: NativeUI.color(:change_label)
        ),
        NativeUI.button("Files", {:workspace_panel_tab, :files},
          style: :plain,
          size: :small,
          fill: tab_fill(tab, :files),
          text_color: NativeUI.color(:change_label)
        )
      ],
      spacing: 2,
      weights: [1, 1],
      background: NativeUI.color(:change_panel)
    )
  end

  def render_content(%{workspace_panel_tab: :changes} = state), do: render(state)

  def render_content(state) do
    state
    |> Map.get(:workspace_tree)
    |> Kernel.||(NativeWorkspaceTree.idle())
    |> NativeWorkspaceTree.render()
  end

  def render(state) when is_map(state) do
    ui = ui_state(state)

    nodes =
      case state_changes(state) do
        [] ->
          [
            NativeUI.text("No file changes in this conversation.",
              text_color: @muted,
              align: :center,
              padding: [top: 24]
            )
          ]

        changes ->
          Enum.map(changes, &change_node(&1, state, ui))
      end

    NativeUI.scroll(
      NativeUI.node(
        :column,
        [spacing: 6, padding: [top: 6, right: 8, bottom: 10, left: 8]],
        nodes
      )
    )
  end

  def changes(entries, status_overrides \\ %{}) when is_list(entries) do
    entries
    |> FileChangeCard.changes()
    |> Enum.map(fn change ->
      case Map.get(status_overrides, change_id(change)) do
        nil -> change
        status -> put_revert_status(change, status)
      end
    end)
  end

  def find_change(state, change_id) when is_binary(change_id) do
    case Enum.find(state_changes(state), &(change_id(&1) == change_id)) do
      nil -> {:error, :not_found}
      change -> {:ok, change_data(change)}
    end
  end

  def toggle(state, change_id) when is_binary(change_id) do
    update_ui(state, fn ui ->
      expanded =
        if MapSet.member?(ui.expanded, change_id),
          do: MapSet.delete(ui.expanded, change_id),
          else: MapSet.put(ui.expanded, change_id)

      %{ui | expanded: expanded, feedback: nil}
    end)
  end

  def confirm(state, change_id) when is_binary(change_id) do
    update_ui(state, &%{&1 | confirming: change_id, feedback: nil})
  end

  def cancel_confirm(state), do: update_ui(state, &%{&1 | confirming: nil})

  def mark_reverting(state, change_id) when is_binary(change_id) do
    update_ui(state, fn ui ->
      %{
        ui
        | confirming: nil,
          feedback: nil,
          status_overrides: Map.put(ui.status_overrides, change_id, "reverting")
      }
    end)
  end

  def apply_revert_result(state, change_id, result) when is_binary(change_id) do
    case result do
      {:ok, info} ->
        update_ui(state, fn ui ->
          %{
            ui
            | status_overrides: Map.put(ui.status_overrides, change_id, "reverted"),
              feedback: %{change_id: change_id, kind: :success, text: success_text(info)}
          }
        end)

      {:error, reason} ->
        update_ui(state, fn ui ->
          %{
            ui
            | status_overrides: Map.delete(ui.status_overrides, change_id),
              feedback: %{change_id: change_id, kind: :error, text: error_text(reason)}
          }
        end)

      other ->
        apply_revert_result(state, change_id, {:error, other})
    end
  end

  def revert(change, workspace_root) when is_map(change) and is_binary(workspace_root) do
    ChangeReverter.revert(change, workspace_root)
  end

  defp state_changes(state) do
    changes(timeline(state), ui_state(state).status_overrides)
  end

  defp timeline(state) do
    case Map.get(state, :chat) do
      nil ->
        []

      chat ->
        NativeTimeline.project(
          chat,
          Map.get(state, :work_groups, %{}),
          Map.get(state, :work_segments, %{}),
          Map.get(state, :tool_outputs, %{})
        )
    end
  end

  defp change_node(change, state, ui) do
    id = change_id(change)
    expanded? = MapSet.member?(ui.expanded, id)
    confirming? = ui.confirming == id
    feedback = if ui.feedback && ui.feedback.change_id == id, do: ui.feedback

    label =
      [
        if(expanded?, do: "▾", else: "▸"),
        change_label(change),
        relative_path(file_path(change), workspace_path(state)),
        delta(change)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("  ")

    children = [
      NativeUI.button(label, {:toggle_change, id},
        style: :plain,
        size: :small,
        fill: @row_fill,
        text_color: NativeUI.color(:change_path)
      )
    ]

    children =
      if expanded?, do: children ++ detail_nodes(change, confirming?, feedback), else: children

    NativeUI.node(:column, [spacing: 0], children)
  end

  defp detail_nodes(change, confirming?, feedback) do
    patch = diff_text(change["diff_lines"] || [])

    diff =
      if String.trim(patch) == "" do
        NativeUI.text("No textual diff available.", text_color: @muted, padding: 8)
      else
        NativeUI.text(patch,
          font: :monospace,
          selectable: true,
          text_color: NativeUI.color(:change_diff_ink),
          background: @diff_background,
          padding: 8
        )
      end

    [diff] ++ action_nodes(change, confirming?) ++ feedback_nodes(feedback)
  end

  defp action_nodes(change, confirming?) do
    cond do
      revert_status(change) == "reverted" ->
        [NativeUI.text("Reverted", text_color: @success, font_weight: :medium, padding: 6)]

      revert_status(change) == "reverting" ->
        [NativeUI.text("Reverting…", text_color: @muted, padding: 6)]

      confirming? ->
        id = change_id(change)
        path = Path.basename(file_path(change) || "file")

        [
          NativeUI.row(
            [
              NativeUI.text("Revert #{path}?", text_color: @muted),
              NativeUI.button("Cancel", :cancel_revert_change, style: :plain, size: :small),
              NativeUI.button("Revert", {:revert_change, id},
                style: :plain,
                size: :small,
                text_color: @danger
              )
            ],
            spacing: 6,
            weights: [1, 0, 0],
            padding: 5,
            background: NativeUI.color(:change_action)
          )
        ]

      reversible?(change) ->
        [
          NativeUI.row(
            [
              NativeUI.text("", text_color: @muted),
              NativeUI.button("Revert", {:confirm_revert_change, change_id(change)},
                style: :plain,
                size: :small,
                text_color: @danger
              )
            ],
            spacing: 6,
            padding: 5,
            weights: [1, 0],
            background: NativeUI.color(:change_action)
          )
        ]

      true ->
        [NativeUI.text("Review only", text_color: @muted, padding: 6)]
    end
  end

  defp feedback_nodes(nil), do: []

  defp feedback_nodes(%{kind: kind, text: text}) do
    color = if kind == :success, do: @success, else: @danger
    [NativeUI.text(text, text_color: color, padding: 6)]
  end

  defp change_data(change), do: ChangeHelper.change_from_entry(change)

  defp change_id(change) do
    SafeMap.get(change_data(change), "change_id") || SafeMap.get(change, "id")
  end

  defp file_path(change) do
    SafeMap.get(change, "file_path") || SafeMap.get(change_data(change), "file_path")
  end

  defp revert_status(change) do
    SafeMap.get(change, "revert_status") ||
      SafeMap.get(change_data(change), "revert_status", "unavailable")
  end

  defp put_revert_status(change, status) do
    change
    |> Map.put("revert_status", status)
    |> Map.update("change", %{"revert_status" => status}, &Map.put(&1, "revert_status", status))
  end

  defp reversible?(change) do
    SafeMap.get(change_data(change), "reversible") == true and
      is_binary(change_id(change)) and
      revert_status(change) not in ["reverted", "conflict", "reverting"]
  end

  defp change_label(change) do
    case SafeMap.get(change, "change_type") || SafeMap.get(change_data(change), "change_type") do
      "write" -> "Created"
      "delete" -> "Deleted"
      _ -> "Edited"
    end
  end

  defp delta(change) do
    {added, removed} =
      Enum.reduce(change["diff_lines"] || [], {0, 0}, fn line, {added, removed} ->
        case SafeMap.get(line, "type") do
          type when type in [:ins, "ins", :add, "add"] -> {added + 1, removed}
          type when type in [:del, "del", :remove, "remove"] -> {added, removed + 1}
          _ -> {added, removed}
        end
      end)

    [if(added > 0, do: "+#{added}"), if(removed > 0, do: "-#{removed}")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp diff_text(lines) do
    lines
    |> Enum.map(fn line ->
      prefix =
        case SafeMap.get(line, "type") do
          type when type in [:ins, "ins", :add, "add"] -> "+"
          type when type in [:del, "del", :remove, "remove"] -> "-"
          _ -> " "
        end

      prefix <> to_string(SafeMap.get(line, "text") || SafeMap.get(line, "content") || "")
    end)
    |> Enum.join("\n")
  end

  defp workspace_path(state) do
    case Map.get(state, :workspace) do
      %{"path" => path} when is_binary(path) -> path
      %{path: path} when is_binary(path) -> path
      _ -> nil
    end
  end

  defp relative_path(path, root) when is_binary(path) and is_binary(root) do
    case Path.relative_to(path, root) do
      relative when relative == path -> path
      relative -> relative
    end
  end

  defp relative_path(path, _root), do: path || "file"

  defp tab_fill(tab, tab), do: @active_tab_fill
  defp tab_fill(_active, _tab), do: NativeUI.color(:change_idle)

  defp ui_state(state) do
    default = %{expanded: MapSet.new(), confirming: nil, status_overrides: %{}, feedback: nil}
    Map.merge(default, Map.get(state, :changes_ui) || %{})
  end

  defp update_ui(state, fun), do: Map.put(state, :changes_ui, fun.(ui_state(state)))

  defp success_text(:deleted), do: "Reverted; the newly created file was removed."
  defp success_text(_info), do: "Reverted successfully."

  defp error_text(%{code: :conflict}),
    do: "File changed after this edit. Nothing was overwritten."

  defp error_text(:outside_workspace), do: "This file is outside the active workspace."
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: "Revert failed: #{inspect(reason)}"
end
