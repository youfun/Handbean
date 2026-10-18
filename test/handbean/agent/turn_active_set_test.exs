defmodule Handbean.Agent.TurnActiveSetTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.{Config, State, Turn}

  setup do
    # Register some tools
    Enum.each(
      [
        Handbean.Tool.Builtin.Read,
        Handbean.Tool.Builtin.Bash,
        Handbean.Tool.Builtin.Edit,
        Handbean.Tool.Builtin.Write
      ],
      &Handbean.Tool.Registry.register/1
    )

    # Clean up any previous active sets
    :ok
  end

  @tag :tmp_dir
  test "tool_defs filtered by session active set" do
    session_id = "turn-active-#{System.unique_integer([:positive])}"

    # Set active tools to only read + bash
    Handbean.Tool.Registry.set_active_for_session(session_id, ["read", "bash"])

    # Use FakeProvider with notify to capture what tool_defs the provider sees
    notify_pid = self()

    tmp = System.tmp_dir!() |> Path.join("turn_active_#{session_id}")
    File.mkdir_p!(tmp)

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: tmp,
      max_turns: 2,
      provider_config: %{scenario: :simple_answer, notify: notify_pid},
      tool_timeout: 30_000
    }

    state = State.init(config, "hello")
    opts = [session_id: session_id]

    result = Turn.run_loop(state, opts)
    assert result.status == :completed

    # FakeProvider sends {:provider_tool_defs, tool_defs} to notify_pid
    assert_receive {:provider_tool_defs, tool_defs}, 2000

    # The tool_defs should be filtered to only read + bash
    names = Enum.map(tool_defs, & &1.name)
    assert "read" in names
    assert "bash" in names
    refute "edit" in names
    refute "write" in names
  end

  test "no active set returns full tool_defs" do
    session_id = "turn-noactive-#{System.unique_integer([:positive])}"
    notify_pid = self()

    tmp = System.tmp_dir!() |> Path.join("turn_noactive_#{session_id}")
    File.mkdir_p!(tmp)

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: tmp,
      max_turns: 2,
      provider_config: %{scenario: :simple_answer, notify: notify_pid},
      tool_timeout: 30_000
    }

    state = State.init(config, "hello")
    opts = [session_id: session_id]

    result = Turn.run_loop(state, opts)
    assert result.status == :completed

    assert_receive {:provider_tool_defs, tool_defs}, 2000
    names = Enum.map(tool_defs, & &1.name)
    # All registered tools should be present
    assert "read" in names
    assert "edit" in names
    assert "write" in names
    assert "bash" in names
  end
end
