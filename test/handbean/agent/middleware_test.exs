defmodule Handbean.Agent.MiddlewareTest do
  @moduledoc """
  Tests for the middleware behaviour and built-in middleware.

  Reference: `alloy/` (Middleware hook points)
  Test pattern reference: `jido_ai/test/` (middleware testing)

  Covers:
    - Logger middleware at all hook points
    - Security middleware at all hook points
    - Middleware behaviour contract
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.{Config, State, Middleware}
  alias Handbean.Agent.Middleware.{Logger, Security}

  describe "Logger middleware" do
    @tag :capture_log
    test "session_start hook passes through state" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")

      result = Logger.call(:session_start, state)
      assert result == state
      # Logger.info is below test log level :warning — verify pass-through only
    end

    @tag :capture_log
    test "session_end hook passes through state" do
      config = %Config{model: "test-model"}
      state = %{State.init(config, "test") | status: :completed, turn: 3}

      result = Logger.call(:session_end, state)
      assert result == state
    end

    @tag :capture_log
    test "on_error hook passes through state" do
      config = %Config{model: "test-model"}
      state = %{State.init(config, "test") | error: "Something went wrong"}

      import ExUnit.CaptureLog
      # Logger.error IS at warning level — should be captured
      logs =
        capture_log(fn ->
          result = Logger.call(:on_error, state)
          assert result == state
        end)

      assert logs =~ "Something went wrong"
    end

    test "before_completion hook is a no-op pass-through" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Logger.call(:before_completion, state)
      assert result == state
    end

    test "after_completion hook is a no-op pass-through" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Logger.call(:after_completion, state)
      assert result == state
    end

    test "after_tool_request hook is a no-op pass-through" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Logger.call(:after_tool_request, state)
      assert result == state
    end

    test "after_tool_execution hook is a no-op pass-through" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Logger.call(:after_tool_execution, state)
      assert result == state
    end
  end

  describe "Security middleware" do
    test "session_start hook passes through state" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Security.call(:session_start, state)
      assert result == state
    end

    test "session_end hook passes through state" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Security.call(:session_end, state)
      assert result == state
    end

    test "before_completion hook passes through state" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Security.call(:before_completion, state)
      assert result == state
    end

    test "after_completion hook passes through state" do
      config = %Config{model: "test-model"}
      state = State.init(config, "test")
      result = Security.call(:after_completion, state)
      assert result == state
    end
  end

  describe "Middleware behaviour" do
    test "behaviour defines expected callbacks" do
      # Verify the call behaviour is defined on the behaviour module
      assert Middleware.behaviour_info(:callbacks) |> Keyword.has_key?(:call)
    end
  end
end
