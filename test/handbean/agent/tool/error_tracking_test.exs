defmodule Handbean.Agent.Tool.ErrorTrackingTest do
  use Handbean.DataCase, async: false

  alias ErrorTracker.Occurrence
  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.Executor

  defmodule FailingTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "error_tracking_fixture"
    def description, do: "Return a deterministic tool error"
    def input_schema, do: %{type: "object", properties: %{private: %{type: "string"}}}
    def concurrent?, do: false
    def execute(_input, _context), do: {:error, "No engram found with id 143"}
  end

  setup do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)
    Handbean.Tool.Registry.register(FailingTool)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:error_tracker, :enabled),
        else: Application.put_env(:error_tracker, :enabled, previous)
    end)

    :ok
  end

  test "records tool errors without retaining tool input" do
    config = %Config{
      allowed_tools: [FailingTool.name()],
      context: %{conversation_id: "conversation-1", workspace_id: "workspace-1"},
      model: "model-1",
      provider: Handbean.TestSupport.FakeProvider,
      provider_config: %{provider: "gateway-a", base_url: "https://gateway.test/v1"},
      run_id: "run-1",
      working_directory: File.cwd!()
    }

    state = State.init(config, "call the failing tool")

    assert {:ok, result} =
             Executor.execute_all(
               [
                 %{
                   id: "tool-call-1",
                   name: FailingTool.name(),
                   input: %{"private" => "must-not-be-recorded"}
                 }
               ],
               state
             )

    assert [%{is_error: true, content: content}] = result.content
    assert content =~ "No engram found with id 143"

    assert [occurrence] = Repo.all(Occurrence)
    assert occurrence.context["failure_class"] == "tool_error"
    assert occurrence.context["tool"] == FailingTool.name()
    assert occurrence.context["tool_call_id"] == "tool-call-1"
    assert occurrence.context["conversation_id"] == "conversation-1"
    refute inspect(occurrence) =~ "must-not-be-recorded"
  end
end
