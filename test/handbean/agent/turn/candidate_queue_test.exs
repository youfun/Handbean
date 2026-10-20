defmodule Handbean.Agent.TurnCandidateQueueTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.{Config, State, Turn}
  alias Handbean.TestSupport.FakeProvider

  defp injected_events(events) do
    events
    |> Agent.get(& &1)
    |> Enum.filter(&match?({:candidate_message_injected, _}, &1))
  end

  describe "candidate queue injection" do
    test "injects steer messages before provider call" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-steer", owner: self())

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer now",
          deliver_as: :steer,
          message_id: "msg-steer-start"
        )

      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :echo_last_user, notify: self()}
      }

      state = State.init(config, "initial")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert_receive {:provider_messages, provider_messages}
      assert Enum.map(provider_messages, & &1.content) == ["initial", "steer now"]
      assert result.status == :completed
      assert List.last(result.messages).content == "echo: steer now"

      assert [
               {:candidate_message_injected,
                %{deliver_as: :steer, count: 1, message_ids: ["msg-steer-start"]}}
             ] = injected_events(events)
    end

    test "injects steer messages after tool execution before the next provider call" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-tool-steer", owner: self())

      test_pid = self()
      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: File.cwd!() |> Path.join("test/fixtures"),
        provider_config: %{scenario: :steer_after_tool, notify: self()}
      }

      state = State.init(config, "read first")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn
            {:tool_end, _payload} = event ->
              Agent.update(events, &(&1 ++ [event]))

              Handbean.Agent.CandidateQueue.enqueue(queue, "after tool",
                deliver_as: :steer,
                message_id: "msg-steer-after-tool"
              )

              send(test_pid, :tool_ended)

            event ->
              Agent.update(events, &(&1 ++ [event]))
          end
        )

      assert_receive :tool_ended
      assert_receive {:provider_messages, first_call}
      assert_receive {:provider_messages, second_call}
      refute Enum.any?(first_call, &(&1.content == "after tool"))
      assert Enum.any?(second_call, &(&1.role == :user and &1.content == "after tool"))
      assert result.status == :completed
      assert List.last(result.messages).content == "echo: after tool"

      assert [
               {:candidate_message_injected,
                %{deliver_as: :steer, count: 1, message_ids: ["msg-steer-after-tool"]}}
             ] = injected_events(events)
    end

    test "continues after end_turn when follow_up messages are pending" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-follow", owner: self())

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "follow up",
          deliver_as: :follow_up,
          message_id: "msg-follow-end"
        )

      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :echo_last_user, notify: self()}
      }

      state = State.init(config, "initial")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert_receive {:provider_messages, first_call}
      assert_receive {:provider_messages, second_call}
      assert Enum.map(first_call, & &1.content) == ["initial"]
      assert Enum.any?(second_call, &(&1.role == :user and &1.content == "follow up"))
      assert result.status == :completed
      assert result.turn == 2
      assert List.last(result.messages).content == "echo: follow up"

      assert injected_events(events) == [
               {:candidate_message_injected, %{deliver_as: :steer, count: 0, message_ids: []}},
               {:candidate_message_injected,
                %{deliver_as: :follow_up, count: 1, message_ids: ["msg-follow-end"]}}
             ]
    end

    test "emits message_ids for remaining follow_up after start-of-turn steer drain" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-both-pending", owner: self())

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer first",
          deliver_as: :steer,
          message_id: "msg-both-steer"
        )

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "follow later",
          deliver_as: :follow_up,
          message_id: "msg-both-follow"
        )

      {:ok, events} = Agent.start_link(fn -> [] end)

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :echo_last_user, notify: self()}
      }

      state = State.init(config, "initial")

      result =
        Turn.run_loop(state,
          candidate_queue: queue,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      assert injected_events(events) == [
               {:candidate_message_injected,
                %{deliver_as: :steer, count: 1, message_ids: ["msg-both-steer"]}},
               {:candidate_message_injected, %{deliver_as: :steer, count: 0, message_ids: []}},
               {:candidate_message_injected,
                %{deliver_as: :follow_up, count: 1, message_ids: ["msg-both-follow"]}}
             ]
    end

    test "keeps completed behavior when no pending messages exist" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(session_id: "turn-none", owner: self())

      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")
      result = Turn.run_loop(state, candidate_queue: queue)

      assert result.status == :completed
      assert length(result.messages) == 2

      assert {:error, :sealed} =
               Handbean.Agent.CandidateQueue.enqueue(queue, "arrived after completion")
    end

    test "does not leak the streamed text tracker process" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_chunks}
      }

      before_links = self() |> Process.info(:links) |> elem(1) |> MapSet.new()

      try do
        state = State.init(config, "Hello")
        assert %State{status: :completed} = Turn.run_loop(state, streaming: true)

        after_links = self() |> Process.info(:links) |> elem(1) |> MapSet.new()
        assert MapSet.equal?(after_links, before_links)
      after
        self()
        |> Process.info(:links)
        |> elem(1)
        |> MapSet.new()
        |> MapSet.difference(before_links)
        |> Enum.each(fn pid ->
          if Process.alive?(pid), do: Agent.stop(pid)
        end)
      end
    end
  end
end
