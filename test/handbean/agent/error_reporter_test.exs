defmodule Handbean.Agent.ErrorReporterTest do
  use Handbean.DataCase, async: false

  alias ErrorTracker.{Error, Occurrence}
  alias Handbean.Agent.ErrorReporter

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

  test "separates gateway failures and strips configured credentials" do
    context = %{
      "source" => "agent_runner",
      "conversation_id" => "conversation-1",
      "run_id" => "run-1",
      "model" => "model-1"
    }

    assert :ok =
             ErrorReporter.report(
               {:server_is_overloaded, "Bearer bearer-secret", "api-key-secret"},
               context,
               provider_config: %{
                 provider: "gateway-a",
                 base_url: "https://a.gateway.test/v1?token=query-secret",
                 api_key: "api-key-secret"
               }
             )

    assert :ok =
             ErrorReporter.report(:server_is_overloaded, context,
               provider_config: %{
                 provider: "gateway-b",
                 base_url: "https://b.gateway.test/v1"
               }
             )

    errors = Repo.all(from(error in Error, order_by: error.source_line))

    assert Enum.map(errors, & &1.source_line) == [
             "agent://a.gateway.test/server_is_overloaded:0",
             "agent://b.gateway.test/server_is_overloaded:0"
           ]

    assert Enum.all?(errors, &String.ends_with?(&1.kind, "Agent.ErrorReporter.AgentRunError"))

    occurrences = Repo.all(from(occurrence in Occurrence, order_by: occurrence.id))

    assert Enum.map(occurrences, & &1.context["gateway_host"]) == [
             "a.gateway.test",
             "b.gateway.test"
           ]

    assert Enum.all?(occurrences, &(&1.context["failure_class"] == "provider_overloaded"))

    recorded = inspect({errors, occurrences})
    refute recorded =~ "bearer-secret"
    refute recorded =~ "api-key-secret"
    refute recorded =~ "query-secret"
  end

  test "does not recursively persist SQLite storage failures" do
    context = %{"source" => "agent_runner", "conversation_id" => "conversation-1"}

    assert :ok = ErrorReporter.report("database or disk is full", context)
    assert Repo.aggregate(Error, :count) == 0
    assert Repo.aggregate(Occurrence, :count) == 0
  end

  test "classifies only explicit or normalized recoverable tool failures as expected" do
    assert {:expected, "text_not_found"} =
             ErrorReporter.tool_failure_disposition(
               "edit #1: Could not find text. Re-read and retry.",
               %{}
             )

    assert {:expected, "invalid_arguments"} =
             ErrorReporter.tool_failure_disposition("file_path is required", %{})

    assert {:expected, "file_not_found"} =
             ErrorReporter.tool_failure_disposition("File not found: /tmp/missing", %{})

    assert {:expected, "path_not_allowed"} =
             ErrorReporter.tool_failure_disposition(
               "Path traversal blocked: /tmp/private is outside workspace",
               %{}
             )

    assert {:expected, _category} =
             ErrorReporter.tool_failure_disposition("arbitrary message", %{code: :input_rejected})

    assert {:expected, _category} =
             ErrorReporter.tool_failure_disposition("arbitrary message", %{permission: :denied})

    assert {:report, "unexpected_bridge_state"} =
             ErrorReporter.tool_failure_disposition("unexpected bridge state", %{})

    assert {:report, "capability_unavailable"} =
             ErrorReporter.tool_failure_disposition("internal task service unavailable", %{})

    assert {:report, "failed_with_redacted"} =
             ErrorReporter.tool_failure_disposition(
               "failed with api-key-secret",
               %{},
               %{api_key: "api-key-secret"}
             )

    assert {:report, _category} =
             ErrorReporter.tool_failure_disposition("unknown failure", %{code: :new_unknown_code})
  end

  test "separates tool reason categories while grouping dynamic details" do
    context = %{"source" => "agent_tool", "tool" => "read_thread"}

    assert :ok = ErrorReporter.report(:not_accessible, context, failure_class: :tool_error)

    assert :ok =
             ErrorReporter.report(:stale_or_invalid_cursor, context, failure_class: :tool_error)

    assert :ok =
             ErrorReporter.report(:stale_or_invalid_cursor, context, failure_class: :tool_error)

    dynamic_context = %{"source" => "agent_tool", "tool" => "task_status"}

    assert :ok =
             ErrorReporter.report(
               ~s(No subagent "11111111-1111-4111-8111-111111111111" in this conversation),
               dynamic_context,
               failure_class: :tool_error
             )

    assert :ok =
             ErrorReporter.report(
               ~s(No subagent "22222222-2222-4222-8222-222222222222" in this conversation),
               dynamic_context,
               failure_class: :tool_error
             )

    http_context = %{"source" => "agent_tool", "tool" => "web_fetch"}
    assert :ok = ErrorReporter.report("HTTP status 404", http_context, failure_class: :tool_error)
    assert :ok = ErrorReporter.report("HTTP status 429", http_context, failure_class: :tool_error)
    assert :ok = ErrorReporter.report("HTTP status 404", http_context, failure_class: :tool_error)

    errors = Repo.all(from(error in Error, order_by: error.source_line))

    assert Enum.map(errors, & &1.source_line) == [
             "agent://agent_tool/read_thread/not_accessible:0",
             "agent://agent_tool/read_thread/stale_or_invalid_cursor:0",
             "agent://agent_tool/task_status/subagent_not_found:0",
             "agent://agent_tool/web_fetch/http_status_404:0",
             "agent://agent_tool/web_fetch/http_status_429:0"
           ]

    assert Repo.aggregate(Occurrence, :count) == 8

    categories =
      Occurrence
      |> Repo.all()
      |> Enum.frequencies_by(& &1.context["reason_category"])

    assert categories == %{
             "http_status_404" => 2,
             "http_status_429" => 1,
             "not_accessible" => 1,
             "stale_or_invalid_cursor" => 2,
             "subagent_not_found" => 2
           }
  end
end
