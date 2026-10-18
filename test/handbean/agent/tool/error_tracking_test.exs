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

  setup do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)
    Handbean.Tool.Registry.register(ExpectedFailureTool)
    Handbean.Tool.Registry.register(UnknownFailureTool)
    Handbean.Tool.Registry.register(CrashingTool)
    Handbean.Tool.Registry.register(Handbean.Tool.Builtin.Edit)

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

    assert [occurrence] = Repo.all(Occurrence)
    assert occurrence.context["tool_error_code"] == "tool_exception"
    assert occurrence.context["failure_class"] == "tool_error"
    refute inspect(occurrence) =~ "api-key-secret"
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
