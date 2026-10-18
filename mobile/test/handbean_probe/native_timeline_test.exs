defmodule HandbeanProbe.NativeTimelineTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeanProbe.Gettext

  alias HandbeanProbe.NativeTimeline

  @tiny_png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
              1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248,
              207, 192, 240, 31, 0, 5, 0, 1, 253, 46, 43, 34, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66,
              96, 130>>

  test "internal compaction and memory reflection entries are not rendered" do
    chat = %{
      entries: [
        %{
          "id" => "compaction-1",
          "content_type" => "model_compaction",
          "role" => "internal",
          "summary" => "PRIVATE-COMPACTION-SUMMARY"
        },
        %{
          "id" => "memory-reflection-compaction-1",
          "content_type" => "memory_reflection",
          "role" => "internal",
          "content" => "PRIVATE-REFLECTION-CANDIDATE"
        },
        %{"id" => "user-1", "role" => "user", "content" => "visible user message"}
      ],
      stream: "",
      running: false
    }

    rendered = inspect(render(chat, MapSet.new()), limit: :infinity)
    assert rendered =~ "visible user message"
    refute rendered =~ "PRIVATE-COMPACTION-SUMMARY"
    refute rendered =~ "PRIVATE-REFLECTION-CANDIDATE"
    refute rendered =~ "compaction-1"
  end

  test "sent images use controlled local sources without network or bytes" do
    {chat, dest, relative} = chat_with_png("user-img", "shot.png")

    tree = render(chat, MapSet.new())
    encoded = inspect(tree)
    images = match_image_nodes(tree)
    assert length(images) == 1
    [thumb] = images
    assert thumb.props.src == dest
    assert thumb.props.upload_only == true
    assert thumb.props.local_only == true
    assert encoded =~ "识别图片"
    refute encoded =~ "https://"
    refute encoded =~ Base.encode64(@tiny_png)
    refute encoded =~ "data:image"
    assert thumb.props.src == Path.join([chat.workspace_path, relative])
  end

  test "write and browser tool cards expose system open and share actions" do
    chat = %{
      conversation: %{"id" => "c1"},
      workspace_id: "ws-1",
      workspace_path: "/tmp/ws",
      entries: [
        %{
          "id" => "t1",
          "content_type" => "tool",
          "tool_name" => "write",
          "tool_status" => "done",
          "input" => %{"file_path" => "out/report.pdf"},
          "content" => "wrote"
        },
        %{
          "id" => "t2",
          "content_type" => "tool",
          "tool_name" => "browser",
          "tool_status" => "done",
          "input" => %{"action" => "open", "url" => "https://example.com/login"},
          "content" => "opened"
        }
      ],
      stream: "",
      running: false
    }

    encoded = inspect(render(chat, MapSet.new(["t1"])), limit: :infinity)
    assert encoded =~ gettext("Open")
    assert encoded =~ gettext("Open in another app")
    assert encoded =~ gettext("Share file")
    assert encoded =~ gettext("Open in system browser")
    assert encoded =~ ":workspace_open"
    assert encoded =~ "https://example.com/login"
  end

  test "write card uses the current workspace for absolute paths" do
    ws = "/tmp/ws-abs"

    chat = %{
      conversation: %{"id" => "c1"},
      workspace_id: "ws-abs",
      workspace_path: ws,
      entries: [
        %{
          "id" => "t1",
          "content_type" => "tool",
          "tool_name" => "write",
          "tool_status" => "done",
          "input" => %{"file_path" => Path.join(ws, "out/report.pdf")},
          "content" => "wrote"
        }
      ],
      stream: "",
      running: false
    }

    tree = render(chat, MapSet.new(["t1"]))
    encoded = inspect(tree)
    assert encoded =~ gettext("Open in another app")
    assert encoded =~ "out/report.pdf"
  end

  test "expanded reads, commands, and edit actions are available" do
    chat = %{
      entries: [
        %{
          "id" => "r",
          "content_type" => "tool",
          "tool_name" => "read",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/a.ex"}
        },
        %{
          "id" => "gap",
          "role" => "assistant",
          "content" => "next",
          "content_type" => "assistant_msg"
        },
        %{
          "id" => "b",
          "content_type" => "tool",
          "tool_name" => "bash",
          "tool_status" => "done",
          "input" => %{"command" => "mix test"}
        },
        %{
          "id" => "e",
          "content_type" => "tool",
          "tool_name" => "edit",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/a.ex"},
          "diff_lines" => [%{"type" => "add", "text" => "added"}]
        }
      ],
      stream: "",
      running: false
    }

    tree = render(chat, MapSet.new(["r", "b", "e"]))
    encoded = inspect(tree, limit: :infinity)

    assert encoded =~ "read lib/a.ex"
    assert encoded =~ "$ mix test"

    refute encoded =~ " · done"
    assert encoded =~ "+1"
    assert encoded =~ "toggle_file_diff"
    refute encoded =~ gettext("Show Work")
    refute encoded =~ gettext("Hide Work")
  end

  test "a mixed group exposes reads, commands, diffs, and copy actions" do
    chat = %{
      entries: [
        %{
          "id" => "r",
          "content_type" => "tool",
          "tool_name" => "read",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/a.ex"}
        },
        %{
          "id" => "e",
          "content_type" => "tool",
          "tool_name" => "edit",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/a.ex"},
          "diff_lines" => [
            %{"type" => "add", "text" => "added"},
            %{"type" => "del", "text" => "removed"}
          ]
        },
        %{
          "id" => "b",
          "content_type" => "tool",
          "tool_name" => "bash",
          "tool_status" => "done",
          "input" => %{"command" => "mix test"}
        }
      ],
      stream: "",
      running: false
    }

    tree = render(chat, MapSet.new(["r"]))
    encoded = inspect(tree, limit: :infinity)

    assert encoded =~ "read lib/a.ex"
    assert encoded =~ "$ mix test"
    assert encoded =~ "+1"
    assert encoded =~ "−1"
    assert encoded =~ "toggle_file_diff"
    assert encoded =~ gettext("Copy relative path")
  end

  test "an open edit diff shows prefixed lines, a copy path button, and truncation" do
    lines =
      for i <- 1..81 do
        %{"type" => if(rem(i, 2) == 0, do: "del", else: "ins"), "text" => "L#{i}"}
      end

    chat = %{
      workspace_path: "/tmp/ws",
      entries: [
        %{
          "id" => "e",
          "content_type" => "tool",
          "tool_name" => "edit",
          "tool_status" => "done",
          "file_path" => "/tmp/ws/lib/a.ex",
          "input" => %{"file_path" => "/tmp/ws/lib/a.ex"},
          "diff_lines" => lines,
          "file_diff_open" => true
        }
      ],
      stream: "",
      running: false
    }

    tree = render(chat, MapSet.new(["e"]))
    encoded = inspect(tree, limit: :infinity)
    diff_texts = text_nodes(tree) |> Enum.filter(&diff_line?/1)

    assert encoded =~ "Edited 1 file (+41 -40)"
    assert encoded =~ "edit /tmp/ws/lib/a.ex"
    assert encoded =~ "+41"
    assert encoded =~ "−40"
    assert encoded =~ "toggle_file_diff"
    assert encoded =~ "copy_relative_path"
    assert encoded =~ "lib/a.ex"
    assert encoded =~ gettext("Copy relative path")
    refute encoded =~ "tool-output-e"
    assert length(diff_texts) == 81
    assert hd(diff_texts).props.text == "+L1"
    assert Enum.at(diff_texts, 1).props.text == "−L2"

    assert List.last(diff_texts).props.text ==
             ngettext("1 line not shown", "%{count} lines not shown", 1)

    refute encoded =~ "L81"
  end

  test "assistant text renders without a show work boundary" do
    chat = %{
      entries: [
        %{
          "id" => "plan",
          "role" => "assistant",
          "content" => "I will read the file",
          "phase" => "commentary",
          "work_hidden" => true
        },
        %{
          "id" => "answer",
          "role" => "user",
          "content" => "continue"
        }
      ],
      stream: "",
      running: false
    }

    tree = render(chat, MapSet.new())
    encoded = inspect(tree, limit: :infinity)
    assistant_text = Enum.find(text_nodes(tree), &(&1.props[:id] == "plan"))

    assert assistant_text.props.text == "I will read the file"
    assert assistant_text.props.markdown == true
    assert encoded =~ "I will read the file"
    assert encoded =~ "continue"
    refute encoded =~ gettext("Attachment")
    refute encoded =~ gettext("Show Work")
    refute encoded =~ gettext("Hide Work")
  end

  test "empty assistant media renders a public metadata card without a blank text node" do
    chat = %{
      entries: [
        %{
          "id" => "media-message",
          "role" => "assistant",
          "content" => "",
          "attachments" => [
            %{
              "media_id" => "media-1",
              "conversation_id" => "conversation-1",
              "kind" => "image",
              "mime_type" => "image/png",
              "filename" => "result.png",
              "size_bytes" => 238_104,
              "sha256" => "public-checksum",
              "source" => "agent"
            }
          ]
        }
      ],
      stream: "",
      running: false
    }

    tree = render(chat, MapSet.new())
    texts = text_nodes(tree) |> Enum.map(& &1.props.text)

    assert gettext("Attachment") in texts
    assert "result.png" in texts
    assert "image/png · 238104 B" in texts
    refute "" in texts
    assert match_image_nodes(tree) == []
  end

  test "multiple sent images cap at four" do
    workspace = tmp_ws()
    conv_id = Ecto.UUID.generate()

    attachments =
      for i <- 1..5 do
        {_dest, relative} = place_png(workspace, conv_id, "img-#{i}")

        %{
          "id" => "img-#{i}",
          "kind" => "image",
          "mime_type" => "image/png",
          "filename" => "p#{i}.png",
          "relative_path" => relative
        }
      end

    chat = chat(workspace, conv_id, "user-m", "多图", attachments)
    tree = render(chat, MapSet.new())
    images = match_image_nodes(tree)
    assert length(images) == 4
  end

  test "text-only attachments stay names and history restore uses upload refs" do
    workspace = tmp_ws()
    conv_id = Ecto.UUID.generate()
    {_dest, relative} = place_png(workspace, conv_id, "hist-1")

    entry = %{
      "id" => "hist-msg",
      "role" => "user",
      "content" => "历史图",
      "attachments" => [
        %{
          "id" => "hist-1",
          "kind" => "image",
          "mime_type" => "image/png",
          "filename" => "hist.png",
          "relative_path" => relative
        }
      ]
    }

    chat = %{
      conversation: %{"id" => conv_id, "workspace_id" => "ws-hist"},
      workspace_path: workspace,
      workspace_id: "ws-hist",
      entries: [entry],
      stream: "",
      running: false
    }

    tree = render(chat, MapSet.new())
    images = match_image_nodes(hd(tree))
    assert length(images) == 1
    assert hd(images).props.src =~ "/.handbean/uploads/#{conv_id}/"

    text_only = %{
      entries: [
        %{
          "id" => "u-text",
          "role" => "user",
          "content" => "看文件",
          "attachments" => [
            %{
              "id" => "n1",
              "filename" => "note.ex",
              "mime_type" => "text/x-source",
              "kind" => "text"
            }
          ]
        }
      ],
      stream: "",
      running: false
    }

    [row | _] = render(text_only, MapSet.new())
    encoded = inspect(row)
    assert encoded =~ "note.ex"
    assert match_image_nodes(row) == []
  end

  test "missing or naked paths fall back and never use a foreign workspace" do
    workspace = tmp_ws()
    other = tmp_ws()
    conv_id = Ecto.UUID.generate()
    {_dest, relative} = place_png(workspace, conv_id, "own-1")

    owned = %{
      "id" => "own-1",
      "kind" => "image",
      "mime_type" => "image/png",
      "filename" => "own.png",
      "relative_path" => relative,
      "controlled_path" => "/tmp/evil.png"
    }

    missing = %{
      "id" => "gone",
      "kind" => "image",
      "mime_type" => "image/png",
      "filename" => "gone.png",
      "relative_path" => Path.join([".handbean", "uploads", conv_id, "gone.png"])
    }

    chat = chat(workspace, conv_id, "user-own", "图", [owned, missing])
    [row | _] = render(chat, MapSet.new())
    images = match_image_nodes(row)
    assert length(images) == 2
    assert Enum.at(images, 0).props.src == Path.join(workspace, relative)
    refute Enum.at(images, 0).props.src == "/tmp/evil.png"
    assert Enum.at(images, 1).props.src == ""
    assert Enum.at(images, 1).props.fallback == gettext("Image cannot be displayed")

    foreign = %{chat | workspace_path: other}
    [foreign_row | _] = render(foreign, MapSet.new())
    foreign_images = match_image_nodes(foreign_row)
    assert Enum.all?(foreign_images, &(&1.props.src == ""))
  end

  test "sent card resolves the same upload ref by message and attachment id" do
    {chat, dest, _relative} = chat_with_png("user-card", "card.png")

    card =
      render_sent_card(chat, %{message_id: "user-card", attachment_id: "att-1"})

    assert card
    encoded = inspect(card)
    assert encoded =~ "card.png"
    assert encoded =~ "image/png"
    [image] = match_image_nodes(card)
    assert image.props.src == dest
    assert image.props.upload_only == true
    refute render_sent_card(chat, nil)
  end

  test "thread handoffs render compact controls for details, navigation and direct messages" do
    parent_id = Ecto.UUID.generate()
    child_id = Ecto.UUID.generate()

    chat = %{
      conversation: %{"id" => parent_id},
      current_conversation_id: parent_id,
      expanded_handoffs: MapSet.new(["handoff-1"]),
      entries: [
        %{
          "id" => "handoff-entry",
          "content_type" => "thread_handoff",
          "content" => %{
            "type" => "thread_handoff",
            "handoff_id" => "handoff-1",
            "event" => "received",
            "data" => %{
              "origin" => %{
                "conversation_id" => child_id,
                "agent_id" => "researcher"
              },
              "messages" => [
                %{"role" => "assistant", "content" => "The mobile audit is complete."}
              ]
            }
          }
        }
      ],
      stream: "",
      running: false
    }

    encoded = inspect(NativeTimeline.render(chat, MapSet.new()), limit: :infinity)

    assert encoded =~ "Reply from researcher"
    assert encoded =~ "The mobile audit is complete."
    assert encoded =~ ":toggle_thread_handoff"
    assert encoded =~ ":open_subagent_thread"
    assert encoded =~ child_id
    assert encoded =~ ":prefill_subagent_message"
  end

  # Sent-image paths are resolved when entries enter chat state; render itself
  # never touches the filesystem.
  defp render(chat, toggles),
    do: NativeTimeline.render(HandbeanProbe.NativeLocalImage.resolve_sent(chat), toggles)

  defp render_sent_card(chat, open),
    do: NativeTimeline.render_sent_card(HandbeanProbe.NativeLocalImage.resolve_sent(chat), open)

  defp chat_with_png(message_id, name) do
    workspace = tmp_ws()
    conv_id = Ecto.UUID.generate()
    {dest, relative} = place_png(workspace, conv_id, "att-1")

    att = %{
      "id" => "att-1",
      "kind" => "image",
      "mime_type" => "image/png",
      "filename" => name,
      "relative_path" => relative
    }

    {chat(workspace, conv_id, message_id, "识别图片", [att]), dest, relative}
  end

  defp chat(workspace, conv_id, message_id, body, attachments) do
    %{
      conversation: %{"id" => conv_id, "workspace_id" => "ws-bound"},
      workspace_path: workspace,
      workspace_id: "ws-bound",
      entries: [
        %{"id" => message_id, "role" => "user", "content" => body, "attachments" => attachments}
      ],
      stream: "",
      running: false
    }
  end

  defp place_png(workspace, conv_id, att_id) do
    dest =
      Path.join(Handbean.Uploads.ensure_conversation_dir!(workspace, conv_id), "#{att_id}.png")

    File.write!(dest, @tiny_png)
    {dest, Path.join([".handbean", "uploads", conv_id, "#{att_id}.png"])}
  end

  defp tmp_ws do
    dir = Path.join(System.tmp_dir!(), "tl_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp text_nodes(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &text_nodes/1)
  defp text_nodes(%{type: :text} = node), do: [node | text_nodes(node.children)]
  defp text_nodes(%{children: children}) when is_list(children), do: text_nodes(children)
  defp text_nodes(_), do: []

  defp diff_line?(%{props: %{text: text}}) when is_binary(text) do
    Regex.match?(~r/^[+−]L\d+$/u, text) or String.ends_with?(text, "line not shown") or
      String.ends_with?(text, "lines not shown")
  end

  defp diff_line?(_), do: false

  defp match_image_nodes(node), do: collect_images(node, []) |> Enum.reverse()

  defp collect_images(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_images/2)
  end

  defp collect_images(%{type: :image} = node, acc), do: [node | acc]

  defp collect_images(%{children: children}, acc) when is_list(children) do
    Enum.reduce(children, acc, &collect_images/2)
  end

  defp collect_images(_, acc), do: acc
end
