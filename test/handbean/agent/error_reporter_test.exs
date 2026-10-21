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

    assert :ok =
             ErrorReporter.report(
               {:error, %Exqlite.Error{message: "database is locked"}},
               context
             )

    for message <- [
          "database is locked",
          "database or disk is full",
          "disk I/O error",
          "file is not a database"
        ] do
      diagnostic =
        ErrorReporter.capture_exception(
          RuntimeError.exception(message <> " private SQL"),
          [],
          :tool_execution
        )

      refute inspect(diagnostic) =~ "private SQL"
      assert :ok = ErrorReporter.report(diagnostic, context)
    end

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

  test "uses only allowlisted Browser policy metadata for stable categories" do
    base = %{
      code: :browser_policy_denied,
      error_owner: :browser_policy,
      error_rule: :shell_metacharacters
    }

    assert {:report, "browser_policy_eval_shell_metacharacters_script"} =
             ErrorReporter.tool_failure_disposition(
               "fixed message",
               Map.merge(base, %{error_command: :eval, error_argument_role: :script})
             )

    assert {:report, "browser_policy_fill_shell_metacharacters_ref"} =
             ErrorReporter.tool_failure_disposition(
               "first private selector",
               Map.merge(base, %{error_command: :fill, error_argument_role: :ref})
             )

    assert {:report, "browser_policy_type_shell_metacharacters_text"} =
             ErrorReporter.tool_failure_disposition(
               "first private text",
               Map.merge(base, %{error_command: :type, error_argument_role: :text})
             )

    assert {:report, "browser_policy_type_shell_metacharacters_text"} =
             ErrorReporter.tool_failure_disposition(
               "different private text",
               Map.merge(base, %{error_command: "type", error_argument_role: "text"})
             )

    assert {:report, "fixed_message"} =
             ErrorReporter.tool_failure_disposition(
               "fixed message",
               Map.merge(base, %{
                 error_command: "../../private/source",
                 error_argument_role: "Module.function/3"
               })
             )
  end

  test "IDs and stack line numbers do not classify internal exceptions as provider errors" do
    for digits <- ["4298", "401", "403"] do
      reason =
        RuntimeError.exception(
          "Transcript persistence failed for #{Ecto.UUID.generate()}-#{digits}"
        )

      stack = [{__MODULE__, :internal_failure, 0, [file: "internal.ex", line: 429]}]
      ErrorReporter.report({:error, {reason, stack}}, %{"source" => "agent_runner"})
    end

    occurrences = Repo.all(Occurrence)
    assert length(occurrences) == 3
    assert Enum.all?(occurrences, &(&1.context["failure_class"] == "exception"))
    assert Enum.all?(Repo.all(Error), &(&1.kind == "Elixir.RuntimeError"))
    assert Enum.all?(Repo.all(Error), &(&1.source_line == "internal.ex:429"))
  end

  test "HTTP statuses use explicit status positions, not unrelated body numbers" do
    for {reason, expected} <- [
          {{:retry_exhausted, 429, "authentication failed 401", []}, "provider_rate_limited"},
          {{:http_error, 401, "request 4298"}, "provider_auth"},
          {{:http_status, 403}, "provider_auth"},
          {%{status: 503, body: "request 401"}, "provider_server"},
          {"HTTP 429: retry later", "provider_rate_limited"},
          {"HTTP 401: unauthorized", "provider_auth"},
          {"HTTP status 403", "provider_auth"},
          {"delegated-401-403-4298 failed", "agent_error"},
          {"JS validation failed: setTimeout is forbidden", "agent_error"},
          {"OpenAI API error 429 (after retries): request rejected", "provider_rate_limited"},
          {"OpenAI API error 401: request rejected", "provider_auth"},
          {"invalid_request_error: Incorrect API key provided: sample", "provider_auth"},
          {%Req.TransportError{reason: :timeout}, "provider_timeout"},
          {{:http_error, %Req.TransportError{reason: :timeout}}, "provider_timeout"},
          {{%Req.TransportError{reason: :timeout}, []}, "provider_timeout"},
          {%Req.TransportError{reason: :closed}, "provider_error"}
        ] do
      id = Ecto.UUID.generate()
      ErrorReporter.report(reason, %{"case" => id})
      occurrence = Enum.find(Repo.all(Occurrence), &(&1.context["case"] == id))
      assert occurrence.context["failure_class"] == expected
    end
  end

  test "recoverable input results stay expected while exceptions and unknown codes are reported" do
    for reason <- [
          :invalid_input,
          :no_parent,
          :idempotency_conflict,
          "/tmp: Is a directory",
          "/tmp/file: Binary file, cannot display as text",
          "Offset 100 beyond file end (10 lines)",
          "unsandboxed is not available for job=true"
        ] do
      assert {:expected, _} = ErrorReporter.tool_failure_disposition(reason)
    end

    for reason <- [
          "question (max 8000 bytes) is required",
          "message (max 16000 bytes) is required",
          "diff parameter is required when mode=diff",
          "child_conversation_id is required for get",
          "pattern is required to search contents. Use glob to list files.",
          "invalid_input\n\nTool hint: Fix input"
        ] do
      assert {:expected, _} = ErrorReporter.tool_failure_disposition(reason)
    end

    for code <- [:invalid_input, :no_parent, :idempotency_conflict] do
      assert {:expected, _} = ErrorReporter.tool_failure_disposition("rejected", %{code: code})

      assert {:expected, _} =
               ErrorReporter.tool_failure_disposition("rejected", %{
                 "code" => Atom.to_string(code)
               })
    end

    for reason <- [
          RuntimeError.exception("file_path is required"),
          {:error, {RuntimeError.exception("permission denied"), []}},
          "HTTP status 403",
          "HTTP status 404",
          "HTTP status 415",
          "authentication service failed",
          "invalid input!",
          "internal configuration is required",
          "index database file not found"
        ] do
      assert {:report, _} = ErrorReporter.tool_failure_disposition(reason)
    end

    assert {:report, _} =
             ErrorReporter.tool_failure_disposition("file not found", %{code: :internal_failure})

    assert {:report, category} =
             ErrorReporter.tool_failure_disposition(
               "JS validation failed: setTimeout is forbidden"
             )

    refute category == "timeout"
    assert {:report, "timeout"} = ErrorReporter.tool_failure_disposition("request timed out")
  end

  test "plain and tuple exceptions preserve identity and redact configured credentials" do
    for reason <- [
          RuntimeError.exception("internal 401-403-4298 failure"),
          {RuntimeError.exception("internal 401-403-4298 failure"), []},
          {:error, RuntimeError.exception("internal 401-403-4298 failure")}
        ] do
      ErrorReporter.report(reason, %{})
    end

    assert Enum.all?(Repo.all(Occurrence), &(&1.context["failure_class"] == "exception"))

    ErrorReporter.report(
      {:error,
       {RuntimeError.exception("failed with configured-secret"),
        [{__MODULE__, :decode, 1, [file: "source.ex", line: 403]}]}},
      %{},
      provider_config: %{api_key: "configured-secret"}
    )

    refute inspect(Repo.all(Occurrence)) =~ "configured-secret"
    refute inspect(Repo.all(Error)) =~ "configured-secret"
    assert Enum.any?(Repo.all(Error), &(&1.source_line == "source.ex:403"))
  end

  test "captured diagnostics discard payloads and arguments but preserve call sites" do
    exception = ArgumentError.exception("private-event-data")

    stack = [
      {__MODULE__, :decode, ["private-stack-argument"],
       [file: "decoder.ex", line: 401, error_info: %{cause: "private-cause"}]}
    ]

    {safe, safe_stack} = ErrorReporter.capture_exception(exception, stack, :sse)
    assert Exception.message(safe) == "sse failed (ArgumentError)"
    assert safe_stack == [{__MODULE__, :decode, 1, [file: "decoder.ex", line: 401]}]
    refute inspect({safe, safe_stack}) =~ "private-"
    assert :ok = ErrorReporter.report({safe, safe_stack}, %{})
    assert [occurrence] = Repo.all(Occurrence)
    assert occurrence.context["failure_class"] == "exception"
    refute inspect(occurrence) =~ "private-"
  end

  test "separates tool reason categories while grouping dynamic details" do
    context = %{"source" => "agent_tool", "tool" => "read_conversation"}

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
             "agent://agent_tool/read_conversation/not_accessible:0",
             "agent://agent_tool/read_conversation/stale_or_invalid_cursor:0",
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
