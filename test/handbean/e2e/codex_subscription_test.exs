defmodule Handbean.E2E.CodexSubscriptionTest do
  @moduledoc """
  Codex completed item events survive an empty terminal output array through
  Coordinator → Runner → real provider parser → read tool → durable transcript.
  Only HTTP is stubbed: replacing Codex with FakeProvider would hide this bug.

  Run: mix test --include e2e test/handbean/e2e/codex_subscription_test.exs
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session

  @moduletag :e2e

  setup :setup_home
  setup {Req.Test, :set_req_test_to_shared}

  defp setup_home(_) do
    root = Path.join(System.tmp_dir!(), "codex-e2e-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "probe.txt"), "ORCHID-5928")
    old_home = System.get_env("HOME")
    System.put_env("HOME", root)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "streamed tool executes once and final answer is persisted without an empty-turn retry", %{
    root: root
  } do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      input = Handbean.JSON.decode!(body)["input"]
      send(owner, :codex_request)

      item =
        case Enum.find(input, &(&1["type"] == "function_call_output")) do
          nil ->
            %{
              "type" => "function_call",
              "call_id" => "read-local",
              "name" => "read",
              "arguments" => ~s({"file_path":"probe.txt"})
            }

          result ->
            assert result["call_id"] == "read-local"
            assert result["output"] =~ "ORCHID-5928"

            %{
              "id" => "msg_final",
              "type" => "message",
              "role" => "assistant",
              "phase" => "final_answer",
              "content" => [%{"type" => "output_text", "text" => "Read ORCHID-5928"}]
            }
        end

      stream =
        event("response.output_item.done", %{"output_index" => 0, "item" => item}) <>
          event("response.completed", %{
            "response" => %{"status" => "completed", "output" => []}
          })

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, stream)
    end)

    {:ok, conversation} = ConversationStore.create("codex-workspace")
    sid = conversation["id"]
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "Read probe.txt",
               workspace_path: root,
               model: "gpt-5.6-sol",
               provider: Handbean.Agent.Provider.Codex,
               provider_config: %{
                 api_key: Handbean.CodexTestHelper.token(),
                 req_options: [plug: {Req.Test, __MODULE__}]
               },
               tools: [Handbean.Tool.Builtin.Read],
               middleware: [],
               source: :cli,
               streaming: true,
               max_turns: 3
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed, turns: 2}}},
                   5_000

    settle(sid)

    assert_received :codex_request
    assert_received :codex_request
    refute_received :codex_request

    {:ok, entries} = ConversationTranscriptStore.list(sid)
    assert [tool] = Enum.filter(entries, &(&1["content_type"] == "tool"))
    assert tool["tool_use_id"] == "read-local"
    assert tool["tool_status"] == "done"
    assert [answer] = Enum.filter(entries, &(&1["role"] == "assistant"))
    assert answer["content"] == "Read ORCHID-5928"
    refute Enum.any?(entries, &(&1["message_type"] == "error"))
  end

  test "a follow-up replays persisted assistant text with a Codex message ID" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      input = Handbean.JSON.decode!(body)["input"]

      text =
        if List.last(input)["content"] == "follow up" do
          assert [_, assistant, _] = input
          assert assistant["id"] =~ ~r/\Amsg_[A-Za-z0-9_-]+\z/
          assert byte_size(assistant["id"]) <= 64
          assert assistant["phase"] == "final_answer"
          assert [%{"text" => "First answer"}] = assistant["content"]
          "Second answer"
        else
          "First answer"
        end

      item = %{
        "id" => "msg_native",
        "type" => "message",
        "role" => "assistant",
        "phase" => "final_answer",
        "content" => [%{"type" => "output_text", "text" => text}]
      }

      stream =
        event("response.output_item.added", %{"output_index" => 0, "item" => item}) <>
          event("response.output_text.delta", %{"output_index" => 0, "delta" => text}) <>
          event("response.output_item.done", %{"output_index" => 0, "item" => item}) <>
          event("response.completed", %{
            "response" => %{"status" => "completed", "output" => []}
          })

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, stream)
    end)

    {:ok, conversation} = ConversationStore.create_free()
    sid = conversation["id"]
    :ok = Session.subscribe(sid)

    for prompt <- ["hello", "follow up"] do
      assert {:ok, %{action: :started}} =
               Coordinator.add_message(sid, prompt,
                 chat_scope: :free,
                 model: "gpt-6-luna",
                 provider: Handbean.Agent.Provider.Codex,
                 provider_config: %{
                   api_key: Handbean.CodexTestHelper.token(),
                   req_options: [plug: {Req.Test, __MODULE__}]
                 },
                 tools: [],
                 middleware: [],
                 source: :live_view,
                 streaming: true,
                 max_turns: 2
               )

      assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 5_000
      settle(sid)
    end

    {:ok, entries} = ConversationTranscriptStore.list(sid)
    answers = Enum.filter(entries, &(&1["role"] == "assistant"))
    assert Enum.map(answers, & &1["content"]) == ["First answer", "Second answer"]
    assert Enum.all?(answers, &String.starts_with?(&1["id"], "msg-assistant-"))
    refute Enum.any?(entries, &(&1["message_type"] == "error"))
  end

  defp settle(sid) do
    # run_end precedes Runner cleanup and its collaboration task. Keep the
    # isolated HOME in place until both have finished their persistence work.
    for {pid, _} <- Registry.lookup(Handbean.AgentRunRegistry, sid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp event(type, attrs),
    do: "data: " <> Handbean.JSON.encode!(Map.put(attrs, "type", type)) <> "\n\n"
end
