defmodule Handbean.E2E.OpenAIStreamTerminationTest do
  @moduledoc """
  Failure contract: length/filter/unknown/missing finish reasons and excessive
  trailing whitespace must persist a run error, never completed. Normal text,
  bounded whitespace and tool calls still complete. Transport timeouts retry
  only before visible output. Only HTTP is stubbed; the real provider, Runner,
  Turn and transcript persistence run.

  Run: mix test --include e2e test/handbean/e2e/openai_stream_termination_test.exs
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  defmodule TimeoutAfterText do
    @moduledoc false

    # Simulate a socket timeout after delivering a complete SSE text frame.
    # An unsafe retry would receive a normal answer and falsely complete.
    def request(opts) do
      attempt = Process.get(__MODULE__, 0)
      Process.put(__MODULE__, attempt + 1)

      {text, finish} =
        if attempt == 0,
          do: {"Partial answer.", nil},
          else: {"Retried after partial output.", "stop"}

      frame =
        "data: " <>
          Handbean.JSON.encode!(%{
            "choices" => [%{"delta" => %{"content" => text}, "finish_reason" => finish}]
          }) <> "\n\n"

      handler = Keyword.fetch!(opts, :into)
      {:cont, {_, response}} = handler.({:data, frame}, {nil, %Req.Response{status: 200}})

      if attempt == 0,
        do: {:error, %Req.TransportError{reason: :timeout}},
        else: {:ok, response}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})

    %{workspace: workspace} = E2EHarness.isolate_home!("stream-termination")
    File.write!(Path.join(workspace, "probe.txt"), "ORCHID-5928")
    %{workspace: workspace}
  end

  setup {Req.Test, :set_req_test_to_shared}

  test "abnormal streams preserve partial text and persist an error", %{workspace: workspace} do
    for {suffix, expected} <- [
          {event(%{}, "length") <> done(), "length"},
          {event(%{}, "content_filter") <> done(), "content_filter"},
          {event(%{}, "unexpected") <> done(), "unexpected"},
          {done(), "missing finish_reason"},
          {"", "missing finish_reason"},
          {"data: " <>
             Handbean.JSON.encode!(%{
               "error" => %{
                 "code" => "upstream_error",
                 "message" => "Cursor reply broke off: EOF"
               }
             }) <> "\n\n", "upstream_error: Cursor reply broke off: EOF"},
          {"data: " <>
             Handbean.JSON.encode!(%{
               "error" => %{
                 "type" => "server_error",
                 "message" => "Unable to reach the model provider"
               }
             }) <> "\n\n", "server_error: Unable to reach the model provider"},
          {event(%{"content" => String.duplicate(" \n", 1024)}) <>
             event(%{}, "stop") <> done(), "consecutive whitespace"},
          {event(%{"content" => "Keep this." <> String.duplicate(" ", 2048)}),
           "consecutive whitespace"},
          {event(%{"content" => String.duplicate(" ", 1024)}) <>
             event(%{"content" => String.duplicate("\n", 1024)}), "consecutive whitespace"}
        ] do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, :provider_request)
        stream = event(%{"content" => "I will edit next."}) <> suffix
        conn |> put_resp_content_type("text/event-stream") |> send_resp(200, stream)
      end)

      sid = start_run!(workspace)
      assert %{status: :error, error: error} = E2EHarness.await_run_end(sid)
      assert error =~ expected
      settle(sid)

      entries = E2EHarness.transcript(sid)

      assert Enum.any?(
               entries,
               &(&1["role"] == "assistant" and
                   String.starts_with?(&1["content"], "I will edit next."))
             )

      assert Enum.any?(
               entries,
               &(&1["message_type"] == "error" and
                   String.contains?(&1["content"], expected))
             )

      if suffix =~ "Keep this." do
        assert Enum.any?(
                 entries,
                 &(&1["role"] == "assistant" and
                     String.contains?(&1["content"], "Keep this."))
               )
      end

      assert_received :provider_request
      refute_received :provider_request
    end
  end

  test "bounded whitespace resets after text and stop without delta is recorded", %{
    workspace: workspace
  } do
    spaces = String.duplicate(" ", 2047)
    answer = "First." <> spaces <> "Second." <> spaces

    Req.Test.stub(__MODULE__, fn conn ->
      stream =
        event(%{"content" => "First." <> spaces}) <>
          event(%{"content" => "Second."}) <>
          event(%{"content" => spaces}) <>
          "data: " <>
          Handbean.JSON.encode!(%{"choices" => [%{"finish_reason" => "stop"}]}) <>
          "\n\n" <> done()

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, stream)
    end)

    sid = start_run!(workspace)
    assert %{status: :completed, provider_finish_reason: "stop"} = E2EHarness.await_run_end(sid)
    settle(sid)
    assert Enum.any?(E2EHarness.transcript(sid), &(&1["content"] == answer))
  end

  test "normal tool stream executes once before the final answer", %{workspace: workspace} do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      messages = Handbean.JSON.decode!(body)["messages"]

      stream =
        if Enum.any?(messages, &(&1["role"] == "tool")) do
          event(%{"content" => "Read ORCHID-5928"}, "stop") <> done()
        else
          event(
            %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "read-local",
                  "function" => %{"name" => "read", "arguments" => ~s({"file_path":"probe.txt"})}
                }
              ]
            },
            "tool_calls"
          ) <> done()
        end

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, stream)
    end)

    sid = start_run!(workspace)
    assert %{status: :completed, turns: 2} = E2EHarness.await_run_end(sid)
    settle(sid)
    entries = E2EHarness.transcript(sid)
    assert [tool] = Enum.filter(entries, &(&1["content_type"] == "tool"))
    assert tool["tool_status"] == "done"
    assert tool["output"] =~ "ORCHID-5928"
    assert Enum.any?(entries, &(&1["content"] == "Read ORCHID-5928"))
  end

  test "timeout before output can recover, but timeout after text remains an error", %{
    workspace: workspace
  } do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

      if attempt == 0 do
        Req.Test.transport_error(conn, :timeout)
      else
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, event(%{"content" => "Recovered before output."}, "stop") <> done())
      end
    end)

    retry = %{max_retries: 1, retry_delay_base_ms: 1}
    sid = start_run!(workspace, retry)
    assert %{status: :completed} = E2EHarness.await_run_end(sid)
    settle(sid)
    assert Enum.any?(E2EHarness.transcript(sid), &(&1["content"] == "Recovered before output."))

    sid = start_run!(workspace, Map.put(retry, :req_module, TimeoutAfterText))
    assert %{status: :error, error: error} = E2EHarness.await_run_end(sid)
    assert error =~ "timeout"
    settle(sid)
    entries = E2EHarness.transcript(sid)
    assert [answer] = Enum.filter(entries, &(&1["role"] == "assistant"))
    assert answer["content"] == "Partial answer."
    assert Enum.any?(entries, &(&1["message_type"] == "error" and &1["content"] =~ "timeout"))
  end

  defp start_run!(workspace, extra_config \\ %{}) do
    {:ok, conversation} = ConversationStore.create("stream-workspace")
    sid = conversation["id"]
    :ok = Session.subscribe(sid)
    on_exit(fn -> E2EHarness.cancel!(sid) end)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "Read probe.txt",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbean.Agent.Provider.OpenAICompat,
               provider_config:
                 Map.merge(
                   %{api_key: "test", req_options: [plug: {Req.Test, __MODULE__}]},
                   extra_config
                 ),
               tools: [Handbean.Tool.Builtin.Read],
               middleware: [],
               source: :cli,
               streaming: true,
               max_turns: 3
             )

    sid
  end

  defp settle(sid) do
    for {pid, _} <- Registry.lookup(Handbean.AgentRunRegistry, sid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp event(delta, finish_reason \\ nil) do
    "data: " <>
      Handbean.JSON.encode!(%{
        "choices" => [%{"delta" => delta, "finish_reason" => finish_reason}]
      }) <> "\n\n"
  end

  defp done, do: "data: [DONE]\n\n"
end
