defmodule Handbean.Tool.Builtin.ErrorTrackerTest do
  use Handbean.DataCase, async: false

  alias Handbean.Tool.Builtin.ErrorTracker, as: ErrorTrackerTool

  setup do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:error_tracker, :enabled),
        else: Application.put_env(:error_tracker, :enabled, previous)
    end)

    :ok
  end

  test "lists details, resolves errors, and omits automatic debugger failures" do
    regular =
      ErrorTracker.report(
        RuntimeError.exception("regular failure"),
        [{__MODULE__, :regular_failure, 0, [file: __ENV__.file, line: __ENV__.line]}],
        %{
          "source" => "agent_runner",
          "conversation_id" => "regular-conversation",
          "workspace_path" => "/tmp/project"
        }
      )

    _automatic =
      ErrorTracker.report(
        RuntimeError.exception("debugger failure"),
        [{__MODULE__, :debugger_failure, 0, [file: __ENV__.file, line: __ENV__.line]}],
        %{"source" => "agent_runner", "conversation_id" => "debugger-conversation"}
      )

    _automatic_child =
      ErrorTracker.report(
        RuntimeError.exception("debugger child failure"),
        [{__MODULE__, :debugger_child_failure, 0, [file: __ENV__.file, line: __ENV__.line]}],
        %{
          "source" => "agent_runner",
          "conversation_id" => "debugger-child",
          "parent_conversation_id" => "debugger-conversation"
        }
      )

    context = %{source: :schedule, conversation_id: "debugger-conversation"}
    assert {:ok, encoded} = ErrorTrackerTool.execute(%{"action" => "list"}, context)

    assert [%{"id" => id, "reason" => "regular failure", "occurrence_count" => 1}] =
             Jason.decode!(encoded)

    assert id == regular.error_id

    assert {:ok, encoded} =
             ErrorTrackerTool.execute(%{"action" => "get", "id" => id}, %{})

    assert %{
             "occurrences" => [
               %{
                 "context" => %{
                   "conversation_id" => "regular-conversation",
                   "source" => "agent_runner",
                   "workspace_path" => "/tmp/project"
                 },
                 "stacktrace" => [%{"function" => "regular_failure"}]
               }
             ]
           } = Jason.decode!(encoded)

    assert {:ok, _encoded} =
             ErrorTrackerTool.execute(%{"action" => "resolve", "id" => id}, %{})

    assert {:ok, "[]"} = ErrorTrackerTool.execute(%{"action" => "list"}, context)
  end
end
