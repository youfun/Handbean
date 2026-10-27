defmodule Handbean.E2E.HostBrowserTest do
  @moduledoc """
  A host browser backend is called from a live run through the injected CLI
  runner. Chromium is not started.

  Run: mix test --include e2e test/handbean/e2e/host_browser_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})
    Handbean.Tool.Builtin.Browser.release_backend!()

    ExUnit.Callbacks.on_exit(fn ->
      Handbean.Tool.Builtin.Browser.release_backend!()
      :persistent_term.erase({__MODULE__, :argv})
    end)

    :ok
  end

  test "a run drives the stubbed browser session and records the snapshot" do
    %{workspace: workspace} = E2EHarness.isolate_home!("host-browser")
    E2EHarness.with_host!(%{browser_backend: :cli})
    :ok = E2EHarness.register_tool!(Handbean.Tool.Builtin.Browser)
    Handbean.Tool.Builtin.Browser.fix_backend!()

    {:ok, conversation} =
      ConversationStore.create("browser-ws", permission_mode: "yolo")

    id = conversation["id"]
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    runner = fn argv, _opts ->
      :persistent_term.put({__MODULE__, :argv}, argv)

      {:ok,
       %{
         stdout:
           Handbean.JSON.encode!(%{
             "success" => true,
             "data" => %{"title" => "Example", "url" => "https://example.test"}
           }),
         stderr: "",
         exit_code: 0
       }}
    end

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        "Browser snapshot recorded"
      else
        {:tools, [%{name: "browser", input: %{"args" => ["open", "https://example.test"]}}]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Open the page",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbean.Agent.default_tools() ++ [Handbean.Tool.Builtin.Browser],
               source: :cli,
               streaming: false,
               browser_runner: runner
             )

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]
    argv = :persistent_term.get({__MODULE__, :argv}, nil)
    assert is_list(argv)
    assert "open" in argv
    assert "https://example.test" in argv
    refute Enum.any?(argv, &(&1 == "agent-browser"))

    entries = E2EHarness.transcript(id)
    assert Enum.any?(entries, &(&1["tool_name"] == "browser" and &1["tool_status"] == "done"))

    assert Enum.any?(
             entries,
             &(&1["role"] == "assistant" and &1["content"] == "Browser snapshot recorded")
           )
  end

  test "a free chat searches through public browser navigation without approval" do
    E2EHarness.isolate_home!("free-chat-browser-search")
    E2EHarness.with_host!(%{browser_backend: :cli})
    :ok = E2EHarness.register_tool!(Handbean.Tool.Builtin.Browser)
    Handbean.Tool.Builtin.Browser.fix_backend!()

    {:ok, conversation} = ConversationStore.create_free(title: "Browser search")
    id = conversation["id"]
    search_url = "https://www.google.com/search?q=vitamin%20D3"
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    runner = fn argv, _opts ->
      :persistent_term.put({__MODULE__, :argv}, argv)

      {:ok,
       %{
         stdout:
           Handbean.JSON.encode!(%{
             "success" => true,
             "data" => %{"title" => "Search results", "url" => search_url}
           }),
         stderr: "",
         exit_code: 0
       }}
    end

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        "Search results recorded"
      else
        {:tools, [%{name: "browser", input: %{"args" => ["open", search_url]}}]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Search the web",
               chat_scope: :free,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbean.Agent.free_chat_tools(),
               source: :cli,
               streaming: false,
               browser_runner: runner
             )

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    argv = :persistent_term.get({__MODULE__, :argv}, nil)
    assert is_list(argv)
    assert Enum.take(argv, -2) == ["open", search_url]

    %{events: events} = Session.snapshot(id)
    refute Enum.any?(events, &(&1.kind == :tool_approval_requested))

    entries = E2EHarness.transcript(id)
    assert Enum.any?(entries, &(&1["tool_name"] == "browser" and &1["tool_status"] == "done"))
  end
end
