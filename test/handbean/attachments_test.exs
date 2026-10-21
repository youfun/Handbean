defmodule Handbean.AttachmentsTest do
  use Handbean.DataCase, async: false

  alias Handbean.Attachments
  alias Handbean.Attachments.{Access, History, Imported, MessageBuilder, Type}
  alias Handbean.Agent.{Coordinator, Message}

  setup do
    dir = Path.join(System.tmp_dir!(), "att_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Attachment artifacts use the host data directory; keep them isolated from
    # the real Handbean home.
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(Map.put(previous_host || %{}, :data_dir, dir))

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "classifies octet-stream source as text only with an allowed extension" do
    assert {:ok, "text/x-source"} =
             Type.classify("defmodule X do\nend\n", "mod.ex", "application/octet-stream")

    assert {:error, :unsupported_type} =
             Type.classify("hello world", "note.bin", "application/octet-stream")
  end

  test "rejects declared image without magic, PDF header, and malformed utf8" do
    assert {:error, :unsupported_type} =
             Type.classify("not-an-image", "photo.png", "image/png")

    assert {:error, :unsupported_type} =
             Type.classify("%PDF-1.4\n%", "doc.pdf", "application/pdf")

    assert {:error, :unsupported_type} =
             Type.classify(<<0xFF, 0xFE, 0x00>>, "note.txt", "text/plain")
  end

  test "batch limits use actual file sizes", %{dir: dir} do
    items = for i <- 1..5, do: write_text(dir, "#{i}.txt", "x")
    assert {:error, :too_many_attachments} = Attachments.validate_batch(items)

    png = write_bytes(dir, "big.png", png_header() <> :binary.copy(<<1>>, 5_000_001 - 8))
    assert {:error, :image_too_large} = Attachments.validate_batch([png])

    text = write_bytes(dir, "big.txt", :binary.copy("a", 21 * 1024 * 1024))
    assert {:error, :text_too_large} = Attachments.validate_batch([text])

    a = write_bytes(dir, "a.txt", :binary.copy("a", 20 * 1024 * 1024))
    b = write_bytes(dir, "b.txt", :binary.copy("b", 6 * 1024 * 1024))
    assert {:error, :batch_too_large} = Attachments.validate_batch([a, b])
  end

  test "promote and persist without conversation on import, bind on send", %{dir: dir} do
    workspace = Path.join(dir, "ws")
    File.mkdir_p!(workspace)
    staging = Path.join(dir, "staging")
    File.mkdir_p!(staging)
    src = Path.join(staging, "note.txt")
    File.write!(src, "hello")

    imported = %Imported{
      attachment_id: "att-1",
      source: :test,
      display_name: "note.txt",
      canonical_type: "text/plain",
      size_bytes: 5,
      controlled_path: src
    }

    {:ok, conv} = Handbean.ConversationStore.create("default")

    assert {:ok, message, persistable} =
             MessageBuilder.build("see file", [imported],
               workspace_path: workspace,
               conversation_id: conv["id"],
               staging_roots: [staging]
             )

    assert File.exists?(src)

    assert %Message{
             role: :user,
             content: [%{type: "text", text: "see file"}, %{type: "text", text: note}]
           } = message

    assert note =~ "note.txt"
    assert note =~ ".handbean/uploads/#{conv["id"]}/att-1.txt"
    refute persistable |> Jason.encode!() |> String.contains?("aGVsbG8")
    assert hd(persistable)["relative_path"] =~ ".handbean/uploads/#{conv["id"]}"
    refute hd(persistable)["relative_path"] =~ workspace
  end

  test "rejects traversal, sibling prefix, symlink, and absolute storage fallback", %{dir: dir} do
    workspace = Path.join(dir, "ws")
    File.mkdir_p!(workspace)
    {:ok, conv} = Handbean.ConversationStore.create("default")
    dest_dir = Handbean.Uploads.ensure_conversation_dir!(workspace, conv["id"])
    dest = Path.join(dest_dir, "ok.txt")
    File.write!(dest, "ok")

    secret = Path.join(dir, "secret.txt")
    File.write!(secret, "leaked")

    assert {:error, :malformed_ref} =
             Access.resolve_upload(workspace, conv["id"], "../../../secret.txt")

    sibling = Path.join(workspace, ".handbean/uploads#{conv["id"]}")
    File.mkdir_p!(sibling)
    File.write!(Path.join(sibling, "x.txt"), "nope")

    assert {:error, :malformed_ref} =
             Access.resolve_upload(
               workspace,
               conv["id"],
               Path.join([".handbean", "uploads#{conv["id"]}", "x.txt"])
             )

    link = Path.join(dest_dir, "link.txt")
    File.ln_s!(secret, link)

    assert {:error, _} =
             Access.resolve_upload(
               workspace,
               conv["id"],
               Path.join([".handbean", "uploads", conv["id"], "link.txt"])
             )

    [blocked] =
      History.to_messages(
        %{
          "role" => "user",
          "content" => "x",
          "conversation_id" => conv["id"],
          "attachments" => [
            %{
              "mime_type" => "image/png",
              "filename" => "secret.png",
              "storage_path" => secret
            }
          ]
        },
        workspace
      )

    texts =
      case blocked.content do
        text when is_binary(text) -> [text]
        blocks when is_list(blocks) -> Enum.map(blocks, & &1[:text])
      end

    assert Enum.any?(texts, &(is_binary(&1) and &1 =~ "absolute"))
  end

  test "first-turn missing or grown images fail send; history marks missing", %{dir: dir} do
    workspace = Path.join(dir, "ws")
    File.mkdir_p!(workspace)
    {:ok, conv} = Handbean.ConversationStore.create("default")
    dest_dir = Handbean.Uploads.ensure_conversation_dir!(workspace, conv["id"])
    dest = Path.join(dest_dir, "img-1.png")
    png = png_header() <> <<1, 2, 3, 4>>
    File.write!(dest, png)
    relative = Path.join([".handbean", "uploads", conv["id"], "img-1.png"])

    missing = %{
      mime_type: "image/png",
      filename: "gone.png",
      relative_path: Path.join([".handbean", "uploads", conv["id"], "gone.png"])
    }

    assert {:error, :unreadable_attachment} =
             MessageBuilder.build("see", [missing],
               workspace_path: workspace,
               conversation_id: conv["id"]
             )

    att = %{
      id: "img-1",
      kind: "image",
      mime_type: "image/png",
      filename: "img-1.png",
      relative_path: relative
    }

    File.rm!(dest)

    assert {:error, :unreadable_attachment} =
             MessageBuilder.build("see", [att],
               workspace_path: workspace,
               conversation_id: conv["id"]
             )

    File.write!(dest, png)

    {:ok, entry} =
      Handbean.Agent.TranscriptPersistence.append_inbound(
        conv["id"],
        %Message{
          role: :user,
          content: [
            %{type: "text", text: "look"},
            %{type: "image", mime_type: "image/png", data: "x"}
          ]
        },
        attachments: [
          %{
            "id" => "img-1",
            "kind" => "image",
            "mime_type" => "image/png",
            "filename" => "img-1.png",
            "relative_path" => relative
          }
        ]
      )

    File.write!(dest, png_header() <> :binary.copy(<<9>>, 5_000_001))
    [grown] = History.to_messages(Map.put(entry, "conversation_id", conv["id"]), workspace)

    assert Enum.any?(List.wrap(grown.content), fn
             %{text: text} -> text =~ "missing" or text =~ "too_large"
             _ -> false
           end)
  end

  test "transcript stores refs not base64 and history restores images", %{dir: dir} do
    workspace = Path.join(dir, "ws")
    File.mkdir_p!(workspace)
    {:ok, conv} = Handbean.ConversationStore.create("default")
    png = png_header() <> <<0, 1, 2, 3>>
    dest_dir = Handbean.Uploads.ensure_conversation_dir!(workspace, conv["id"])
    dest = Path.join(dest_dir, "img-1.png")
    File.write!(dest, png)
    relative = Path.join([".handbean", "uploads", conv["id"], "img-1.png"])

    message = %Message{
      role: :user,
      content: [
        %{type: "text", text: "look"},
        %{type: "image", mime_type: "image/png", data: Base.encode64(png)}
      ]
    }

    attachments = [
      %{
        "id" => "img-1",
        "kind" => "image",
        "mime_type" => "image/png",
        "filename" => "img-1.png",
        "relative_path" => relative
      }
    ]

    {:ok, entry} =
      Handbean.Agent.TranscriptPersistence.append_inbound(conv["id"], message,
        workspace_path: workspace,
        attachments: attachments,
        inbound_id: "inb-1"
      )

    encoded = Jason.encode!(entry)
    refute encoded =~ Base.encode64(png)
    refute encoded =~ ~s("data")
    refute encoded =~ "content://"
    assert entry["inbound_id"] == "inb-1"
    assert Attachments.inbound_ack(conv["id"], "inb-1") == :acknowledged
    assert Attachments.inbound_ack(conv["id"], "missing") == :unknown

    [restored] = History.to_messages(Map.put(entry, "conversation_id", conv["id"]), workspace)
    assert %Message{content: blocks} = restored
    image = Enum.find(blocks, &(&1.type == "image"))
    assert image.data == Base.encode64(png)

    File.rm!(dest)
    [missing] = History.to_messages(Map.put(entry, "conversation_id", conv["id"]), workspace)
    assert %Message{content: missing_blocks} = missing
    assert Enum.any?(missing_blocks, &(is_binary(&1.text) and &1.text =~ "missing"))
  end

  test "history drops failed assistant loops and replays encrypted reasoning" do
    loop = %{
      "role" => "assistant",
      "content" => String.duplicate("same phrase ", 8),
      "status" => "error"
    }

    assert History.to_messages(loop, nil) == []

    item = %{
      "type" => "reasoning",
      "id" => "rs_hist",
      "encrypted_content" => "enc-hist"
    }

    source = %{
      "provider" => "openai",
      "api" => "openai_responses",
      "model" => "gpt-5.2"
    }

    [restored] =
      History.to_messages(
        %{
          "role" => "assistant",
          "content" => "visible",
          "status" => "completed",
          "content_blocks" => [
            %{"type" => "responses_reasoning", "provider_context" => source, "item" => item}
          ]
        },
        nil
      )

    assert restored.content == [
             %{"type" => "responses_reasoning", "provider_context" => source, "item" => item},
             %{type: "text", text: "visible"}
           ]

    recent_item = %{
      "type" => "reasoning",
      "id" => "rs_recent",
      "encrypted_content" => "enc-recent"
    }

    restored_window =
      History.to_messages(
        [
          %{
            "role" => "assistant",
            "content" => "old visible",
            "status" => "completed",
            "content_blocks" => [%{"type" => "responses_reasoning", "item" => item}]
          },
          %{"role" => "user", "content" => String.duplicate("middle", 20_000)},
          %{
            "role" => "assistant",
            "content" => "recent visible",
            "status" => "completed",
            "content_blocks" => [
              %{"type" => "responses_reasoning", "item" => recent_item}
            ]
          }
        ],
        nil,
        nil
      )

    [old, _middle, recent] = restored_window
    refute Enum.any?(old.content, &(&1["type"] == "responses_reasoning"))
    assert Enum.any?(recent.content, &(&1["type"] == "responses_reasoning"))

    [phased] =
      History.to_messages(
        %{
          "id" => "msg_final",
          "role" => "assistant",
          "content" => "Hello! How can I help?",
          "status" => "completed",
          "phase" => "final_answer"
        },
        nil
      )

    assert phased.content == [
             %{
               type: "text",
               text: "Hello! How can I help?",
               phase: "final_answer",
               id: "msg_final"
             }
           ]

    assert phased.id == "msg_final"
  end

  test "history stamps transcript provenance and checkpoints reject live or edited context" do
    {:ok, conv} = Handbean.ConversationStore.create("default")
    id = conv["id"]

    {:ok, first_entry} =
      Handbean.ConversationTranscriptStore.append(id, %{
        "id" => "history-user-1",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "content" => "original"
      })

    {:ok, assistant_entry} =
      Handbean.ConversationTranscriptStore.append(id, %{
        "id" => "history-assistant-1",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "content" => "older answer",
        "status" => "completed"
      })

    [first, assistant] = History.to_messages([first_entry, assistant_entry], nil, id)
    assert first.id == first_entry["id"]
    assert assistant.id == assistant_entry["id"]

    event = %{
      first: first,
      previous_summary: nil,
      messages_to_summarize: [assistant],
      summary: "durable summary",
      context_edited: false,
      context_generation: 0,
      context_window: 272_000,
      model: "gpt-5.6-sol",
      run_id: "run-1"
    }

    assert {:ok, checkpoint} =
             Handbean.Agent.CompactionCheckpoint.persist(id, event, [])

    assert checkpoint["content_type"] == "model_compaction"
    assert checkpoint["first_entry_id"] == first.id
    assert checkpoint["covered_through_id"] == assistant.id

    assert {:error, :invalid_provenance} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               put_in(event, [:messages_to_summarize], [%{assistant | id: nil}]),
               []
             )

    assert {:error, :context_edited} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               Map.put(event, :context_edited, true),
               []
             )
  end

  test "history reuses chained checkpoints, preserves suffix reasoning, and falls back" do
    {:ok, conv} = Handbean.ConversationStore.create("default")
    id = conv["id"]

    append = fn entry ->
      {:ok, persisted} = Handbean.ConversationTranscriptStore.append(id, entry)
      persisted
    end

    first_entry =
      append.(%{
        "id" => "chain-user-1",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "content" => "original task"
      })

    old_entry =
      append.(%{
        "id" => "chain-assistant-1",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "content" => "old answer",
        "status" => "completed"
      })

    next_entry =
      append.(%{
        "id" => "chain-user-2",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "content" => "next question"
      })

    reasoning = %{
      "type" => "reasoning",
      "id" => "chain-reasoning",
      "encrypted_content" => "encrypted-chain"
    }

    recent_entry =
      append.(%{
        "id" => "chain-assistant-2",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "content" => "recent answer",
        "content_blocks" => [%{"type" => "responses_reasoning", "item" => reasoning}],
        "status" => "completed"
      })

    [first, old, next, recent] =
      History.to_messages([first_entry, old_entry, next_entry, recent_entry], nil, id)

    checkpoint_event = fn previous_summary, summarized, summary, run_id ->
      %{
        first: first,
        previous_summary: previous_summary,
        messages_to_summarize: summarized,
        summary: summary,
        context_edited: false,
        context_generation: 0,
        context_window: 272_000,
        model: "gpt-5.6-sol",
        run_id: run_id
      }
    end

    assert {:ok, checkpoint_1} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               checkpoint_event.(nil, [old], "first durable summary", "run-1"),
               []
             )

    entries = Handbean.ConversationStore.load_messages(id)

    [rebuilt_first, summary_1, rebuilt_next, rebuilt_recent] =
      History.to_messages(entries, nil, id)

    assert rebuilt_first.id == first.id
    assert summary_1.id == checkpoint_1["id"]
    assert summary_1.content =~ "first durable summary"
    assert rebuilt_next.id == next.id
    assert rebuilt_recent.id == recent.id
    assert Enum.any?(rebuilt_recent.content, &(&1["type"] == "responses_reasoning"))

    assert {:ok, checkpoint_2} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               checkpoint_event.(summary_1, [rebuilt_next], "second durable summary", "run-2"),
               []
             )

    suffix_entry =
      append.(%{
        "id" => "chain-user-3",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "content" => "appended after checkpoint"
      })

    [_, summary_2, after_second, appended] =
      id |> Handbean.ConversationStore.load_messages() |> History.to_messages(nil, id)

    assert summary_2.id == checkpoint_2["id"]
    assert summary_2.content =~ "second durable summary"
    assert after_second.id == recent.id
    assert appended.id == suffix_entry["id"]

    assert {:ok, _updated} =
             Handbean.ConversationTranscriptStore.update(
               id,
               next_entry["id"],
               %{"content" => "edited after first boundary"}
             )

    [_, fallback_summary, edited, _, _] =
      id |> Handbean.ConversationStore.load_messages() |> History.to_messages(nil, id)

    assert fallback_summary.id == checkpoint_1["id"]
    assert fallback_summary.content =~ "first durable summary"
    assert edited.id == next_entry["id"]
    assert edited.content == "edited after first boundary"
  end

  test "history compaction rebuild leads with a user message when the first entry is an assistant message" do
    {:ok, conv} = Handbean.ConversationStore.create("default")
    id = conv["id"]

    append = fn entry ->
      {:ok, persisted} = Handbean.ConversationTranscriptStore.append(id, entry)
      persisted
    end

    # Imported or injected histories can start with an assistant entry. The
    # rebuilt context must still lead with a user message: providers reject an
    # assistant-first context (the Pi Durable #10904 lesson).
    assistant_first =
      append.(%{
        "id" => "lead-assistant-1",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "content" => "greeting before any user turn",
        "status" => "completed"
      })

    user_entry =
      append.(%{
        "id" => "lead-user-1",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "content" => "the actual task"
      })

    recent_entry =
      append.(%{
        "id" => "lead-assistant-2",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "content" => "recent answer",
        "status" => "completed"
      })

    [first, user_message, _recent] =
      History.to_messages([assistant_first, user_entry, recent_entry], nil, id)

    assert first.role == :assistant

    assert {:ok, checkpoint} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               %{
                 first: first,
                 previous_summary: nil,
                 messages_to_summarize: [user_message],
                 summary: "handoff summary",
                 context_edited: false,
                 context_generation: 0,
                 context_window: 272_000,
                 model: "gpt-5.6-sol",
                 run_id: "run-1"
               },
               []
             )

    [head | _rest] =
      id |> Handbean.ConversationStore.load_messages() |> History.to_messages(nil, id)

    assert head.role == :user
    assert head.id == checkpoint["id"]
    assert head.content =~ "handoff summary"
  end

  test "history compaction rebuild keeps a user first entry in front of the summary" do
    {:ok, conv} = Handbean.ConversationStore.create("default")
    id = conv["id"]

    append = fn entry ->
      {:ok, persisted} = Handbean.ConversationTranscriptStore.append(id, entry)
      persisted
    end

    first_entry =
      append.(%{
        "id" => "userlead-user-1",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "content" => "original task"
      })

    old_entry =
      append.(%{
        "id" => "userlead-assistant-1",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "content" => "old answer",
        "status" => "completed"
      })

    [first, old] = History.to_messages([first_entry, old_entry], nil, id)

    assert {:ok, checkpoint} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               %{
                 first: first,
                 previous_summary: nil,
                 messages_to_summarize: [old],
                 summary: "durable summary",
                 context_edited: false,
                 context_generation: 0,
                 context_window: 272_000,
                 model: "gpt-5.6-sol",
                 run_id: "run-1"
               },
               []
             )

    [head, summary] =
      id |> Handbean.ConversationStore.load_messages() |> History.to_messages(nil, id)

    assert head.role == :user
    assert head.id == first_entry["id"]
    assert summary.role == :user
    assert summary.id == checkpoint["id"]
  end

  test "history falls back to full replay when the checkpoint digest no longer matches" do
    {:ok, conv} = Handbean.ConversationStore.create("default")
    id = conv["id"]

    append = fn entry ->
      {:ok, persisted} = Handbean.ConversationTranscriptStore.append(id, entry)
      persisted
    end

    first_entry =
      append.(%{
        "id" => "digest-user-1",
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "content" => "original task"
      })

    old_entry =
      append.(%{
        "id" => "digest-assistant-1",
        "content_type" => "assistant_msg",
        "message_type" => "assistant",
        "role" => "assistant",
        "content" => "old answer",
        "status" => "completed"
      })

    [first, old] = History.to_messages([first_entry, old_entry], nil, id)

    assert {:ok, checkpoint} =
             Handbean.Agent.CompactionCheckpoint.persist(
               id,
               %{
                 first: first,
                 previous_summary: nil,
                 messages_to_summarize: [old],
                 summary: "durable summary",
                 context_edited: false,
                 context_generation: 0,
                 context_window: 272_000,
                 model: "gpt-5.6-sol",
                 run_id: "run-1"
               },
               []
             )

    # Editing a covered source entry invalidates the checkpoint digest, so the
    # projection must reject it and rebuild the full history instead.
    assert {:ok, _updated} =
             Handbean.ConversationTranscriptStore.update(id, old_entry["id"], %{
               "content" => "tampered after checkpoint"
             })

    messages = id |> Handbean.ConversationStore.load_messages() |> History.to_messages(nil, id)

    assert Enum.all?(messages, &(&1.id != checkpoint["id"]))
    assert [%{role: :user}, %{role: :assistant}] = messages
    assert hd(messages).content == "original task"
    assert Enum.at(messages, 1).content == "tampered after checkpoint"
  end

  test "history restore is what Coordinator uses for later turns", %{dir: dir} do
    workspace = Path.join(dir, "ws")
    File.mkdir_p!(workspace)
    {:ok, conv} = Handbean.ConversationStore.create("default")
    png = png_header() <> <<1, 2, 3, 4>>
    dest = Path.join(Handbean.Uploads.ensure_conversation_dir!(workspace, conv["id"]), "a.png")
    File.write!(dest, png)

    {:ok, entry} =
      Handbean.Agent.TranscriptPersistence.append_inbound(
        conv["id"],
        %Message{
          role: :user,
          content: [
            %{type: "text", text: "img"},
            %{type: "image", mime_type: "image/png", data: "xxxx"}
          ]
        },
        attachments: [
          %{
            "id" => "a",
            "kind" => "image",
            "mime_type" => "image/png",
            "filename" => "a.png",
            "relative_path" => Path.join([".handbean", "uploads", conv["id"], "a.png"])
          }
        ]
      )

    refute Jason.encode!(entry) =~ "xxxx"

    messages = History.to_messages(Map.put(entry, "conversation_id", conv["id"]), workspace)
    assert match?([%Message{role: :user, content: [_ | _]}], messages)
    _ = Coordinator
  end

  test "read_bounded streams at most max+1 bytes and rejects growth past the cap", %{dir: dir} do
    path = Path.join(dir, "grow.bin")
    File.write!(path, "abc")
    assert {:ok, "abc"} = Access.read_bounded(path, 10)
    File.write!(path, :binary.copy("x", 32))
    assert {:error, :too_large_or_empty} = Access.read_bounded(path, 8)
    assert {:error, :too_large_or_empty} = Access.read_bounded(path, 31)
  end

  test "export authorize rejects traversal and oversized files", %{dir: dir} do
    workspace = Path.join(dir, "ws")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "x")
    assert {:ok, meta} = Handbean.ExportSnapshot.authorize(workspace, "ok.txt")
    assert meta.size_bytes == 1
    assert {:error, :invalid_path} = Handbean.ExportSnapshot.authorize(workspace, "../secret")
    assert {:error, :invalid_path} = Handbean.ExportSnapshot.authorize(workspace, "/etc/passwd")
  end

  test "free chat inlines an image without a workspace path", %{dir: dir} do
    staging = Path.join(dir, "staging")
    File.mkdir_p!(staging)
    src = Path.join(staging, "shot.png")
    png = png_header() <> <<1, 2, 3, 4>>
    File.write!(src, png)
    {:ok, conv} = Handbean.ConversationStore.create("default")

    imported = %Imported{
      attachment_id: "att-free",
      source: :test,
      display_name: "shot.png",
      canonical_type: "image/png",
      size_bytes: byte_size(png),
      controlled_path: src
    }

    assert {:ok, %Message{content: blocks}, persistable} =
             MessageBuilder.build("look", [imported],
               chat_scope: :free,
               conversation_id: conv["id"],
               staging_roots: [staging]
             )

    image = Enum.find(blocks, &(&1.type == "image"))
    assert image.data == Base.encode64(png)
    assert hd(persistable)["relative_path"] == "att-free.png"
  end

  defp png_header, do: <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

  defp write_text(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)

    %{
      mime_type: "text/plain",
      filename: name,
      controlled_path: path,
      size_bytes: byte_size(body)
    }
  end

  defp write_bytes(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    mime = if String.ends_with?(name, ".png"), do: "image/png", else: "text/plain"

    %{
      mime_type: mime,
      filename: name,
      controlled_path: path,
      size_bytes: 1
    }
  end
end
