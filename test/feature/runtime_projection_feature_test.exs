defmodule HandbeanWeb.Feature.RuntimeProjectionFeatureTest do
  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection

  defmodule UnavailableHistory do
    def page(_id, _opts), do: {:error, :unavailable}
  end

  setup do
    %{workspace: workspace} = E2EHarness.isolate_home!("projection-feature")
    E2EHarness.use_fake_provider!(:simple_answer)
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]
    on_exit(fn -> E2EHarness.cancel!(id) end)

    owner = self()

    opts = [
      workspace_path: workspace,
      model: "fake",
      source: :web,
      tools: [],
      middleware: [],
      provider: Handbean.TestSupport.ProjectionProvider,
      provider_config: %{notify: owner},
      streaming: true,
      on_event: fn
        {:message_delta, %{chunk: chunk}} when is_binary(chunk) ->
          if String.ends_with?(chunk, " stream"),
            do: send(owner, :projected_suffix_persisted),
            else: :ok

        _event ->
          :ok
      end
    ]

    {:ok, %{run_id: run_id}} = Coordinator.add_message(id, "stream once", opts)
    assert_receive {:projected_stream, provider}, 5_000
    assert_receive :projected_suffix_persisted, 5_000
    %{id: id, run_id: run_id, provider: provider}
  end

  test "completed assistant stays final when an active run is restored", ctx do
    assistant =
      ctx.id
      |> E2EHarness.transcript()
      |> Enum.find(&(&1["role"] == "assistant"))

    assert assistant["status"] == "streaming"

    {:ok, _entry} =
      ConversationTranscriptStore.update(ctx.id, assistant["id"], %{"status" => "completed"})

    {:ok, _entry} =
      ConversationTranscriptStore.append(ctx.id, %{
        "id" => "tool-after-completed-assistant",
        "content_type" => "tool",
        "role" => "tool",
        "run_id" => ctx.run_id,
        "tool_name" => "read",
        "tool_status" => "done"
      })

    completed_assistant = Map.put(assistant, "status", "completed")
    assert RuntimeProjection.assistant_final?(completed_assistant, true, assistant["id"])
    refute RuntimeProjection.assistant_streaming?(completed_assistant, true, assistant["id"])

    ctx.conn
    |> visit("/w/default/c/#{ctx.id}")
    |> unwrap(fn view ->
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.running
      assert assigns.current_assistant_entry_id == nil

      rendered = Phoenix.LiveViewTest.render(view)
      assert rendered =~ ~s(data-entry-id="#{assistant["id"]}")
      assert rendered =~ ~s(data-final="true")
      assert rendered =~ ~s(data-streaming="false")
      rendered
    end)

    send(ctx.provider, :finish)
  end

  test "active-run recovery combines settled history with replayed run usage", ctx do
    :ok =
      Handbean.ConversationStore.record_run_usage(ctx.id, "historical-run", %{
        input_tokens: 100,
        output_tokens: 40,
        cache_read_input_tokens: 200,
        cache_creation_input_tokens: 100,
        total_input_tokens: 400
      })

    :ok =
      Handbean.ConversationStore.record_run_usage(ctx.id, ctx.run_id, %{
        input_tokens: 50,
        output_tokens: 10,
        cache_read_input_tokens: 300,
        cache_creation_input_tokens: 150,
        total_input_tokens: 500
      })

    Session.broadcast_event(ctx.id, :usage_updated, %{
      run_id: ctx.run_id,
      usage: %{
        input_tokens: 50,
        output_tokens: 10,
        cache_read_input_tokens: 300,
        cache_creation_input_tokens: 150,
        total_input_tokens: 500
      }
    })

    # Evict both run_start and usage_updated from the bounded control snapshot.
    # Recovery must use the independently retained latest usage for this run.
    for index <- 1..505 do
      Session.broadcast_event(ctx.id, :session_state, %{
        run_id: ctx.run_id,
        state: "checkpoint-#{index}"
      })
    end

    bounded_snapshot = Session.snapshot(ctx.id)
    refute Enum.any?(bounded_snapshot.control_events, &(&1.kind == :run_start))
    refute Enum.any?(bounded_snapshot.control_events, &(&1.kind == :usage_updated))

    snapshot = Session.recovery_snapshot(ctx.id)
    refute Enum.any?(snapshot.control_events, &(&1.kind == :run_start))
    assert Enum.any?(snapshot.control_events, &(&1.kind == :usage_updated))

    ctx.conn
    |> visit("/w/default/c/#{ctx.id}")
    |> unwrap(fn view ->
      assert Phoenix.LiveViewTest.has_element?(view, "#status-input-tokens", "150")
      assert Phoenix.LiveViewTest.has_element?(view, "#status-output-tokens", "50")
      assert Phoenix.LiveViewTest.has_element?(view, "#status-cache-hit-rate", "55.6%")
      Phoenix.LiveViewTest.render(view)
    end)

    send(ctx.provider, :finish)
  end

  test "idle recovery replaces stale running usage with persisted totals", ctx do
    page = visit(ctx.conn, "/w/default/c/#{ctx.id}")

    page
    |> unwrap(fn view ->
      send(self(), {:stale_socket, :sys.get_state(view.pid).socket})
      Phoenix.LiveViewTest.render(view)
    end)

    assert_receive {:stale_socket, stale_socket}
    assert stale_socket.assigns.running

    :ok = Session.subscribe(ctx.id)
    send(ctx.provider, :finish)
    assert %{status: :completed} = E2EHarness.await_run_end(ctx.id)

    assert {:ok, persisted} = Handbean.ConversationStore.get_token_usage(ctx.id)
    recovered = RuntimeProjection.restore_active_session(stale_socket)

    refute recovered.assigns.running
    assert recovered.assigns.status_info.input_tokens == persisted.input_tokens
    assert recovered.assigns.status_info.output_tokens == persisted.output_tokens
    assert recovered.assigns.status_info.total_input_tokens == persisted.total_input_tokens
    assert recovered.assigns.run_usage_baseline.run_id == nil
    assert recovered.assigns.run_usage_baseline.usage == persisted
  end

  test "session restart recovers a lower seq without losing the active run", ctx do
    page = visit(ctx.conn, "/w/default/c/#{ctx.id}")
    previous = Session.snapshot(ctx.id)
    :ok = Handbean.SessionSupervisor.stop_session(ctx.id)
    {:ok, _} = Session.start_or_get(session_id: ctx.id, session_store_enabled?: false)
    restarted = Session.snapshot(ctx.id)
    assert restarted.last_seq < previous.last_seq
    assert restarted.meta.run_id == ctx.run_id

    Session.broadcast_event(ctx.id, :thinking_delta, %{run_id: ctx.run_id})
    checkpoint = Session.snapshot(ctx.id)

    page
    |> unwrap(fn view ->
      Phoenix.LiveViewTest.render(view)
      assert :sys.get_state(view.pid).socket.assigns.session_seq == checkpoint.last_seq
      assert :sys.get_state(view.pid).socket.assigns.session_epoch == checkpoint.epoch
      Phoenix.LiveViewTest.render(view)
    end)
    |> assert_has(".msg-bubble.msg-assistant", "Hello from stream", count: 1)

    send(ctx.provider, :finish)
  end

  test "failed prefix recovery retains the last acknowledged checkpoint and text", ctx do
    page = visit(ctx.conn, "/w/default/c/#{ctx.id}")
    snapshot = Session.snapshot(ctx.id)
    delta = Enum.find(snapshot.events, &(&1.kind == :message_delta))
    previous_store = Application.get_env(:handbean, :conversation_transcript_store)

    try do
      Application.put_env(:handbean, :conversation_transcript_store, UnavailableHistory)

      page
      |> unwrap(fn view ->
        gap = %{
          delta
          | seq: snapshot.last_seq + 1,
            payload: %{transcript_id: "missing-prefix", text_offset: 20, text: "suffix"}
        }

        send(view.pid, {:agent_event, gap})
        Phoenix.LiveViewTest.render(view)
        assert :sys.get_state(view.pid).socket.assigns.session_seq == snapshot.last_seq
        Phoenix.LiveViewTest.render(view)
      end)
      |> assert_has(".msg-bubble.msg-assistant", "Hello from stream", count: 1)
      |> refute_has("#ai-messages", "suffix")
    after
      if previous_store,
        do: Application.put_env(:handbean, :conversation_transcript_store, previous_store),
        else: Application.delete_env(:handbean, :conversation_transcript_store)

      send(ctx.provider, :finish)
    end
  end

  test "streaming deltas do not evict active approval or tool controls on reconnect", ctx do
    for index <- 1..5 do
      tool_use_id = "completed-#{index}"

      Session.broadcast_event(ctx.id, :tool_start, %{
        run_id: ctx.run_id,
        tool: "read",
        tool_use_id: tool_use_id,
        input: %{}
      })

      Session.broadcast_event(ctx.id, :tool_end, %{
        run_id: ctx.run_id,
        tool: "read",
        tool_use_id: tool_use_id,
        output: "done"
      })
    end

    Session.broadcast_event(ctx.id, :tool_start, %{
      run_id: ctx.run_id,
      tool: "read",
      tool_use_id: "in-flight",
      input: %{}
    })

    Session.broadcast_event(ctx.id, :tool_approval_requested, %{
      run_id: ctx.run_id,
      action_requests: [%{tool_call_id: "approval", tool_name: "read", args: %{}}]
    })

    for _ <- 1..550, do: Session.broadcast_event(ctx.id, :thinking_delta, %{run_id: ctx.run_id})
    snapshot = Session.snapshot(ctx.id)
    refute Enum.any?(snapshot.events, &(&1.kind == :tool_approval_requested))

    ctx.conn
    |> visit("/w/default/c/#{ctx.id}")
    |> unwrap(fn view ->
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.pending_approval != nil
      assert assigns.tools_active["read"] == :running
      assert Enum.any?(assigns.timeline, &(&1["tool_use_id"] == "in-flight"))

      refute Enum.any?(
               assigns.timeline,
               &String.starts_with?(&1["tool_use_id"] || "", "completed-")
             )

      assert assigns.session_seq == snapshot.last_seq
      Phoenix.LiveViewTest.render(view)
    end)
    |> assert_has(".msg-bubble.msg-assistant", "Hello from stream", count: 1)

    send(ctx.provider, :finish)
  end

  test "reconnect and seq gap restore durable text once, and reject queued stale events",
       %{conn: conn, id: id, run_id: run_id, provider: provider} do
    page =
      conn
      |> visit("/w/default/c/#{id}")
      |> assert_has(".msg-bubble.msg-assistant", "Hello from stream", count: 1)
      |> refute_has(".msg-bubble.msg-assistant", "Hello from streamHello")

    snapshot = Session.snapshot(id)
    [delta | _] = Enum.filter(snapshot.events, &(&1.kind == :message_delta))

    page =
      page
      |> unwrap(fn view ->
        send(view.pid, {:agent_event, delta})
        Phoenix.LiveViewTest.render(view)
      end)
      |> assert_has(".msg-bubble.msg-assistant", "Hello from stream", count: 1)

    # Simulate lost control events. The gap must reload the checkpoint/history,
    # not concatenate the gap event or fabricate text from it.
    page =
      page
      |> unwrap(fn view ->
        gap = %{
          delta
          | seq: snapshot.last_seq + 3,
            payload: %{
              run_id: run_id,
              transcript_id: delta.payload.transcript_id,
              text_offset: 0,
              text: "must not appear"
            }
        }

        send(view.pid, {:agent_event, gap})
        Phoenix.LiveViewTest.render(view)
      end)
      |> refute_has("#ai-messages", "must not appear")
      |> assert_has(".msg-bubble.msg-assistant", "Hello from stream", count: 1)

    _ = page

    conn
    |> visit("/w/default/c/#{id}")
    |> assert_has(".msg-bubble.msg-assistant", "Hello from stream", count: 1)

    :ok = Session.subscribe(id)
    send(provider, :finish)
    assert E2EHarness.await_run_end(id)[:status] == :completed

    assert [%{"content" => "Hello from stream"}] =
             Enum.filter(E2EHarness.transcript(id), &(&1["role"] == "assistant"))
  end
end
