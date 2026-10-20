defmodule Handbean.Agent.TurnToolEventTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Handbean.Agent.{Config, State, Turn}
  alias Handbean.TestSupport.FakeProvider

  defp ensure_registered(mod) do
    case Handbean.Tool.Registry.get(mod.name()) do
      {:ok, _} -> :ok
      :error -> Handbean.Tool.Registry.register(mod)
    end
  end

  describe "fake provider scenarios" do
    test "simple_answer produces one message" do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        provider_config: %{scenario: :simple_answer}
      }

      state = State.init(config, "Hello")
      result = Turn.run_loop(state, [])

      # Should have: user message + assistant message = 2
      assert length(result.messages) == 2
    end
  end

  describe "tool_end event emission" do
    setup do
      ensure_registered(Handbean.Tool.Builtin.Read)
      ensure_registered(Handbean.Tool.Builtin.Bash)
      ensure_registered(Handbean.Tool.Builtin.Write)

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_turn_tool_end_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "emits file_path in tool_end for write tool", %{tmp_dir: tmp_dir} do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: tmp_dir,
        provider_config: %{scenario: :tool_use_chain}
      }

      state = State.init(config, "Write a file")

      # Directly test via Executor to verify ui_blocks have details
      alias Handbean.Agent.Tool.Executor

      tool_calls = [
        %{
          id: "tend_1",
          name: "write",
          input: %{"file_path" => "hello.exs", "content" => "IO.puts(\"hi\")"}
        }
      ]

      {:ok, _result_msg, ui_blocks} = Executor.execute_all_with_details(tool_calls, state)

      [ui_block] = ui_blocks
      assert ui_block[:details][:file_path] == Path.join(tmp_dir, "hello.exs")
      assert ui_block[:details][:bytes] == 13
    end

    test "provider result_msg has no details even when ui_blocks do", %{tmp_dir: tmp_dir} do
      alias Handbean.Agent.Tool.Executor

      config = %Config{
        working_directory: tmp_dir
      }

      state = State.init(config, "Write")

      tool_calls = [
        %{
          id: "nd_1",
          name: "write",
          input: %{"file_path" => "no_details.exs", "content" => ":ok"}
        }
      ]

      {:ok, result_msg, ui_blocks} = Executor.execute_all_with_details(tool_calls, state)

      [block] = result_msg.content
      refute Map.has_key?(block, :details)

      [ui_block] = ui_blocks
      assert Map.has_key?(ui_block, :details)
      assert ui_block[:details][:file_path] == Path.join(tmp_dir, "no_details.exs")
    end

    test "tool events via on_event contain stable tool_use_id", %{tmp_dir: tmp_dir} do
      config = %Config{
        provider: FakeProvider,
        model: "fake",
        max_turns: 50,
        working_directory: tmp_dir,
        provider_config: %{scenario: :tool_use_chain}
      }

      state = State.init(config, "Read a file")
      events = Agent.start_link(fn -> [] end) |> elem(1)

      _result =
        with_log(fn ->
          Turn.run_loop(state,
            on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
          )
        end)

      emitted = Agent.get(events, & &1)

      turn_events =
        Enum.filter(emitted, fn {kind, _payload} -> kind in [:turn_start, :turn_end] end)

      assert [
               {:turn_start, %{turn: 1}},
               {:turn_end, %{turn: 1, stop_reason: "tool_use"}},
               {:turn_start, %{turn: 2}},
               {:turn_end, %{turn: 2, stop_reason: "completed"}}
             ] = turn_events

      assert {:tool_start, %{tool_use_id: "toolu_001", tool: "read"}} =
               Enum.find(emitted, fn {kind, _payload} -> kind == :tool_start end)

      assert {:tool_end,
              %{
                tool_use_id: "toolu_001",
                tool: "read",
                file_path: file_path,
                duration_ms: duration_ms,
                started_at: started_at,
                completed_at: completed_at,
                timing_fidelity: "exact",
                turn_number: 1
              }} = Enum.find(emitted, fn {kind, _payload} -> kind == :tool_end end)

      assert file_path == "test_file.txt"
      assert is_integer(duration_ms) and duration_ms >= 0
      assert is_binary(started_at)
      assert is_binary(completed_at)
    end
  end
end
