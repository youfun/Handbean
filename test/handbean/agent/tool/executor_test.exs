defmodule Handbean.Agent.Tool.ExecutorTest do
  @moduledoc """
  Tests for the tool executor — executes tool calls and returns results.

  Reference: `alloy/` (Tool Executor behavior)
  Test pattern reference: `jido_ai/test/executor_test.exs`

  Covers:
    - Executing known tool calls
    - Unknown tool error handling
    - Context passthrough to tools
    - Tool timeout handling
    - ToolResult + Truncate integration
    - Details preservation in tool_result blocks
  """

  use Handbean.DataCase, async: false
  import ExUnit.CaptureLog, only: [with_log: 1]
  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.Executor

  import Handbean.Agent.Tool.ExecutorTestSupport, only: [ensure_registered: 1]

  defmodule ContextFixtureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "context_fixture"
    def description, do: "Returns the effective reasoning level exposed to tools"
    def input_schema, do: %{type: "object", properties: %{}}

    def execute(_input, context) do
      {:ok, Keyword.get(context.conversation_run_opts, :reasoning_level) || "missing"}
    end
  end

  defmodule ExitingFixtureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "exiting_fixture"
    def description, do: "Concurrent tool that exits"
    def input_schema, do: %{type: "object", properties: %{}}
    def execute(_input, _context), do: exit(:fixture_timeout)
  end

  @fixtures_dir Path.join(File.cwd!(), "test/fixtures")
  setup do
    ensure_registered(Handbean.Tool.Builtin.Read)
    ensure_registered(Handbean.Tool.Builtin.Bash)
    ensure_registered(Handbean.Tool.Builtin.EditContext)
    ensure_registered(ContextFixtureTool)
    ensure_registered(ExitingFixtureTool)
    :ok
  end

  describe "execute_all/2" do
    test "successful edit_context marks the run as diverged from its transcript" do
      state =
        State.init(%Config{}, [
          Handbean.Agent.Message.user("original"),
          Handbean.Agent.Message.assistant("replace this exact span")
        ])

      assert {:ok, _result, _ui_blocks, updated} =
               Executor.execute_all_with_context(
                 [
                   %{
                     id: "edit-1",
                     name: "edit_context",
                     input: %{
                       "old_text" => "replace this exact span",
                       "new_text" => "short replacement"
                     }
                   }
                 ],
                 state
               )

      assert updated.context_edited
    end

    test "executes a known tool call" do
      config = %Config{
        working_directory: @fixtures_dir
      }

      state = State.init(config, "Read sample")

      tool_calls = [
        %{id: "tool_001", name: "read", input: %{"file_path" => "sample.txt", "limit" => 5}}
      ]

      {:ok, result_msg} = Executor.execute_all(tool_calls, state)

      assert result_msg.role == :tool_result
      assert is_list(result_msg.content)

      first_block = List.first(result_msg.content)
      assert first_block[:tool_use_id] == "tool_001"
      assert first_block[:is_error] == false
      assert first_block[:content] =~ "line one"
    end

    test "tools receive the run's effective reasoning level" do
      config = %Config{
        working_directory: @fixtures_dir,
        model: "fake-model",
        reasoning_level: "max"
      }

      state = State.init(config, "Inspect run selection")

      assert {:ok, result_msg} =
               Executor.execute_all(
                 [%{id: "context-reasoning", name: "context_fixture", input: %{}}],
                 state
               )

      assert [block] = result_msg.content
      refute block[:is_error]
      assert block[:content] == "max"
    end

    test "workspace yolo mode reaches tools as unrestricted path access" do
      root =
        Path.join(
          System.tmp_dir!(),
          "handbean-executor-yolo-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(root, "workspace")
      outside = Path.join(root, "outside.txt")
      File.mkdir_p!(workspace)
      File.write!(outside, "outside through executor")
      on_exit(fn -> File.rm_rf!(root) end)

      assert :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace, :yolo)

      state = State.init(%Config{working_directory: workspace}, "Read outside")

      assert {:ok, result_msg} =
               Executor.execute_all(
                 [%{id: "yolo-read", name: "read", input: %{"file_path" => outside}}],
                 state
               )

      assert [block] = result_msg.content
      refute block[:is_error]
      assert block[:content] =~ "outside through executor"
    end

    test "each call executes with its frozen admission mode after the run mode changes" do
      root =
        Path.join(
          System.tmp_dir!(),
          "handbean-executor-frozen-admission-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(root, "workspace")
      outside = Path.join(root, "outside.txt")
      File.mkdir_p!(workspace)
      File.write!(outside, "frozen admission")
      on_exit(fn -> File.rm_rf!(root) end)

      call = %{id: "frozen-read", name: "read", input: %{"file_path" => outside}}

      narrowed =
        State.init(
          %Config{
            working_directory: workspace,
            context: %{permission_mode: :prompt, approval_mode: :prompt, permission_revision: 2}
          },
          "Read outside"
        )

      admitted_in_yolo = %{
        narrowed
        | tool_guard_admission_contexts: %{
            call.id => %{
              permission_mode: :yolo,
              approval_mode: :yolo,
              permission_revision: 1
            }
          }
      }

      assert {:ok, result_msg} = Executor.execute_all([call], admitted_in_yolo)
      assert [allowed] = result_msg.content
      refute allowed[:is_error]
      assert allowed[:content] =~ "frozen admission"

      broadened =
        State.init(
          %Config{
            working_directory: workspace,
            context: %{permission_mode: :yolo, approval_mode: :yolo, permission_revision: 4}
          },
          "Read outside"
        )

      admitted_in_prompt = %{
        broadened
        | tool_guard_admission_contexts: %{
            call.id => %{
              permission_mode: :prompt,
              approval_mode: :prompt,
              permission_revision: 3
            }
          }
      }

      assert {:ok, result_msg} = Executor.execute_all([call], admitted_in_prompt)
      assert [blocked] = result_msg.content
      assert blocked[:is_error]
    end

    test "execution grants are consumed before parallel dispatch and cannot be replayed" do
      root =
        Path.join(
          System.tmp_dir!(),
          "handbean-executor-grant-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(root, "workspace")
      outside = Path.join(root, "outside.txt")
      other = Path.join(root, "other.txt")
      File.mkdir_p!(workspace)
      File.write!(outside, "approved outside")
      File.write!(other, "unapproved outside")
      on_exit(fn -> File.rm_rf!(root) end)

      context = %{
        working_directory: workspace,
        workspace_id: "grant-workspace",
        conversation_id: "grant-conversation",
        run_id: "grant-run"
      }

      approved = %{id: "shared-id", name: "read", input: %{"file_path" => outside}}
      replay = %{id: "shared-id", name: "read", input: %{"file_path" => other}}
      requirement = Handbean.Permissions.Boundary.requirement(approved, context)
      grant = Handbean.Permissions.Boundary.grant(approved, context, requirement, :human)

      config = %Config{
        working_directory: workspace,
        run_id: "grant-run",
        context: Map.drop(context, [:working_directory, :run_id])
      }

      state = %{
        State.init(config, "read the exact approved file")
        | tool_guard_execution_grants: %{approved.id => grant}
      }

      assert {:ok, result_msg, _ui_blocks, next_state} =
               Executor.execute_all_with_context([approved, replay], state)

      assert [approved_result, replay_result] = result_msg.content
      refute approved_result[:is_error]
      assert approved_result[:content] =~ "approved outside"
      assert replay_result[:is_error]
      assert replay_result[:content] =~ "outside workspace"
      assert next_state.tool_guard_execution_grants == %{}
    end

    test "parallel calls receive only their own grant" do
      root =
        Path.join(
          System.tmp_dir!(),
          "handbean-executor-isolation-#{System.unique_integer([:positive])}"
        )

      workspace = Path.join(root, "workspace")
      first = Path.join(root, "first.txt")
      second = Path.join(root, "second.txt")
      File.mkdir_p!(workspace)
      File.write!(first, "first approved")
      File.write!(second, "second unapproved")
      on_exit(fn -> File.rm_rf!(root) end)

      context = %{
        working_directory: workspace,
        workspace_id: "parallel-workspace",
        conversation_id: "parallel-conversation",
        run_id: "parallel-run"
      }

      approved = %{id: "parallel-1", name: "read", input: %{"file_path" => first}}
      unapproved = %{id: "parallel-2", name: "read", input: %{"file_path" => second}}
      requirement = Handbean.Permissions.Boundary.requirement(approved, context)
      grant = Handbean.Permissions.Boundary.grant(approved, context, requirement, :human)

      config = %Config{
        working_directory: workspace,
        run_id: "parallel-run",
        context: Map.drop(context, [:working_directory, :run_id])
      }

      state = %{
        State.init(config, "read only the approved file")
        | tool_guard_execution_grants: %{approved.id => grant}
      }

      assert {:ok, result_msg} = Executor.execute_all([approved, unapproved], state)
      assert [approved_result, unapproved_result] = result_msg.content
      refute approved_result[:is_error]
      assert unapproved_result[:is_error]
    end

    test "returns error for unknown tool" do
      config = %Config{}
      state = State.init(config, "Use unknown tool")

      tool_calls = [
        %{id: "tool_002", name: "nonexistent_tool", input: %{}}
      ]

      {{:ok, result_msg}, _log} = with_log(fn -> Executor.execute_all(tool_calls, state) end)

      [block] = result_msg.content
      assert block[:is_error] == true
      assert block[:content] =~ "Unknown tool"
    end

    test "handles multiple tool calls (parallel-safe scenario)" do
      config = %Config{
        working_directory: @fixtures_dir
      }

      state = State.init(config, "Multi read")

      tool_calls = [
        %{id: "tool_a", name: "read", input: %{"file_path" => "sample.txt", "limit" => 2}},
        %{id: "tool_b", name: "read", input: %{"file_path" => "sample.txt", "limit" => 3}}
      ]

      {:ok, result_msg} = Executor.execute_all(tool_calls, state)

      blocks = result_msg.content
      assert length(blocks) == 2

      a_block = Enum.find(blocks, &(&1[:tool_use_id] == "tool_a"))
      b_block = Enum.find(blocks, &(&1[:tool_use_id] == "tool_b"))

      assert a_block[:is_error] == false
      assert b_block[:is_error] == false
    end

    test "turns a concurrent tool exit into a tool error without exiting the caller" do
      state = State.init(%Config{}, "Run concurrent tool")

      assert {:ok, result_msg} =
               Executor.execute_all(
                 [%{id: "tool_exit", name: "exiting_fixture", input: %{}}],
                 state
               )

      assert [block] = result_msg.content
      assert block[:tool_use_id] == "tool_exit"
      assert block[:is_error] == true
      assert block[:content] =~ "timed out"
    end
  end
end
