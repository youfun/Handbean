defmodule Handbean.Agent.Tool.ExecutorNestedExecutionTest do
  use Handbean.DataCase, async: false
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Handbean.Agent.Tool.ExecutorTestSupport, only: [ensure_registered: 1]
  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.Executor

  @fixtures_dir Path.join(File.cwd!(), "test/fixtures")

  defmodule NestedOnlyExecutorTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "nested_executor_probe"
    def description, do: "hidden from the model"
    def input_schema, do: %{type: "object", properties: %{text: %{type: "string"}}}
    def nested_only?, do: true
    def max_result_chars, do: 80

    def execute(%{"mode" => "boundary"}, context) do
      {:ok,
       "grant=#{Map.has_key?(context, :boundary_grant)}:collection=#{Map.has_key?(context, :tool_execution_grants)}"}
    end

    def execute(%{"mode" => "huge"}, _context) do
      {:ok, String.duplicate("spill-line\n", 40)}
    end

    def execute(%{"text" => text}, context) do
      {:ok, "ran:#{text}:caller=#{context[:tool_caller]}:parent=#{context[:parent_tool_call_id]}"}
    end

    def execute(_input, _context), do: {:ok, "ran"}
  end

  describe "nested-only execution" do
    setup do
      ensure_registered(NestedOnlyExecutorTool)
      :ok
    end

    test "a model-issued call fails as an unknown tool" do
      config = %Config{working_directory: @fixtures_dir}
      state = State.init(config, "call hidden")

      {{:ok, result_msg}, _log} =
        with_log(fn ->
          Executor.execute_all(
            [%{id: "model-1", name: "nested_executor_probe", input: %{"text" => "x"}}],
            state
          )
        end)

      [block] = result_msg.content
      assert block[:is_error] == true
      assert block[:content] == "Unknown tool: nested_executor_probe"
      refute block[:content] =~ "nested-only"
    end

    test "an executor nested call succeeds and carries the parent tool-call id" do
      config = %Config{
        working_directory: @fixtures_dir,
        context: %{conversation_id: "conv-nested"}
      }

      state = State.init(config, "nested")
      parent = self()

      assert {:ok, text, _details} =
               Executor.execute_nested("nested_executor_probe", %{"text" => "ok"}, state,
                 parent_tool_call_id: "parent-1",
                 on_event: fn event -> send(parent, {:nested_event, event}) end
               )

      assert text == "ran:ok:caller=nested:parent=parent-1"
      assert_receive {:nested_event, {:tool_start, start_payload}}
      assert start_payload.parent_tool_call_id == "parent-1"
      assert start_payload.tool_name == "nested_executor_probe"
      assert_receive {:nested_event, {:tool_end, end_payload}}
      assert end_payload.parent_tool_call_id == "parent-1"
      assert end_payload.tool == "nested_executor_probe"
    end

    test "nested execution strips parent boundary capabilities" do
      stale_grant = %{
        tool_call_id: "parent",
        tool_name: "read",
        input_fingerprint: "stale",
        source_workspace_id: "workspace",
        source_conversation_id: "conv-nested",
        run_id: "run-nested",
        resource: %{kind: :path, path: "/tmp/stale", scope: :file},
        operation: :read,
        provenance: :human
      }

      config = %Config{
        working_directory: @fixtures_dir,
        run_id: "run-nested",
        context: %{
          conversation_id: "conv-nested",
          workspace_id: "workspace",
          boundary_grant: stale_grant,
          tool_execution_grants: %{"parent" => stale_grant}
        }
      }

      state = %{
        State.init(config, "nested")
        | tool_guard_execution_grants: %{"parent" => stale_grant}
      }

      assert {:ok, text, _details} =
               Executor.execute_nested("nested_executor_probe", %{"mode" => "boundary"}, state,
                 parent_tool_call_id: "parent"
               )

      assert text == "grant=false:collection=false"
    end

    test "nested execution still honors the session active set" do
      session_id = "nested-active-set"
      :ok = Handbean.Tool.Registry.set_active_for_session(session_id, ["read"])

      config = %Config{
        working_directory: @fixtures_dir,
        context: %{conversation_id: session_id}
      }

      state = State.init(config, "blocked nested")

      assert {:error, "Unknown tool: nested_executor_probe", %{}} =
               Executor.execute_nested("nested_executor_probe", %{"text" => "no"}, state,
                 parent_tool_call_id: "parent-2"
               )
    after
      Handbean.Tool.Registry.set_active_for_session("nested-active-set", nil)
    end
  end
end
