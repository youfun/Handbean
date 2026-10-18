defmodule Handbean.Tool.Builtin.ErrorTrackerTest do
  use Handbean.DataCase, async: false

  alias ErrorTracker.Error
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

  test "lists details, resolves errors, and scans past automatic debugger failures" do
    regular =
      report_error("regular failure", 10, %{
        "source" => "agent_runner",
        "conversation_id" => "regular-conversation",
        "workspace_path" => "/tmp/project"
      })

    for line <- 20..26 do
      report_error("debugger failure #{line}", line, %{
        "source" => "agent_runner",
        "conversation_id" => "debugger-conversation"
      })
    end

    _automatic_child =
      report_error("debugger child failure", 27, %{
        "source" => "agent_runner",
        "conversation_id" => "debugger-child",
        "parent_conversation_id" => "debugger-conversation"
      })

    context = %{source: :schedule, conversation_id: "debugger-conversation"}

    assert {:ok, encoded} =
             ErrorTrackerTool.execute(%{"action" => "list", "limit" => 1}, context)

    assert %{
             "errors" => [
               %{"id" => id, "reason" => "regular failure", "occurrence_count" => 1}
             ],
             "next_cursor" => nil
           } = Handbean.JSON.decode!(encoded)

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
                 "stacktrace" => [%{"function" => "tracked_failure"}]
               }
             ]
           } = Handbean.JSON.decode!(encoded)

    assert {:ok, _encoded} =
             ErrorTrackerTool.execute(%{"action" => "resolve", "id" => id}, %{})

    assert {:ok, encoded} = ErrorTrackerTool.execute(%{"action" => "list"}, context)
    assert %{"errors" => [], "next_cursor" => nil} = Handbean.JSON.decode!(encoded)
  end

  test "uses stable keyset pagination without omissions or duplicates when timestamps tie" do
    ids =
      for line <- 100..104 do
        report_error("failure #{line}", line, %{
          "failure_class" => "tool_error",
          "reason_category" => "fixture_#{line}",
          "tool" => "fixture"
        }).error_id
      end

    tied_at = ~U[2026-01-02 03:04:05.123456Z]

    from(error in Error, where: error.id in ^ids)
    |> Repo.update_all(set: [last_occurrence_at: tied_at])

    {first, cursor1} = list_page(%{"action" => "list", "limit" => 2})
    {second, cursor2} = list_page(%{"action" => "list", "limit" => 2, "cursor" => cursor1})
    {third, cursor3} = list_page(%{"action" => "list", "limit" => 2, "cursor" => cursor2})

    listed_ids = Enum.map(first ++ second ++ third, & &1["id"])

    assert listed_ids == Enum.sort(ids, :desc)
    assert length(listed_ids) == length(Enum.uniq(listed_ids))
    assert is_binary(cursor1)
    assert is_binary(cursor2)
    assert cursor3 == nil
  end

  test "filters classifications, tools, status, mute state, and time while retaining history" do
    old =
      report_error("old tool failure", 200, %{
        "failure_class" => "tool_error",
        "reason_category" => "text_not_found",
        "tool" => "edit"
      })

    recent =
      report_error("recent provider failure", 201, %{
        "failure_class" => "provider_timeout",
        "reason_category" => "timeout"
      })

    historical = report_error("historical failure", 202, %{})

    old_at = ~U[2026-01-01 00:00:00.000000Z]
    recent_at = ~U[2026-02-01 00:00:00.000000Z]
    set_last_occurrence(old.error_id, old_at)
    set_last_occurrence(recent.error_id, recent_at)
    set_last_occurrence(historical.error_id, recent_at)

    {errors, nil} =
      list_page(%{
        "action" => "list",
        "failure_class" => "tool_error",
        "reason_category" => "text_not_found",
        "tool" => "edit"
      })

    assert [%{"id" => id, "failure_class" => "tool_error", "tool" => "edit"}] = errors
    assert id == old.error_id

    {errors, nil} =
      list_page(%{
        "action" => "list",
        "since" => "2026-01-15T00:00:00Z",
        "until" => "2026-02-02T00:00:00Z"
      })

    assert MapSet.new(Enum.map(errors, & &1["id"])) ==
             MapSet.new([recent.error_id, historical.error_id])

    assert Enum.any?(errors, fn error ->
             error["id"] == historical.error_id and is_nil(error["failure_class"])
           end)

    recent_error = Repo.get!(Error, recent.error_id)
    assert {:ok, _} = ErrorTracker.resolve(recent_error)

    {resolved, nil} = list_page(%{"action" => "list", "status" => "resolved"})
    assert Enum.map(resolved, & &1["id"]) == [recent.error_id]

    old_error = Repo.get!(Error, old.error_id)
    assert {:ok, _} = ErrorTracker.mute(old_error)

    {muted, nil} = list_page(%{"action" => "list", "muted" => true})
    assert Enum.map(muted, & &1["id"]) == [old.error_id]
  end

  test "returns structured recoverable errors for invalid cursors and keeps mute idempotent" do
    occurrence = report_error("mute me", 300, %{})

    assert {:error, "invalid error_tracker cursor", details} =
             ErrorTrackerTool.execute(%{"action" => "list", "cursor" => "not-a-cursor"}, %{})

    assert details.code == :invalid_arguments

    assert {:ok, encoded} =
             ErrorTrackerTool.execute(%{"action" => "mute", "id" => occurrence.error_id}, %{})

    assert %{"muted" => true} = Handbean.JSON.decode!(encoded)

    assert {:ok, "already muted"} =
             ErrorTrackerTool.execute(%{"action" => "mute", "id" => occurrence.error_id}, %{})
  end

  defp list_page(input) do
    assert {:ok, encoded} = ErrorTrackerTool.execute(input, %{})
    %{"errors" => errors, "next_cursor" => cursor} = Handbean.JSON.decode!(encoded)
    {errors, cursor}
  end

  defp report_error(reason, line, context) do
    ErrorTracker.report(
      RuntimeError.exception(reason),
      [{__MODULE__, :tracked_failure, 0, [file: __ENV__.file, line: line]}],
      context
    )
  end

  defp set_last_occurrence(id, datetime) do
    from(error in Error, where: error.id == ^id)
    |> Repo.update_all(set: [last_occurrence_at: datetime])
  end
end
