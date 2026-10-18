defmodule Handbean.E2E.ExtensionHotReloadTest do
  @moduledoc """
  A user-reachable hot-reload path per test:

  1. Dropping an extension into `<workspace>/.handbean/extensions` and
     reloading registers `ext__*__ping`; a live Coordinator run calls the
     tool through the transcript, and a second reload swaps the tool's
     behavior for the conversation's next run.
  2. A broken compile leaves the last good tool registered and working; the
     next good reload picks the new version up.

  Run: mix test --include e2e test/handbean/e2e/extension_hot_reload_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session

  @moduletag :e2e

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "ext-e2e-#{Ecto.UUID.generate()}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)

    old_home = System.get_env("HOME")
    old_models = System.get_env("HANDBEAN_MODELS_FILE")
    models = Path.join(root, "models.json")

    File.write!(
      models,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HOME", home)
    System.put_env("HANDBEAN_MODELS_FILE", models)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if old_models,
        do: System.put_env("HANDBEAN_MODELS_FILE", old_models),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace}
  end

  test "a dropped extension answers a live run and a reload swaps behavior mid-conversation", %{
    workspace: workspace
  } do
    ext_name = unique_ext_name()
    tool = "ext__#{ext_name}__ping"
    module = "Ext.E2e.Arb#{ext_name}.Ping"

    write_ping_extension!(workspace, ext_name, module, "1.0.0", "pong-v1")

    assert {:ok, diags} = Handbean.Extension.HotReloader.reload(project: workspace)
    assert Enum.all?(diags, &(&1.type != :error)), inspect(diags)

    {:ok, entry} = Handbean.Tool.Registry.get(tool)
    assert {:ok, "pong-v1"} = entry.executor.(%{}, %{})

    sid = "ext-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    # Run 1: the agent calls the extension tool, transcript records "pong-v1".
    run(sid, workspace, tool)
    assert_tool_entry(sid, tool, "pong-v1")
    settle(sid)

    # Reload with a new version: same tool name, new behavior.
    write_ping_extension!(workspace, ext_name, module, "2.0.0", "pong-v2")

    assert {:ok, diags} = Handbean.Extension.HotReloader.reload(project: workspace)
    assert Enum.all?(diags, &(&1.type != :error)), inspect(diags)

    {:ok, reloaded} = Handbean.Tool.Registry.get(tool)
    assert {:ok, "pong-v2"} = reloaded.executor.(%{}, %{})

    # Run 2 in the same conversation picks the new version up.
    run(sid, workspace, tool)
    assert_tool_entry(sid, tool, "pong-v2")
    settle(sid)
  end

  test "a broken compile keeps the last good tool alive until the next good reload", %{
    workspace: workspace
  } do
    ext_name = unique_ext_name()
    tool = "ext__#{ext_name}__ping"
    module = "Ext.E2e.Arb#{ext_name}.Ping"

    write_ping_extension!(workspace, ext_name, module, "1.0.0", "pong-v1")
    assert {:ok, _} = Handbean.Extension.HotReloader.reload(project: workspace)

    # Break the entry file: the reload must not unregister the good tool.
    ext_dir = Path.join([workspace, ".handbean", "extensions", ext_name])
    File.write!(Path.join(ext_dir, "hot_demo.ex"), "this is not elixir\n")

    assert {:ok, diags} = Handbean.Extension.HotReloader.reload(project: workspace)
    assert diags != [], "a broken compile must produce a diagnostic"
    assert {:ok, still_good} = Handbean.Tool.Registry.get(tool)
    assert {:ok, "pong-v1"} = still_good.executor.(%{}, %{})

    # The next good reload swaps to the new version.
    write_ping_extension!(workspace, ext_name, module, "2.0.0", "pong-v2")
    assert {:ok, diags} = Handbean.Extension.HotReloader.reload(project: workspace)
    assert Enum.all?(diags, &(&1.type != :error)), inspect(diags)

    {:ok, fixed} = Handbean.Tool.Registry.get(tool)
    assert {:ok, "pong-v2"} = fixed.executor.(%{}, %{})
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp unique_ext_name, do: "e2eext#{System.unique_integer([:positive])}"

  defp write_ping_extension!(workspace, ext_name, module, version, result) do
    ext_dir = Path.join([workspace, ".handbean", "extensions", ext_name])
    File.mkdir_p!(ext_dir)

    File.write!(
      Path.join(ext_dir, "extension.json"),
      Jason.encode!(%{
        "name" => ext_name,
        "version" => version,
        "entry" => "hot_demo.ex",
        "tools" => [%{"name" => "ping"}]
      })
    )

    File.write!(
      Path.join(ext_dir, "hot_demo.ex"),
      """
      defmodule #{module} do
        @behaviour Handbean.Agent.Tool

        def name, do: "ext__#{ext_name}__ping"
        def description, do: "hot reload ping"
        def input_schema, do: %{"type" => "object", "properties" => %{}}
        def execute(_input, _context), do: {:ok, "#{result}"}
      end
      """
    )

    ext_dir
  end

  defp settle(sid, attempts \\ 200) do
    busy? = Registry.lookup(Handbean.AgentRunRegistry, sid) != []

    cond do
      busy? and attempts > 0 ->
        receive do
        after
          20 -> settle(sid, attempts - 1)
        end

      busy? ->
        flunk("run did not settle")

      true ->
        for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        end

        {:ok, session} = Session.start_or_get(session_id: sid)
        :sys.get_state(session)

        if tracker = Process.whereis(Handbean.Runtime.TaskTracker), do: :sys.get_state(tracker)

        :ok
    end
  end

  defp run(sid, workspace, tool) do
    script = fn messages, _defs ->
      if Enum.any?(messages, &match?(%Handbean.Agent.Message{role: :tool_result}, &1)) do
        "the extension tool answered"
      else
        {:tools, [%{name: tool, input: %{}}]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "call the extension tool",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbean.Agent.default_tools(),
               source: :cli,
               streaming: false,
               max_turns: 4
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000
  end

  defp assert_tool_entry(sid, tool, expected_output) do
    {:ok, entries} = ConversationTranscriptStore.list(sid)

    # Both runs call the same tool; assert on the most recent entry.
    tool_entry = entries |> Enum.filter(&(&1["tool_name"] == tool)) |> List.last()

    assert tool_entry, "the extension tool call must appear in the transcript"
    assert tool_entry["tool_status"] == "done"
    assert tool_entry["output"] =~ expected_output
    assert tool_entry["tool_error"] in [nil, ""]

    assert Enum.any?(
             entries,
             &(&1["role"] == "assistant" and &1["status"] == "completed" and
                 &1["content"] == "the extension tool answered")
           )
  end
end
