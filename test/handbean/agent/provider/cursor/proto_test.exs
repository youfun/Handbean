defmodule Handbean.Agent.Provider.Cursor.ProtoTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.Cursor.Proto

  test "value round-trip for nested json schema" do
    schema = %{
      "type" => "object",
      "properties" => %{"key" => %{"type" => "string"}},
      "required" => ["key"]
    }

    assert Proto.decode_value(Proto.encode_value(schema)) == schema
  end

  test "mcp args map values decode independently" do
    encoded =
      Proto.finish(
        Proto.encode_string(1, "probe_lookup") ++
          Proto.encode_map_entry(2, "key", Proto.encode_value("violet-17")) ++
          Proto.encode_string(3, "call-1")
      )

    exec =
      Proto.decode_server(
        Proto.finish(
          Proto.encode_message(
            2,
            Proto.finish(Proto.encode_message(11, encoded) ++ Proto.encode_string(15, "exec-9"))
          )
        )
      )

    assert {:exec, %{kind: :mcp, payload: payload, exec_id: "exec-9"}} = exec
    assert payload.name == "probe_lookup"
    assert payload.args == %{"key" => "violet-17"}
    assert payload.tool_call_id == "call-1"
  end

  test "interaction text delta" do
    inner = Proto.finish(Proto.encode_message(1, Proto.encode_string(1, "703")))
    msg = Proto.finish(Proto.encode_message(1, inner))
    assert {:interaction, {:text_delta, "703"}} = Proto.decode_server(msg)
  end

  test "current interaction query decodes and approval uses client field 6" do
    query = Proto.finish(Proto.encode_uint32(1, 42) ++ Proto.encode_message(5, <<>>))
    server = Proto.finish(Proto.encode_message(7, query))

    assert {:interaction_query, %{id: 42, kind: :exa_search, response_field: 5}} =
             Proto.decode_server(server)

    response = Proto.encode_interaction_approval(42, 5)
    client = Proto.encode_client(%{interaction_response: response})
    client_fields = Proto.decode_fields(client)
    response_fields = client_fields |> Proto.field(6) |> Proto.nested()
    approval_fields = response_fields |> Proto.field(5) |> Proto.nested()

    assert Proto.field(response_fields, 1) == 42
    assert Proto.field(approval_fields, 1) == <<>>
  end

  test "current grind planning exec decodes and success uses field 36" do
    args =
      Proto.finish(Proto.encode_string(1, "Discover tools") ++ Proto.encode_string(2, "call-1"))

    server =
      Proto.finish(
        Proto.encode_message(
          2,
          Proto.finish(Proto.encode_uint32(1, 7) ++ Proto.encode_message(36, args))
        )
      )

    assert {:exec,
            %{
              id: 7,
              kind: :start_grind_planning,
              payload: %{explanation: "Discover tools", tool_call_id: "call-1"},
              result_field: 36
            }} = Proto.decode_server(server)

    result = Proto.encode_exec_client(7, "", 36, Proto.encode_start_grind_planning_success())
    fields = Proto.decode_fields(result)
    assert Proto.field(fields, 1) == 7
    assert Proto.field(fields, 36) == Proto.finish(Proto.encode_message(1, <<>>))
  end

  test "tool call step nests MCP under ConversationStep 2 then ToolCall 15" do
    input = %{
      "key" => "violet-17",
      "ok" => true,
      "count" => 3,
      "nested" => %{"flag" => false},
      "list" => [1, "two"],
      "empty" => nil
    }

    step =
      Proto.encode_tool_call_step(
        "call-1",
        "probe_lookup",
        input,
        {:success, "ORCHID-5928", false}
      )

    assert {:tool_call, {:mcp, decoded}} = IndependentProto.decode_conversation_step(step)
    assert decoded.args.tool_call_id == "call-1"
    assert decoded.args.name == "probe_lookup"
    assert decoded.args.args["key"] == "violet-17"
    assert decoded.args.args["ok"] == true
    assert decoded.args.args["count"] == 3.0
    assert decoded.args.args["nested"] == %{"flag" => false}
    assert decoded.args.args["list"] == [1.0, "two"]
    assert decoded.args.args["empty"] == nil
    assert {:success, %{content: ["ORCHID-5928"], is_error: false}} = decoded.result
  end

  test "usable models decode" do
    model =
      Proto.finish(
        Proto.encode_string(1, "composer-2.5") ++
          Proto.encode_string(4, "Composer 2.5")
      )

    body = Proto.finish(Proto.encode_message(1, model))
    assert [%{id: "composer-2.5", name: "Composer 2.5"}] = Proto.decode_models_response(body)
  end

  test "AvailableModels request enables parameter metadata without markdown" do
    fields = Proto.encode_available_models_request() |> Proto.decode_fields()

    assert Proto.field(fields, 5) == 1
    assert Proto.field(fields, 7) == 1
  end

  test "requested model sends max mode and all selected parameters" do
    encoded =
      Proto.encode_requested_model("gpt-5.6-luna",
        max_mode: true,
        parameters: [
          %{"id" => "context", "value" => "1m"},
          %{"id" => "reasoning", "value" => "high"}
        ]
      )

    fields = Proto.decode_fields(encoded)
    assert Proto.field(fields, 1) == "gpt-5.6-luna"
    assert Proto.field(fields, 2) == 1

    assert Enum.map(Proto.fields(fields, 3), fn parameter ->
             parameter = Proto.nested(parameter)
             {Proto.field(parameter, 1), Proto.field(parameter, 2)}
           end) == [{"context", "1m"}, {"reasoning", "high"}]
  end

  test "run request uses only current requested_model routing" do
    requested = Proto.encode_requested_model("gpt-5.6-luna", max_mode: true)

    run =
      Proto.encode_run_request(
        conversation_state: <<>>,
        action: <<>>,
        conversation_id: "conversation",
        requested_model: requested
      )

    fields = Proto.decode_fields(run)
    assert Proto.field(fields, 3) == nil
    assert Proto.field(fields, 9) == requested
  end
end
