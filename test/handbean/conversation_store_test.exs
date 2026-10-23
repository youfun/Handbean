defmodule Handbean.ConversationStoreTest do
  use Handbean.DataCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore}
  alias Handbean.Storage.ConversationRunUsage

  test "channel bindings are generic, projected and immutable" do
    assert {:error, :invalid_channel_binding} =
             ConversationStore.create_free(
               id: "invalid-channel-binding",
               channel_binding: %{channel: "WeChat", label: "微信"}
             )

    assert {:error, :invalid_channel_binding} =
             ConversationStore.create_free(
               id: "missing-channel-binding",
               channel_binding: %{label: "微信"}
             )

    assert {:error, :invalid_channel_binding} =
             ConversationStore.create_free(
               id: "boolean-channel-binding",
               channel_binding: %{channel: true, label: "微信"}
             )

    assert {:error, :invalid_channel_binding} =
             ConversationStore.create_free(
               id: "malformed-channel-binding",
               channel_binding: [{:channel, "weixin"}, :invalid]
             )

    assert {:error, :invalid_channel_binding} =
             ConversationStore.create_free(
               id: "oversized-channel-label",
               channel_binding: %{channel: "weixin", label: String.duplicate("微", 25)}
             )

    assert {:ok, created} =
             ConversationStore.create_free(
               id: "channel-bound",
               channel_binding: %{channel: :weixin, label: " 微信 ", token: "not-projected"}
             )

    expected = %{"channel" => "weixin", "label" => "微信"}
    assert created["channel_binding"] == expected
    assert {:ok, %{"channel_binding" => ^expected}} = ConversationStore.get_summary(created["id"])

    assert {:ok, unbound} = ConversationStore.create_free(id: "channel-unbound")
    assert is_nil(unbound["channel_binding"])

    assert {:ok, %{"channel_binding" => ^expected}} =
             ConversationStore.bind_channel(unbound["id"], channel: "weixin", label: "微信")

    assert {:ok, %{"channel_binding" => ^expected}} =
             ConversationStore.bind_channel(unbound["id"], %{
               "channel" => "weixin",
               "label" => "微信"
             })

    assert {:error, :conversation_already_bound} =
             ConversationStore.bind_channel(unbound["id"], channel: "telegram", label: "Telegram")

    assert {:error, :invalid_channel_binding} =
             ConversationStore.bind_channel(unbound["id"], channel: "telegram", label: "")
  end

  test "concurrent channel binding has one immutable winner" do
    for attempt <- 1..5 do
      id = "concurrent-channel-#{attempt}"
      assert {:ok, _conversation} = ConversationStore.create_free(id: id)
      parent = self()

      tasks =
        for index <- 1..8 do
          Task.async(fn ->
            send(parent, {:channel_binder_ready, self()})

            receive do
              :bind_channel -> :ok
            end

            ConversationStore.bind_channel(id,
              channel: "sns_#{index}",
              label: "SNS #{index}"
            )
          end)
        end

      task_pids =
        for _index <- 1..8 do
          assert_receive {:channel_binder_ready, pid}
          pid
        end

      Enum.each(task_pids, &send(&1, :bind_channel))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, _metadata}, &1)) == 1
      assert Enum.count(results, &match?({:error, :conversation_already_bound}, &1)) == 7

      assert {:ok, %{"channel_binding" => persisted}} = ConversationStore.get_summary(id)
      assert Enum.any?(results, &match?({:ok, %{"channel_binding" => ^persisted}}, &1))
    end
  end

  test "concurrent identical channel bindings are idempotent" do
    assert {:ok, conversation} = ConversationStore.create_free(id: "same-concurrent-channel")
    parent = self()

    tasks =
      for _index <- 1..8 do
        Task.async(fn ->
          send(parent, {:same_channel_binder_ready, self()})

          receive do
            :bind_channel -> :ok
          end

          ConversationStore.bind_channel(conversation["id"], channel: "weixin", label: "微信")
        end)
      end

    task_pids =
      for _index <- 1..8 do
        assert_receive {:same_channel_binder_ready, pid}
        pid
      end

    Enum.each(task_pids, &send(&1, :bind_channel))

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %{"channel_binding" => %{"channel" => "weixin"}}}, Task.await(task))
           end)
  end

  test "metadata and timeline-free lists keep query counts bounded as conversations grow" do
    for scope <- [:workspace, :free] do
      create = fn id ->
        opts = [
          id: id,
          editor_files: [%{"path" => id}],
          active_file: id,
          timeline: [%{"id" => "entry", "content" => "persisted"}]
        ]

        case scope do
          :workspace -> ConversationStore.create("query-workspace", opts)
          :free -> ConversationStore.create_free(opts)
        end
      end

      metadata = fn ->
        case scope do
          :workspace -> ConversationStore.list_metadata("query-workspace")
          :free -> ConversationStore.list_free_metadata()
        end
      end

      detailed = fn ->
        case scope do
          :workspace ->
            ConversationStore.list_for_workspace("query-workspace", include_timeline?: false)

          :free ->
            ConversationStore.list_free(include_timeline?: false)
        end
      end

      {:ok, first} = create.("query-#{scope}-1")
      :ok = ConversationStore.record_run_usage(first["id"], "run", %{"input_tokens" => 3})
      :ok = ConversationStore.add_token_usage(first["id"], %{"input_tokens" => 5})
      :ok = ConversationStore.record_delegated_usage(first["id"], "child", %{"input_tokens" => 7})
      {[_], one_metadata} = count_queries(metadata)
      {[_], one_detailed} = count_queries(detailed)

      for index <- 2..5, do: create.("query-#{scope}-#{index}")

      :ok =
        ConversationStore.record_run_usage("query-#{scope}-2", "run", %{
          "input_tokens" => 11,
          "unknown" => true
        })

      {rows, many_metadata} = count_queries(metadata)
      {details, many_detailed} = count_queries(detailed)

      assert length(rows) == 5
      assert length(details) == 5
      assert many_metadata == one_metadata
      assert many_detailed == one_detailed
      assert many_metadata <= 2
      assert many_detailed <= 3

      for row <- rows do
        assert {:ok, ^row} = ConversationStore.get_metadata(row["id"])
      end

      for detail <- details do
        assert {:ok, ^detail} = ConversationStore.get(detail["id"], include_timeline?: false)
        assert detail["timeline"] == []
      end

      populated = Enum.find(rows, &(&1["id"] == first["id"]))
      assert populated["token_usage"]["input_tokens"] == 8
      assert populated["usage_legacy"]["input_tokens"] == 5
      assert populated["delegated_usage"]["child"]["input_tokens"] == 7
      refute populated["token_usage"]["unknown"]
      second = Enum.find(rows, &(&1["id"] == "query-#{scope}-2"))
      assert second["token_usage"]["input_tokens"] == 11
      assert second["token_usage"]["unknown"]
      assert second["delegated_usage"] == %{}

      {full, sources} =
        query_sources(fn ->
          case scope do
            :workspace -> ConversationStore.list_for_workspace("query-workspace")
            :free -> ConversationStore.list_free()
          end
        end)

      assert length(sources) == 3 + 2 * length(full)
      assert Enum.count(sources, &(&1 == ConversationRunUsage.__schema__(:source))) == 1

      assert Enum.count(
               sources,
               &(&1 == Handbean.Storage.ConversationEditorState.__schema__(:source))
             ) == 1

      assert Enum.map(full, &Map.put(&1, "timeline", [])) == details

      for row <- full,
          do: assert([%{"id" => "entry", "content" => "persisted"}] = row["timeline"])
    end

    assert {all, 3} = count_queries(fn -> ConversationStore.list(include_timeline?: false) end)
    assert length(all) == 10
    assert {full, sources} = query_sources(fn -> ConversationStore.list() end)
    assert length(sources) == 23
    assert Enum.map(full, &Map.put(&1, "timeline", [])) == all
    assert Enum.all?(full, &(length(&1["timeline"]) == 1))
  end

  test "authorization avoids usage queries and detailed reads fetch usage once" do
    {:ok, conversation} = ConversationStore.create_free(id: "query-read")
    assert :ok = ConversationStore.record_run_usage(conversation["id"], "run", %{})

    assert {:ok, 1} =
             count_queries(fn -> ConversationStore.authorize_read(conversation["id"], []) end)

    assert {{:ok, _}, 2} =
             count_queries(fn -> ConversationStore.get_metadata(conversation["id"]) end)

    assert {{:ok, _}, 3} =
             count_queries(fn ->
               ConversationStore.get(conversation["id"], include_timeline?: false)
             end)
  end

  test "summaries recognize persisted custom IDs without widening metadata authorization" do
    ids = ["summary:custom", String.duplicate("x", 129)]

    for id <- ids, visibility <- ["internal", "user"] do
      id = id <> visibility
      assert {:ok, created} = ConversationStore.create_free(id: id, visibility: visibility)
      assert created["id"] == id
      assert ConversationStore.exists?(id)
      assert ConversationStore.internal?(id) == (visibility == "internal")
      assert {:error, :not_found} = ConversationStore.get_metadata(id)

      assert {{:error, :not_found}, 0} =
               count_queries(fn -> ConversationStore.authorize_read(id, []) end)

      assert {{:ok, summary}, 1} = count_queries(fn -> ConversationStore.get_summary(id) end)
      assert summary["id"] == id
      assert summary["visibility"] == visibility
    end

    assert {:error, :not_found} = ConversationStore.authorize_read(nil, [])
  end

  test "single summaries expose internal ancestry but exclude content and inactive rows" do
    {:ok, _} = ConversationStore.create_free(id: "summary-owner")

    {:ok, conversation} =
      ConversationStore.create_free(
        id: "summary-private",
        visibility: "internal",
        parent_conversation_id: "summary-owner",
        parent_run_id: "run",
        parent_tool_call_id: "tool",
        editor_files: [%{"path" => "private.txt"}]
      )

    assert {{:ok, summary}, 1} =
             count_queries(fn -> ConversationStore.get_summary(conversation["id"]) end)

    assert summary["visibility"] == "internal"
    assert summary["parent_conversation_id"] == "summary-owner"
    assert summary["parent_run_id"] == "run"
    assert summary["parent_tool_call_id"] == "tool"

    refute Enum.any?(
             ~w(token_usage run_usage usage_legacy delegated_usage editor_files timeline),
             &Map.has_key?(summary, &1)
           )

    assert {{:error, :not_found}, 1} =
             count_queries(fn -> ConversationStore.get(conversation["id"]) end)

    assert {{:error, :not_found}, 1} =
             count_queries(fn -> ConversationStore.authorize_read(conversation["id"], []) end)

    Repo.update_all(
      from(row in Handbean.Storage.Conversation, where: row.id == ^conversation["id"]),
      set: [status: "pending_delete"]
    )

    assert {:error, :not_found} = ConversationStore.get_summary(conversation["id"])

    for id <- [nil, "../invalid", "missing"],
        do: assert({:error, :not_found} = ConversationStore.get_summary(id))
  end

  test "internal reads retain live parent, run and workspace authorization" do
    {:ok, _} = ConversationStore.create("authorization", id: "authorization-parent")

    {:ok, _} =
      ConversationStore.create("authorization",
        id: "authorization-child",
        visibility: "internal",
        parent_conversation_id: "authorization-parent",
        parent_run_id: "run"
      )

    context = %{
      conversation_id: "authorization-parent",
      run_id: "run",
      workspace_id: "authorization",
      runner_pid: self()
    }

    assert {:error, :not_found} =
             ConversationStore.authorize_read("authorization-child", access_context: context)

    {:ok, _} =
      Registry.register(Handbean.AgentRunRegistry, "authorization-parent", %{
        run_id: "run",
        active?: true
      })

    assert :ok = ConversationStore.authorize_read("authorization-child", access_context: context)

    assert {:ok, _} =
             ConversationStore.get("authorization-child",
               access_context: context,
               include_timeline?: false
             )

    for invalid <- [
          %{context | run_id: "wrong"},
          %{context | workspace_id: "other"},
          %{context | conversation_id: "other"}
        ] do
      assert {:error, :not_found} =
               ConversationStore.authorize_read("authorization-child", access_context: invalid)

      assert {:error, :not_found} =
               ConversationStore.get("authorization-child", access_context: invalid)
    end

    Registry.unregister(Handbean.AgentRunRegistry, "authorization-parent")

    assert {:error, :not_found} =
             ConversationStore.authorize_read("authorization-child", access_context: context)

    assert {:error, :not_found} =
             ConversationStore.get("authorization-child", access_context: context)
  end

  test "timeline-free lists preserve filtering, order, empty usage and missing editor defaults" do
    {:ok, _} = ConversationStore.create("batch-filter", id: "batch-older")
    {:ok, _} = ConversationStore.create("batch-filter", id: "batch-newer")
    {:ok, _} = ConversationStore.create("batch-filter", id: "batch-archived")

    {:ok, _} =
      ConversationStore.create("batch-filter", id: "batch-internal", visibility: "internal")

    {:ok, _} = ConversationStore.archive("batch-archived")

    {:ok, _} =
      ConversationStore.update_meta("batch-older",
        updated_at: "2000-01-01T00:00:00Z",
        touch: false
      )

    {:ok, _} =
      ConversationStore.update_meta("batch-newer",
        updated_at: "2001-01-01T00:00:00Z",
        touch: false
      )

    Repo.delete_all(
      from(state in Handbean.Storage.ConversationEditorState,
        where: state.conversation_id == "batch-older"
      )
    )

    rows = ConversationStore.list_for_workspace("batch-filter", include_timeline?: false)
    assert Enum.map(rows, & &1["id"]) == ["batch-newer", "batch-older"]
    assert List.last(rows)["editor_files"] == []
    assert List.last(rows)["active_file"] == nil
    assert List.last(rows)["token_usage"]["input_tokens"] == 0
    assert List.last(rows)["delegated_usage"] == %{}
    assert Enum.all?(rows, &(&1["timeline"] == []))

    all =
      ConversationStore.list_for_workspace("batch-filter",
        include_timeline?: false,
        include_archived?: true,
        include_internal?: true
      )

    assert Enum.sort(Enum.map(all, & &1["id"])) ==
             ~w(batch-archived batch-internal batch-newer batch-older)

    assert Enum.map(ConversationStore.list(include_timeline?: false), & &1["id"]) ==
             Enum.map(ConversationStore.list_metadata("batch-filter"), & &1["id"])

    assert {[], 1} =
             count_queries(fn ->
               ConversationStore.list_for_workspace("empty-workspace", include_timeline?: false)
             end)
  end

  defp count_queries(operation) do
    {result, sources} = query_sources(operation)
    {result, length(sources)}
  end

  defp query_sources(operation) do
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:handbean, :repo, :query],
        &__MODULE__.record_query/4,
        {self(), ref}
      )

    try do
      result = operation.()
      {result, drain_queries(ref, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def record_query(_event, _measurements, metadata, {caller, ref}) do
    if self() == caller, do: send(caller, {:store_query, ref, metadata.source})
  end

  defp drain_queries(ref, sources) do
    receive do
      {:store_query, ^ref, source} -> drain_queries(ref, [source | sources])
    after
      0 -> Enum.reverse(sources)
    end
  end

  test "creates one conversation with editor state and transcript in a transaction" do
    assert {:ok, conversation} =
             ConversationStore.create("workspace-a",
               id: "conversation-create",
               title: "Stored chat",
               editor_files: [%{"path" => "notes.md", "content" => "hello"}],
               active_file: "notes.md",
               timeline: [%{"id" => "first", "role" => "user", "content" => "hello"}]
             )

    assert conversation["id"] == "conversation-create"
    assert conversation["scope"] == "workspace"
    assert conversation["workspace_id"] == "workspace-a"
    assert conversation["title"] == "Stored chat"
    assert conversation["active_file"] == "notes.md"
    assert [%{"path" => "notes.md"}] = conversation["editor_files"]
    assert [%{"id" => "first", "sequence" => 1}] = conversation["timeline"]
    assert {:ok, _, 0} = DateTime.from_iso8601(conversation["created_at"])
    assert {:ok, _, 0} = DateTime.from_iso8601(conversation["updated_at"])
  end

  test "creation rolls back when an initial entry violates the transcript contract" do
    assert {:error, _reason} =
             ConversationStore.create("workspace-a",
               id: "conversation-rollback",
               timeline: [%{"id" => "duplicate"}, %{"id" => "duplicate"}]
             )

    refute ConversationStore.exists?("conversation-rollback")
  end

  test "lists active user conversations by recency without exposing internal conversations" do
    {:ok, older} = ConversationStore.create("workspace-a", id: "older")
    {:ok, newer} = ConversationStore.create("workspace-a", id: "newer")
    {:ok, archived} = ConversationStore.create("workspace-a", id: "archived")

    {:ok, internal} =
      ConversationStore.create("workspace-a", id: "internal", visibility: "internal")

    {:ok, _} =
      ConversationStore.update_meta(older["id"], updated_at: "2000-01-01T00:00:00Z", touch: false)

    {:ok, _} =
      ConversationStore.update_meta(newer["id"], updated_at: "2001-01-01T00:00:00Z", touch: false)

    {:ok, _} = ConversationStore.archive(archived["id"])

    assert Enum.map(ConversationStore.list_for_workspace("workspace-a"), & &1["id"]) == [
             "newer",
             "older"
           ]

    assert Enum.sort(
             Enum.map(
               ConversationStore.list_for_workspace("workspace-a",
                 include_archived?: true,
                 include_internal?: true
               ),
               & &1["id"]
             )
           ) == Enum.sort([older["id"], newer["id"], archived["id"], internal["id"]])
  end

  test "summaries keep their public projection while detailed metadata retains usage" do
    {:ok, _parent} =
      ConversationStore.create("workspace-a", id: "summary-parent", visibility: "internal")

    {:ok, older} =
      ConversationStore.create("workspace-a",
        id: "summary-older",
        title: "Older",
        parent_conversation_id: "summary-parent",
        parent_run_id: "parent-run",
        parent_tool_call_id: "tool-call"
      )

    {:ok, newer} = ConversationStore.create("workspace-a", id: "summary-newer", title: "Newer")
    {:ok, archived} = ConversationStore.create_free(id: "summary-archived", title: "Archived")

    {:ok, _internal} =
      ConversationStore.create_free(id: "summary-internal", visibility: "internal")

    assert :ok =
             ConversationStore.record_run_usage(older["id"], "run-1", %{
               "input_tokens" => 12,
               "output_tokens" => 3
             })

    assert {:ok, _} = ConversationStore.archive(archived["id"])

    assert {:ok, _} =
             ConversationStore.update_meta(older["id"],
               updated_at: "2000-01-01T00:00:00Z",
               touch: false
             )

    assert {:ok, _} =
             ConversationStore.update_meta(newer["id"],
               updated_at: "2001-01-01T00:00:00Z",
               touch: false
             )

    assert {:ok, summaries} = ConversationStore.fetch_summaries()
    assert Enum.map(summaries, & &1["id"]) == [archived["id"], newer["id"], older["id"]]

    assert Enum.sort(Map.keys(hd(summaries))) ==
             Enum.sort(
               ~w(id visibility parent_conversation_id parent_run_id parent_tool_call_id scope workspace_id checkout_path title title_source channel_binding archived_at pinned_at created_at updated_at)
             )

    assert Enum.map(ConversationStore.list_summaries("workspace-a"), & &1["id"]) == [
             newer["id"],
             older["id"]
           ]

    assert [free_summary] = ConversationStore.list_free_summaries()
    assert free_summary["id"] == archived["id"]
    assert is_binary(free_summary["archived_at"])

    older_summary = Enum.find(summaries, &(&1["id"] == older["id"]))
    assert older_summary["parent_conversation_id"] == "summary-parent"
    assert older_summary["parent_run_id"] == "parent-run"
    assert older_summary["parent_tool_call_id"] == "tool-call"
    refute Map.has_key?(older_summary, "token_usage")

    assert {:ok, metadata} = ConversationStore.get_metadata(older["id"])
    assert metadata["token_usage"]["input_tokens"] == 12
    assert metadata["token_usage"]["output_tokens"] == 3
    assert metadata["run_usage"]["run-1"]["input_tokens"] == 12
  end

  test "legacy collaboration parents are ignored" do
    {:ok, _parent} = ConversationStore.create("workspace-a", id: "legacy-parent")

    {:ok, child} =
      ConversationStore.create("workspace-a",
        id: "legacy-child",
        collaboration: %{"parent" => "legacy-parent", "read_only" => true}
      )

    assert child["parent_conversation_id"] == nil

    assert Enum.find(ConversationStore.list_summaries("workspace-a"), &(&1["id"] == child["id"]))[
             "parent_conversation_id"
           ] == nil

    assert %Handbean.Storage.Conversation{parent_conversation_id: nil} =
             Handbean.Repo.get(Handbean.Storage.Conversation, child["id"])
  end

  test "touch false and assistant writes do not reorder the sidebar; user append does" do
    {:ok, conversation} = ConversationStore.create("workspace-a", id: "recency")
    original = conversation["updated_at"]

    assert {:ok, _} =
             ConversationStore.update_meta(conversation["id"],
               selected_model: "fake",
               touch: false
             )

    assert {:ok, _} =
             ConversationTranscriptStore.append(conversation["id"], %{
               "id" => "assistant",
               "role" => "assistant",
               "content" => "answer"
             })

    assert {:ok, unchanged} = ConversationStore.get(conversation["id"], include_timeline?: false)
    assert unchanged["updated_at"] == original

    assert {:ok, _} =
             ConversationTranscriptStore.append(conversation["id"], %{
               "id" => "user",
               "role" => "user",
               "content" => "question"
             })

    assert {:ok, touched} = ConversationStore.get(conversation["id"], include_timeline?: false)
    assert touched["updated_at"] > original
  end

  test "upsert preserves owned metadata and does not erase an existing transcript with an omitted timeline" do
    {:ok, _parent} = ConversationStore.create("workspace-a", id: "parent")

    {:ok, conversation} =
      ConversationStore.create("workspace-a",
        id: "upsert-owned",
        parent_conversation_id: "parent",
        parent_run_id: "run",
        timeline: [%{"id" => "kept", "content" => "persisted"}]
      )

    assert {:ok, updated} =
             ConversationStore.upsert(%{
               "id" => conversation["id"],
               "scope" => "workspace",
               "workspace_id" => "workspace-a",
               "title" => "Updated",
               "visibility" => "internal",
               "parent_conversation_id" => nil,
               "timeline" => []
             })

    assert updated["title"] == "Updated"
    assert updated["visibility"] == "user"
    assert updated["parent_conversation_id"] == "parent"
    assert updated["parent_run_id"] == "run"
    assert [%{"id" => "kept", "content" => "persisted"}] = updated["timeline"]
  end

  test "editor state round-trips independently and rejects a missing conversation" do
    {:ok, conversation} = ConversationStore.create_free(id: "editor-state")

    assert :ok =
             ConversationStore.save_files(conversation["id"], %{
               "editor_files" => [%{"path" => "a.txt", "content" => "A"}],
               "active_file" => "a.txt",
               "file_preview_error" => %{"code" => "binary"}
             })

    assert %{
             "active_file" => "a.txt",
             "editor_files" => [%{"path" => "a.txt", "content" => "A"}],
             "file_preview_error" => %{"code" => "binary"}
           } = ConversationStore.load_files(conversation["id"])

    assert {:error, :not_found} = ConversationStore.save_files("missing", %{})
  end

  test "run usage is idempotent by source and run while unkeyed usage accumulates" do
    {:ok, conversation} = ConversationStore.create("workspace-a", id: "usage")

    usage = %{
      "input_tokens" => 10,
      "output_tokens" => 2,
      "cache_read_tokens" => 3,
      "cache_write_tokens" => 4
    }

    assert :ok = ConversationStore.record_run_usage(conversation["id"], "run-1", usage)

    assert :ok =
             ConversationStore.record_run_usage(conversation["id"], "run-1", %{
               "input_tokens" => 999
             })

    assert :ok =
             ConversationStore.record_delegated_usage(conversation["id"], "child-1", %{
               "input_tokens" => 7
             })

    assert :ok =
             ConversationStore.add_token_usage(conversation["id"], %{
               "input_tokens" => 4,
               "cache_read_input_tokens" => 2,
               "cache_creation_input_tokens" => 1
             })

    assert :ok =
             ConversationStore.add_token_usage(conversation["id"], %{
               "input_tokens" => 6,
               "cache_read_tokens" => 5,
               "cache_write_tokens" => 2
             })

    assert {:ok, totals} = ConversationStore.get_token_usage(conversation["id"])
    assert totals.input_tokens == 20
    assert totals.output_tokens == 2
    assert totals.cache_read_tokens == 10
    assert totals.cache_write_tokens == 7
    refute totals.usage_incomplete

    assert Enum.any?(
             Handbean.Repo.all(ConversationRunUsage),
             &(&1.source == "parent" and &1.cache_read_tokens == 3 and
                 &1.cache_write_tokens == 4)
           )

    assert ConversationStore.delegated_usage(conversation["id"])["child-1"]["input_tokens"] == 7
  end

  test "usage rebuild atomically replaces parent and unkeyed usage but preserves delegated usage" do
    {:ok, conversation} = ConversationStore.create("workspace-a", id: "usage-rebuild")
    assert :ok = ConversationStore.add_token_usage(conversation["id"], %{"input_tokens" => 40})

    assert :ok =
             ConversationStore.record_delegated_usage(conversation["id"], "child", %{
               "input_tokens" => 9
             })

    events = [
      %{
        kind: :run_end,
        payload: %{
          run_id: "run-a",
          status: :completed,
          usage: %{
            input_tokens: 3,
            cache_read_input_tokens: 7,
            cache_creation_input_tokens: 2
          }
        }
      },
      %{
        kind: :run_end,
        payload: %{run_id: "ignored", status: :interrupted, usage: %{input_tokens: 100}}
      }
    ]

    assert :ok = ConversationStore.rebuild_token_usage_from_events(conversation["id"], events)

    assert {:ok, %{input_tokens: 3, cache_read_tokens: 7, cache_write_tokens: 2}} =
             ConversationStore.get_token_usage(conversation["id"])

    assert ConversationStore.delegated_usage(conversation["id"])["child"]["input_tokens"] == 9
  end

  test "missing conversations return stable not_found results" do
    assert {:error, :not_found} = ConversationStore.get("missing")
    assert {:error, :not_found} = ConversationStore.update_meta("missing", title: "No")
    assert {:error, :not_found} = ConversationStore.append_message("missing", %{"id" => "entry"})
    assert {:error, :not_found} = ConversationStore.replace_messages("missing", [])
  end

  test "workspace creation fails without a resolvable checkout outside the test escape hatch" do
    previous = Application.fetch_env(:handbean, :allow_unbound_test_conversations)
    Application.delete_env(:handbean, :allow_unbound_test_conversations)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:handbean, :allow_unbound_test_conversations, value)
        :error -> Application.delete_env(:handbean, :allow_unbound_test_conversations)
      end
    end)

    assert {:error, {:invalid_checkout_path, :not_found}} =
             ConversationStore.create("unknown-workspace", id: "strict-checkout")

    refute ConversationStore.exists?("strict-checkout")
  end

  test "workspace checkout is canonical, exposed in summaries, and immutable" do
    root =
      Path.join(System.tmp_dir!(), "conversation-checkout-#{System.unique_integer([:positive])}")

    other = root <> "-other"
    File.mkdir_p!(root)
    File.mkdir_p!(other)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(other)
    end)

    assert {:ok, conversation} =
             ConversationStore.create("workspace-a", id: "checkout", checkout_path: root)

    expected = Handbean.Security.PathValidator.resolve_symlink(root)
    assert conversation["checkout_path"] == expected
    assert {:ok, ^expected} = ConversationStore.effective_checkout_path(conversation)

    assert Enum.find(ConversationStore.list_summaries("workspace-a"), &(&1["id"] == "checkout"))[
             "checkout_path"
           ] == conversation["checkout_path"]

    assert {:ok, _metadata} =
             ConversationStore.update_meta("checkout", checkout_path: other, title: "Still here")

    assert {:ok, unchanged} = ConversationStore.get_metadata("checkout")
    assert unchanged["checkout_path"] == conversation["checkout_path"]

    assert {:ok, upserted} =
             ConversationStore.upsert(%{
               "id" => "checkout",
               "scope" => "workspace",
               "workspace_id" => "workspace-a",
               "checkout_path" => other,
               "title" => "Upserted"
             })

    assert upserted["checkout_path"] == conversation["checkout_path"]
  end

  test "free chats have no checkout and missing checkouts never fall back" do
    assert {:ok, free} = ConversationStore.create_free(id: "free-checkout")
    assert free["checkout_path"] == nil
    assert {:error, :checkout_path_missing} = ConversationStore.effective_checkout_path(free)

    root = Path.join(System.tmp_dir!(), "deleted-checkout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    assert {:ok, conversation} =
             ConversationStore.create("workspace-a", id: "deleted-checkout", checkout_path: root)

    File.rm_rf!(root)

    assert {:error, :checkout_unavailable} =
             ConversationStore.effective_checkout_path(conversation)
  end

  test "ensure_for_workspaces creates only missing conversations" do
    {:ok, existing} = ConversationStore.create("workspace-a", id: "existing")
    workspaces = [%{"id" => "workspace-a"}, %{"id" => "workspace-b"}]

    result = ConversationStore.ensure_for_workspaces(workspaces)
    assert Enum.map(result["workspace-a"], & &1["id"]) == [existing["id"]]
    assert [%{"workspace_id" => "workspace-b"}] = result["workspace-b"]
    assert length(ConversationStore.list_for_workspace("workspace-b")) == 1
  end
end
