defmodule Handbean.E2E.ProgressWatchdogTest do
  @moduledoc """
  An interactive run may exceed its configured watchdog window while it keeps
  streaming progress. The final answer and terminal status must remain durable.

  Run: mix test --include e2e test/handbean/e2e/progress_watchdog_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  defmodule ProgressProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, tool_defs, config),
      do: stream(messages, tool_defs, config, fn _ -> :ok end)

    @impl true
    def stream(_messages, _tool_defs, _config, on_chunk) do
      Enum.each(["still ", "working ", "done"], fn chunk ->
        receive do
        after
          150 -> on_chunk.(chunk)
        end
      end)

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbean.Agent.Message.assistant("still working done")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})
    :ok
  end

  for source <- [:live_view, :native, :cli, :sns, :webhook] do
    @tag source: source
    test "repeated reads respect the progress policy for #{source}", %{source: source} do
      %{workspace: workspace} = E2EHarness.isolate_home!("repeated-reads")
      File.write!(Path.join(workspace, "sample.txt"), "unchanged contents\n")
      {:ok, conversation} = ConversationStore.create("repeated-reads")
      id = conversation["id"]
      :ok = Session.subscribe(id)
      ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

      script = fn messages, _tools ->
        if Enum.count(messages, &(&1.role == :tool_result)) < 4 do
          {:tools, [%{name: "read", input: %{"file_path" => "sample.txt"}}]}
        else
          "Finished after rereading"
        end
      end

      assert {:ok, %{action: :started}} =
               Coordinator.add_message(id, "Read the file four times, then finish",
                 workspace_path: workspace,
                 model: "fake-model",
                 provider: Handbean.TestSupport.FakeProvider,
                 provider_config: %{scenario: {:script, script}},
                 tools: [Handbean.Tool.Builtin.Read],
                 source: source,
                 max_turns: 6,
                 streaming: true
               )

      payload = E2EHarness.await_run_end(id)
      entries = E2EHarness.transcript(id)
      reads = Enum.filter(entries, &(&1["tool_name"] == "read"))
      assert Enum.all?(reads, &(&1["tool_status"] == "done"))
      assert Enum.all?(reads, &String.contains?(&1["output"], "unchanged contents"))

      if source in [:live_view, :native] do
        assert payload[:status] in [:completed, "completed"]
        assert length(reads) == 4

        assert Enum.any?(entries, fn entry ->
                 entry["role"] == "assistant" and
                   entry["content"] == "Finished after rereading"
               end)

        refute_received {:agent_event, %{kind: :stall_check_requested}}
      else
        assert payload[:status] in [:stalled, "stalled"]
        assert payload[:signal] == :repeated_call
        assert length(reads) == 3
      end
    end
  end

  test "streaming progress keeps an interactive run alive beyond one watchdog window" do
    %{workspace: workspace} = E2EHarness.isolate_home!("progress-watchdog")
    {:ok, conversation} = ConversationStore.create("progress-watchdog")
    id = conversation["id"]
    :ok = Session.subscribe(id)

    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "keep working",
               workspace_path: workspace,
               model: "fake-model",
               provider: ProgressProvider,
               provider_config: %{},
               tools: [],
               source: :live_view,
               timeout_ms: 250,
               streaming: true
             )

    assert_receive {:agent_event, %{kind: :run_start}}, 1_000
    assert [{index, _metadata}] = Registry.lookup(ExFff.Registry, Path.expand(workspace))
    assert Process.alive?(index)

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    assert Enum.any?(
             E2EHarness.transcript(id),
             &(&1["role"] == "assistant" and &1["content"] == "still working done")
           )
  end
end
