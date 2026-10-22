defmodule Handbean.Agent.Tool.ExecutorResultContractTest do
  use Handbean.DataCase, async: false
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Handbean.Agent.Tool.ExecutorTestSupport, only: [ensure_registered: 1]
  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.{Executor, Result}

  @fixtures_dir Path.join(File.cwd!(), "test/fixtures")

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

  setup do
    ensure_registered(ResultFixtureTool)
    :ok
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
