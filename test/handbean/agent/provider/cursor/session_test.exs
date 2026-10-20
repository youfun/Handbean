defmodule Handbean.Agent.Provider.Cursor.SessionTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Cursor
  alias Handbean.Agent.Provider.Cursor.Session

  defmodule FakeTransport do
    def connect(_opts) do
      case :persistent_term.get({__MODULE__, :connect}, :ok) do
        {:error, reason} ->
          {:error, reason}

        _ ->
          {:ok,
           %{
             open?: true,
             sent: [],
             sent_count: 0,
             window: 65_535,
             pause: :persistent_term.get({__MODULE__, :pause}, nil)
           }}
      end
    end

    def open_run(transport, _token, _opts), do: {:ok, transport}

    def send_message(transport, payload, _opts \\ []) do
      sent_count = transport.sent_count + 1
      transport = %{transport | sent_count: sent_count}
      notify({:cursor_transport, :sent, self()})

      if :persistent_term.get({__MODULE__, :fail_on_send}, nil) == sent_count do
        {:error, transport, :injected_send_failure}
      else
        {:ok, Map.update(transport, :sent, [payload], &[payload | &1])}
      end
    end

    def handle_mint(transport, {:cursor_frames, frames}) do
      pause_if_needed(transport)
      {:ok, transport, frames}
    end

    def handle_mint(transport, _other) do
      pause_if_needed(transport)
      {:ok, transport, []}
    end

    def cancel(transport) do
      notify({:cursor_transport, :cancelled, self()})
      Map.put(transport, :open?, false)
    end

    def close(transport), do: Map.put(transport, :open?, false)

    defp pause_if_needed(%{pause: pid}) when is_pid(pid) do
      send(pid, {:mint_paused, self()})

      receive do
        :continue -> :ok
      after
        2_000 -> :ok
      end
    end

    defp pause_if_needed(_), do: :ok

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :notify}, nil) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end
  end

  setup do
    unless Process.whereis(Handbean.CursorSessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: Handbean.CursorSessionRegistry})
    end

    unless Process.whereis(Handbean.Agent.Provider.Cursor.Supervisor) do
      start_supervised!(
        {DynamicSupervisor,
         name: Handbean.Agent.Provider.Cursor.Supervisor, strategy: :one_for_one}
      )
    end

    :persistent_term.put({FakeTransport, :connect}, :ok)
    :persistent_term.put({FakeTransport, :fail_on_send}, nil)
    :persistent_term.put({FakeTransport, :pause}, nil)
    :persistent_term.put({FakeTransport, :notify}, self())
    flush_transport_notifies()
    :ok
  end

  test "one mint batch with two MCP execs is delivered together then both results return" do
    id = Ecto.UUID.generate()
    config = config()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("lookup both")], tool_defs(), config, fn _ -> :ok end)
      end)

    pid = wait_running(id)

    send(
      pid,
      {:cursor_frames,
       [
         {:message, mcp_exec(1, "call-1", "probe_lookup", "a")},
         {:message, mcp_exec(2, "call-2", "probe_lookup", "b")}
       ]}
    )

    assert {:ok, response} = Task.await(task)
    assert response.stop_reason == :tool_use
    ids = Enum.map(hd(response.messages).content, & &1[:id])
    assert ids == ["call-1", "call-2"]

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [
            Message.user("lookup both"),
            Message.assistant_blocks(hd(response.messages).content),
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"}),
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-2", content: "B"})
          ],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)

    result_ids =
      pid
      |> :sys.get_state()
      |> then(&Enum.reverse(&1.transport.sent))
      |> Enum.map(&exec_client_id/1)
      |> Enum.reject(&is_nil/1)

    assert result_ids == [1, 2]

    send(pid, {:cursor_frames, [{:message, text_delta("done")}, {:message, turn_ended()}]})
    assert {:ok, final} = Task.await(task2)
    assert final.stop_reason == :end_turn
    assert Message.text(hd(final.messages)) == "done"
  end

  test "tool continuation gets a fresh timeout generation" do
    id = Ecto.UUID.generate()
    config = config(%{receive_timeout: 10_000})

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("lookup")], tool_defs(), config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    initial_generation = :sys.get_state(pid).generation
    initial_ticket = :sys.get_state(pid).timeout_ticket
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    assert {:ok, first} = Task.await(task)
    assert :sys.get_state(pid).timeout_ref == nil

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [
            Message.user("lookup"),
            Message.assistant_blocks(hd(first.messages).content),
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"})
          ],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    state = :sys.get_state(pid)
    assert state.generation == initial_generation + 1
    assert is_reference(state.timeout_ref)

    send(pid, {:run_timeout, initial_ticket})
    send(pid, {:cursor_frames, [{:message, text_delta("done")}, {:message, turn_ended()}]})

    assert {:ok, final} = Task.await(task2)
    assert Message.text(hd(final.messages)) == "done"
  end

  test "stream close after final text completes the turn" do
    id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("answer")], [], config(), fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("final")}, :done]})

    assert {:ok, response} = Task.await(task)
    assert response.stop_reason == :end_turn
    assert Message.text(hd(response.messages)) == "final"
  end

  test "web search interaction query sends a matching approval response" do
    id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("search")], [], config(), fn _ -> :ok end)
      end)

    pid = wait_running(id)
    sent_before = :sys.get_state(pid).transport.sent

    query = IndependentProto.encode_uint32(1, 42) <> IndependentProto.encode_message(2, <<>>)
    send(pid, {:cursor_frames, [{:message, IndependentProto.encode_message(7, query)}]})
    assert_receive {:cursor_transport, :sent, ^pid}, 1_000

    [approval] = :sys.get_state(pid).transport.sent -- sent_before
    client_fields = IndependentProto.decode_fields(approval)

    response_fields =
      client_fields |> IndependentProto.field(6) |> IndependentProto.decode_fields()

    approved = response_fields |> IndependentProto.field(2) |> IndependentProto.decode_fields()

    assert IndependentProto.field(response_fields, 1) == 42
    assert IndependentProto.field(approved, 1) == <<>>

    send(pid, {:cursor_frames, [{:message, text_delta("done")}, {:message, turn_ended()}]})
    assert {:ok, response} = Task.await(task)
    assert Message.text(hd(response.messages)) == "done"
  end

  test "late second exec after first batch is held until results return" do
    id = Ecto.UUID.generate()
    config = config()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("one")], tool_defs(), config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    assert {:ok, first} = Task.await(task)
    assert [call] = hd(first.messages).content
    assert call.id == "call-1"

    send(pid, {:cursor_frames, [{:message, mcp_exec(2, "call-2", "probe_lookup", "b")}]})
    assert %{held: 1} = GenServer.call(pid, :status)

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [
            Message.user("one"),
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"})
          ],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    assert {:ok, second} = Task.await(task2)
    assert Enum.map(hd(second.messages).content, & &1[:id]) == ["call-2"]
  end

  test "switching model while awaiting tools starts a new run instead of missing-result" do
    id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("hi")],
          tool_defs(),
          config(%{model: "composer-2.5"}),
          fn _ ->
            :ok
          end
        )
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    assert {:ok, _} = Task.await(task)

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("switch")],
          tool_defs(),
          config(%{model: "composer-2.5-fast"}),
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("switched")}, {:message, turn_ended()}]})
    assert {:ok, response} = Task.await(task2)
    assert Message.text(hd(response.messages)) == "switched"
  end

  test "workspace identity change releases the old stream" do
    id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("hi")],
          [],
          config(%{working_directory: "/tmp/a"}),
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("a")}, {:message, turn_ended()}]})
    assert {:ok, _} = Task.await(task)

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("hi2")],
          [],
          config(%{working_directory: "/tmp/b"}),
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("b")}, {:message, turn_ended()}]})
    assert {:ok, response} = Task.await(task2)
    assert Message.text(hd(response.messages)) == "b"
  end

  test "completed run can start again; disconnect during tools is not a permanent lock" do
    id = Ecto.UUID.generate()
    config = config()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("x")], [], config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("1")}, {:message, turn_ended()}]})
    assert {:ok, _} = Task.await(task)

    task2 =
      Task.async(fn ->
        Session.complete(id, [Message.user("y")], [], config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("2")}, {:message, turn_ended()}]})
    assert {:ok, response} = Task.await(task2)
    assert Message.text(hd(response.messages)) == "2"
  end

  test "steer user after tool results is sent as conversation_action" do
    id = Ecto.UUID.generate()
    config = config()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("first")], tool_defs(), config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    {:ok, _} = Task.await(task)

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [
            Message.user("first"),
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"}),
            Message.user("steer now")
          ],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("steered")}, {:message, turn_ended()}]})
    assert {:ok, response} = Task.await(task2)
    assert Message.text(hd(response.messages)) == "steered"
  end

  test "queued GenServer close is not swallowed by mint handle_info" do
    id = Ecto.UUID.generate()
    :persistent_term.put({FakeTransport, :pause}, self())
    config = config()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("hi")], [], config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, []})
    assert_receive {:mint_paused, ^pid}, 500
    ref = make_ref()
    send(pid, {:"$gen_call", {self(), ref}, :close})
    send(pid, :continue)
    assert_receive {^ref, :ok}, 500
    assert {:error, message} = Task.await(task)
    assert is_binary(message)
    refute Process.alive?(pid)
  end

  test "tool continuation after disconnect does not open a second connection" do
    id = Ecto.UUID.generate()
    config = config()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("lookup")], tool_defs(), config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    assert {:ok, _} = Task.await(task)

    send(pid, {:cursor_frames, [:done]})
    :persistent_term.put({FakeTransport, :connect}, {:error, :new_run_attempted})

    assert {:error, message} =
             Session.complete(
               id,
               [
                 Message.user("lookup"),
                 Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"})
               ],
               tool_defs(),
               config,
               fn _ -> :ok end
             )

    assert message =~ "not retrying"
  end

  test "historical user is not replayed as conversation_action on tool continuation" do
    id = Ecto.UUID.generate()
    old = %{Message.user("OLD instruction") | id: "old"}
    config = config(%{run_id: "run-a"})

    task =
      Task.async(fn ->
        Session.complete(
          id,
          [old, Message.assistant("prev"), %{Message.user("new") | id: "new"}],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    {:ok, _} = Task.await(task)

    before = :sys.get_state(pid).transport.sent

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [
            old,
            Message.assistant("prev"),
            %{Message.user("new") | id: "new"},
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"})
          ],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    after_sent = :sys.get_state(pid).transport.sent
    extra = after_sent -- before
    assert Enum.filter(extra, &conversation_action?/1) == []
    send(pid, {:cursor_frames, [{:message, text_delta("ok")}, {:message, turn_ended()}]})
    assert {:ok, _} = Task.await(task2)
  end

  test "repeated transport errors keep uncertain then a new run_id is allowed" do
    id = Ecto.UUID.generate()
    config = config(%{run_id: "run-1"})

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("lookup")], tool_defs(), config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    {:ok, _} = Task.await(task)
    send(pid, {:cursor_frames, [:done]})
    send(pid, {:cursor_frames, [{:end_stream, <<>>}]})
    assert %{uncertain_run_id: "run-1"} = GenServer.call(pid, :status)

    assert {:error, message} =
             Session.complete(
               id,
               [
                 Message.user("lookup"),
                 Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"})
               ],
               tool_defs(),
               config,
               fn _ -> :ok end
             )

    assert message =~ "not retrying"

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("fresh")],
          [],
          config(%{run_id: "run-2"}),
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, text_delta("ok")}, {:message, turn_ended()}]})
    assert {:ok, response} = Task.await(task2)
    assert Message.text(hd(response.messages)) == "ok"
  end

  test "same text different ids and two candidate users are all sent" do
    id = Ecto.UUID.generate()
    config = config()
    first = %{Message.user("same") | id: "u1"}

    task =
      Task.async(fn ->
        Session.complete(id, [first], tool_defs(), config, fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    {:ok, _} = Task.await(task)

    second = %{Message.user("same") | id: "u2"}
    third = %{Message.user("other") | id: "u3"}

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [
            first,
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"}),
            second,
            third
          ],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    state = :sys.get_state(pid)
    actions = Enum.filter(state.transport.sent, &conversation_action?/1)
    assert length(actions) == 2
    send(pid, {:cursor_frames, [{:message, text_delta("ok")}, {:message, turn_ended()}]})
    assert {:ok, _} = Task.await(task2)
  end

  test "missing pending tool result writes nothing to the open stream" do
    id = Ecto.UUID.generate()
    config = config()
    first = start_two_tool_calls(id, config)
    pid = first.pid
    sent_before = :sys.get_state(pid).transport.sent
    flush_transport_notifies()

    assert {:error, message} =
             Session.complete(
               id,
               [
                 Message.user("lookup both"),
                 Message.assistant_blocks(hd(first.response.messages).content),
                 Message.tool_result(%{
                   type: "tool_result",
                   tool_use_id: "call-1",
                   content: "A"
                 })
               ],
               tool_defs(),
               config,
               fn _ -> :ok end
             )

    assert message =~ "missing"
    assert :sys.get_state(pid).transport.sent == sent_before
    refute_receive {:cursor_transport, :sent, ^pid}, 0
  end

  test "tool result send failure stops later writes and marks the run uncertain" do
    id = Ecto.UUID.generate()
    config = config(%{run_id: "run-send-failure"})
    first = start_two_tool_calls(id, config)
    pid = first.pid
    :persistent_term.put({FakeTransport, :fail_on_send}, 2)
    flush_transport_notifies()

    assert {:error, :injected_send_failure} =
             Session.complete(
               id,
               [
                 Message.user("lookup both"),
                 Message.assistant_blocks(hd(first.response.messages).content),
                 Message.tool_result(%{
                   type: "tool_result",
                   tool_use_id: "call-1",
                   content: "A"
                 }),
                 Message.tool_result(%{
                   type: "tool_result",
                   tool_use_id: "call-2",
                   content: "B"
                 })
               ],
               tool_defs(),
               config,
               fn _ -> :ok end
             )

    assert_receive {:cursor_transport, :sent, ^pid}, 0
    refute_receive {:cursor_transport, :sent, ^pid}, 0

    assert %{phase: :idle, uncertain_run_id: "run-send-failure"} =
             GenServer.call(pid, :status)
  end

  test "caller exit cancels the original stream without reopening it" do
    id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Session.complete(id, [Message.user("wait")], [], config(), fn _ -> :ok end)
      end)

    pid = wait_running(id)
    assert nil == Task.shutdown(task, :brutal_kill)
    assert_receive {:cursor_transport, :cancelled, ^pid}, 1_000

    state = :sys.get_state(pid)
    assert state.phase == :idle
    refute state.transport.open?
    assert state.transport.sent_count == 1
    refute_receive {:cursor_transport, :sent, ^pid}, 0
  end

  test "provider isolation refuses empty model" do
    assert {:error, message} =
             Cursor.stream([Message.user("hi")], [], %{api_key: "tok", model: ""}, fn _ -> :ok end)

    assert message =~ "refusing to fall back"
  end

  test "inbound thinking slides the run timeout" do
    id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("think")],
          [],
          config(%{receive_timeout: 500}),
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    before = :sys.get_state(pid)
    Process.sleep(200)
    send(pid, {:cursor_frames, [{:message, thinking_delta("still thinking")}]})
    assert %{phase: :running} = GenServer.call(pid, :status)
    after_frame = :sys.get_state(pid)

    assert is_reference(after_frame.timeout_ref)
    refute after_frame.timeout_ref == before.timeout_ref
    assert Process.read_timer(after_frame.timeout_ref) > 300

    send(pid, {:run_timeout, before.timeout_ticket})
    send(pid, {:cursor_frames, [{:message, text_delta("done")}, {:message, turn_ended()}]})

    assert {:ok, response} = Task.await(task, 1_000)
    assert Message.text(hd(response.messages)) == "done"
  end

  test "actual run timeout closes the session without leaving a caller" do
    id = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("slow")],
          [],
          config(%{receive_timeout: 30}),
          fn _ -> :ok end
        )
      end)

    _pid = wait_running(id)
    assert {:error, message} = Task.await(task, 1_000)
    assert message =~ "timed out"
  end

  defp start_two_tool_calls(id, config) do
    task =
      Task.async(fn ->
        Session.complete(
          id,
          [Message.user("lookup both")],
          tool_defs(),
          config,
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)

    send(
      pid,
      {:cursor_frames,
       [
         {:message, mcp_exec(1, "call-1", "probe_lookup", "a")},
         {:message, mcp_exec(2, "call-2", "probe_lookup", "b")}
       ]}
    )

    {:ok, response} = Task.await(task)
    %{pid: pid, response: response}
  end

  defp exec_client_id(payload) do
    case IndependentProto.field(IndependentProto.decode_fields(payload), 2) do
      nil -> nil
      exec -> exec |> IndependentProto.decode_fields() |> IndependentProto.field(1)
    end
  end

  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        api_key: "tok",
        model: "composer-2.5",
        cursor_transport: FakeTransport,
        conversation_id: "conv",
        working_directory: "/tmp/ws"
      },
      overrides
    )
  end

  defp wait_running(_id) do
    assert_receive {:cursor_transport, :sent, pid}, 1_000
    flush_transport_notifies()
    pid
  end

  defp flush_transport_notifies do
    receive do
      {:cursor_transport, :sent, _} -> flush_transport_notifies()
    after
      0 -> :ok
    end
  end

  defp tool_defs do
    [%{name: "probe_lookup", description: "lookup", input_schema: %{"type" => "object"}}]
  end

  defp text_delta(text) do
    IndependentProto.encode_server_interaction(1, IndependentProto.encode_string(1, text))
  end

  defp thinking_delta(text) do
    IndependentProto.encode_server_interaction(4, IndependentProto.encode_string(1, text))
  end

  defp turn_ended do
    IndependentProto.encode_server_interaction(14, <<>>)
  end

  defp mcp_exec(id, call_id, name, key) do
    IndependentProto.encode_mcp_exec(id, call_id, name, key)
  end

  defp conversation_action?(bin) when is_binary(bin) do
    fields = Handbean.Agent.Provider.Cursor.Proto.decode_fields(bin)
    Handbean.Agent.Provider.Cursor.Proto.field(fields, 4) != nil
  end

  defp conversation_action?(_), do: false
end
