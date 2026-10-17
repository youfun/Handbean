defmodule Handbean.E2E.WorkspaceSearchTest do
  @moduledoc """
  A workspace run searches with grep, reads the hit, and keeps the same answer
  in the finished transcript.

  Run: mix test --include e2e test/handbean/e2e/workspace_search_test.exs
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
    :ok
  end

  test "grep hit is read and the final answer matches the transcript" do
    %{workspace: workspace} = E2EHarness.isolate_home!("workspace-search")

    File.write!(
      Path.join(workspace, "lib.ex"),
      "defmodule Marker do\n  @value \"ORCHID-7711\"\nend\n"
    )

    File.mkdir_p!(Path.join([workspace, "generated", "assets"]))
    File.write!(Path.join(workspace, ".gitignore"), "generated/**\n")

    File.write!(
      Path.join([workspace, "generated", "assets", "bundle.js"]),
      "defmodule Marker do // ignored generated duplicate\n"
    )

    {:ok, conversation} = ConversationStore.create("search-ws")
    id = conversation["id"]
    :ok = Session.subscribe(id)

    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    result_text = fn messages ->
      messages
      |> Enum.filter(&(&1.role == :tool_result))
      |> Enum.map_join("\n", fn
        %{content: content} when is_binary(content) ->
          content

        %{content: blocks} when is_list(blocks) ->
          Enum.map_join(blocks, "\n", &(&1[:content] || &1["content"] || ""))

        _ ->
          ""
      end)
    end

    script = fn messages, _tools ->
      text = result_text.(messages)

      cond do
        text =~ "ORCHID-7711" ->
          "Found ORCHID-7711"

        text =~ "defmodule Marker" ->
          {:tools, [%{name: "read", input: %{"file_path" => "lib.ex"}}]}

        true ->
          {:tools,
           [
             %{
               name: "grep",
               input: %{"pattern" => "defmodule Marker", "path" => "lib.ex", "literal" => true}
             }
           ]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Find the marker",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbean.Agent.default_tools(),
               source: :cli,
               max_turns: 6,
               streaming: false
             )

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    entries = E2EHarness.transcript(id)

    assert Enum.any?(entries, fn entry ->
             entry["tool_name"] == "grep" and entry["tool_status"] == "done" and
               entry["output"] =~ "defmodule Marker" and
               not String.contains?(entry["output"], "bundle.js")
           end)

    assert Enum.any?(entries, &(&1["tool_name"] == "read" and &1["output"] =~ "ORCHID-7711"))

    assert Enum.any?(
             entries,
             &(&1["role"] == "assistant" and &1["content"] == "Found ORCHID-7711")
           )
  end

  test "a tool write is visible to the next grep without a full rebuild" do
    %{workspace: workspace} = E2EHarness.isolate_home!("workspace-search-update")
    {:ok, conversation} = ConversationStore.create("search-update-ws")
    id = conversation["id"]
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    step = :atomics.new(1, [])

    script = fn _messages, _tools ->
      case :atomics.add_get(step, 1, 1) do
        1 ->
          {:tools,
           [
             %{
               name: "grep",
               input: %{"pattern" => "INCREMENTAL-991", "path" => ".", "literal" => true}
             }
           ]}

        2 ->
          {:tools,
           [
             %{
               name: "write",
               input: %{"file_path" => "incremental.txt", "content" => "INCREMENTAL-991\n"}
             }
           ]}

        3 ->
          {:tools,
           [
             %{
               name: "grep",
               input: %{"pattern" => "INCREMENTAL-991", "path" => ".", "literal" => true}
             }
           ]}

        _ ->
          "Incremental search updated"
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Write and find the marker",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbean.Agent.default_tools(),
               source: :cli,
               max_turns: 6,
               streaming: false
             )

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    entries = E2EHarness.transcript(id)
    assert File.read!(Path.join(workspace, "incremental.txt")) == "INCREMENTAL-991\n"

    assert Enum.any?(entries, fn entry ->
             entry["tool_name"] == "grep" and entry["tool_status"] == "done" and
               entry["output"] =~ "incremental.txt:1:INCREMENTAL-991"
           end)
  end
end
