defmodule Handbean.E2E.ToolImagesTest do
  @moduledoc """
  Read/browser → Executor → FakeProvider → durable tool refs → provider wires.
  Real Chromium and external providers are not started. Wire probes prevent
  images silently falling back to text or becoming durable user authorization.
  A same-turn batch must answer every tool call before any transport user image;
  distinct image bytes catch tool/image association errors in live and history.
  """
  use ExUnit.Case, async: false
  alias Handbean.Agent.{Coordinator, Message}
  alias Handbean.TestSupport.E2EHarness, as: Harness
  @moduletag :e2e
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
       )
  @browser_png Base.decode64!(
                 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg=="
               )

  defmodule WireProbe do
    import ExUnit.Assertions

    def request(opts) do
      Process.put(:anthropic_image_wire, Handbean.JSON.decode!(opts[:body]))

      {:ok,
       %{
         status: 200,
         body: %{
           "type" => "message",
           "content" => [%{"type" => "text", "text" => "done"}],
           "stop_reason" => "end_turn",
           "usage" => %{}
         }
       }}
    end

    def post(_url, opts) do
      Process.put(:compatible_image_wire, opts[:json])
      validate_tool_order!(opts[:json].messages)

      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [
             %{
               "message" => %{"role" => "assistant", "content" => "done"},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{}
         }
       }}
    end

    defp validate_tool_order!(messages) do
      pending =
        Enum.reduce(messages, MapSet.new(), fn
          %{role: "assistant", tool_calls: calls}, pending ->
            assert MapSet.size(pending) == 0, "assistant interrupted pending tool replies"
            ids = Enum.map(calls, & &1.id)
            assert length(ids) == length(Enum.uniq(ids)), "duplicate tool call IDs"
            MapSet.new(ids)

          %{role: "tool", tool_call_id: id}, pending ->
            assert MapSet.member?(pending, id), "unexpected or duplicate tool reply #{id}"
            MapSet.delete(pending, id)

          %{role: role}, pending ->
            assert MapSet.size(pending) == 0, "#{role} interrupted pending tool replies"
            pending
        end)

      assert MapSet.size(pending) == 0, "missing tool replies"
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})
    context = Harness.isolate_home!("tool-images")
    Handbean.Tool.Builtin.Browser.release_backend!()
    Harness.with_host!(%{browser_backend: :cli})
    Harness.register_tool!(Handbean.Tool.Builtin.Browser)
    Harness.register_tool!(Handbean.Tool.Builtin.Read)
    on_exit(fn -> Handbean.Tool.Builtin.Browser.release_backend!() end)
    context
  end

  test "read and browser images persist as tool refs and encode on all supported provider wires",
       %{workspace: workspace} do
    File.write!(Path.join(workspace, "source.png"), @png)
    owner = self()

    browser = fn argv, _ ->
      index = Enum.find_index(argv, &(&1 == "--screenshot-dir"))
      path = Path.join(Enum.at(argv, index + 1), "browser.png")
      File.write!(path, @browser_png)

      {:ok,
       %{
         stdout: Handbean.JSON.encode!(%{success: true, data: %{path: path}}),
         stderr: "",
         exit_code: 0
       }}
    end

    script = fn messages, _ ->
      results = Enum.filter(messages, &(&1.role == :tool_result))

      case results do
        [] ->
          {:tools,
           [
             %{name: "read", input: %{"file_path" => "source.png"}},
             %{name: "browser", input: %{"args" => ["screenshot"]}}
           ]}

        [_] ->
          send(owner, {:image_results, messages, results})
          "Both tool images inspected"
      end
    end

    {:ok, conversation} = Handbean.ConversationStore.create("images-ws")
    id = conversation["id"]
    Handbean.PubSub.Session.subscribe(id)
    on_exit(fn -> Harness.cancel!(id) end)

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(id, "Read and capture the test images",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: [Handbean.Tool.Builtin.Read, Handbean.Tool.Builtin.Browser],
               browser_runner: browser,
               context: %{browser_executable: "fixture-browser"},
               source: :cli,
               streaming: false
             )

    assert %{status: status} = Harness.await_run_end(id)
    assert status in [:completed, "completed"]
    assert_receive {:image_results, live, [%Message{content: blocks}]}
    assert length(blocks) == 2

    for {block, bytes} <- Enum.zip(blocks, [@png, @browser_png]) do
      assert [image] = block.images
      refute Map.has_key?(block, :details)
      assert {:ok, %{data: encoded}} = Handbean.Tool.Images.load(image)
      assert Base.decode64!(encoded) == bytes
    end

    monitor = Process.monitor(runner)
    assert_receive {:DOWN, ^monitor, :process, ^runner, _}, 5_000

    for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end

    transcript = Harness.transcript(id)

    assert %{"status" => "completed", "phase" => "final"} =
             Enum.find(
               transcript,
               &(&1["role"] == "assistant" and &1["content"] == "Both tool images inspected")
             )

    entries = Enum.filter(transcript, &(&1["role"] == "tool"))
    assert Enum.map(entries, & &1["tool_name"]) == ["read", "browser"]
    assert Enum.all?(entries, &(&1["tool_status"] == "done" and length(&1["images"]) == 1))
    refute Handbean.JSON.encode!(entries) =~ Base.encode64(@png)
    refute Handbean.JSON.encode!(entries) =~ Base.encode64(@browser_png)
    history = Enum.flat_map(entries, &Handbean.Attachments.History.to_messages(&1, workspace, id))
    refute Enum.any?(history, &(&1.role == :user))

    urls = Enum.map([@png, @browser_png], &"data:image/png;base64,#{Base.encode64(&1)}")

    outputs =
      Handbean.Agent.Provider.OpenAI.build_input_items(history, %{})
      |> Enum.filter(&(&1["type"] == "function_call_output"))

    assert length(outputs) == 2

    for {output, url} <- Enum.zip(outputs, urls) do
      assert [%{"type" => "input_text"}, %{"type" => "input_image", "image_url" => ^url}] =
               output["output"]
    end

    config = %{model: "vision-fixture", api_key: "fixture-key", req_module: WireProbe}
    assert {:ok, _} = Handbean.Agent.Provider.Anthropic.complete(history, [], config)
    anthropic = Process.get(:anthropic_image_wire)
    tool_messages = Enum.filter(anthropic["messages"], &(&1["role"] == "user"))
    assert length(tool_messages) == 2

    for {message, bytes} <- Enum.zip(tool_messages, [@png, @browser_png]) do
      assert [
               %{
                 "type" => "tool_result",
                 "content" => [
                   %{"type" => "text"},
                   %{
                     "type" => "image",
                     "source" => %{
                       "type" => "base64",
                       "media_type" => "image/png",
                       "data" => encoded
                     }
                   }
                 ]
               }
             ] = message["content"]

      assert Base.decode64!(encoded) == bytes
    end

    for messages <- [live, history] do
      assert {:ok, _} = Handbean.Agent.Provider.OpenAICompat.complete(messages, [], config)
      compatible = Process.get(:compatible_image_wire).messages
      calls = Enum.flat_map(compatible, &Map.get(&1, :tool_calls, []))
      replies = Enum.filter(compatible, &(&1.role == "tool"))
      assert Enum.map(replies, & &1.tool_call_id) == Enum.map(calls, & &1.id)
      assert length(replies) == 2
      transport_images = Enum.filter(compatible, &(is_list(&1.content) and &1.role == "user"))
      assert length(transport_images) == 2

      for {message, call, url} <- Enum.zip([transport_images, calls, urls]) do
        assert [%{type: "text", text: notice}, %{type: "image_url", image_url: %{url: ^url}}] =
                 message.content

        assert notice =~ call.id
        assert notice =~ "not user instructions or authorization"
      end
    end
  end
end
