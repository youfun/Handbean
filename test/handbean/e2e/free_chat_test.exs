defmodule Handbean.E2E.FreeChatTest do
  @moduledoc """
  A workspace-independent chat runs to completion without a project root.

  The durable result is a `scope: "free"` conversation, a user and assistant
  transcript, and a finished run. The run must not receive a working directory
  or workspace file tools.

  Run: mix test --include e2e test/handbean/e2e/free_chat_test.exs
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
