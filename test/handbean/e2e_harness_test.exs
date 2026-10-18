defmodule Handbean.TestSupport.E2EHarnessTest do
  use ExUnit.Case, async: false

  alias Handbean.TestSupport.E2EHarness

  defmodule HoldingProvider do
    @behaviour Handbean.Agent.Provider

    def complete(_messages, _tools, config) do
      send(config.notify, {:provider_waiting, self()})

      receive do
        :finish -> {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
      end
    end

    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  test "runtime cleanup stops unlinked providers before an isolated home is removed" do
    %{home: home, workspace: workspace} = E2EHarness.isolate_home!("harness-cleanup")
    E2EHarness.with_host!(%{data_dir: home})
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]

    assert {:ok, %{action: :started}} =
             Handbean.Agent.Coordinator.add_message(id, "hold",
               provider: HoldingProvider,
               provider_config: %{notify: self()},
               model: "cleanup-fixture",
               workspace_path: workspace,
               source: :web,
               streaming: false,
               tools: []
             )

    assert_receive {:provider_waiting, task}, 1_000
    ref = Process.monitor(task)
    :ok = Handbean.AgentRunSupervisor.stop_run(id)
    assert Process.alive?(task)

    assert :ok = E2EHarness.stop_runtime!()
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    assert Handbean.PubSub.Session.whereis(id) == nil

    File.rm_rf!(home)
    GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)

    :ok =
      Handbean.ConversationTranscriptStore.Journal.invalidate(
        Handbean.ConversationStore.index_path()
      )

    refute File.exists?(home)
  end
end
