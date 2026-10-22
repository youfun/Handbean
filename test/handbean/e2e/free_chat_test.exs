defmodule Handbean.E2E.FreeChatTest do
  @moduledoc """
  A workspace-independent chat runs to completion without a project root.

  The durable result is a `scope: "free"` conversation, a user and assistant
  transcript, and a finished run. The run must not receive a working directory
  or workspace file tools.

  Run: mix test --include e2e test/handbean/e2e/free_chat_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.{Config, Coordinator, State}
  alias Handbean.ConversationStore
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session

  @moduletag :e2e

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})

    old_home = System.get_env("HOME")
    home_dir = Path.join(System.tmp_dir!(), "handbean_free_chat_#{Ecto.UUID.generate()}")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "a free chat completes without a workspace path or file tools" do
    {:ok, conversation} = ConversationStore.create_free(title: "Free chat")
    sid = conversation["id"]

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "hello without a project",
               chat_scope: :free,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: :simple_answer},
               tools: Handbean.Agent.free_chat_tools(),
               source: :live_view,
               streaming: false,
               max_turns: 3
             )

    wait_for_run_end(sid)

    %{events: events} = Session.snapshot(sid)

    assert Enum.any?(events, fn event ->
             event.kind == :run_end and event.payload[:status] in ["completed", :completed]
           end)

    {:ok, meta} = ConversationStore.get_metadata(sid)
    assert meta["scope"] == "free"
    assert meta["workspace_id"] in [nil, ""]
    assert ConversationStore.list_for_workspace("missing") == []
    assert Enum.any?(ConversationStore.list_free(), &(&1["id"] == sid))

    {:ok, entries} = ConversationTranscriptStore.list(sid)

    assert Enum.any?(
             entries,
             &(&1["role"] == "user" and &1["content"] == "hello without a project")
           )

    assert Enum.any?(entries, &(&1["role"] == "assistant"))

    %{meta: session_meta} = Session.snapshot(sid)
    refute session_meta[:running?]
  end

  test "free chat does not expose, approve, or execute globally registered bash" do
    {:ok, conversation} = ConversationStore.create_free(title: "Isolated free chat")
    sid = conversation["id"]
    marker = Path.join(System.get_env("HOME"), "bash-must-not-run")
    parent = self()

    assert "bash" in Handbean.Tool.Registry.list()

    scenario = fn messages, tool_defs ->
      send(parent, {:free_chat_tool_defs, Enum.map(tool_defs, & &1.name)})

      if Enum.any?(messages, &match?(%Handbean.Agent.Message{role: :tool_result}, &1)) do
        "finished after denied tool call"
      else
        {:tools, [%{name: "bash", input: %{"command" => "touch #{marker}"}}]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "try a workspace tool",
               chat_scope: :free,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, scenario}},
               tools: Handbean.Agent.free_chat_tools(),
               allowed_tools: ["bash" | Enum.map(Handbean.Agent.free_chat_tools(), & &1.name())],
               source: :live_view,
               streaming: false,
               max_turns: 3
             )

    wait_for_run_end(sid)

    assert_receive {:free_chat_tool_defs, first_turn_defs}
    refute "bash" in first_turn_defs
    refute File.exists?(marker)

    %{events: events} = Session.snapshot(sid)
    refute Enum.any?(events, &(&1.kind == :tool_approval_requested))

    assert Enum.any?(events, fn event ->
             event.kind == :run_end and event.payload[:status] in ["completed", :completed]
           end)
  end

  test "stall resume reapplies the free-chat ceiling and disables MCP" do
    config =
      Config.from_opts(
        provider: Handbean.TestSupport.FakeProvider,
        provider_config: %{scenario: :simple_answer, notify: self()},
        model: "fake-model",
        max_turns: 2,
        allowed_tools: nil
      )

    config = %{config | context: Map.put(config.context, :mcp_scope, %{servers: ["legacy"]})}

    interrupted =
      config
      |> State.init("continue after stall")
      |> then(&%{&1 | status: :interrupted, interrupt_data: %{type: :stall_check}})

    canonical_names = Enum.map(Handbean.Agent.free_chat_tools(), & &1.name())

    assert {:ok, resumed} =
             Handbean.Agent.resume_after_stall_check(interrupted, [],
               chat_scope: :free,
               mcp: true,
               tools: [Handbean.Tool.Builtin.Bash | Handbean.Agent.free_chat_tools()],
               allowed_tools: ["bash" | canonical_names],
               streaming: false
             )

    assert resumed.status == :completed
    assert resumed.config.allowed_tools == canonical_names
    assert resumed.config.context[:chat_scope] == :free
    refute Map.has_key?(resumed.config.context, :mcp_scope)

    assert_receive {:provider_tool_defs, tool_defs}
    refute "bash" in Enum.map(tool_defs, & &1.name)
  end

  test "stall resume cannot widen an existing free-chat ceiling" do
    for existing_allowed <- [["web_fetch"], []] do
      config =
        Config.from_opts(
          provider: Handbean.TestSupport.FakeProvider,
          provider_config: %{scenario: :simple_answer, notify: self()},
          model: "fake-model",
          max_turns: 2,
          chat_scope: :free,
          allowed_tools: existing_allowed
        )

      interrupted =
        config
        |> State.init("continue with narrow tools")
        |> then(&%{&1 | status: :interrupted, interrupt_data: %{type: :stall_check}})

      assert {:ok, resumed} =
               Handbean.Agent.resume_after_stall_check(interrupted, [], streaming: false)

      assert resumed.status == :completed
      assert resumed.config.allowed_tools == existing_allowed

      assert_receive {:provider_tool_defs, tool_defs}
      assert Enum.map(tool_defs, & &1.name) == existing_allowed
    end
  end

  defp wait_for_run_end(sid, attempts \\ 50)

  defp wait_for_run_end(sid, 0), do: flunk("expected run_end event for #{sid}")

  defp wait_for_run_end(sid, attempts) do
    %{events: events} = Session.snapshot(sid)

    if Enum.any?(events, &(&1.kind == :run_end)) do
      :ok
    else
      Process.sleep(20)
      wait_for_run_end(sid, attempts - 1)
    end
  end

  test "workspace runs still require a workspace path" do
    assert {:error, {:missing_opts, missing}} =
             Coordinator.add_message("unused", "hello",
               model: "fake-model",
               provider_config: %{},
               tools: [],
               source: :cli
             )

    assert :workspace_path in missing
  end
end
