defmodule Handbean.E2E.ComputerUseTest do
  @moduledoc """
  Coordinator → run-scoped native lease → host → tool image → provider → durable transcript.
  Linux uses an injected host, not macOS input. Boundary failures exercised:
  forged/cross-conversation image refs, replaced bytes, stale action receipts,
  cancellation while the native request is outstanding. No TCC is automated.
  """
  use ExUnit.Case, async: false

  alias Handbean.Agent.{Coordinator, Message}
  alias Handbean.TestSupport.E2EHarness, as: Harness
  alias Handbean.PubSub.Session

  @moduletag :e2e
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
       )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})
    context = Harness.isolate_home!("computer-use")
    :ok = Handbean.Settings.save_global_section("computer_use", %{"enabled" => true})
    Harness.register_tool!(Handbean.Tool.Builtin.Computer)
    on_exit(fn -> Handbean.Tool.Registry.unregister("computer") end)
    context
  end

  test "native target selection runs directly; images reach the provider and replay as tool results",
       %{
         workspace: workspace
       } do
    owner = self()

    backend = fn input, context ->
      send(owner, {:native, input, context.conversation_id})

      {:ok,
       %{
         "text" => "observed window 42",
         "observation_id" => "fresh-1",
         "image" => Base.encode64(@png),
         "mime_type" => "image/png",
         "side_effect" => "not_started"
       }}
    end

    Harness.with_host!(%{computer_use_backend: backend})

    script = fn messages, _defs ->
      case Enum.find(messages, &(&1.role == :tool_result)) do
        nil ->
          {:tools,
           [
             %{
               name: "computer",
               input: %{
                 "action" => "select",
                 "app_id" => "com.apple.calculator",
                 "window_id" => 42
               }
             }
           ]}

        %Message{content: [block]} ->
          send(owner, {:tool_image, block})
          "Window observed"
      end
    end

    {id, runner} = start(workspace, script)

    assert_receive {:native, %{"action" => "select"}, ^id}, 5_000
    assert_receive {:tool_image, %{images: [image]} = block}, 5_000
    assert [%{type: "text"}, %{type: "image", data: data}] = Handbean.Tool.Images.content(block)
    assert Base.decode64!(data) == @png
    assert %{status: status} = Harness.await_run_end(id)
    assert status in [:completed, "completed"]
    entry = Enum.find(Harness.transcript(id), &(&1["tool_name"] == "computer"))
    assert entry["tool_status"] == "done"
    assert [stored] = entry["images"]
    refute Handbean.JSON.encode!(entry) =~ Base.encode64(@png)

    assert [%Message{role: :assistant}, %Message{role: :tool_result, content: [restored]}] =
             Handbean.Attachments.History.to_messages(entry, workspace, id)

    [%{type: "text", text: restored_text}, restored_image] =
      Handbean.Tool.Images.content(restored)

    [%{type: "text", text: live_text}, live_image] = Handbean.Tool.Images.content(block)
    assert live_text =~ restored_text
    assert restored_image == live_image

    assert [
             %{
               "type" => "function_call_output",
               "output" => [
                 %{"type" => "input_text"},
                 %{"type" => "input_image", "image_url" => url}
               ]
             }
           ] =
             Handbean.Agent.Provider.OpenAI.build_input_items(
               [Message.tool_results([block])],
               %{}
             )

    assert url == "data:image/png;base64,#{data}"
    assert {:error, _} = Handbean.Tool.Images.load(Map.put(stored, "ref", "../secret"))

    assert {:error, _} =
             Handbean.Tool.Images.load(Map.put(image, :sha256, String.duplicate("0", 64)))

    assert [%Message{}, %Message{content: [%{images: []}]}] =
             Handbean.Attachments.History.to_messages(entry, workspace, "other-conversation")

    messages = [Message.user("task"), Message.tool_results([block]), Message.assistant("recent")]

    assert [_first, %Message{content: [compacted]}, _recent] =
             Handbean.Agent.Compactor.compact_messages(messages, keep_recent: 1)

    refute Map.has_key?(compacted, :images)
    drain(runner)
  end

  test "cancel closes native control before run_end and persists cancelled terminal state", %{
    workspace: workspace
  } do
    owner = self()
    {:ok, workers} = Agent.start_link(fn -> nil end)

    backend = fn input, _context ->
      case input["action"] do
        "stop" ->
          if worker = Agent.get(workers, & &1), do: send(worker, :stopped)
          send(owner, :native_stopped)
          {:ok, %{"text" => "stopped"}}

        "observe" ->
          worker = self()
          Agent.update(workers, fn _ -> worker end)
          send(owner, {:native_waiting, self()})

          receive do
            :stopped -> {:error, :cancelled}
          end
      end
    end

    Harness.with_host!(%{computer_use_backend: backend})
    script = fn _, _ -> {:tools, [%{name: "computer", input: %{"action" => "observe"}}]} end
    {id, runner} = start(workspace, script)
    assert_receive {:native_waiting, _}, 5_000
    assert :ok = Coordinator.cancel(id)
    assert_receive :native_stopped, 5_000
    assert %{status: "cancelled"} = Harness.await_run_end(id)
    assert %{meta: %{running?: false}} = Session.snapshot(id)
    refute Enum.any?(Harness.transcript(id), &(&1["content"] == "Window observed"))
    drain(runner)
  end

  test "trusted root alias works but reserved directory and file symlinks cannot escape", %{
    root: root,
    home: home,
    workspace: workspace
  } do
    alias_path = Path.join(root, "host-data-alias")
    File.ln_s!(home, alias_path)
    Harness.with_host!(%{data_dir: alias_path, computer_use_backend: observation_backend()})
    {id, runner} = start(workspace, one_observation())
    assert %{status: status} = Harness.await_run_end(id)
    assert status in [:completed, "completed"]
    entry = Enum.find(Harness.transcript(id), &(&1["tool_name"] == "computer"))
    assert entry["tool_status"] == "done"
    assert length(entry["images"]) == 1, inspect(entry)
    [image] = entry["images"]
    assert {:ok, %{data: data}} = Handbean.Tool.Images.load(image)
    assert Base.decode64!(data) == @png
    drain(runner)

    images_root = Path.join([home, ".handbean", "tool-images"])
    stored_path = Path.join(images_root, image["ref"])
    File.rm!(stored_path)
    escaped_file = Path.join(root, "outside.png")
    File.write!(escaped_file, @png)
    File.ln_s!(escaped_file, stored_path)
    assert {:error, _} = Handbean.Tool.Images.load(image)

    outside = Path.join(root, "outside-images")
    File.mkdir_p!(outside)
    File.rm_rf!(images_root)
    File.ln_s!(outside, images_root)
    {failed_id, failed_runner} = start(workspace, one_observation())
    assert %{status: status} = Harness.await_run_end(failed_id)
    assert status in [:completed, "completed"]
    failed = Enum.find(Harness.transcript(failed_id), &(&1["tool_name"] == "computer"))
    assert failed["tool_status"] == "error"
    assert failed["tool_error"] =~ "symlink_directory"
    assert failed["images"] == []
    assert File.ls!(outside) == []
    drain(failed_runner)
  end

  test "long observation runs and restored history keep only the newest two images", %{
    workspace: workspace
  } do
    owner = self()
    Harness.with_host!(%{computer_use_backend: observation_backend()})

    script = fn messages, _defs ->
      results = Enum.filter(messages, &(&1.role == :tool_result))

      images =
        for message <- results, block <- message.content, image <- block[:images], do: image

      assert length(images) == min(length(results), 2)

      if length(results) < 6 do
        {:tools,
         [
           %{
             name: "computer",
             input: %{"action" => "observe", "observation_id" => "step-#{length(results)}"}
           }
         ]}
      else
        send(owner, {:bounded_observations, messages, images})
        "Six observations complete"
      end
    end

    {id, runner} = start(workspace, script)
    assert %{status: status} = Harness.await_run_end(id)
    assert status in [:completed, "completed"]
    assert_receive {:bounded_observations, messages, [old_image, new_image]}, 5_000
    entries = Enum.filter(Harness.transcript(id), &(&1["tool_name"] == "computer"))
    assert length(entries) == 6

    expected =
      Enum.take(entries, -2) |> Enum.flat_map(& &1["images"]) |> Handbean.Tool.Images.project()

    assert [old_image, new_image] == expected

    restored =
      Enum.flat_map(entries, &Handbean.Attachments.History.to_messages(&1, workspace, id))

    wire = Handbean.Agent.Provider.OpenAI.build_input_items(restored, %{})
    outputs = Enum.filter(wire, &(&1["type"] == "function_call_output"))
    assert Enum.count(outputs, &is_list(&1["output"])) == 2

    assert Enum.all?(
             Enum.take(outputs, 4),
             &String.contains?(&1["output"], "Older tool image omitted")
           )

    refute Enum.any?(restored, &(&1.role == :user))

    # Reference text alone is below this budget; charging visual observations
    # must cross it. Fallback compacting also removes old images.
    config =
      Handbean.Agent.Config.from_opts(
        max_tokens: 6_000,
        compaction: [reserve_tokens: 1, keep_recent_tokens: 1],
        provider: Handbean.TestSupport.FakeProvider,
        provider_config: %{scenario: :simple_answer}
      )

    assert {:compacted, _} =
             Handbean.Agent.Compactor.maybe_compact(%Handbean.Agent.State{
               messages: messages,
               config: config
             })

    drain(runner)
  end

  defp observation_backend do
    fn
      %{"action" => "stop"}, _ ->
        {:ok, %{"text" => "stopped"}}

      _, _ ->
        {:ok,
         %{
           "image" => Base.encode64(@png),
           "mime_type" => "image/png",
           "text" => "observed",
           "side_effect" => "not_started"
         }}
    end
  end

  test "native transport rejects foreign responses, never retries input and closes its socket", %{
    workspace: workspace
  } do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    old =
      Map.new(
        [:computer_use_port, :computer_use_token],
        &{&1, Application.get_env(:handbean, &1)}
      )

    token = Ecto.UUID.generate()
    Application.put_env(:handbean, :computer_use_port, port)
    Application.put_env(:handbean, :computer_use_token, token)

    on_exit(fn ->
      :gen_tcp.close(listener)

      Enum.each(old, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:handbean, key),
          else: Application.put_env(:handbean, key, value)
      end)
    end)

    Harness.with_host!(%{computer_use_backend: Handbean.ComputerUse.Native})

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
        request = Handbean.JSON.decode!(line)
        assert request["token"] == token
        assert request["input"]["action"] == "click"
        assert request["deadline_ms"] > System.system_time(:millisecond)
        send(owner, {:native_wire, request})
        # A plausible success for a different UUID is never accepted.
        :ok =
          :gen_tcp.send(
            socket,
            Handbean.JSON.encode!(%{
              id: Ecto.UUID.generate(),
              result: %{side_effect: "committed", text: "foreign success"}
            }) <> "\n"
          )

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
        {:ok, stop_socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, line} = :gen_tcp.recv(stop_socket, 0, 5_000)
        stop = Handbean.JSON.decode!(line)
        assert stop["input"] == %{"action" => "stop"}
        assert stop["session"] == request["session"]

        :ok =
          :gen_tcp.send(
            stop_socket,
            Handbean.JSON.encode!(%{id: stop["id"], result: %{text: "stopped"}}) <> "\n"
          )

        :gen_tcp.close(stop_socket)
      end)

    script = fn messages, _ ->
      if Enum.any?(messages, &(&1.role == :tool_result)),
        do: "Observe before any retry",
        else:
          {:tools,
           [
             %{
               name: "computer",
               input: %{
                 "action" => "click",
                 "observation_id" => "fixture-receipt",
                 "x" => 40,
                 "y" => 85
               }
             }
           ]}
    end

    {id, runner} = start(workspace, script)

    assert_receive {:native_wire, wire}, 5_000
    assert String.starts_with?(wire["session"], id <> ":")
    assert %{status: status} = Harness.await_run_end(id)
    assert status in [:completed, "completed"]
    entry = Enum.find(Harness.transcript(id), &(&1["tool_name"] == "computer"))
    assert entry["tool_status"] == "error"
    assert entry["tool_error"] =~ "native_outcome_unknown"
    assert entry["details"]["side_effect"] == "unknown"
    assert entry["details"]["recovery"] == "observe"
    refute entry["output"] =~ "foreign success"
    drain(runner)
    Task.await(server, 5_000)
  end

  defp one_observation do
    fn messages, _ ->
      if Enum.any?(messages, &(&1.role == :tool_result)),
        do: "Observation handled",
        else: {:tools, [%{name: "computer", input: %{"action" => "observe"}}]}
    end
  end

  defp drain(runner) do
    ref = Process.monitor(runner)
    assert_receive {:DOWN, ^ref, :process, ^runner, _}, 5_000

    for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp start(workspace, script) do
    {:ok, conversation} = Handbean.ConversationStore.create("computer-ws")
    id = conversation["id"]
    Session.subscribe(id)
    on_exit(fn -> Harness.cancel!(id) end)

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(id, "Use the selected test window",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: [Handbean.Tool.Builtin.Computer],
               source: :cli,
               streaming: false
             )

    {id, runner}
  end
end
