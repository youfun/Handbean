defmodule Handbean.E2E.MemoryRecallTest do
  @moduledoc """
  Keyword-bag mem_recall finds an engram that mem_learn stored in an earlier run.

  Run: mix test --include e2e test/handbean/e2e/memory_recall_test.exs
  """

  use Handbean.DataCase, async: false

  alias Handbean.Agent.{Config, Coordinator, Message, State}
  alias Handbean.Agent.Middleware.MemoryProjection
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  @learned "Handbean UI locale now persists globally in SQLite ui_settings under primary key ui.locale. 定时任务 预览 file search scoring is tiered."

  test "keyword recall finds a memory learned in a previous run" do
    %{workspace: workspace} = E2EHarness.isolate_home!("memory-recall")
    {:ok, conversation} = ConversationStore.create("memory-recall")
    id = conversation["id"]
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    learn = :atomics.new(1, [])

    learn_script = fn _messages, _tools ->
      case :atomics.add_get(learn, 1, 1) do
        1 ->
          {:tools, [%{name: "mem_learn", input: %{"content" => @learned, "kind" => "pattern"}}]}

        _ ->
          "Learned the locale pattern"
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Remember how UI locale is stored",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, learn_script}},
               om: %{memory_scope: "workspace", privacy_mode: "standard"},
               tools: Handbean.Agent.default_tools(),
               source: :cli,
               max_turns: 4,
               streaming: false
             )

    learn_payload = E2EHarness.await_run_end(id)
    assert learn_payload[:status] in ["completed", :completed]

    queries = [
      {"UI locale SQLite ui_settings commit language persistence", :hit},
      {"ex_fff file_search scoring glob", :hit},
      {"定时 预览 监控", :hit},
      {"kubernetes helm chart", :miss},
      {"Handbean", :miss},
      {"What should we do with the build for this release?", :miss},
      {"定时任务预览怎么做", :hit}
    ]

    recall = :atomics.new(1, [])

    recall_script = fn _messages, _tools ->
      case Enum.at(queries, :atomics.add_get(recall, 1, 1) - 1) do
        {query, _kind} ->
          {:tools, [%{name: "mem_recall", input: %{"query" => query}}]}

        nil ->
          "Finished memory search"
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Search memory for the locale notes",
               workspace_path: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, recall_script}},
               om: %{memory_scope: "workspace", privacy_mode: "standard"},
               tools: Handbean.Agent.default_tools(),
               source: :cli,
               max_turns: 10,
               streaming: false
             )

    recall_payload = E2EHarness.await_run_end(id, 15_000)
    assert recall_payload[:status] in ["completed", :completed]

    entries = E2EHarness.transcript(id)

    assert Enum.any?(entries, fn entry ->
             entry["tool_name"] == "mem_learn" and entry["tool_status"] == "done" and
               entry["output"] =~ @learned
           end)

    for {query, kind} <- queries do
      output = recall_output(entries, query)

      case kind do
        :hit ->
          assert output =~ "<stored-knowledge", "expected a hit for #{query}"
          assert output =~ @learned

        :miss ->
          assert output == "No memories found.", "expected a miss for #{query}"
      end
    end

    # Session-start injection is the middleware, not another Coordinator run.
    # A function-word message must not pull the learned engram into the prompt.
    # A no-space Chinese phrase that overlaps the engram still does.
    refute injected?("What should we do with this?", "memory-recall")
    assert injected?("定时任务预览怎么做", "memory-recall")
  end

  test "Repo.init keeps the configured database unless the host injects data_dir" do
    previous = Application.get_env(:handbean, :host)

    ExUnit.Callbacks.on_exit(fn ->
      if previous do
        Application.put_env(:handbean, :host, previous)
      else
        Application.delete_env(:handbean, :host)
      end
    end)

    Application.put_env(:handbean, :host, %{computer_use_backend: :native})

    assert {:ok, kept} = Handbean.Repo.init(:runtime, database: "/x/y.db")
    assert kept[:database] == "/x/y.db"

    :ok = Handbean.Host.put!(%{data_dir: "/tmp/explicit-data-dir"})

    assert {:ok, still_explicit} = Handbean.Repo.init(:runtime, database: "/x/y.db")
    assert still_explicit[:database] == "/x/y.db"
  end

  defp injected?(user_text, workspace_id) do
    state = %State{
      config: %Config{
        system_prompt: "Base system prompt",
        builtin_memory_enabled: true,
        context: %{
          workspace_id: workspace_id,
          memory_scope: "workspace",
          privacy_mode: "standard"
        }
      },
      messages: [Message.user(user_text)],
      run_metadata: %{session_id: "memory-recall-injection"}
    }

    result = MemoryProjection.call(:session_start, state)
    result.config.system_prompt =~ @learned
  end

  defp recall_output(entries, query) do
    Enum.find_value(entries, fn entry ->
      input = entry["input"] || %{}
      asked = input["query"] || input[:query]

      if entry["tool_name"] == "mem_recall" and entry["tool_status"] == "done" and asked == query do
        entry["output"]
      end
    end)
  end
end
