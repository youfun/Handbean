defmodule Handbean.Agent.Tool.ErrorTrackingTest do
  use Handbean.DataCase, async: false

  alias ErrorTracker.Occurrence
  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.Executor

  defmodule ExpectedFailureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "expected_failure_fixture"
    def description, do: "Return a deterministic recoverable tool error"
    def input_schema, do: %{type: "object", properties: %{private: %{type: "string"}}}
    def concurrent?, do: false

    def execute(_input, _context) do
      {:error, "No engram found with id 143",
       %{code: :not_found, status: :failed, side_effect: :not_started}}
    end
  end

  defmodule UnknownFailureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "unknown_failure_fixture"
    def description, do: "Return an unclassified internal tool error"
    def input_schema, do: %{type: "object", properties: %{private: %{type: "string"}}}
    def concurrent?, do: false
    def execute(_input, _context), do: {:error, "internal bridge failed with api-key-secret"}
  end

  defmodule CrashingTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "crashing_fixture"
    def description, do: "Raise a deterministic tool exception"
    def input_schema, do: %{type: "object", properties: %{}}
    def concurrent?, do: false
    def execute(_input, _context), do: raise("crashed with api-key-secret")
  end

  defmodule CapturedFailureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "captured_failure_fixture"
    def description, do: "Return a safe diagnostic from a concurrent tool"
    def input_schema, do: %{type: "object", properties: %{}}
    def concurrent?, do: true

    def execute(_input, _context) do
      diagnostic =
        Handbean.Agent.ErrorReporter.capture_exception(
          ArgumentError.exception("private-source-payload"),
          [
            {__MODULE__, :decode, ["private-source-payload"],
             [file: "captured_tool.ex", line: 403]}
          ],
          :grep
        )

      Handbean.Agent.Tool.Result.error(
        "Internal search failure",
        %{code: :tool_exception},
        diagnostic
      )
    end
  end

  setup do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)
    Handbean.Tool.Registry.register(ExpectedFailureTool)
    Handbean.Tool.Registry.register(UnknownFailureTool)
    Handbean.Tool.Registry.register(CrashingTool)
    Handbean.Tool.Registry.register(CapturedFailureTool)
    Handbean.Tool.Registry.register(Handbean.Tool.Builtin.Edit)
    Handbean.Tool.Registry.register(Handbean.Tool.Builtin.Read)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:error_tracker, :enabled),
        else: Application.put_env(:error_tracker, :enabled, previous)
    end)

    :ok
  end

  test "keeps a structured recoverable failure in the trajectory without reporting it" do
    state = state_for(ExpectedFailureTool.name())

    assert {:ok, result} =
             Executor.execute_all(
               [
                 %{
                   id: "tool-call-1",
                   name: ExpectedFailureTool.name(),
                   input: %{"private" => "must-not-be-recorded"}
                 }
               ],
               state
             )

    assert [%{is_error: true, content: content}] = result.content
    assert content =~ "No engram found with id 143"
    assert Repo.aggregate(Occurrence, :count) == 0
  end

  test "edit misses remain recoverable tool results and do not pollute ErrorTracker" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "handbean-edit-error-tracking-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "sample.txt"), "current contents\n")
    on_exit(fn -> File.rm_rf!(directory) end)

    state =
      State.init(
        %Config{
          allowed_tools: ["edit"],
          context: %{conversation_id: "conversation-edit", workspace_id: "workspace-1"},
          run_id: "run-edit",
          working_directory: directory
        },
        "edit stale text"
      )

    assert {:ok, result} =
             Executor.execute_all(
               [
                 %{
                   id: "edit-call-1",
                   name: "edit",
                   input: %{
                     "file_path" => "sample.txt",
                     "old_string" => "stale contents",
                     "new_string" => "replacement"
                   }
                 }
               ],
               state
             )

    assert [%{is_error: true, content: content}] = result.content
    assert content =~ "Could not find text"
    assert Repo.aggregate(Occurrence, :count) == 0
  end

  test "read input failures with appended recovery hints stay out of ErrorTracker" do
    directory =
      Path.join(System.tmp_dir!(), "handbean-read-failure-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "sample.txt"), "one line\n")
    File.write!(Path.join(directory, "sample.bin"), <<0, 1, 2, 3>>)
    on_exit(fn -> File.rm_rf!(directory) end)

    state =
      State.init(%Config{allowed_tools: ["read"], working_directory: directory}, "read files")

    inputs = [
      %{"file_path" => "missing"},
      %{"file_path" => "."},
      %{"file_path" => "sample.bin"},
      %{"file_path" => "sample.txt", "offset" => 99}
    ]

    calls =
      Enum.with_index(inputs, fn input, index ->
        %{id: "read-#{index}", name: "read", input: input}
      end)

    assert {:ok, result} = Executor.execute_all(calls, state)
    assert Enum.all?(result.content, & &1.is_error)
    assert Enum.all?(result.content, &String.contains?(&1.content, "Tool hint:"))
    assert Repo.aggregate(Occurrence, :count) == 0
  end

  test "reports unknown internal tool failures with classification and redaction" do
    state = state_for(UnknownFailureTool.name())

    assert {:ok, result} =
             Executor.execute_all(
               [
                 %{
                   id: "tool-call-2",
                   name: UnknownFailureTool.name(),
                   input: %{"private" => "must-not-be-recorded"}
                 }
               ],
               state
             )

    assert [%{is_error: true, content: content}] = result.content
    assert content =~ "api-key-secret"

    assert [occurrence] = Repo.all(Occurrence)
    assert occurrence.context["failure_class"] == "tool_error"
    assert occurrence.context["reason_category"] == "internal_bridge_failed_with_redacted"
    assert occurrence.context["tool"] == UnknownFailureTool.name()
    assert occurrence.context["tool_call_id"] == "tool-call-2"
    assert occurrence.context["conversation_id"] == "conversation-1"

    recorded = inspect(occurrence)
    refute recorded =~ "api-key-secret"
    refute recorded =~ "must-not-be-recorded"
  end

  test "reports tool exceptions with a structured internal code" do
    state = state_for(CrashingTool.name())

    assert {:ok, result} =
             Executor.execute_all(
               [%{id: "crash-call", name: CrashingTool.name(), input: %{}}],
               state
             )

    assert [%{is_error: true, content: content}] = result.content
    assert content =~ "Tool crashing_fixture crashed"
    refute content =~ "api-key-secret"

    assert [occurrence] = Repo.all(Occurrence)
    assert occurrence.context["tool_error_code"] == "tool_exception"
    assert occurrence.context["failure_class"] == "tool_error"
    refute inspect(occurrence) =~ "api-key-secret"
    assert Enum.any?(occurrence.stacktrace.lines, &(&1.function == "execute"))
  end

  test "concurrent and nested diagnostics report once and stay out of public results" do
    state = state_for(CapturedFailureTool.name())
    call = %{id: "captured-call", name: CapturedFailureTool.name(), input: %{}}

    assert {:ok, result, blocks} = Executor.execute_all_with_details([call], state)
    assert [occurrence] = Repo.all(Occurrence)
    assert occurrence.reason == "grep failed (ArgumentError)"

    assert Enum.any?(
             occurrence.stacktrace.lines,
             &(&1.file == "captured_tool.ex" and &1.line == 403)
           )

    refute inspect({result, blocks, occurrence}) =~ "private-source-payload"
    refute inspect({result, blocks}) =~ "diagnostic"
    refute inspect({result, blocks}) =~ "captured_tool.ex"

    assert {:error, "Internal search failure", details} =
             Executor.execute_nested(CapturedFailureTool.name(), %{}, state,
               parent_tool_call_id: "parent-call",
               on_event: fn event -> send(self(), event) end
             )

    assert Repo.aggregate(Occurrence, :count) == 2
    assert_receive {:tool_end, payload}
    refute inspect(payload) =~ "diagnostic"
    refute inspect(payload) =~ "captured_tool.ex"
    refute inspect(details) =~ "diagnostic"
    refute inspect(details) =~ "captured_tool.ex"
  end

  defp state_for(tool) do
    config = %Config{
      allowed_tools: [tool],
      context: %{conversation_id: "conversation-1", workspace_id: "workspace-1"},
      model: "model-1",
      provider: Handbean.TestSupport.FakeProvider,
      provider_config: %{
        provider: "gateway-a",
        base_url: "https://gateway.test/v1",
        api_key: "api-key-secret"
      },
      run_id: "run-1",
      working_directory: File.cwd!()
    }

    State.init(config, "call the failing tool")
  end
end
