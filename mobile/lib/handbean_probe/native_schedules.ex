defmodule HandbeanProbe.NativeSchedules do
  @moduledoc """
  Native state and rendering for the scheduled-task center.

  The schedule rows, claim/status semantics and rule descriptions stay with
  the shared owners (`Handbean.Schedule.Store`, `Handbean.Schedule.Presentation`
  and `Handbean.Schedule.Rule`); this module only projects them into Mob nodes
  and keeps the page-local UI state (delete confirmation, expanded
  instructions). The list is cross-workspace — every card names its workspace
  so a task can be managed and opened from any workspace.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias Handbean.Schedule.Rule

  @overdue_grace_seconds 120
  @instruction_clamp_length 160
  @instruction_clamp_lines 3

  def new do
    %{
      loading?: true,
      busy?: false,
      error: nil,
      items: [],
      runs: %{},
      views: %{},
      titles: %{},
      workspace_names: %{},
      now: nil,
      confirming: nil,
      instruction_open: MapSet.new()
    }
  end

  def loading(state), do: %{state | loading?: true, error: nil}
  def busy(state), do: %{state | busy?: true, error: nil}
  def idle(state), do: %{state | busy?: false}

  def loaded(state, {:ok, data}) do
    %{
      state
      | loading?: false,
        error: nil,
        items: Map.get(data, :items, []),
        runs: Map.get(data, :runs, %{}),
        views: Map.get(data, :views, %{}),
        titles: Map.get(data, :titles, %{}),
        workspace_names: Map.get(data, :workspace_names, %{}),
        now: Map.get(data, :now)
    }
  end

  def loaded(state, {:error, reason}),
    do: %{state | loading?: false, error: to_string(reason)}

  def ask_delete(state, id) when is_binary(id), do: %{state | confirming: id}
  def dismiss_confirm(state), do: %{state | confirming: nil}

  def toggle_instruction(state, id) when is_binary(id) do
    open = state.instruction_open

    open =
      if MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id)

    %{state | instruction_open: open}
  end

  def find(%{items: items}, id) when is_binary(id),
    do: Enum.find(items, &(&1.id == id))

  def render(state) do
    children =
      if state.loading? do
        [text(gettext("Loading scheduled tasks…"), padding_top: 24)]
      else
        [heading(), error_text(state.error) | cards(state)]
      end

    scroll(children ++ [confirm_sheet(state)], id: "native-schedules")
  end

  defp heading do
    row([
      text(gettext("Scheduled tasks"), text_size: 16, font_weight: "bold", weight: 1),
      secondary_button(gettext("Refresh"), :schedule_refresh)
    ])
  end

  defp cards(%{items: []}) do
    [
      card([
        text(gettext("No scheduled tasks yet"), text_size: 16),
        text(
          gettext(
            "Describe when and what to do in a chat, and the Agent will create a scheduled task."
          ),
          text_color: color(:muted),
          padding_top: 6
        )
      ])
    ]
  end

  defp cards(state) do
    state.items
    |> sort_items(state)
    |> Enum.map(&entry_card(&1, state))
  end

  defp entry_card(entry, state) do
    view = Map.get(state.views, entry.id)
    runs = Map.get(state.runs, entry.id, [])
    {status_label, status_color} = status(entry, runs, state.now)
    meta = meta_line(entry, state)

    card(
      [
        row([
          text(entry.name || "",
            weight: 1,
            font_weight: "bold",
            max_lines: 1,
            ellipsize: "end"
          ),
          text(status_label, text_size: 12, text_color: color(status_color))
        ]),
        if(meta != "",
          do: text(meta, text_size: 12, text_color: color(:muted), padding_top: 4)
        ),
        text(next_line(entry, runs), text_size: 12, text_color: color(:muted), padding_top: 2),
        quiet_button(conversation_title(state, entry), {:schedule_open, entry.id},
          fill_width: true,
          text_align: "left",
          text_size: 12,
          padding_top: 8,
          padding_bottom: 8
        ),
        instruction_block(entry, state),
        actions_block(entry, view)
      ],
      id: "schedule-#{entry.id}"
    )
  end

  defp meta_line(entry, state) do
    [Rule.describe(entry.rule), workspace_name(state, entry)]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp instruction_block(entry, state) do
    instruction = String.trim(entry.instruction || "")

    if instruction == "" do
      nil
    else
      open? = MapSet.member?(state.instruction_open, entry.id)
      long? = String.length(instruction) > @instruction_clamp_length

      clamp =
        if long? and not open?,
          do: [max_lines: @instruction_clamp_lines, ellipsize: "end"],
          else: []

      [
        text(gettext("Instruction"), text_size: 12, text_color: color(:muted), padding_top: 8),
        text(instruction, [text_size: 13, padding_top: 2] ++ clamp),
        if(long?,
          do:
            quiet_button(
              if(open?, do: gettext("Collapse"), else: gettext("Expand")),
              {:schedule_toggle_instruction, entry.id},
              text_size: 12,
              padding_top: 4
            )
        )
      ]
    end
  end

  defp actions_block(entry, view) do
    toggle =
      case row_action(entry, view) do
        :pause ->
          secondary_button(gettext("Pause"), {:schedule_pause, entry.id}, text_size: 12)

        :resume ->
          secondary_button(gettext("Resume"), {:schedule_resume, entry.id}, text_size: 12)

        nil ->
          nil
      end

    actions_row([
      toggle,
      primary_button(gettext("Run now"), {:schedule_run_now, entry.id}, text_size: 12),
      quiet_button(gettext("Revise"), {:schedule_revise, entry.id}, text_size: 12),
      danger_button(gettext("Delete"), {:schedule_ask_delete, entry.id}, text_size: 12)
    ])
  end

  defp confirm_sheet(%{confirming: nil}), do: nil

  defp confirm_sheet(%{confirming: id} = state) do
    name =
      case find(state, id) do
        nil -> ""
        entry -> entry.name || ""
      end

    sheet(
      [
        text(gettext("Delete scheduled task \"%{name}\"?", name: name), text_size: 16),
        text(
          gettext("It will no longer run on schedule. The conversation history is kept."),
          text_color: color(:muted),
          padding_top: 6
        ),
        actions_row([
          danger_button(gettext("Delete"), :schedule_delete),
          quiet_button(gettext("Keep"), :schedule_dismiss_confirm)
        ])
      ],
      dismiss: :schedule_dismiss_confirm,
      id: "schedule-delete-confirm"
    )
  end

  defp error_text(nil), do: nil

  defp error_text(error),
    do: text(error, text_color: color(:danger), padding_top: 8, padding_bottom: 8)

  # ── projection ──

  @doc "Row toggle: the presentation view wins, then the persisted status."
  def row_action(entry, view) do
    cond do
      view && view.action -> view.action
      entry.status == "active" -> :pause
      entry.status == "paused" -> :resume
      true -> nil
    end
  end

  @doc """
  Status chip `{label, color}` for a card header.

  A recurring task keeps `active` after a bad run, so the newest run decides
  whether the row needs attention; `now` comes from the load that built the
  list and is `nil` until the first load lands.
  """
  def status(entry, runs, now) do
    last = last_run(runs)

    cond do
      entry.status == "paused" ->
        {gettext("Paused"), :muted}

      entry.status == "disabled" ->
        {gettext("Disabled"), :muted}

      entry.status == "completed" ->
        {gettext("Completed"), :hint}

      last && last.status in ["failed", "stalled", "halted", "unknown"] ->
        {run_status_label(last.status), :danger}

      last && last.status in ["claimed", "started"] ->
        {gettext("Running"), :added}

      last && last.status == "skipped" ->
        {gettext("Skipped"), :muted}

      overdue?(entry, now) ->
        {gettext("Overdue"), :danger}

      entry.status in ["active", "running"] ->
        {gettext("Enabled"), :added}

      true ->
        {to_string(entry.status || ""), :hint}
    end
  end

  def next_line(entry, runs) do
    zone = entry.time_zone || "Etc/UTC"

    case entry.next_run_at do
      %DateTime{} = at ->
        gettext("Next: %{at}", at: Rule.format_local(at, zone))

      nil ->
        case last_run(runs) do
          nil ->
            gettext("No next run")

          run ->
            gettext("No next run · Last %{at}", at: Rule.format_local(run.updated_at, zone))
        end
    end
  end

  def conversation_title(state, entry) do
    case Map.get(state.titles, entry.conversation_id) do
      title when is_binary(title) and title != "" -> title
      _ -> gettext("Conversation")
    end
  end

  def workspace_name(state, entry),
    do: Map.get(state.workspace_names, entry.workspace_id) || entry.workspace_id || ""

  # Attention first, then armed tasks by their next slot, then paused, then
  # ended; the name keeps the order stable for equal slots.
  defp sort_items(entries, state) do
    entries
    |> Enum.sort_by(&sort_key(&1, Map.get(state.runs, &1.id, []), state.now))
  end

  defp sort_key(entry, runs, now) do
    {rank(entry, runs, now), next_sort(entry.next_run_at), String.downcase(entry.name || "")}
  end

  defp rank(entry, runs, now) do
    cond do
      attention?(entry, runs, now) -> 0
      entry.status in ["active", "running"] -> 1
      entry.status == "paused" -> 2
      true -> 3
    end
  end

  defp attention?(entry, runs, now) do
    overdue?(entry, now) or
      Enum.any?(runs, &(&1.status in ["failed", "stalled", "halted", "unknown"]))
  end

  defp overdue?(entry, %DateTime{} = now) do
    match?(%DateTime{}, entry.next_run_at) and
      DateTime.compare(entry.next_run_at, DateTime.add(now, -@overdue_grace_seconds, :second)) ==
        :lt
  end

  defp overdue?(_entry, _now), do: false

  defp next_sort(nil), do: {1, 0}
  defp next_sort(%DateTime{} = at), do: {0, DateTime.to_unix(at)}

  defp last_run([run | _]), do: run
  defp last_run(_runs), do: nil

  defp run_status_label("failed"), do: gettext("Failed")
  defp run_status_label("stalled"), do: gettext("Stalled")
  defp run_status_label("halted"), do: gettext("Halted")
  defp run_status_label("unknown"), do: gettext("Unknown result")
  defp run_status_label(status), do: to_string(status)
end
