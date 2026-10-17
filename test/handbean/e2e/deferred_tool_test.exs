defmodule Handbean.E2E.DeferredToolTest do
  @moduledoc """
  Deferred tools stay out of the first provider request. `tool_search` loads a
  match onto the conversation, the next request appends that schema, and a
  later run in the same conversation still declares it.

  Run: mix test --include e2e test/handbean/e2e/deferred_tool_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session
  alias Handbean.Tool.Registry

  @moduletag :e2e

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "deferred-e2e-#{Ecto.UUID.generate()}")
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

    %{workspace: workspace}
  end

  test "a deferred tool is searched, appended, called, and kept on the conversation", %{
    workspace: workspace
  } do
    :ok =
      Registry.register_virtual(
        "calendar_create",
        "Create a calendar event on the device",
        %{
          "type" => "object",
          "properties" => %{"title" => %{"type" => "string", "description" => "Event title"}},
          "required" => ["title"]
        },
        fn input, _context -> {:ok, "created #{input["title"]}"} end,
        deferred?: true,
        meta: %{server: "calendar", server_description: "Create and update device events"}
      )

    :ok =
      Registry.register_virtual(
        "weather_report",
        "Forecast the weekly weather",
        %{"type" => "object", "properties" => %{}},
        fn _input, _context -> {:ok, "sunny"} end,
        deferred?: true,
        meta: %{server: "weather", server_description: "Forecast the weather"}
      )

    on_exit(fn ->
      Registry.unregister("calendar_create")
      Registry.unregister("weather_report")
    end)

    sid = "deferred-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    on_exit(fn -> Handbean.TestSupport.E2EHarness.cancel!(sid) end)

    parent = self()

    script = fn messages, defs ->
      names = Enum.map(defs, & &1.name)
      send(parent, {:defs, names})
      results = Enum.count(messages, &(&1.role == :tool_result))

      cond do
        results == 0 ->
          {:tools, [%{name: "tool_search", input: %{"query" => "create a calendar event"}}]}

        results == 1 ->
          {:tools, [%{name: "calendar_create", input: %{"title" => "standup"}}]}

        true ->
          "created the event"
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "add a calendar event",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}, notify: parent},
               tools: Handbean.Agent.default_tools(),
               mcp: false,
               trusted_project?: true,
               source: :cli,
               streaming: false,
               max_turns: 4
             )

    assert_receive {:provider_config, first_config}, 20_000
    assert first_config.system_prompt =~ "Deferred tools"
    assert first_config.system_prompt =~ "calendar: Create and update device events"
    assert first_config.system_prompt =~ "weather: Forecast the weather"

    assert_receive {:defs, first_names}, 20_000
    assert "tool_search" in first_names
    assert "read" in first_names
    refute "calendar_create" in first_names
    refute "weather_report" in first_names

    assert_receive {:defs, second_names}, 20_000
    assert second_names == first_names ++ ["calendar_create"]

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000

    {:ok, %{"loaded_tools" => ["calendar_create"]}} = ConversationStore.get_meta(sid)

    {:ok, entries} = ConversationTranscriptStore.list(sid)
    search = Enum.find(entries, &(&1["tool_name"] == "tool_search"))
    created = Enum.find(entries, &(&1["tool_name"] == "calendar_create"))
    assert search["tool_status"] == "done"
    assert search["output"] =~ "calendar_create"
    assert created["tool_status"] == "done"
    assert created["output"] == "created standup"

    follow_up = fn _messages, defs ->
      send(parent, {:follow_up, Enum.map(defs, & &1.name)})
      "the event is still there"
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "is the event still loaded?",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, follow_up}},
               tools: Handbean.Agent.default_tools(),
               mcp: false,
               trusted_project?: true,
               source: :cli,
               streaming: false,
               max_turns: 2
             )

    assert_receive {:follow_up, follow_names}, 20_000
    assert List.last(follow_names) == "calendar_create"
    refute "weather_report" in follow_names
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000
  end

  test "tool_search stays out of the request when nothing is deferred", %{workspace: workspace} do
    sid = "deferred-idle-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    on_exit(fn -> Handbean.TestSupport.E2EHarness.cancel!(sid) end)

    parent = self()

    script = fn _messages, defs ->
      send(parent, {:idle_defs, Enum.map(defs, & &1.name)})
      "nothing to search"
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "hello",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}, notify: parent},
               tools: Handbean.Agent.default_tools(),
               mcp: false,
               trusted_project?: true,
               source: :cli,
               streaming: false,
               max_turns: 2
             )

    assert_receive {:provider_config, config}, 20_000
    refute config.system_prompt =~ "Deferred tools"
    assert_receive {:idle_defs, names}, 20_000
    assert "read" in names
    refute "tool_search" in names
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000
  end
end
