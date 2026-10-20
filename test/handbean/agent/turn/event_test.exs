defmodule Handbean.Agent.TurnEventTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.{Config, State, Turn}
  alias Handbean.TestSupport.FakeProvider

  describe "event emission" do
    test "streaming emits message_delta chunks" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_chunks}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      chunks =
        events
        |> Agent.get(& &1)
        |> Enum.filter(fn {kind, _payload} -> kind == :message_delta end)
        |> Enum.map(fn {_kind, payload} -> payload.chunk end)

      assert chunks == ["Hello", " from", " stream"]
    end

    test "streaming emits final message when provider produces no chunks" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_no_chunks}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      assert {:message_delta, %{chunk: "Fallback streamed response"}} in Agent.get(events, & &1)
    end

    test "streaming emits the missing final tail when final assistant text is longer than streamed chunks" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :streaming_partial_then_final_longer}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed

      chunks =
        events
        |> Agent.get(& &1)
        |> Enum.filter(fn {kind, _payload} -> kind == :message_delta end)
        |> Enum.map(fn {_kind, payload} -> payload.chunk end)

      assert chunks == ["Now I have a", " complete", " picture of the codebase."]
    end

    test "provider thinking events are forwarded without becoming message text" do
      defmodule ThinkingEventProvider do
        @behaviour Handbean.Agent.Provider

        alias Handbean.Agent.Message

        def complete(messages, tool_defs, config),
          do: stream(messages, tool_defs, config, config.on_chunk)

        def stream(_messages, _tool_defs, config, _on_chunk) do
          config.on_event.({:thinking_delta, %{chunk: "private reasoning"}})

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               Message.assistant_blocks([
                 %{type: "thinking", thinking: "private reasoning"},
                 %{type: "text", text: "visible answer"}
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 2},
             response_metadata: %{}
           }}
        end
      end

      config = %Config{
        provider: ThinkingEventProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{}
      }

      state = State.init(config, "Hello")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      result =
        Turn.run_loop(state,
          streaming: true,
          on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
        )

      assert result.status == :completed
      assert {:thinking_delta, %{chunk: "private reasoning"}} in Agent.get(events, & &1)
      assert {:message_delta, %{chunk: "visible answer"}} in Agent.get(events, & &1)
      refute {:message_delta, %{chunk: "private reasoning"}} in Agent.get(events, & &1)
    end

    test "usage updates are cumulative and arrive before tools and run_end" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :tool_use_chain}
      }

      {:ok, events} = Agent.start_link(fn -> [] end)

      result =
        Turn.run_loop(State.init(config, "Read a file"),
          on_event: fn event -> Agent.update(events, &[event | &1]) end
        )

      assert result.status == :completed
      events = Agent.get(events, &Enum.reverse/1)

      relevant =
        Enum.filter(events, fn {kind, _} -> kind in [:usage_updated, :tool_start, :run_end] end)

      assert [
               {:usage_updated, %{usage: %{input_tokens: 10, output_tokens: 15}}},
               {:tool_start, _},
               {:usage_updated, %{usage: %{input_tokens: 25, output_tokens: 35}}},
               {:run_end, %{usage: %{input_tokens: 25, output_tokens: 35}}}
             ] = relevant
    end

    test "run_end event includes cumulative provider usage" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")

      events =
        Agent.start_link(fn -> [] end)
        |> elem(1)

      result =
        Turn.run_loop(state,
          on_event: fn event ->
            Agent.update(events, &(&1 ++ [event]))
          end
        )

      assert result.status == :completed

      assert {:run_end, payload} =
               events
               |> Agent.get(& &1)
               |> Enum.find(fn {kind, _payload} -> kind == :run_end end)

      assert payload.usage.input_tokens > 0
      assert payload.usage.output_tokens > 0
    end
  end
end
