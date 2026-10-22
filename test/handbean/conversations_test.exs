defmodule Handbean.ConversationsTest do
  use Handbean.ConversationsCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore, Conversations}

  test "metadata-only discovery, authorization and guessed IDs", c do
    {:ok, _} = ConversationStore.update_meta(c.target, visibility: "internal")
    assert {:ok, %{conversations: [%{"id" => id}]}} = Conversations.list(%{}, c.context)
    assert id == c.source
    assert {:error, :invalid_input} = Conversations.find(%{}, c.context)

    for id <- [c.target, c.foreign, "../index", "", nil] do
      assert {:error, :not_accessible} = Conversations.read(%{"conversation" => id}, c.context)
      assert {:error, :not_accessible} = Conversations.status(%{"conversation" => id}, c.context)
    end

    assert {:error, :unauthorized} = Conversations.list(%{}, %{})
    assert {:error, :unauthorized} = Conversations.list(%{}, %{c.context | workspace_id: "other"})
    assert {:error, :invalid_input} = Conversations.list(%{"workspace_id" => "other"}, c.context)

    assert {:error, :unauthorized} =
             Conversations.list(%{}, %{c.context | conversation_id: c.target})
  end

  test "a cross-workspace conversation grant is exact and operation scoped", c do
    call = %{
      id: "foreign-read",
      name: "read_conversation",
      input: %{"conversation" => c.foreign}
    }

    requirement = Handbean.Permissions.Boundary.requirement(call, c.context)
    grant = Handbean.Permissions.Boundary.grant(call, c.context, requirement, :human)

    approved =
      c.context
      |> Map.put(:tool_execution_grants, %{call.id => grant})
      |> Handbean.Permissions.Boundary.invocation_context(call)

    assert {:ok, _result} = Conversations.read(call.input, approved)

    assert {:error, :not_accessible} =
             Conversations.status(%{"conversation" => c.foreign}, approved)

    changed = put_in(call, [:input, "conversation"], c.target)

    changed_context =
      c.context
      |> Map.put(:tool_execution_grants, %{call.id => grant})
      |> Handbean.Permissions.Boundary.invocation_context(changed)

    refute Map.has_key?(changed_context, :boundary_grant)
  end

  test "yolo permits exact cross-workspace inspection but not discovery or hidden scopes", c do
    {:ok, _} =
      ConversationTranscriptStore.append(c.foreign, %{
        "id" => "foreign-message",
        "role" => "assistant",
        "content" => "foreign exact result"
      })

    {:ok, hidden} =
      ConversationStore.create("other", title: "Hidden", visibility: "internal")

    {:ok, free} = ConversationStore.create_free(title: "Free")
    yolo = Map.put(c.context, :approval_mode, :yolo)

    assert {:ok, %{messages: messages}} =
             Conversations.read(%{"conversation" => c.foreign}, yolo)

    assert Enum.any?(messages, &(&1["content"] == "foreign exact result"))
    assert {:ok, %{state: "idle"}} = Conversations.status(%{"conversation" => c.foreign}, yolo)

    assert {:ok, %{records: records}} =
             Conversations.trajectory(%{"conversation" => c.foreign}, yolo)

    assert records != []

    for id <- [hidden["id"], free["id"]] do
      assert {:error, :not_accessible} = Conversations.read(%{"conversation" => id}, yolo)
      assert {:error, :not_accessible} = Conversations.status(%{"conversation" => id}, yolo)
      assert {:error, :not_accessible} = Conversations.trajectory(%{"conversation" => id}, yolo)
    end

    assert {:ok, %{conversations: listed}} = Conversations.list(%{"archived" => "all"}, yolo)
    refute Enum.any?(listed, &(&1["id"] == c.foreign))

    assert {:error, :not_accessible} =
             Conversations.search_entries(
               %{"query" => "foreign", "conversation" => c.foreign},
               yolo
             )
  end

  test "same-time pagination binds query, caller and updates", c do
    for id <- [c.source, c.target], do: ConversationStore.update_meta(id, updated_at: "same")
    input = %{"limit" => 1}

    assert {:ok, %{conversations: [a], next_cursor: cursor}} =
             Conversations.list(input, c.context)

    assert {:ok, %{conversations: [^a], next_cursor: empty_cursor}} =
             Conversations.list(Map.put(input, "cursor", ""), c.context)

    assert is_binary(empty_cursor)

    assert {:ok, %{conversations: [b], next_cursor: nil}} =
             Conversations.list(Map.put(input, "cursor", cursor), c.context)

    assert a["id"] != b["id"]

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.list(
               %{"limit" => 1, "archived" => "all", "cursor" => cursor},
               c.context
             )

    ConversationStore.update_meta(c.target, title: "Changed")

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.list(Map.put(input, "cursor", cursor), c.context)
  end

  test "list and find have distinct discovery semantics and shared aggregate summaries", c do
    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "summary-user",
        "role" => "user",
        "run_id" => "summary-run",
        "content" => "question"
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "summary-assistant",
        "role" => "assistant",
        "run_id" => "summary-run",
        "content" => "answer"
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "summary-tool",
        "role" => "tool",
        "content_type" => "tool",
        "run_id" => "summary-run",
        "tool_name" => "read"
      })

    assert :ok =
             ConversationStore.record_run_start(c.target, %{
               run_id: "summary-run",
               model: "provider/model"
             })

    assert :ok =
             ConversationStore.record_run_end(c.target, %{
               run_id: "summary-run",
               status: :completed,
               turns: 1
             })

    assert {:ok, %{conversations: listed}} = Conversations.list(%{"archived" => "all"}, c.context)
    target = Enum.find(listed, &(&1["id"] == c.target))
    assert target["message_count"] == 2
    assert target["tool_call_count"] == 1
    assert target["run_count"] == 1

    assert {:ok, %{conversations: [found]}} =
             Conversations.find(%{"query" => "目标", "archived" => "all"}, c.context)

    assert found == target
    assert {:ok, _} = ConversationStore.archive(c.target)
    assert {:ok, %{conversations: active}} = Conversations.list(%{}, c.context)
    refute Enum.any?(active, &(&1["id"] == c.target))

    assert {:ok, %{conversations: archived}} =
             Conversations.list(%{"archived" => "archived"}, c.context)

    assert Enum.any?(archived, &(&1["id"] == c.target))
  end

  test "entry search authenticates first and scopes targets fail closed", c do
    {:ok, free} = ConversationStore.create_free(title: "Free")
    {:ok, internal} = ConversationStore.create("ws", title: "Internal", visibility: "internal")
    {:ok, pending} = ConversationStore.create("ws", title: "Pending")

    for id <- [c.source, c.target, c.foreign, free["id"], internal["id"], pending["id"]] do
      assert {:ok, _} =
               ConversationTranscriptStore.append(id, %{
                 "id" => "scope-#{id}",
                 "role" => "assistant",
                 "run_id" => if(id == c.source, do: "historical-run", else: nil),
                 "content" => "scope sentinel"
               })
    end

    pending
    |> then(&Handbean.Repo.get!(Handbean.Storage.Conversation, &1["id"]))
    |> Ecto.Changeset.change(status: "pending_delete")
    |> Handbean.Repo.update!()

    assert {:ok, result} = Conversations.search_entries(%{"query" => "scope sentinel"}, c.context)
    assert result.schema_version == 1
    assert result.filters.archived == "all"

    assert Enum.sort(Enum.map(result.matches, & &1.conversation_id)) ==
             Enum.sort([c.source, c.target])

    refute Map.has_key?(result, :total)
    refute Map.has_key?(result, :forbidden)

    assert {:ok, _} = ConversationStore.archive(c.target)

    assert {:ok, %{matches: active_matches}} =
             Conversations.search_entries(
               %{"query" => "scope sentinel", "archived" => "active"},
               c.context
             )

    assert Enum.map(active_matches, & &1.conversation_id) == [c.source]

    assert {:ok, %{matches: [%{conversation_id: archived_id, archived: true}]}} =
             Conversations.search_entries(
               %{"query" => "scope sentinel", "archived" => "archived"},
               c.context
             )

    assert archived_id == c.target

    for context <- [
          %{},
          %{conversation_id: free["id"], workspace_id: "ws"},
          %{conversation_id: internal["id"], workspace_id: "ws"},
          %{c.context | workspace_id: "other"}
        ] do
      assert {:error, :unauthorized} =
               Conversations.search_entries(%{"query" => "scope sentinel"}, context)
    end

    for id <- [c.foreign, free["id"], internal["id"], pending["id"]] do
      assert {:error, :not_accessible} =
               Conversations.search_entries(
                 %{"query" => "scope sentinel", "conversation" => id},
                 c.context
               )
    end
  end

  test "entry search projects settled redacted records and applies filters", c do
    timestamp = "2026-10-16T10:00:00.000000Z"

    entries = [
      %{
        "id" => "search-user",
        "role" => "user",
        "run_id" => "search-run",
        "turn_number" => 1,
        "content" => "Literal %_ ' / path and Unicode 目标🙂",
        "updated_at" => timestamp
      },
      %{
        "id" => "search-assistant",
        "role" => "assistant",
        "run_id" => "search-run",
        "turn_number" => 1,
        "status" => "completed",
        "content" => "CASE-insensitive evidence",
        "updated_at" => timestamp
      },
      %{
        "id" => "search-system",
        "role" => "system",
        "content_type" => "system_msg",
        "content" => "system evidence",
        "updated_at" => timestamp
      },
      %{
        "id" => "search-tool",
        "role" => "tool",
        "content_type" => "tool",
        "run_id" => "search-run",
        "turn_number" => 1,
        "tool_name" => "read",
        "tool_status" => "error",
        "input" => %{
          "file_path" => "lib/Search_Path.ex",
          "api_key" => "secret-only-needle"
        },
        "output" => "visible tool evidence Authorization: Bearer output-secret",
        "tool_error" => "tool failure evidence",
        "updated_at" => timestamp
      },
      %{
        "id" => "search-running",
        "role" => "assistant",
        "status" => "streaming",
        "content" => "streaming sentinel"
      },
      %{
        "id" => "search-audit",
        "role" => "system",
        "message_type" => "internal",
        "content_type" => "memory_reflection",
        "content" => "audit sentinel"
      },
      %{
        "id" => "search-arbitrary",
        "role" => "assistant",
        "content" => "public text",
        "unselected_payload" => "arbitrary sentinel"
      },
      %{
        "id" => "search-legacy-error",
        "role" => "assistant",
        "content" => "legacy public evidence",
        "error" => "legacy failure evidence"
      },
      %{
        "id" => "search-failed-status",
        "role" => "assistant",
        "status" => "failed",
        "content" => "failed status evidence"
      },
      %{
        "id" => "search-false-error",
        "role" => "assistant",
        "content" => "false error evidence",
        "error" => false
      },
      %{
        "id" => "search-non-tool-name",
        "role" => "assistant",
        "content" => "non-tool tool-name sentinel",
        "tool_name" => "read"
      },
      %{
        "id" => "search-string-secret",
        "role" => "assistant",
        "content" =>
          "visible string evidence api_key=sk-abcdefghijklmnopqrstuvwxyz password: hunter2"
      },
      %{
        "id" => "search-unicode-fold",
        "role" => "assistant",
        "content" => String.duplicate("İ", 120) <> " unicode-fold-anchor"
      }
    ]

    for entry <- entries do
      assert {:ok, _} = ConversationTranscriptStore.append(c.target, entry)
    end

    assert {:ok, %{matches: [literal]}} =
             Conversations.search_entries(
               %{"query" => "%_ ' / path and Unicode 目标🙂", "conversation" => c.target},
               c.context
             )

    assert literal.entry_id == "search-user"
    assert literal.kind == "user"
    assert literal.run_id == "search-run"
    assert literal.turn == 1
    assert literal.sequence > 0
    assert literal.revision == 1
    assert String.length(literal.snippet) <= 300

    assert {:ok, %{matches: [%{entry_id: "search-assistant", status: "complete"}]}} =
             Conversations.search_entries(
               %{
                 "query" => "case-INSENSITIVE",
                 "conversation" => c.target,
                 "run_id" => "search-run",
                 "kinds" => ["assistant"]
               },
               c.context
             )

    assert {:ok, %{matches: [tool]}} =
             Conversations.search_entries(
               %{
                 "query" => "tool evidence",
                 "conversation" => c.target,
                 "kinds" => ["tool"],
                 "tool_name" => "read",
                 "file_path" => "search_path.EX",
                 "errors_only" => true,
                 "updated_after" => "2026-10-16T17:59:59+08:00"
               },
               c.context
             )

    assert tool.entry_id == "search-tool"
    assert tool.kind == "tool"
    assert tool.status == "error"
    assert tool.tool_name == "read"
    assert tool.file_path == "lib/Search_Path.ex"
    refute Handbean.JSON.encode!(tool) =~ "output-secret"

    assert {:ok, %{matches: [%{entry_id: "search-legacy-error"}]}} =
             Conversations.search_entries(
               %{
                 "query" => "legacy failure evidence",
                 "conversation" => c.target,
                 "errors_only" => true
               },
               c.context
             )

    assert {:ok, %{matches: [%{entry_id: "search-failed-status", status: "error"}]}} =
             Conversations.search_entries(
               %{
                 "query" => "failed status evidence",
                 "conversation" => c.target,
                 "errors_only" => true
               },
               c.context
             )

    assert {:ok, %{matches: []}} =
             Conversations.search_entries(
               %{
                 "query" => "false error evidence",
                 "conversation" => c.target,
                 "errors_only" => true
               },
               c.context
             )

    assert {:ok, %{matches: []}} =
             Conversations.search_entries(
               %{
                 "query" => "non-tool tool-name sentinel",
                 "conversation" => c.target,
                 "tool_name" => "read"
               },
               c.context
             )

    assert {:ok, %{matches: [%{entry_id: "search-unicode-fold", snippet: unicode_snippet}]}} =
             Conversations.search_entries(
               %{"query" => "unicode-fold-anchor", "conversation" => c.target},
               c.context
             )

    assert String.valid?(unicode_snippet)
    assert unicode_snippet =~ "unicode-fold-anchor"

    assert {:ok, %{matches: [string_secret]}} =
             Conversations.search_entries(
               %{"query" => "visible string evidence", "conversation" => c.target},
               c.context
             )

    encoded_string_secret = Handbean.JSON.encode!(string_secret)
    refute encoded_string_secret =~ "sk-abcdefghijklmnopqrstuvwxyz"
    refute encoded_string_secret =~ "hunter2"

    for query <- [
          "secret-only-needle",
          "sk-abcdefghijklmnopqrstuvwxyz",
          "hunter2",
          "streaming sentinel",
          "audit sentinel",
          "arbitrary sentinel"
        ] do
      assert {:ok, %{matches: []}} =
               Conversations.search_entries(
                 %{"query" => query, "conversation" => c.target},
                 c.context
               )
    end

    assert {:ok, %{matches: [%{entry_id: "search-system", kind: "system"}]}} =
             Conversations.search_entries(
               %{"query" => "system evidence", "kinds" => ["system"]},
               c.context
             )

    assert {:ok, %{matches: []}} =
             Conversations.search_entries(%{"query" => "no such evidence"}, c.context)
  end

  test "entry search excludes the invoking run and keeps pagination stable after its tool records settle",
       c do
    for i <- 1..2 do
      assert {:ok, _} =
               ConversationTranscriptStore.append(c.target, %{
                 "id" => "history-page-#{i}",
                 "role" => "assistant",
                 "run_id" => "historical-run",
                 "content" => "self pollution anchor #{i}"
               })
    end

    assert {:ok, _} =
             ConversationTranscriptStore.append(c.source, %{
               "id" => "current-user-query",
               "role" => "user",
               "run_id" => c.context.run_id,
               "content" => "self pollution anchor"
             })

    input = %{"query" => "self pollution anchor", "limit" => 1, "max_chars" => 2_000}

    assert {:ok, %{matches: [first], next_cursor: cursor}} =
             Conversations.search_entries(input, c.context)

    assert first.conversation_id == c.target
    assert is_binary(cursor)

    assert {:ok, _} =
             ConversationTranscriptStore.append(c.source, %{
               "id" => "settled-search-tool",
               "role" => "tool",
               "content_type" => "tool",
               "run_id" => c.context.run_id,
               "tool_name" => "search_conversations",
               "tool_status" => "done",
               "input" => %{"query" => "self pollution anchor"},
               "output" => "self pollution anchor"
             })

    assert {:ok, %{matches: [second], next_cursor: nil, truncated: false}} =
             Conversations.search_entries(Map.put(input, "cursor", cursor), c.context)

    assert second.conversation_id == c.target
    assert first.entry_id != second.entry_id
  end

  test "entry search validates bounds and paginates a revision-bound snapshot", c do
    timestamp = "2026-10-16T10:00:00.000000Z"

    for i <- 1..3 do
      assert {:ok, _} =
               ConversationTranscriptStore.append(c.target, %{
                 "id" => "page-#{i}",
                 "role" => "assistant",
                 "content" => "pagination anchor #{i}",
                 "created_at" => timestamp,
                 "updated_at" => timestamp
               })
    end

    input = %{
      "query" => "pagination anchor",
      "conversation" => c.target,
      "limit" => 1,
      "max_chars" => 2_000
    }

    assert {:ok, %{matches: [first], truncated: true, next_cursor: cursor}} =
             Conversations.search_entries(input, c.context)

    assert is_binary(cursor)

    assert {:ok, %{matches: [second], next_cursor: second_cursor}} =
             Conversations.search_entries(Map.put(input, "cursor", cursor), c.context)

    assert first.entry_id != second.entry_id

    assert {:ok, %{matches: [third], truncated: false, next_cursor: nil}} =
             Conversations.search_entries(Map.put(input, "cursor", second_cursor), c.context)

    assert MapSet.new([first.entry_id, second.entry_id, third.entry_id]) ==
             MapSet.new(~w(page-1 page-2 page-3))

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.search_entries(
               input |> Map.put("kinds", ["assistant"]) |> Map.put("cursor", cursor),
               c.context
             )

    assert {:ok, _} =
             ConversationTranscriptStore.update(c.target, first.entry_id, %{
               "content" => "pagination anchor edited"
             })

    assert {:error, :stale_or_invalid_cursor} =
             Conversations.search_entries(Map.put(input, "cursor", cursor), c.context)

    for invalid <- [
          %{},
          %{"query" => " "},
          %{"query" => "x", "unknown" => true},
          %{"query" => "x", "errors_only" => "true"},
          %{"query" => "x", "archived" => "no"},
          %{"query" => "x", "kinds" => ["assistant", "assistant"]},
          %{"query" => "x", "limit" => 0},
          %{"query" => "x", "max_chars" => 1_999},
          %{"query" => "x", "updated_after" => "not-a-time"},
          %{"query" => String.duplicate("x", 201)}
        ] do
      assert {:error, :invalid_input} = Conversations.search_entries(invalid, c.context)
    end
  end

  test "entry search max_chars pagination does not skip or duplicate fitted matches", c do
    for i <- 1..8 do
      assert {:ok, _} =
               ConversationTranscriptStore.append(c.target, %{
                 "id" => "tight-page-#{i}",
                 "role" => "assistant",
                 "run_id" => String.duplicate("r", 256),
                 "content" => "tight budget anchor #{i} " <> String.duplicate("x", 1_000)
               })
    end

    input = %{
      "query" => "tight budget anchor",
      "conversation" => c.target,
      "limit" => 20,
      "max_chars" => 2_000
    }

    collect_pages = fn collect_pages, page_input, collected ->
      assert {:ok, page} = Conversations.search_entries(page_input, c.context)
      assert String.length(Handbean.JSON.encode!(page)) <= 2_000
      assert page.matches != []
      collected = collected ++ Enum.map(page.matches, & &1.entry_id)

      if page.next_cursor do
        collect_pages.(collect_pages, Map.put(input, "cursor", page.next_cursor), collected)
      else
        refute page.truncated
        collected
      end
    end

    ids = collect_pages.(collect_pages, input, [])
    assert length(ids) == 8
    assert length(Enum.uniq(ids)) == 8
    assert MapSet.new(ids) == MapSet.new(Enum.map(1..8, &"tight-page-#{&1}"))
  end

  test "entry search reports the documented SQL candidate guard", c do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(1..5_001, fn sequence ->
        %{
          conversation_id: c.target,
          entry_id: "guard-#{sequence}",
          sequence: sequence,
          revision: 1,
          role: "assistant",
          content: "guard-candidate",
          payload: %{},
          created_at: now,
          updated_at: now
        }
      end)

    rows
    |> Enum.chunk_every(100)
    |> Enum.each(&Handbean.Repo.insert_all(Handbean.Storage.ConversationEntry, &1))

    assert {:error, :search_too_broad} =
             Conversations.search_entries(
               %{"query" => "guard-candidate", "conversation" => c.target},
               c.context
             )
  end
end
