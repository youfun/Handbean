defmodule Handbean.Agent.StateTest do
  @moduledoc """
  Tests for the agent state management.

  Reference: `alloy/` (State struct and operations)

  Covers:
    - Initialization from config and prompt
    - Message appending
    - Turn incrementing
    - Usage merging
    - Provider state management
  """

  use ExUnit.Case, async: true

  alias Handbean.Agent.{Config, State, Message}

  describe "init/2" do
    test "creates initial state with user message" do
      config = %Config{}
      state = State.init(config, "Hello world")

      assert state.turn == 0
      assert state.status == :running
      assert length(state.messages) == 1

      [msg] = state.messages
      assert msg.role == :user
      assert msg.content == "Hello world"
    end

    test "initializes empty usage" do
      config = %Config{}
      state = State.init(config, "test")

      assert state.usage.input_tokens == 0
      assert state.usage.output_tokens == 0
    end

    test "initializes empty provider state" do
      config = %Config{}
      state = State.init(config, "test")

      assert state.provider_state == %{}
    end
  end

  describe "append_messages/2" do
    test "appends a single message" do
      config = %Config{}
      state = State.init(config, "test")
      msg = Message.assistant("Response")

      result = State.append_messages(state, msg)
      assert length(result.messages) == 2
      assert List.last(result.messages).content == "Response"
    end

    test "appends a list of messages" do
      config = %Config{}
      state = State.init(config, "test")
      msgs = [Message.assistant("A"), Message.assistant("B")]

      result = State.append_messages(state, msgs)
      assert length(result.messages) == 3
    end
  end

  describe "increment_turn/1" do
    test "increments the turn counter" do
      config = %Config{}
      state = State.init(config, "test")

      result = State.increment_turn(state)
      assert result.turn == 1

      result2 = State.increment_turn(result)
      assert result2.turn == 2
    end
  end

  describe "merge_usage/2" do
    test "accumulates normalized prompt totals across unequal calls and provider conventions" do
      state = State.init(%Config{}, "test")

      state =
        State.merge_usage(state, %{
          input_tokens: 100,
          total_input_tokens: 100,
          cache_read_input_tokens: 80
        })

      state =
        State.merge_usage(state, %{
          input_tokens: 50,
          total_input_tokens: 900,
          cache_read_input_tokens: 100,
          cache_creation_input_tokens: 750
        })

      assert state.usage.input_tokens == 150
      assert state.usage.total_input_tokens == 1000
      assert state.usage.cache_read_input_tokens == 180
      assert state.usage.cache_creation_input_tokens == 750
    end

    test "accumulates token counts" do
      config = %Config{}
      state = State.init(config, "test")

      state = State.merge_usage(state, %{input_tokens: 10, output_tokens: 20})
      assert state.usage.input_tokens == 10
      assert state.usage.output_tokens == 20

      state = State.merge_usage(state, %{input_tokens: 5, output_tokens: 8})
      assert state.usage.input_tokens == 15
      assert state.usage.output_tokens == 28
    end

    test "handles empty usage map" do
      config = %Config{}
      state = State.init(config, "test")

      result = State.merge_usage(state, %{})
      assert result.usage.input_tokens == 0
    end
  end

  describe "merge_provider_state/2" do
    test "merges provider state maps" do
      config = %Config{}
      state = State.init(config, "test")

      state = State.merge_provider_state(state, %{session_id: "abc"})
      assert state.provider_state.session_id == "abc"

      state = State.merge_provider_state(state, %{last_msg_id: "def"})
      assert state.provider_state.session_id == "abc"
      assert state.provider_state.last_msg_id == "def"
    end
  end

  describe "messages/1 accessor" do
    test "returns all messages" do
      config = %Config{}
      state = State.init(config, "A")
      state = State.append_messages(state, Message.assistant("B"))

      msgs = State.messages(state)
      assert length(msgs) == 2
    end
  end
end
