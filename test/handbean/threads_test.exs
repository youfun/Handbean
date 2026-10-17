defmodule Handbean.ThreadsTest do
  use Handbean.DataCase, async: false
  alias Handbean.Agent.TranscriptPersistence
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Threads}
  alias Handbean.Threads.Collaboration

  setup do
    old = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "threads-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      System.put_env("HOME", old)
      File.rm_rf!(home)
    end)

    {:ok, source} = ConversationStore.create("ws", title: "Source")
    {:ok, target} = ConversationStore.create("ws", title: "目标")
    {:ok, foreign} = ConversationStore.create("other", title: "Secret")
    context = %{conversation_id: source["id"], workspace_id: "ws", run_id: "source-run"}

    %{
      source: source["id"],
      target: target["id"],
      foreign: foreign["id"],
      context: context,
      home: home
    }
  end

  test "metadata-only discovery, authorization and guessed IDs", c do
    {:ok, _} = ConversationStore.update_meta(c.target, visibility: "internal")
    assert {:ok, %{threads: [%{"id" => id}]}} = Threads.list(%{}, c.context)
    assert id == c.source
    assert {:error, :invalid_input} = Threads.find(%{}, c.context)

    for id <- [c.target, c.foreign, "../index", "", nil] do
      assert {:error, :not_accessible} = Threads.read(%{"thread" => id}, c.context)
      assert {:error, :not_accessible} = Threads.status(%{"thread" => id}, c.context)
    end

    assert {:error, :unauthorized} = Threads.list(%{}, %{})
    assert {:error, :unauthorized} = Threads.list(%{}, %{c.context | workspace_id: "other"})
    assert {:error, :invalid_input} = Threads.list(%{"workspace_id" => "other"}, c.context)
    assert {:error, :unauthorized} = Threads.list(%{}, %{c.context | conversation_id: c.target})
  end

  test "same-time pagination binds query, caller and updates", c do
    for id <- [c.source, c.target], do: ConversationStore.update_meta(id, updated_at: "same")
    input = %{"limit" => 1}
    assert {:ok, %{threads: [a], next_cursor: cursor}} = Threads.list(input, c.context)

    assert {:ok, %{threads: [^a], next_cursor: empty_cursor}} =
             Threads.list(Map.put(input, "cursor", ""), c.context)

    assert is_binary(empty_cursor)

    assert {:ok, %{threads: [b], next_cursor: nil}} =
             Threads.list(Map.put(input, "cursor", cursor), c.context)

    assert a["id"] != b["id"]

    assert {:error, :stale_or_invalid_cursor} =
             Threads.list(
               %{"limit" => 1, "archived" => "all", "cursor" => cursor},
               c.context
             )

    ConversationStore.update_meta(c.target, title: "Changed")

    assert {:error, :stale_or_invalid_cursor} =
             Threads.list(Map.put(input, "cursor", cursor), c.context)
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

    assert {:ok, %{threads: listed}} = Threads.list(%{"archived" => "all"}, c.context)
    target = Enum.find(listed, &(&1["id"] == c.target))
    assert target["message_count"] == 2
    assert target["tool_call_count"] == 1
    assert target["run_count"] == 1

    assert {:ok, %{threads: [found]}} =
             Threads.find(%{"query" => "目标", "archived" => "all"}, c.context)

    assert found == target
    assert {:ok, _} = ConversationStore.archive(c.target)
    assert {:ok, %{threads: active}} = Threads.list(%{}, c.context)
    refute Enum.any?(active, &(&1["id"] == c.target))
    assert {:ok, %{threads: archived}} = Threads.list(%{"archived" => "archived"}, c.context)
    assert Enum.any?(archived, &(&1["id"] == c.target))
  end

  test "trajectory exposes durable runs, turns and bounded redacted records", c do
    opts = [run_id: "trajectory-run", model: "provider/model"]

    assert {:ok, _} =
             TranscriptPersistence.append_inbound(c.target, "Investigate", opts)

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:run_start, %{model: "provider/model", loop_owner: :handbean}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(c.target, {:turn_start, %{turn: 1}}, opts)

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:message_delta, %{chunk: "Checking the file"}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:tool_start,
                %{
                  tool_use_id: "trajectory-tool",
                  tool: "read",
                  input: %{"file_path" => "lib/app.ex", "api_key" => "top-secret"}
                }},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:tool_end,
                %{
                  tool_use_id: "trajectory-tool",
                  tool: "read",
                  output: "Authorization: Bearer sub-token-value",
                  duration_ms: 12,
                  started_at: "2026-10-16T10:00:00.000000Z",
                  completed_at: "2026-10-16T10:00:00.012000Z",
                  timing_fidelity: "exact"
                }},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:turn_end,
                %{turn: 1, status: :completed, stop_reason: "completed", duration_ms: 20}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               c.target,
               {:run_end,
                %{
                  status: :completed,
                  turns: 1,
                  duration_ms: 25,
                  model: "provider/model"
                }},
               opts
             )

    assert {:ok, summary} =
             Threads.trajectory(
               %{"thread" => c.target, "detail_level" => "summary", "max_chars" => 16_000},
               c.context
             )

    assert summary.schema_version == 1
    assert summary.detail_level == "summary"
    assert summary.records == []
    assert summary.stats == %{errors: 0, records: 3, running: 0, runs: 1, tools: 1, turns: 1}
    assert [%{id: "trajectory-run", status: "completed", turn_count: 1}] = summary.runs
    assert [%{run_id: "trajectory-run", number: 1, status: "completed"}] = summary.turns
    assert summary.fidelity.level == "complete"

    assert {:ok, compact} =
             Threads.trajectory(
               %{"thread" => c.target, "detail_level" => "compact", "max_chars" => 16_000},
               c.context
             )

    tool = Enum.find(compact.records, &(&1.kind == "tool"))
    assert tool.duration_ms == 12
    assert tool.timing_fidelity == "exact"
    refute Map.has_key?(tool, :input)
    refute Map.has_key?(tool, :output)

    assert {:ok, small_page} =
             Threads.trajectory(
               %{"thread" => c.target, "detail_level" => "compact", "max_chars" => 2_000},
               c.context
             )

    assert small_page.records != []
    assert String.length(Handbean.JSON.encode!(small_page)) <= 2_000

    assert {:ok, full} =
             Threads.trajectory(
               %{"thread" => c.target, "detail_level" => "full", "max_chars" => 16_000},
               c.context
             )

    full_tool = Enum.find(full.records, &(&1.kind == "tool"))
    encoded = Handbean.JSON.encode!(full_tool)
    assert encoded =~ "lib/app.ex"
    refute encoded =~ "top-secret"
    refute encoded =~ "sub-token-value"

    assert {:error, :not_accessible} =
             Threads.trajectory(%{"thread" => c.foreign}, c.context)

    assert {:error, :invalid_input} =
             Threads.trajectory(%{"thread" => c.target, "turn" => 1}, c.context)
  end

  test "trajectory cursor is bound to the durable snapshot", c do
    for i <- 1..3 do
      {:ok, _} =
        ConversationTranscriptStore.append(c.target, %{
          "id" => "trajectory-page-#{i}",
          "role" => "assistant",
          "content" => "record #{i}"
        })
    end

    input = %{
      "thread" => c.target,
      "detail_level" => "compact",
      "limit" => 1,
      "max_chars" => 4_000
    }

    assert {:ok, %{records: [first], next_cursor: cursor, truncated: true}} =
             Threads.trajectory(input, c.context)

    assert is_binary(cursor)

    assert {:ok, %{records: [second]}} =
             Threads.trajectory(Map.put(input, "cursor", cursor), c.context)

    assert first.sequence < second.sequence

    assert {:ok, _} =
             ConversationTranscriptStore.update(c.target, first.id, %{"content" => "changed"})

    assert {:error, :stale_or_invalid_cursor} =
             Threads.trajectory(Map.put(input, "cursor", cursor), c.context)
  end

  test "trajectory redacts run errors and recovers lifecycle rows without streaming entries", c do
    assert :ok =
             ConversationStore.record_run_start(c.target, %{
               run_id: "orphan-run",
               model: "provider/model"
             })

    assert :ok =
             ConversationStore.record_turn_start(c.target, %{
               run_id: "orphan-run",
               turn_number: 1
             })

    assert "orphan-run" in Handbean.ConversationTranscriptStore.ConversationStore.unfinished_runs(
             c.target
           )

    assert :ok =
             ConversationStore.record_run_end(c.target, %{
               run_id: "orphan-run",
               status: :error,
               error: "Authorization: Bearer run-secret-value"
             })

    refute "orphan-run" in Handbean.ConversationTranscriptStore.ConversationStore.unfinished_runs(
             c.target
           )

    assert {:ok, trajectory} =
             Threads.trajectory(
               %{
                 "thread" => c.target,
                 "run_id" => "orphan-run",
                 "detail_level" => "summary",
                 "max_chars" => 4_000
               },
               c.context
             )

    assert [%{status: "error"}] = trajectory.runs
    assert [%{status: "error"}] = trajectory.turns
    refute Handbean.JSON.encode!(trajectory) =~ "run-secret-value"
  end

  test "Unicode and single-message continuation preserve the entire tail", c do
    body = "甲🙂é乙終"

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "stable",
        "role" => "assistant",
        "content" => body,
        "details" => %{secret: "hidden"}
      })

    input = %{"thread" => c.target, "max_chars" => 2}
    {:ok, p1} = Threads.read(input, c.context)
    {:ok, p1_empty} = Threads.read(Map.put(input, "cursor", ""), c.context)
    assert p1_empty.messages == p1.messages
    assert p1_empty.truncated == p1.truncated
    {:ok, p2} = Threads.read(Map.put(input, "cursor", p1_empty.next_cursor), c.context)
    {:ok, p3} = Threads.read(Map.put(input, "cursor", p2.next_cursor), c.context)
    assert Enum.map_join(p1.messages ++ p2.messages ++ p3.messages, & &1["content"]) == body
    assert Enum.map(p1.messages ++ p2.messages ++ p3.messages, & &1["offset"]) == [0, 2, 4]
    assert Enum.all?(p1.messages ++ p2.messages ++ p3.messages, &(&1["id"] == "stable"))
    refute Map.has_key?(hd(p1.messages), "details")
    assert p3.next_cursor == nil

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{"id" => "new", "content" => "append"})

    assert {:error, :stale_or_invalid_cursor} =
             Threads.read(Map.put(input, "cursor", p1.next_cursor), c.context)

    {:ok, fresh} = Threads.read(input, c.context)
    ConversationTranscriptStore.update(c.target, "stable", %{"content" => "edited"})

    assert {:error, :stale_or_invalid_cursor} =
             Threads.read(Map.put(input, "cursor", fresh.next_cursor), c.context)
  end

  test "reads text messages by default and includes tool summaries/outputs when opted in", c do
    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "user-1",
        "role" => "user",
        "content" => "Read app.ex"
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "tool-call-1",
        "role" => "tool",
        "content_type" => "tool",
        "tool_name" => "read",
        "tool_status" => "done",
        "input" => %{"file_path" => "lib/app.ex", "api_key" => "top-secret"},
        "output" => "1: defmodule App\nAuthorization: Bearer sub-token-value"
      })

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "assistant-1",
        "role" => "assistant",
        "content" => "Done"
      })

    assert {:ok, %{messages: text_only}} = Threads.read(%{"thread" => c.target}, c.context)
    assert Enum.map(text_only, & &1["id"]) == ["user-1", "assistant-1"]

    assert {:ok, %{messages: [_, msg, _]}} =
             Threads.read(%{"thread" => c.target, "include_tools" => true}, c.context)

    assert msg["id"] == "tool-call-1"
    assert msg["role"] == "tool"
    assert msg["tool_name"] == "read"
    assert msg["tool_status"] == "done"
    assert msg["content"] =~ "[tool read (done)]"
    assert msg["content"] =~ ~s("file_path":"lib/app.ex")
    assert msg["content"] =~ "1: defmodule App"
    refute msg["content"] =~ "top-secret"
    refute msg["content"] =~ "sub-token-value"

    assert {:error, :invalid_input} =
             Threads.read(%{"thread" => c.target, "include_tools" => "yes"}, c.context)
  end

  test "historical status is idle without inventing success", c do
    assert {:ok, %{state: "idle", current_run: nil, last_result: nil}} =
             Threads.status(%{"thread" => c.target}, c.context)
  end

  test "date filtering normalizes offsets and rejects malformed input", c do
    {:ok, %{threads: []}} =
      Threads.list(%{"updated_after" => "2999-01-01T00:00:00+08:00"}, c.context)

    {:ok, %{threads: threads}} =
      Threads.list(%{"updated_after" => "2000-01-01T00:00:00+08:00"}, c.context)

    assert length(threads) == 2

    assert {:error, :invalid_input} =
             Threads.list(%{"updated_after" => "nonsense"}, c.context)
  end

  test "fragment count bounds empty messages and deletion invalidates continuation", c do
    for i <- 1..51,
        do: ConversationTranscriptStore.append(c.target, %{"id" => "m#{i}", "content" => ""})

    {:ok, page} = Threads.read(%{"thread" => c.target}, c.context)
    assert length(page.messages) == 50
    {:ok, tail} = Threads.read(%{"thread" => c.target, "cursor" => page.next_cursor}, c.context)
    assert [%{"id" => "m51"}] = tail.messages
    assert tail.next_cursor == nil
    ConversationTranscriptStore.delete(c.target, "m1")

    assert {:error, :stale_or_invalid_cursor} =
             Threads.read(%{"thread" => c.target, "cursor" => page.next_cursor}, c.context)
  end

  test "cross-workspace send rejects before persistence; same-workspace send needs no opt-in",
       c do
    input = %{"thread" => c.foreign, "message" => "x", "request_id" => "x"}
    assert {:error, :not_accessible} = Collaboration.send_message(input, c.context)
    assert {:ok, []} = ConversationTranscriptStore.list(c.source)

    assert {:ok, _} = Collaboration.send_message(%{input | "thread" => c.target}, c.context)
  end

  test "concurrent identical sends reserve only once; uncertain delivery is not retried", c do
    input = %{"thread" => c.target, "message" => "Report", "request_id" => "request"}

    results =
      1..8
      |> Task.async_stream(fn _ -> Collaboration.send_message(input, c.context) end)
      |> Enum.to_list()

    assert Enum.all?(results, fn {:ok, {:ok, receipt}} ->
             receipt.delivery == "delivery_unknown"
           end)

    {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert length(entries) == 1
    assert hd(entries)["content"] == "Report"

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(%{input | "message" => "Changed"}, c.context)

    assert {:ok, []} = ConversationTranscriptStore.list(c.target)
  end

  test "a root thread creates any number of read-only children", c do
    input = %{"title" => "Audit", "message" => "Inspect", "request_id" => "child"}
    refute Collaboration.create(input, c.context) == {:error, :delegation_not_permitted}
    {:ok, receipt} = Collaboration.create(input, c.context)
    {:ok, same} = Collaboration.create(input, c.context)
    assert same.thread == receipt.thread
    child_context = %{c.context | conversation_id: receipt.thread}
    refute Collaboration.tool_allowed?("bash", child_context)
    refute Collaboration.tool_allowed?("write", child_context)
    assert Collaboration.tool_allowed?("read", child_context)
    assert Collaboration.tool_allowed?("send_thread_message", child_context)

    ConversationStore.upsert(%{
      "id" => receipt.thread,
      "workspace_id" => "ws",
      "title" => "UI save",
      "timeline" => []
    })

    refute Collaboration.tool_allowed?("write", child_context)

    assert {:error, :invalid_input} =
             Collaboration.reply(
               %{"thread" => c.foreign, "message" => "x", "request_id" => "reply"},
               child_context
             )

    assert {:ok, %{thread: parent}} =
             Collaboration.reply(%{"message" => "Result", "request_id" => "reply"}, child_context)

    assert parent == c.source
    assert {:error, :delegation_not_permitted} = Collaboration.create(input, child_context)

    {:ok, sibling} = Collaboration.create(%{input | "request_id" => "sibling"}, c.context)

    assert {:ok, _} =
             Collaboration.send_message(
               %{
                 "thread" => sibling.thread,
                 "message" => "from sibling",
                 "request_id" => "sib-msg"
               },
               child_context
             )

    for i <- 3..6 do
      assert {:ok, _} = Collaboration.create(%{input | "request_id" => "child#{i}"}, c.context)
    end
  end

  test "handoffs are not capped by count", c do
    for i <- 1..12 do
      assert {:ok, _} =
               Collaboration.send_message(
                 %{"thread" => c.target, "message" => "x", "request_id" => "#{i}"},
                 c.context
               )
    end

    {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert Enum.count(entries, &(&1["content_type"] == "thread_handoff")) == 12
  end

  test "registered tools use executor-owned context and deny writes in delegated runs", c do
    modules = Handbean.Tool.Registry.host_tool_modules()
    names = Enum.map(modules, & &1.name())

    for name <-
          ~w(list_threads find_thread read_thread get_thread_status get_thread_trajectory send_thread_message reply_to_parent_thread create_thread),
        do: assert(name in names)

    Enum.each(modules, &Handbean.Tool.Registry.register/1)

    declared = Handbean.Tool.Registry.tool_defs() |> Enum.map(& &1.name)
    refute "get_thread_trajectory" in declared

    config =
      Handbean.Agent.Config.from_opts(
        conversation_id: c.source,
        workspace_id: "ws",
        working_directory: c.home,
        context: %{thread_run_opts: [forged: true]}
      )

    state = Handbean.Agent.State.init(config, "test")

    assert {:ok, _, [block]} =
             Handbean.Agent.Tool.Executor.execute_all_with_details(
               [%{id: "list", name: "list_threads", input: %{}}],
               state
             )

    refute block.is_error
    assert Jason.decode!(block.content)["threads"] |> length() == 2
    ConversationStore.update_meta(c.source, collaboration: %{"read_only" => true})
    path = Path.join(c.home, "must-not-exist")

    assert {:ok, _, [denied]} =
             Handbean.Agent.Tool.Executor.execute_all_with_details(
               [%{id: "write", name: "write", input: %{"file_path" => path, "content" => "bad"}}],
               state
             )

    assert denied.is_error
    refute File.exists?(path)
  end
end
