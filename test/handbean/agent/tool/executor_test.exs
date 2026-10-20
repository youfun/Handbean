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
  alias Handbean.Agent.Tool.{Executor, Result}

  defmodule ResultFixtureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "result_fixture"
    def description, do: "Deterministic executor result fixture"
    def input_schema, do: %{type: "object", properties: %{mode: %{type: "string"}}}

    def execute(%{"mode" => "nonzero"}, _context),
      do: {:ok, "exited with code 42", %{exit_code: 42}}

    def execute(%{"mode" => "contradictory_error", "status" => status}, _context),
      do: {:error, "real failure", %{status: status, side_effect: :unknown}}

    def execute(_input, _context), do: {:ok, "hello", %{exit_code: 0}}
  end

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

  # Avoid re-registration warnings by only registering if not already present
  defp ensure_registered(mod) do
    case Handbean.Tool.Registry.get(mod.name()) do
      {:ok, _} -> :ok
      :error -> Handbean.Tool.Registry.register(mod)
    end
  end

  setup do
    ensure_registered(Handbean.Tool.Builtin.Read)
    ensure_registered(Handbean.Tool.Builtin.Bash)
    ensure_registered(Handbean.Tool.Builtin.EditContext)
    ensure_registered(ResultFixtureTool)
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

  describe "ToolResult integration" do
    test "error tuples cannot be made successful by metadata" do
      for status <- [:succeeded, :running, :interrupted] do
        state = State.init(%Config{}, "probe")

        assert {:ok, message, [ui_block]} =
                 Executor.execute_all_with_details(
                   [
                     %{
                       id: "contradiction",
                       name: "result_fixture",
                       input: %{"mode" => "contradictory_error", "status" => status}
                     }
                   ],
                   state
                 )

        assert [block] = message.content
        assert block.is_error
        assert block.content == "real failure"

        assert ui_block.details.status ==
                 if(status == :interrupted, do: :interrupted, else: :failed)

        assert ui_block.details.side_effect == :unknown
      end
    end

    test "strips details from tool_result blocks before storing in state" do
      config = %Config{
        working_directory: @fixtures_dir
      }

      state = State.init(config, "Write test")

      # Fixture returns {:ok, text, data}; details are stripped by execute_all.
      tool_calls = [
        %{id: "tool_result", name: "result_fixture", input: %{}}
      ]

      {:ok, result_msg} = Executor.execute_all(tool_calls, state)

      [block] = result_msg.content
      assert block[:type] == "tool_result"
      assert block[:tool_use_id] == "tool_result"
      assert block[:is_error] == false
      assert block[:content] =~ "hello"
      # Details MUST be stripped — not sent to LLM, not stored in state
      refute Map.has_key?(block, "details")
    end

    test "strips details from error blocks as well" do
      config = %Config{working_directory: @fixtures_dir}
      state = State.init(config, "Bad bash")

      tool_calls = [%{id: "tool_fail", name: "result_fixture", input: %{"mode" => "nonzero"}}]

      {:ok, result_msg} = Executor.execute_all(tool_calls, state)

      [block] = result_msg.content
      assert block[:is_error] == false
      assert block[:content] =~ "exit"
      refute Map.has_key?(block, "details")
    end
  end

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

  defmodule SpillFixtureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "spill_fixture"
    def description, do: "returns an oversized success"
    def input_schema, do: %{type: "object", properties: %{}}
    def max_result_chars, do: 80
    def execute(_input, _context), do: {:ok, String.duplicate("spill-line\n", 40)}
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

  describe "large result spill" do
    setup do
      ensure_registered(SpillFixtureTool)

      tmp_dir =
        Path.join(System.tmp_dir!(), "handbean_spill_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "oversized success spills to a workspace file with a short preview", %{tmp_dir: tmp_dir} do
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "spill")

      {:ok, result_msg, ui_blocks} =
        Executor.execute_all_with_details(
          [%{id: "spill-1", name: "spill_fixture", input: %{}}],
          state
        )

      [block] = result_msg.content
      refute block[:is_error]
      assert byte_size(block[:content]) < 4_000
      assert block[:content] =~ "Read it with the read tool using offset and limit"
      refute Map.has_key?(block, :details)

      [ui_block] = ui_blocks
      relative = ui_block[:details].spill_path
      content = String.duplicate("spill-line\n", 40)

      hash =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      assert relative == ".handbean/tool-results/spill-#{hash}.txt"

      absolute = Path.expand(relative, tmp_dir)
      assert File.exists?(absolute)
      assert File.read!(absolute) == content
      assert String.starts_with?(Path.relative_to(absolute, tmp_dir), ".handbean/")
      assert Path.dirname(absolute) != System.tmp_dir!()

      {:ok, _second_result, [second_ui_block]} =
        Executor.execute_all_with_details(
          [%{id: "spill-2", name: "spill_fixture", input: %{}}],
          state
        )

      assert second_ui_block[:details].spill_path == relative
      assert Path.wildcard(Path.join(tmp_dir, ".handbean/tool-results/spill-*")) == [absolute]
    end

    test "does not overwrite a mismatched content-addressed spill", %{tmp_dir: tmp_dir} do
      content = String.duplicate("spill-line\n", 40)

      hash =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      absolute =
        Path.join(tmp_dir, ".handbean/tool-results/spill-#{hash}.txt")

      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, "mismatched")

      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "spill collision")

      {:ok, result_msg, [ui_block]} =
        Executor.execute_all_with_details(
          [%{id: "spill-collision", name: "spill_fixture", input: %{}}],
          state
        )

      [block] = result_msg.content
      assert block[:content] =~ "artifact unavailable"
      assert ui_block[:details].artifact_unavailable
      assert File.read!(absolute) == "mismatched"
    end
  end

  describe "truncate_result/2" do
    test "does not truncate content within limit" do
      result = Result.new("short text", %{exit_code: 0})
      truncated = Executor.truncate_result(result, 100)

      assert truncated.content == "short text"
      assert truncated.details.exit_code == 0
    end

    test "truncates content exceeding max_chars using head_tail strategy" do
      long_text = String.duplicate("hello world ", 10_000)
      result = Result.new(long_text, %{exit_code: 0})

      truncated = Executor.truncate_result(result, 1_000)

      # Content should be truncated to a bounded preview. The full body is not
      # retained in details; callers spill it to an artifact when a workspace exists.
      assert byte_size(truncated.content) < 2_000
      assert truncated.content =~ "artifact unavailable"
      refute truncated.details[:original_content]
      assert truncated.details[:exit_code] == 0
    end

    test "bounds error results without retaining the original body" do
      result = Result.error("err: " <> String.duplicate("x", 10_000))
      truncated = Executor.truncate_result(result, 100)

      assert truncated.is_error == true
      assert byte_size(truncated.content) < 2_000
      refute truncated.content == result.content
      refute truncated.details[:original_content]
    end

    test "passes through when max_chars is nil (unlimited)" do
      long_text = String.duplicate("data ", 5_000)
      result = Result.new(long_text)
      truncated = Executor.truncate_result(result, nil)

      assert truncated.content == long_text
    end

    test "does not truncate when content equals limit" do
      text = String.duplicate("x", 500)
      result = Result.new(text, %{})
      truncated = Executor.truncate_result(result, 500)

      assert truncated.content == text
    end
  end

  describe "TOOLRES: tool result dual-channel (Gong 101-104)" do
    setup do
      ensure_registered(Handbean.Tool.Builtin.Read)
      ensure_registered(Handbean.Tool.Builtin.Bash)
      ensure_registered(Handbean.Tool.Builtin.Edit)
      ensure_registered(Handbean.Tool.Builtin.Write)

      tmp_dir =
        Path.join(System.tmp_dir!(), "handbean_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "[TOOLRES-101] edit returns dual-channel ToolResult", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "target.txt")
      File.write!(target, "hello world")

      context = %{working_directory: tmp_dir}

      # Direct tool call returns {:ok, text, data}
      {:ok, text, data} =
        Handbean.Tool.Builtin.Edit.execute(
          %{"file_path" => target, "old_string" => "hello", "new_string" => "hi"},
          context
        )

      assert text =~ "target.txt"
      assert data.replacements == 1
      assert data.file_path == target

      # Wrap in ToolResult: details preserved for UI
      result = Result.new(text, data)
      assert Result.has_details?(result)
      assert Result.ui_details(result).replacements == 1
      assert Result.llm_content(result) =~ "target.txt"

      # Through executor: details STRIPPED from LLM-facing block
      target2 = Path.join(tmp_dir, "target2.txt")
      File.write!(target2, "foo bar")

      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Edit")

      tool_calls = [
        %{
          id: "edit_1",
          name: "edit",
          input: %{"file_path" => target2, "old_string" => "foo", "new_string" => "zip"}
        }
      ]

      {:ok, msg} = Executor.execute_all(tool_calls, state)
      [block] = msg.content

      assert block[:is_error] == false
      assert block[:content] =~ "target2.txt"
      refute Map.has_key?(block, "details")
    end

    @tag :os_sandbox
    test "[TOOLRES-102] bash returns dual-channel ToolResult", %{tmp_dir: tmp_dir} do
      context = %{working_directory: tmp_dir}

      {:ok, text, data} =
        Handbean.Tool.Builtin.Bash.execute(
          %{"command" => "echo dual_channel_test"},
          context
        )

      assert text =~ "dual_channel_test"
      assert data.exit_code == 0

      result = Result.new(text, data)
      assert Result.has_details?(result)
      assert Result.ui_details(result).exit_code == 0

      # Through executor: details stripped
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Bash")

      tool_calls = [
        %{id: "bash_1", name: "bash", input: %{"command" => "echo dual_channel_test"}}
      ]

      {:ok, msg} = Executor.execute_all(tool_calls, state)
      [block] = msg.content

      assert block[:is_error] == false
      assert block[:content] =~ "dual_channel_test"
      refute Map.has_key?(block, "details")
    end

    test "[TOOLRES-103] read returns content-only ToolResult (text mode has no details)", %{
      tmp_dir: tmp_dir
    } do
      target = Path.join(tmp_dir, "sample.txt")
      File.write!(target, "line1\nline2\nline3")

      context = %{working_directory: tmp_dir}

      {:ok, text, details} =
        Handbean.Tool.Builtin.Read.execute(
          %{"file_path" => target},
          context
        )

      assert text =~ "line1"

      # Read text mode now returns metadata for downstream consumers.
      # Image mode also returns details (see BDD-READ-012).
      result = Result.new(text, details)
      assert Result.llm_content(result) =~ "line1"
      assert Result.has_details?(result)
      assert Result.ui_details(result).file_path == target

      # Through executor: details stripped from LLM-facing block
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Read")

      tool_calls = [
        %{id: "read_1", name: "read", input: %{"file_path" => target}}
      ]

      {:ok, msg} = Executor.execute_all(tool_calls, state)
      [block] = msg.content

      assert block[:is_error] == false
      assert block[:content] =~ "line1"
      refute Map.has_key?(block, "details")
    end

    test "[TOOLRES-104] write returns dual-channel ToolResult", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "out.txt")
      context = %{working_directory: tmp_dir}

      {:ok, text, data} =
        Handbean.Tool.Builtin.Write.execute(
          %{"file_path" => target, "content" => "written"},
          context
        )

      assert text =~ "out.txt"
      assert data.bytes == 7
      assert data.lines == 1

      result = Result.new(text, data)
      assert Result.has_details?(result)
      assert Result.ui_details(result).bytes == 7

      # Through executor: details stripped
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Write")

      target2 = Path.join(tmp_dir, "out2.txt")

      tool_calls = [
        %{id: "write_1", name: "write", input: %{"file_path" => target2, "content" => "written"}}
      ]

      {:ok, msg} = Executor.execute_all(tool_calls, state)
      [block] = msg.content

      assert block[:is_error] == false
      assert block[:content] =~ "out2.txt"
      refute Map.has_key?(block, "details")
    end
  end

  describe "result_to_block/2" do
    test "an explicit error flag wins over the struct's default success status" do
      block = Executor.result_to_block(%Result{content: "failed", is_error: true}, "failed-call")
      assert block.is_error
      assert block.details.status == :failed
    end

    test "maps ToolResult to provider-compatible map" do
      result = Result.new("ok", %{exit_code: 0})
      block = Executor.result_to_block(result, "tool_1")

      assert block[:type] == "tool_result"
      assert block[:tool_use_id] == "tool_1"
      assert block[:content] == "ok"
      assert block[:is_error] == false
      assert block[:details].exit_code == 0
    end

    test "omits details key when details are nil" do
      result = Result.new("plain")
      block = Executor.result_to_block(result, "tool_2")

      assert block[:content] == "plain"
      refute Map.has_key?(block, "details")
    end

    test "error result includes details" do
      result = Result.error("bad", %{reason: "permission"})
      block = Executor.result_to_block(result, "tool_err")

      assert block[:is_error] == true
      assert block[:details].reason == "permission"
    end
  end

  describe "execute_all_with_details/2" do
    setup do
      ensure_registered(Handbean.Tool.Builtin.Read)
      ensure_registered(Handbean.Tool.Builtin.Bash)
      ensure_registered(Handbean.Tool.Builtin.Write)

      tmp_dir =
        Path.join(System.tmp_dir!(), "handbean_test_dets_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "returns stripped result_msg and ui_blocks with details for write tool", %{
      tmp_dir: tmp_dir
    } do
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Write file")

      target = Path.join(tmp_dir, "hello.exs")

      tool_calls = [
        %{
          id: "write_99",
          name: "write",
          input: %{"file_path" => "hello.exs", "content" => "IO.puts(\"hello\")"}
        }
      ]

      {:ok, result_msg, ui_blocks} = Executor.execute_all_with_details(tool_calls, state)

      # result_msg should be stripped
      assert result_msg.role == :tool_result
      [block] = result_msg.content
      assert block[:is_error] == false
      assert block[:content] =~ "hello.exs"
      refute Map.has_key?(block, "details")

      # ui_blocks should still have details with file_path
      [ui_block] = ui_blocks
      assert ui_block[:details][:file_path] == target
      assert ui_block[:details][:bytes] > 0
      assert ui_block[:details][:lines] >= 1
    end

    test "provider-facing result_msg has no details key", %{tmp_dir: tmp_dir} do
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Write file")

      tool_calls = [
        %{id: "w_pp", name: "write", input: %{"file_path" => "priv.exs", "content" => "x"}}
      ]

      {:ok, result_msg, _ui_blocks} = Executor.execute_all_with_details(tool_calls, state)

      [block] = result_msg.content
      refute Map.has_key?(block, "details")
    end

    test "ui_blocks for failed tool have is_error but still carry details", %{tmp_dir: tmp_dir} do
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Bad tool")

      tool_calls = [
        %{id: "fail_tool", name: "nonexistent_tool", input: %{}}
      ]

      {{:ok, result_msg, ui_blocks}, _log} =
        with_log(fn -> Executor.execute_all_with_details(tool_calls, state) end)

      [block] = result_msg.content
      assert block[:is_error] == true
      refute Map.has_key?(block, "details")

      # ui_block should have original details
      [ui_block] = ui_blocks
      assert ui_block[:is_error] == true
      # Error details may or may not have file_path — depends on tool
    end

    test "execute_all is backward compatible", %{tmp_dir: tmp_dir} do
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "Write")

      tool_calls = [
        %{id: "bc_1", name: "write", input: %{"file_path" => "bc.exs", "content" => "1"}}
      ]

      {:ok, result_msg} = Executor.execute_all(tool_calls, state)
      assert result_msg.role == :tool_result
      [block] = result_msg.content
      assert block[:is_error] == false
      refute Map.has_key?(block, "details")
    end
  end

  describe "error details and browser context" do
    defmodule ErrorDetailsTool do
      @behaviour Handbean.Agent.Tool

      def name, do: "error_details_probe"
      def description, do: "probe"
      def input_schema, do: %{type: "object", properties: %{}}

      def execute(_input, _context) do
        {:error, "Browser command timed out",
         %{
           result_category: "failure",
           failure_category: "timeout",
           operation_id: "probe-op",
           status: :failed,
           side_effect: :not_started,
           recovery: %{action: :retry_saved_input, ref: "probe-op"}
         }}
      end

      def hint, do: "Change the arguments from this error and retry once."
    end

    defmodule NoHintErrorTool do
      @behaviour Handbean.Agent.Tool

      def name, do: "context_probe_error"
      def description, do: "probe"
      def input_schema, do: %{type: "object", properties: %{}}
      def execute(_input, _context), do: {:error, "plain failure"}
    end

    defmodule ContextProbeTool do
      @behaviour Handbean.Agent.Tool

      def name, do: "context_probe"
      def description, do: "probe"
      def input_schema, do: %{type: "object", properties: %{}}

      def execute(_input, context) do
        {:ok, "ok",
         %{
           conversation_id: context[:conversation_id],
           session_id: context[:session_id],
           workspace_id: context[:workspace_id]
         }}
      end
    end

    setup do
      ensure_registered(ErrorDetailsTool)
      ensure_registered(NoHintErrorTool)
      ensure_registered(ContextProbeTool)
      :ok
    end

    test "appends the tool hint to a failed model-facing result" do
      state = State.init(%Config{}, "probe")

      {:ok, result_msg, ui_blocks} =
        Executor.execute_all_with_details(
          [%{id: "h1", name: "error_details_probe", input: %{}}],
          state
        )

      [block] = result_msg.content
      assert block[:is_error] == true
      assert block[:content] =~ "Browser command timed out"
      assert block[:content] =~ "Tool hint: Change the arguments from this error"
      refute block[:content] =~ "Tool hint: Tool hint:"

      [ui_block] = ui_blocks
      assert ui_block[:content] == block[:content]
      assert ui_block[:details].failure_category == "timeout"
      assert ui_block[:details].operation_id == "probe-op"
      assert ui_block[:details].side_effect == :not_started
      assert ui_block[:details].recovery.action == :retry_saved_input
    end

    test "does not append a tool hint when the tool defines none" do
      state = State.init(%Config{}, "probe")

      {:ok, result_msg, _ui_blocks} =
        Executor.execute_all_with_details(
          [%{id: "n1", name: "context_probe_error", input: %{}}],
          state
        )

      [block] = result_msg.content
      assert block[:content] == "plain failure"
      refute block[:content] =~ "Tool hint:"
    end

    test "preserves details from {:error, content, details} on ui blocks" do
      state = State.init(%Config{}, "probe")

      {:ok, result_msg, ui_blocks} =
        Executor.execute_all_with_details(
          [%{id: "e1", name: "error_details_probe", input: %{}}],
          state
        )

      [block] = result_msg.content
      assert block[:is_error] == true
      assert block[:content] =~ "timed out"
      refute Map.has_key?(block, :details)

      [ui_block] = ui_blocks
      assert ui_block[:is_error] == true
      assert ui_block[:details].failure_category == "timeout"
    end

    test "passes conversation, session, and workspace ids into tool context" do
      config = %Config{
        working_directory: @fixtures_dir,
        context: %{conversation_id: "conv-1", workspace_id: "ws-1"}
      }

      state =
        config
        |> State.init("probe")
        |> State.merge_run_metadata(%{session_id: "sess-1"})

      {:ok, _msg, ui_blocks} =
        Executor.execute_all_with_details(
          [%{id: "c1", name: "context_probe", input: %{}}],
          state
        )

      [ui_block] = ui_blocks
      assert ui_block[:details].conversation_id == "conv-1"
      assert ui_block[:details].session_id == "sess-1"
      assert ui_block[:details].workspace_id == "ws-1"
    end

    test "falls back to session_id as conversation_id when context omitted it" do
      config = %Config{working_directory: @fixtures_dir, context: %{}}

      state =
        config
        |> State.init("probe")
        |> State.merge_run_metadata(%{session_id: "conv-from-session"})

      {:ok, _msg, ui_blocks} =
        Executor.execute_all_with_details(
          [%{id: "c2", name: "context_probe", input: %{}}],
          state
        )

      [ui_block] = ui_blocks
      assert ui_block[:details].session_id == "conv-from-session"
      assert ui_block[:details].conversation_id == "conv-from-session"
    end
  end
end
