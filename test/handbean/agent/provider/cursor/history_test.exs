defmodule Handbean.Agent.Provider.Cursor.HistoryTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Cursor.{Blobs, Session}

  defmodule FakeTransport do
    def connect(_opts), do: {:ok, %{open?: true, sent: []}}
    def open_run(transport, _token, _opts), do: {:ok, transport}

    def send_message(transport, payload, _opts \\ []) do
      case :persistent_term.get({__MODULE__, :notify}, nil) do
        pid when is_pid(pid) -> send(pid, {:cursor_transport, :sent, self()})
        _ -> :ok
      end

      {:ok, Map.update(transport, :sent, [payload], &[payload | &1])}
    end

    def handle_mint(transport, {:cursor_frames, frames}), do: {:ok, transport, frames}
    def handle_mint(transport, _), do: {:ok, transport, []}
    def cancel(t), do: Map.put(t, :open?, false)
    def close(t), do: Map.put(t, :open?, false)
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

    :persistent_term.put({FakeTransport, :notify}, self())
    flush_transport_notifies()
    :ok
  end

  test "Run payload encodes MCP tool_use+result as ConversationStep 2→15 with Value args" do
    id = Ecto.UUID.generate()

    input = %{
      "key" => "violet-17",
      "ok" => true,
      "count" => 3,
      "nested" => %{"flag" => false},
      "list" => [1, "two"],
      "empty" => nil
    }

    history = [
      %{Message.user("hi") | id: "old"},
      Message.assistant_blocks([
        %{type: "tool_use", id: "call-1", name: "probe_lookup", input: input}
      ]),
      Message.tool_result(%{
        type: "tool_result",
        tool_use_id: "call-1",
        content: "ORCHID-5928",
        is_error: false
      }),
      %{Message.user("again") | id: "new"}
    ]

    task =
      Task.async(fn ->
        Session.complete(
          id,
          history,
          [],
          %{
            api_key: "tok",
            model: "composer-2.5",
            cursor_transport: FakeTransport,
            run_id: "run-hist"
          },
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    state = :sys.get_state(pid)
    run = hd(Enum.reverse(state.transport.sent))
    step = mcp_step(run, state.blobs)
    send(pid, {:cursor_frames, [{:message, turn_ended()}]})
    _ = Task.await(task)

    assert {:tool_call, {:mcp, decoded}} = IndependentProto.decode_conversation_step(step)
    assert decoded.args.name == "probe_lookup"
    assert decoded.args.tool_name == "probe_lookup"
    assert decoded.args.tool_call_id == "call-1"
    assert decoded.args.provider_identifier == "handbean"
    assert decoded.args.args["key"] == "violet-17"
    assert decoded.args.args["ok"] == true
    assert decoded.args.args["count"] == 3.0
    assert decoded.args.args["nested"] == %{"flag" => false}
    assert decoded.args.args["list"] == [1.0, "two"]
    assert decoded.args.args["empty"] == nil
    assert {:success, %{content: ["ORCHID-5928"], is_error: false}} = decoded.result
  end

  test "nil-id duplicate text is a new user appearance, not content de-dupe" do
    id = Ecto.UUID.generate()
    first = Message.user("continue")
    refute first.id

    task =
      Task.async(fn ->
        Session.complete(id, [first], tool_defs(), config(), fn _ -> :ok end)
      end)

    pid = wait_running(id)
    send(pid, {:cursor_frames, [{:message, mcp_exec(1, "call-1", "probe_lookup", "a")}]})
    {:ok, _} = Task.await(task)
    before = :sys.get_state(pid).transport.sent

    second = Message.user("continue")
    refute second.id

    task2 =
      Task.async(fn ->
        Session.complete(
          id,
          [
            first,
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"}),
            second
          ],
          tool_defs(),
          config(),
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    extra = :sys.get_state(pid).transport.sent -- before
    assert Enum.count(extra, &conversation_action?/1) == 1
    send(pid, {:cursor_frames, [{:message, text_delta("ok")}, {:message, turn_ended()}]})
    assert {:ok, _} = Task.await(task2)
  end

  test "nil-id historical user is not replayed on tool continuation" do
    id = Ecto.UUID.generate()
    old = Message.user("OLD instruction")
    refute old.id
    new = Message.user("new")

    task =
      Task.async(fn ->
        Session.complete(
          id,
          [old, Message.assistant("prev"), new],
          tool_defs(),
          config(%{run_id: "run-a"}),
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
            new,
            Message.tool_result(%{type: "tool_result", tool_use_id: "call-1", content: "A"})
          ],
          tool_defs(),
          config(%{run_id: "run-a"}),
          fn _ -> :ok end
        )
      end)

    pid = wait_running(id)
    extra = :sys.get_state(pid).transport.sent -- before
    assert Enum.filter(extra, &conversation_action?/1) == []
    send(pid, {:cursor_frames, [{:message, text_delta("ok")}, {:message, turn_ended()}]})
    assert {:ok, _} = Task.await(task2)
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

  defp tool_defs do
    [%{name: "probe_lookup", description: "lookup", input_schema: %{}}]
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

  defp turn_ended, do: IndependentProto.encode_server_interaction(14, <<>>)

  defp text_delta(text) do
    IndependentProto.encode_server_interaction(1, IndependentProto.encode_string(1, text))
  end

  defp mcp_exec(id, call_id, name, key) do
    IndependentProto.encode_mcp_exec(id, call_id, name, key)
  end

  defp conversation_action?(bin) do
    IndependentProto.field(IndependentProto.decode_fields(bin), 4) != nil
  end

  defp mcp_step(bin, blobs) do
    client = IndependentProto.decode_fields(bin)
    run = IndependentProto.decode_fields(IndependentProto.field(client, 1))
    state_fields = IndependentProto.decode_fields(IndependentProto.field(run, 1))
    turn_ids = IndependentProto.fields(state_fields, 8)

    Enum.find_value(turn_ids, fn turn_id ->
      turn = blobs |> Blobs.fetch(turn_id) |> IndependentProto.decode_fields()
      agent = IndependentProto.decode_fields(IndependentProto.field(turn, 1))

      Enum.find_value(IndependentProto.fields(agent, 2), fn step_id ->
        step = Blobs.fetch(blobs, step_id)

        case IndependentProto.decode_conversation_step(step) do
          {:tool_call, _} -> step
          _ -> nil
        end
      end)
    end)
  end
end
