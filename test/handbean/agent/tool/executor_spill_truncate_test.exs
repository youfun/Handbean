defmodule Handbean.Agent.Tool.ExecutorSpillTruncateTest do
  use Handbean.DataCase, async: false
  import Handbean.Agent.Tool.ExecutorTestSupport, only: [ensure_registered: 1]
  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.{Executor, Result}

  defmodule SpillFixtureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "spill_fixture"
    def description, do: "returns an oversized success"
    def input_schema, do: %{type: "object", properties: %{}}
    def max_result_chars, do: 80
    def execute(_input, _context), do: {:ok, String.duplicate("spill-line\n", 40)}
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

    test "oversized success spills to a conversation artifact with a short preview", %{
      tmp_dir: tmp_dir
    } do
      artifact_root = Path.join(tmp_dir, "artifacts")

      {:ok, _conversation} =
        Handbean.ConversationStore.create("default", id: "spill-conversation")

      config = %Config{
        working_directory: tmp_dir,
        context: %{
          conversation_id: "spill-conversation",
          conversation_artifact_root: artifact_root
        }
      }

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
      ref = ui_block[:details].artifact_ref
      content = String.duplicate("spill-line\n", 40)

      hash =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      assert ref == "conversation_artifact:tool-results/spill-#{hash}.txt"

      absolute =
        Path.join([
          artifact_root,
          "items",
          "spill-conversation",
          "tool-results",
          "spill-#{hash}.txt"
        ])

      assert File.read!(absolute) == content
      refute File.exists?(Path.join(tmp_dir, ".handbean/tool-results"))

      assert {:ok, read_content, %{file_path: ^ref}} =
               Handbean.Tool.Builtin.Read.execute(
                 %{"file_path" => ref, "limit" => 2},
                 config.context
               )

      assert read_content =~ "spill-line"
      assert read_content =~ "more lines"

      assert {:error, "conversation artifact is unavailable"} =
               Handbean.Tool.Builtin.Read.execute(
                 %{"file_path" => ref},
                 %{config.context | conversation_id: "other-conversation"}
               )

      {:ok, _second_result, [second_ui_block]} =
        Executor.execute_all_with_details(
          [%{id: "spill-2", name: "spill_fixture", input: %{}}],
          state
        )

      assert second_ui_block[:details].artifact_ref == ref

      assert Path.wildcard(Path.join([artifact_root, "items/*/tool-results/spill-*"])) == [
               absolute
             ]
    end

    test "does not overwrite a mismatched content-addressed spill", %{tmp_dir: tmp_dir} do
      artifact_root = Path.join(tmp_dir, "artifacts")
      {:ok, _conversation} = Handbean.ConversationStore.create("default", id: "spill-collision")
      content = String.duplicate("spill-line\n", 40)

      hash =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)

      absolute =
        Path.join([
          artifact_root,
          "items",
          "spill-collision",
          "tool-results",
          "spill-#{hash}.txt"
        ])

      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, "mismatched")

      config = %Config{
        working_directory: tmp_dir,
        context: %{
          conversation_id: "spill-collision",
          conversation_artifact_root: artifact_root
        }
      }

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

    test "does not persist an oversized result without a conversation", %{tmp_dir: tmp_dir} do
      config = %Config{working_directory: tmp_dir}
      state = State.init(config, "spill without conversation")

      {:ok, result_msg, [ui_block]} =
        Executor.execute_all_with_details(
          [%{id: "spill-no-conversation", name: "spill_fixture", input: %{}}],
          state
        )

      [block] = result_msg.content
      assert block[:content] =~ "artifact unavailable"
      assert ui_block[:details].artifact_unavailable
      refute File.exists?(Path.join(tmp_dir, ".handbean/tool-results"))
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
end
