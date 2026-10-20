defmodule HandbeanWeb.WorkspaceLive.SendMessageQueueAndUploadTest do
  use HandbeanWeb.WorkspaceLiveCase

  describe "send_message" do
    test "tool_events remain visible on new message send", %{conn: conn} do
      configure_test_models!()

      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        sid = create_default_conversation(view)
        {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
        {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
        :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
        topic = "session:#{sid}"

        send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, topic)})

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{tool: "read", input: %{file_path: "test.txt"}},
             2,
             topic
           )}
        )

        send(
          view.pid,
          {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 25}, 3, topic)}
        )

        assert has_element?(view, "#tool-event-read")
        send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed"}, 4, topic)})

        view
        |> element("form")
        |> render_submit(%{"message" => "New message", "model" => "stepfun/step-router-v1"})

        assert has_element?(view, "#tool-event-read")
        assert render(view) =~ "New message"
      end)
    end

    test "running submit enqueues candidate instead of clearing active tool state", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.txt"}}, 2, topic)}
      )

      assert has_element?(view, "#tool-event-read")

      view
      |> element("form")
      |> render_submit(%{"message" => "please adjust", "model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#tool-event-read")
      assert render(view) =~ "please adjust"

      assert [%Handbean.Agent.Message{role: :user, content: "please adjust"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)

      assert [] = Handbean.Agent.CandidateQueue.drain_follow_up(queue)
    end

    test "queued follow-up can be sent immediately", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("#queue-button")
      |> render_click(%{
        "message" => "when finished",
        "model" => "stepfun/step-router-v1"
      })

      assert render(view) =~ "when finished"
      assert render(view) =~ "Queued"
      assert has_element?(view, "button[phx-click='send_pending_now']", "Send now")

      assert [%{message: %{content: "when finished"}, metadata: %{deliver_as: :follow_up}}] =
               Handbean.Agent.CandidateQueue.get_messages(queue)

      view
      |> element("button[phx-click='send_pending_now']")
      |> render_click()

      refute has_element?(view, "button[phx-click='send_pending_now']")
      assert render(view) =~ "Waiting to insert"

      assert [%Handbean.Agent.Message{role: :user, content: "when finished"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)

      assert [] = Handbean.Agent.CandidateQueue.drain_follow_up(queue)
    end

    test "undo queued follow-up removes it so a second queue is not duplicated", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("#queue-button")
      |> render_click(%{
        "message" => "确认部署",
        "model" => "stepfun/step-router-v1"
      })

      assert render(view) =~ "确认部署"
      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [old_id] = Map.keys(pending)

      view
      |> element("button[phx-click='cancel_pending']")
      |> render_click()

      timeline = :sys.get_state(view.pid).socket.assigns.timeline
      refute Enum.any?(timeline, &(&1["id"] == old_id))
      refute Enum.any?(timeline, &(&1["content"] == "确认部署"))

      view
      |> element("#queue-button")
      |> render_click(%{
        "message" => "确认部署",
        "model" => "stepfun/step-router-v1"
      })

      timeline = :sys.get_state(view.pid).socket.assigns.timeline
      queued = Enum.filter(timeline, &(&1["content"] == "确认部署"))
      assert length(queued) == 1
      html = render(view)
      assert html =~ "Queued"
      assert html =~ "确认部署"

      _ = queue
    end

    test "queued follow-up stays last while the turn continues, then after inject", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("#queue-button")
      |> render_click(%{
        "message" => "after this turn",
        "model" => "stepfun/step-router-v1"
      })

      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [msg_id] = Map.keys(pending)

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "later.txt"}}, 2, topic)}
      )

      html = render(view)
      assert html =~ "after this turn"
      assert html =~ "Queued"
      timeline_ids = Enum.map(:sys.get_state(view.pid).socket.assigns.timeline, & &1["id"])
      assert List.last(timeline_ids) == msg_id
      assert Enum.find_index(timeline_ids, &(&1 == msg_id)) > 0

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :candidate_message_injected,
           %{message_ids: [msg_id], count: 1, deliver_as: :follow_up},
           3,
           topic
         )}
      )

      _ = render(view)
      timeline_ids = Enum.map(:sys.get_state(view.pid).socket.assigns.timeline, & &1["id"])
      assert List.last(timeline_ids) == msg_id
      refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.pending_messages, msg_id)

      _ = queue
    end

    test "idle queue_message starts a new run instead of erroring", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      _sid = create_default_conversation(view)

      render_click(view, "queue_message", %{
        "message" => "idle queue becomes a run",
        "model" => "stepfun/step-router-v1"
      })

      html = render(view)
      assert html =~ "idle queue becomes a run"
      refute html =~ "no longer accepting"
    end

    test "running submit records pending, undo restores draft, terminal run_end marks undelivered",
         %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("form")
      |> render_submit(%{"message" => "steer pending", "model" => "stepfun/step-router-v1"})

      assert render(view) =~ "Waiting to insert"
      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [msg_id] = Map.keys(pending)

      view
      |> element("button[phx-click='cancel_pending']")
      |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.input_value =~ "steer pending"
      assert Handbean.Agent.CandidateQueue.get_messages(queue) == []

      view
      |> element("form")
      |> render_submit(%{"message" => "left behind", "model" => "stepfun/step-router-v1"})

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_end, %{status: "cancelled"})
      # Wait for the asynchronous terminal event before checking its rendered result.
      _snapshot = Handbean.PubSub.Session.snapshot(sid)

      html = render(view)
      assert html =~ "Not delivered"

      _ = msg_id
    end

    test "resend_pending keeps composer draft and pending attachments, and ignores a second click",
         %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("form")
      |> render_submit(%{"message" => "retry later", "model" => "stepfun/step-router-v1"})

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_end, %{status: "cancelled"})

      assert render(view) =~ "Not delivered"
      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [old_id] = Map.keys(pending)

      render_keyup(view, "update_input", %{"value" => "keep draft"})

      keep_att = %{"id" => "keep-web", "filename" => "keep.png"}

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{state | socket: Phoenix.Component.assign(socket, :pending_attachments, [keep_att])}
      end)

      view
      |> element("button[phx-click='resend_pending']")
      |> render_click(%{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "keep draft"
      assert assigns.pending_attachments == [keep_att]
      refute Map.has_key?(assigns.pending_messages, old_id)

      queued = Handbean.Agent.CandidateQueue.get_messages(queue)
      assert Enum.any?(queued, &(&1.message.content == "retry later"))
      queue_count = length(queued)

      render_click(view, "resend_pending", %{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "keep draft"
      assert length(Handbean.Agent.CandidateQueue.get_messages(queue)) == queue_count
    end

    test "delete_undelivered removes the durable message without restoring the draft", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("form")
      |> render_submit(%{"message" => "delete me", "model" => "stepfun/step-router-v1"})

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_end, %{status: "cancelled"})

      assert render(view) =~ "Not delivered"
      [message_id] = Map.keys(:sys.get_state(view.pid).socket.assigns.pending_messages)
      render_keyup(view, "update_input", %{"value" => "keep this draft"})

      assert has_element?(view, "button[phx-click='delete_undelivered']", "Delete")

      view
      |> element("button[phx-click='delete_undelivered']")
      |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "keep this draft"
      refute Map.has_key?(assigns.pending_messages, message_id)
      refute Enum.any?(assigns.timeline, &(&1["id"] == message_id))
      refute render(view) =~ "delete me"
      assert {:ok, entries} = Handbean.ConversationTranscriptStore.list(sid)
      refute Enum.any?(entries, &(&1["id"] == message_id))

      _ = queue
    end

    test "resend_pending keeps the undelivered item when send fails", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("form")
      |> render_submit(%{"message" => "cannot resend", "model" => "stepfun/step-router-v1"})

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_end, %{status: "cancelled"})

      assert render(view) =~ "Not delivered"
      [old_id] = Map.keys(:sys.get_state(view.pid).socket.assigns.pending_messages)

      too_many =
        for i <- 1..5 do
          %{"id" => "att-#{i}", "filename" => "#{i}.png"}
        end

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        pending = socket.assigns.pending_messages

        pending =
          Map.update!(pending, old_id, fn item ->
            Map.put(item, :attachments, too_many)
          end)

        %{state | socket: Phoenix.Component.assign(socket, :pending_messages, pending)}
      end)

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("button[phx-click='resend_pending']")
      |> render_click(%{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.pending_messages[old_id].status == :undelivered
      assert assigns.composer_error == "At most 4 attachments per message."
    end

    test "reload hydrates queued attachments from transcript and undo restores them", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      mid = "msg-hyd-#{System.unique_integer([:positive])}"
      atts = [%{"id" => "att-w", "filename" => "pic.png", "kind" => "image"}]

      {:ok, _} =
        Handbean.ConversationTranscriptStore.append(sid, %{
          "id" => mid,
          "role" => "user",
          "content_type" => "user_msg",
          "content" => "with picture",
          "attachments" => atts
        })

      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.enqueue_candidate(sid, "with picture", message_id: mid)

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("#conversation-#{sid} button[phx-click='select_conversation']")
      |> render_click()

      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      assert pending[mid].content == "with picture"
      assert hd(pending[mid].attachments)["id"] == "att-w"
      assert hd(pending[mid].attachments)["filename"] == "pic.png"

      view
      |> element("button[phx-click='cancel_pending']")
      |> render_click(%{"id" => mid})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value =~ "with picture"
      assert Enum.any?(assigns.pending_attachments, &(&1["filename"] == "pic.png"))
      assert Handbean.Agent.CandidateQueue.get_messages(queue) == []
    end

    test "running steer button click enqueues candidate", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      assert has_element?(view, "#status-label", "running")

      view
      |> element("form")
      |> render_submit(%{
        "message" => "please adjust by click",
        "model" => "stepfun/step-router-v1"
      })

      assert render(view) =~ "please adjust by click"

      assert [%Handbean.Agent.Message{role: :user, content: "please adjust by click"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)
    end

    test "UI running with idle coordinator starts a new run instead of stale error", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-stale-running",
          title: "Stale running"
        )

      sid = conversation["id"]

      on_exit(fn ->
        _ = Handbean.Agent.Coordinator.cancel(sid)

        case Registry.lookup(Handbean.AgentRunRegistry, sid) do
          [{pid, _value}] ->
            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

          [] ->
            :ok
        end
      end)

      {:ok, view, _html} = live(conn, "/w/default/c/#{sid}")
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      assert has_element?(view, "#status-label", "running")

      view
      |> element("form")
      |> render_submit(%{"message" => "start again", "model" => "stepfun/step-router-v1"})

      rendered = render(view)
      refute rendered =~ "The previous run is no longer accepting input"
      assert rendered =~ "start again"

      assert Enum.any?(
               Handbean.ConversationStore.load_messages(sid),
               &(&1["content"] == "start again")
             )
    end

    test "turn_start restores working indicator when a later provider turn is active", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:message_delta, %{chunk: "working"}, 2, topic)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "completed"}, 3, topic)}
      )

      refute has_element?(view, "#agent-working")

      send(
        view.pid,
        {:agent_event, agent_event(:turn_start, %{turn: 8}, 4, topic)}
      )

      assert has_element?(view, "#agent-working")
      assert has_element?(view, "#status-label", "running")
    end

    test "sending a message with an uploaded image renders attachments in the timeline", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{path: png_path, name: "x.png", type: "image/png", content: File.read!(png_path)}
        ])

      render_upload(upload, "x.png")

      view |> element("form") |> render_submit(%{"message" => "see image"})
      rendered = render(view)

      assert rendered =~ "see image"
      assert rendered =~ "/uploads/"
      assert rendered =~ "msg-shot"
      assert rendered =~ "data-shot-open"
    end

    test "completed uploaded image renders a composer attachment preview before send", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{path: png_path, name: "preview.png", type: "image/png", content: File.read!(png_path)}
        ])

      render_upload(upload, "preview.png")

      assert has_element?(view, "#composer-attachments")
      assert has_element?(view, "#composer-attachments span.sr-only", "preview.png")
      assert has_element?(view, "#composer-attachments button[phx-click='cancel_upload']")
      assert render(view) =~ "preview.png"

      view
      |> element("#composer-attachments button[phx-click='cancel_upload']")
      |> render_click()

      refute has_element?(view, "#composer-attachments span.sr-only", "preview.png")
      refute has_element?(view, "#composer-attachments button[phx-click='cancel_upload']")
    end

    test "pending composer attachment can be removed from the thumbnail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{
          state
          | socket:
              Phoenix.Component.assign(socket, :pending_attachments, [
                %{"id" => "keep-web", "filename" => "keep.png", "url" => "/uploads/keep.png"}
              ])
        }
      end)

      render_click(view, "clear_composer_error", %{})
      assert has_element?(view, "#composer-attachments button[phx-click='remove_attachment']")

      view
      |> element("#composer-attachments button[phx-click='remove_attachment']")
      |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.pending_attachments == []
      refute has_element?(view, "#composer-attachments button[phx-click='remove_attachment']")
    end

    test "sent image uses persistable string-key fields for timeline urls", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{
            path: png_path,
            name: "string-key.png",
            type: "image/png",
            content: File.read!(png_path)
          }
        ])

      render_upload(upload, "string-key.png")
      view |> element("form") |> render_submit(%{"message" => "string keys"})
      html = render(view)
      assert html =~ "string keys"
      assert html =~ "/uploads/"
      assert html =~ "string-key.png" or html =~ "alt="
    end

    test "upload plus button wraps the live file input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".composer-icon-btn input[type='file']")
    end
  end
end
