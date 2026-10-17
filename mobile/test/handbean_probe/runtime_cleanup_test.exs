defmodule HandbeanProbe.RuntimeCleanupTest do
  use ExUnit.Case, async: false

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

  test "cleanup stops an unlinked provider and drains lifecycle writes before the home is removed" do
    dir = Path.join(System.tmp_dir!(), "mobile_cleanup_#{System.unique_integer([:positive])}")
    host = Application.fetch_env!(:handbean, :host)
    Handbean.Host.put!(Map.put(host, :data_dir, dir))

    on_exit(fn ->
      HandbeanProbe.RuntimeCleanup.stop!()
      Application.put_env(:handbean, :host, host)
      File.rm_rf!(dir)
    end)

    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]

    assert {:ok, %{action: :started}} =
             Handbean.Agent.Coordinator.add_message(id, "hold",
               provider: HoldingProvider,
               provider_config: %{notify: self()},
               model: "cleanup-fixture",
               workspace_path: dir,
               source: :native,
               streaming: false,
               tools: []
             )

    assert_receive {:provider_waiting, task}, 1_000
    ref = Process.monitor(task)
    :ok = Handbean.AgentRunSupervisor.stop_run(id)
    assert Process.alive?(task)
    assert :ok = HandbeanProbe.RuntimeCleanup.stop!()
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    assert Handbean.PubSub.Session.whereis(id) == nil

    File.rm_rf!(dir)
    GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)

    :ok =
      Handbean.ConversationTranscriptStore.Journal.invalidate(
        Handbean.ConversationStore.index_path()
      )

    refute File.exists?(dir)
  end
end
