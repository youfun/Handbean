defmodule HandbeanProbe.NativeTimeline do
  @moduledoc "Native rendering of the shared Work transcript projection."
  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI
  alias HandbeanProbe.Bridge.Payload
  alias HandbeanProbe.{NativeLocalImage, WorkTimeline}
  alias HandbeanWeb.WorkspaceHelper

  def project(chat, groups, segments, outputs) do
    entries =
      if chat,
        do: Handbean.PubSub.Projection.visible_entries(chat.entries),
        else: []

    entries =
      Enum.map(entries, fn entry ->
        type =
          case entry["role"] do
            "user" -> "user_msg"
            "assistant" -> "assistant_msg"
            "tool" -> "tool"
            _ -> "system_msg"
          end

        Map.put_new(entry, "content_type", type)
      end)

    streaming =
      if chat && chat.stream != "" do
        [
          %{
            "id" => "stream-text",
            "content_type" => "assistant_msg",
            "role" => "assistant",
            "content" => chat.stream,
            "streaming" => true
          }
        ]
      else
        []
      end

    WorkTimeline.project(entries ++ streaming, groups, segments, outputs)
  end

  def render_sent_card(_chat, open) when open in [nil, %{}], do: nil

  def render_sent_card(chat, %{message_id: message_id, attachment_id: attachment_id}) do
    entry = Enum.find(List.wrap(chat && chat.entries), &(&1["id"] == message_id))
    attachments = List.wrap(entry && entry["attachments"])
    att = Enum.find(attachments, &(NativeLocalImage.att_id(&1) == attachment_id))

    if att && NativeLocalImage.image_attachment?(att) do
      name = NativeLocalImage.att_name(att)
      type = NativeLocalImage.mime(att)
      src = upload_src(chat, att)

      node(
        :column,
        [
          fill_width: true,
          background: color(:card),
          border_color: color(:border),
          border_width: 1,
          corner_radius: 12,
          padding: 10,
          padding_bottom: 8
        ],
        [
          row([
            text(name, weight: 1, text_size: 13),
            text(type, text_size: 11, text_color: color(:hint))
          ]),
          NativeLocalImage.card_image(src, name, upload_only: true),
          button(gettext("Close"), :close_sent_image, text_size: 11, padding: 6)
        ]
      )
    end
  end

  def render_sent_card(_, _), do: nil

  def render(chat, expanded) when is_struct(expanded, MapSet) do
    tool_ids =
      (chat[:entries] || [])
      |> Enum.filter(fn entry ->
        entry["content_type"] == "tool" or entry["role"] == "tool"
      end)
      |> Enum.map(& &1["id"])

    groups =
      tool_ids
      |> Map.new(&{&1, true})
      |> Map.merge(Map.new(expanded, &{&1, true}))

    render(chat, groups, %{}, %{})
  end

  def render(chat, groups, segments, outputs, diffs \\ %{}) do
    project(chat, groups, segments, outputs)
    |> Enum.map(&put_file_diff(&1, diffs))
    |> Enum.flat_map(fn entry ->
      [
        entry(entry, chat),
        tool_actions(entry, chat)
      ]
    end)
    |> Kernel.++([
      if(chat && chat.running,
        do:
          text(
            if(chat.pending_approval,
              do: gettext("Waiting for approval…"),
              else: if(chat.thinking, do: gettext("Thinking…"), else: gettext("Generating…"))
            ),
            id: "stream-status",
            text_size: 12,
            text_color: color(:hint),
            padding_top: 8
          )
      )
    ])
    |> Enum.reject(&is_nil/1)
  end

  defp put_file_diff(entry, diffs) do
    open? =
      case Map.fetch(diffs, entry["id"]) do
        {:ok, value} -> value == true
        :error -> entry["file_diff_open"] == true
      end

    Map.put(entry, "file_diff_open", open?)
  end

  defp entry(%{"content_type" => "thread_handoff"} = entry, chat) do
    content = entry["content"] || %{}
    data = content["data"] || %{}
    handoff_id = content["handoff_id"] || entry["id"] || "handoff"
    expanded? = MapSet.member?(Map.get(chat, :expanded_handoffs, MapSet.new()), handoff_id)
    messages = List.wrap(data["messages"])
    {conversation_id, agent_id} = handoff_target(data, chat)
    message_ref = conversation_id || agent_id
    label = handoff_label(content["event"], agent_id)
    summary = handoff_summary(messages)
    marker = if expanded?, do: "▾", else: "▸"

    details =
      if expanded? do
        Enum.map(messages, fn message ->
          text(to_string(message["content"] || ""),
            text_size: 12,
            markdown: (message["role"] || "assistant") == "assistant"
          )
        end)
      else
        []
      end

    actions =
      [
        if(is_binary(conversation_id) or is_binary(agent_id),
          do:
            button(
              gettext("Open thread"),
              {:open_subagent_thread, conversation_id, agent_id},
              text_size: 10,
              padding: 5
            )
        ),
        if(is_binary(message_ref),
          do:
            button(gettext("Message"), {:prefill_subagent_message, message_ref},
              text_size: 10,
              padding: 5
            )
        )
      ]
      |> Enum.reject(&is_nil/1)

    node(
      :column,
      [
        fill_width: true,
        spacing: 5,
        padding: 7,
        background: color(:handoff_card),
        corner_radius: 8
      ],
      [
        button("#{marker}  #{label}  #{summary}", {:toggle_thread_handoff, handoff_id},
          style: :plain,
          size: :small,
          text_size: 10,
          padding: 4
        )
        | details ++
            if(actions == [],
              do: [],
              else: [node(:row, [fill_width: true, spacing: 6], actions)]
            )
      ]
    )
  end

  defp entry(%{"content_type" => "tool"} = entry, chat) do
    entry = Map.put(entry, "workspace_path", chat_workspace_path(chat))
    open? = entry["work_collapsed"] != true

    children = [
      if(entry["work_group_first"], do: summary(entry)),
      if(open? and entry["work_edit"] == true, do: edit_line(entry)),
      if(open? and entry["work_edit"] != true, do: tool_line(entry)),
      if(open?, do: delivery_actions(entry, chat))
    ]

    if Enum.any?(children, & &1), do: node(:column, [fill_width: true], children)
  end

  defp entry(entry, chat) do
    role = Payload.first(entry, ["role", "message_type"]) || "system"
    body = Payload.first(entry, ["content", "error"]) || ""

    if role == "user" do
      attachments = List.wrap(entry["attachments"])
      {images, others} = Enum.split_with(attachments, &NativeLocalImage.image_attachment?/1)
      images = Enum.take(images, 4)

      names =
        others
        |> Enum.map(&(&1["filename"] || &1["display_name"]))
        |> Enum.reject(&is_nil/1)

      attachment_line =
        if names == [],
          do: nil,
          else: text(Enum.join(names, " · "), text_size: 11, text_color: color(:hint))

      row(
        [
          node(:column, weight: 1),
          node(:column, [weight: 3], [
            sent_thumbs(chat, entry["id"], images),
            if(body != "",
              do:
                node(:box, [fill_width: true, align: "top_trailing"], [
                  text(body,
                    selectable: true,
                    background: color(:bubble),
                    corner_radius: 18,
                    padding: 10
                  )
                ])
            ),
            if(attachment_line,
              do: node(:box, [fill_width: true, align: "top_trailing"], [attachment_line])
            ),
            pending_status_row(entry, chat)
          ])
        ],
        nav_user_id: entry["id"],
        nav_user_summary:
          body |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 80)
      )
    else
      if role == "assistant" do
        assistant_entry(entry, body)
      else
        node(:column, [fill_width: true, padding_top: 12, padding_bottom: 20], [
          text(gettext("System"), text_size: 11, text_color: color(:hint)),
          text(body, id: entry["id"], selectable: true)
        ])
      end
    end
  end

  defp assistant_entry(entry, body) do
    body_node =
      if is_binary(body) and String.trim(body) != "" do
        text(body,
          id: entry["id"],
          selectable: true,
          markdown: true,
          markdown_streaming: entry["streaming"] == true
        )
      end

    media_nodes =
      entry["attachments"]
      |> List.wrap()
      |> Enum.map(&Payload.attachment/1)
      |> Enum.filter(&public_media?/1)
      |> Enum.map(&assistant_media_card/1)

    case [body_node | media_nodes] |> Enum.reject(&is_nil/1) do
      [] -> nil
      children -> node(:column, [fill_width: true, padding_top: 12, padding_bottom: 20], children)
    end
  end

  defp public_media?(attachment) do
    case attachment["media_id"] do
      media_id when is_binary(media_id) -> String.trim(media_id) != ""
      _ -> false
    end
  end

  defp assistant_media_card(attachment) do
    name = display_metadata(attachment["filename"]) || gettext("Attachment")

    details =
      [display_metadata(attachment["mime_type"]), media_size(attachment["size_bytes"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    node(
      :column,
      [
        fill_width: true,
        background: color(:card),
        border_color: color(:border),
        border_width: 1,
        corner_radius: 10,
        padding: 10
      ],
      [
        text(gettext("Attachment"), text_size: 11, text_color: color(:hint)),
        text(name, text_size: 13, weight: 1),
        if(details != "", do: text(details, text_size: 11, text_color: color(:muted)))
      ]
    )
  end

  defp display_metadata(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp display_metadata(_), do: nil

  defp media_size(size) when is_integer(size) and size >= 0, do: "#{size} B"
  defp media_size(_), do: nil

  defp summary(entry) when is_map(entry) do
    # Hug the summary. A full-width row would park the chevron on the far edge.
    row(
      [
        text(entry["work_summary"] || "", text_size: 13, text_color: color(:muted)),
        chevron(entry["work_collapsed"] != true),
        outcome(
          entry["work_failed"],
          gettext("%{count} failed", count: entry["work_failed"]),
          :danger
        ),
        outcome(
          entry["work_cancelled"],
          gettext("%{count} cancelled", count: entry["work_cancelled"]),
          :muted
        )
      ],
      fill_width: false,
      padding_top: 2,
      padding_bottom: 2,
      align: "center",
      on_tap: {self(), {:toggle_tool_work, entry["work_group_id"]}},
      id: inspect({:toggle_tool_work, entry["work_group_id"]})
    )
  end

  defp chevron(expanded?) do
    node(:icon,
      name: if(expanded?, do: "chevron_down", else: "chevron_right"),
      text: "",
      width: 12,
      height: 12,
      text_size: 12,
      padding: 0,
      text_color: color(:hint)
    )
  end

  defp outcome(count, label, tone) when is_integer(count) and count > 0 do
    text(label, text_size: 13, text_color: color(tone))
  end

  defp outcome(_, _, _), do: nil

  defp tool_line(entry) do
    output = WorkTimeline.output(entry)

    node(:column, [fill_width: true, padding_left: indent_padding(entry)], [
      text(activity_line(entry),
        on_tap: {self(), {:toggle_tool_output, entry["id"]}},
        id: inspect({:toggle_tool_output, entry["id"]}),
        max_lines: 1,
        ellipsize: "end",
        text_size: 13,
        text_color: color(:muted)
      ),
      if(entry["tool_output_open"],
        do:
          node(:scroll, [id: "tool-output-#{entry["id"]}", fill_width: true, max_height: 180], [
            text(if(output == "", do: gettext("No output yet"), else: output),
              text_size: 12,
              selectable: true
            )
          ])
      )
    ])
  end

  @max_diff_lines 80

  defp edit_line(entry) do
    path = relative_file_path(entry)

    node(:column, [fill_width: true, padding_left: indent_padding(entry)], [
      row(
        [
          row(
            [
              chevron(entry["file_diff_open"] == true),
              text(activity_line(entry),
                text_size: 13,
                text_color: color(:muted),
                max_lines: 1,
                ellipsize: "end"
              ),
              count_text(entry["work_added"], "+", :added),
              count_text(entry["work_removed"], "−", :danger)
            ],
            fill_width: false,
            align: "center",
            on_tap: {self(), {:toggle_file_diff, entry["id"]}},
            id: inspect({:toggle_file_diff, entry["id"]})
          ),
          if(path != "", do: copy_path_button(path))
        ],
        fill_width: false,
        align: "center"
      ),
      if(entry["file_diff_open"] == true, do: diff_view(entry))
    ])
  end

  defp copy_path_button(path) do
    button(gettext("Copy relative path"), {:copy_relative_path, path},
      text_size: 11,
      padding: 4,
      corner_radius: 4
    )
  end

  defp count_text(count, prefix, tone) when is_integer(count) and count > 0 do
    text(prefix <> Integer.to_string(count), text_size: 13, text_color: color(tone))
  end

  defp count_text(_, _, _), do: nil

  defp diff_view(entry) do
    {shown, hidden} = Enum.split(diff_lines(entry), @max_diff_lines)

    note =
      if hidden != [],
        do:
          text(
            ngettext("1 line not shown", "%{count} lines not shown", length(hidden)),
            text_size: 12,
            text_color: color(:hint)
          )

    node(:column, [fill_width: true], Enum.map(shown, &diff_line/1) ++ [note])
  end

  defp diff_line(line) do
    {prefix, tone} = diff_style(line["type"])
    text(prefix <> line["text"], text_size: 12, text_color: color(tone))
  end

  defp diff_style(type) when type in ["add", "added", "ins", "+"], do: {"+", :added}

  defp diff_style(type) when type in ["remove", "removed", "delete", "del", "-"],
    do: {"−", :danger}

  defp diff_style(_), do: {" ", :muted}

  defp diff_lines(entry) do
    case entry["diff_lines"] do
      lines when is_list(lines) ->
        lines
        |> Payload.string_keys()
        |> Enum.map(fn line ->
          %{
            "type" => to_string(line["type"] || "eq"),
            "text" => to_string(line["text"] || "")
          }
        end)

      _ ->
        []
    end
  end

  defp indent_padding(%{"work_indent" => 2}), do: 28
  defp indent_padding(_), do: 12

  defp relative_file_path(entry) do
    raw =
      case entry["file_path"] do
        path when is_binary(path) and path != "" -> path
        _ -> input_file_path(entry)
      end

    case raw do
      path when is_binary(path) and path != "" ->
        HandbeanWeb.FileChangeCard.relative_display_path(path, entry["workspace_path"])

      _ ->
        ""
    end
  end

  defp input_file_path(entry) do
    entry
    |> Handbean.TranscriptEntry.input()
    |> Payload.string_keys()
    |> Map.get("file_path")
  end

  defp activity_line(entry) do
    verb = entry["work_verb"] || WorkTimeline.name(entry)
    target = entry["work_target"] || ""
    if target == "", do: verb, else: verb <> " " <> target
  end

  defp tool_actions(%{"content_type" => "tool"} = entry, chat) do
    preview = WorkspaceHelper.preview_card(entry)
    takeover = WorkspaceHelper.browser_takeover_prompt(entry)

    cond do
      preview ->
        button(
          gettext("Open preview · %{title}", title: preview.title),
          {:tool_action, chat.conversation["id"], :preview, preview.preview_id},
          fill_width: true
        )

      takeover && is_binary(takeover.session_id) ->
        button(
          gettext("Take over browser · %{reason}", reason: takeover.reason),
          {:tool_action, chat.conversation["id"], :browser, takeover.session_id},
          fill_width: true
        )

      true ->
        nil
    end
  end

  defp tool_actions(_, _), do: nil

  defp pending_status_row(entry, chat) do
    pending = chat && Map.get(chat, :pending)
    item = is_map(pending) && Map.get(pending, entry["id"])
    if item, do: pending_status_controls(entry["id"], item, chat)
  end

  defp pending_status_controls(id, %{status: :undelivered}, _chat) do
    row(
      [
        text(gettext("Not delivered"), text_size: 12, text_color: color(:hint), weight: 1),
        button(gettext("Resend"), {:resend_pending, id}, text_size: 11, padding: 6)
      ],
      padding_top: 4
    )
  end

  defp pending_status_controls(id, %{status: :queued, deliver_as: deliver_as}, chat) do
    label =
      cond do
        chat && chat.pending_approval ->
          gettext("Inserts after approval")

        deliver_as == :follow_up ->
          gettext("Queued · when this run finishes")

        true ->
          gettext("Waiting to insert · next step")
      end

    row(
      [
        text(label, text_size: 12, text_color: color(:hint), weight: 1),
        button(gettext("Undo"), {:cancel_pending, id}, text_size: 11, padding: 6)
      ],
      padding_top: 4
    )
  end

  defp pending_status_controls(_, _, _), do: nil

  defp sent_thumbs(_chat, _message_id, []), do: nil

  defp sent_thumbs(chat, message_id, images) do
    thumbs =
      Enum.map(images, fn att ->
        id = NativeLocalImage.att_id(att)
        name = NativeLocalImage.att_name(att)
        src = upload_src(chat, att)

        NativeLocalImage.thumb(src, name,
          upload_only: true,
          on_tap: {self(), {:open_sent_image, message_id, id}},
          id: "sent-thumb-#{message_id}-#{id}"
        )
      end)

    node(:box, [fill_width: true, align: "top_trailing", padding_bottom: 6], [
      node(:row, [align: "center"], thumbs)
    ])
  end

  # Resolved when entries entered chat state (NativeLocalImage.resolve_entries/3);
  # render never stats the filesystem.
  defp upload_src(_chat, att), do: NativeLocalImage.sent_src(att)

  defp handoff_target(data, chat) do
    origin = data["origin"] || %{}
    current_conversation_id = Map.get(chat || %{}, :current_conversation_id)
    origin_conversation_id = origin["conversation_id"]

    if is_binary(origin_conversation_id) and origin_conversation_id != current_conversation_id do
      {origin_conversation_id, origin["agent_id"]}
    else
      {nil, data["peer"]}
    end
  end

  defp handoff_label("sent", agent_id), do: "Delegated to #{short_agent(agent_id)}"
  defp handoff_label("received", agent_id), do: "Reply from #{short_agent(agent_id)}"
  defp handoff_label(_event, agent_id), do: "Subagent · #{short_agent(agent_id)}"

  defp short_agent(value) when is_binary(value) do
    value
    |> String.split([":", "/"], trim: true)
    |> List.last()
    |> case do
      nil -> "subagent"
      label -> String.slice(label, 0, 24)
    end
  end

  defp short_agent(_value), do: "subagent"

  defp handoff_summary(messages) do
    messages
    |> Enum.map(&to_string(&1["content"] || ""))
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> ""
      value -> value |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)
    end
  end

  defp chat_workspace_path(%{workspace_path: path}) when is_binary(path), do: path
  defp chat_workspace_path(_), do: nil

  defp chat_workspace_id(%{workspace_id: id}) when is_binary(id), do: id
  defp chat_workspace_id(_), do: nil

  defp chat_conversation_id(%{conversation: %{"id" => id}}) when is_binary(id), do: id
  defp chat_conversation_id(_), do: nil

  defp delivery_actions(entry, chat) do
    workspace = chat_workspace_path(chat)

    case HandbeanProbe.NativeArtifactDelivery.timeline_target(entry, workspace) do
      {:url, url} ->
        actions_row([
          button(gettext("Open in system browser"), {:delivery, :open_url, url},
            text_size: 11,
            padding: 6
          )
        ])

      {:file, path} ->
        spec =
          HandbeanProbe.NativeWorkspaceOpen.spec(
            :timeline,
            path,
            chat_workspace_id(chat),
            chat_conversation_id(chat)
          )

        actions_row([
          button(gettext("Open"), {:workspace_open, :view, spec}, text_size: 11, padding: 6),
          button(gettext("Open in another app"), {:delivery, :open_file, spec},
            text_size: 11,
            padding: 6
          ),
          button(gettext("Share file"), {:delivery, :share_file, spec}, text_size: 11, padding: 6)
        ])

      _ ->
        nil
    end
  end
end
