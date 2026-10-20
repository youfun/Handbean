defmodule Handbean.Agent.Provider.Cursor.EncoderTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Message

  alias Handbean.Agent.Provider.Cursor.{
    Blobs,
    HistoryEncoder,
    RequestEncoder,
    ToolResultEncoder
  }

  test "request encoder splits trailing users and exposes the consumed ledger" do
    messages = [
      %{Message.user("old") | id: "old-id"},
      Message.assistant("prior answer"),
      %{Message.user("first action") | id: "first-id"},
      %{Message.user("second action") | id: "second-id"}
    ]

    encoded =
      RequestEncoder.encode(
        messages,
        "fallback-model",
        %{
          system_prompt: "system",
          model_meta: %{
            "cursorRequestedModel" => %{"modelId" => "routed-model", "maxMode" => true}
          }
        },
        Blobs.new(),
        "cursor-conversation",
        fn -> flunk("all input messages have IDs") end
      )

    assert encoded.consumed_user_ids == MapSet.new(["old-id", "first-id"])
    assert encoded.consumed_nil_users == 0
    assert Enum.map(encoded.extra_users, & &1.id) == ["second-id"]

    run = encoded.payload |> fields() |> field(1) |> fields()
    assert field(run, 5) == "cursor-conversation"

    requested_model = run |> field(9) |> fields()
    assert field(requested_model, 1) == "routed-model"
    assert field(requested_model, 2) == 1

    user_message = run |> field(2) |> fields() |> field(1) |> fields() |> field(1) |> fields()
    assert field(user_message, 1) == "first action"
    assert field(user_message, 2) == "first-id"

    conversation_state = run |> field(1) |> fields()
    assert length(IndependentProto.fields(conversation_state, 1)) == 3
    assert length(IndependentProto.fields(conversation_state, 8)) == 1
  end

  test "history encoder generates one wire ID for each nil-id historical user" do
    parent = self()

    {_root_ids, [turn_id], blobs} =
      HistoryEncoder.encode(
        [Message.user("historical"), Message.assistant("answer")],
        nil,
        Blobs.new(),
        fn ->
          send(parent, :generated_history_id)
          "generated-history-id"
        end
      )

    assert_receive :generated_history_id
    refute_receive :generated_history_id, 0

    user_blob_id =
      blobs
      |> Blobs.fetch(turn_id)
      |> fields()
      |> field(1)
      |> fields()
      |> field(1)

    user_message = blobs |> Blobs.fetch(user_blob_id) |> fields()
    assert field(user_message, 1) == "historical"
    assert field(user_message, 2) == "generated-history-id"
  end

  test "string-type tool blocks retain string-key-only root blob semantics" do
    content = [
      %{
        "type" => "tool_use",
        "id" => "string-id",
        :id => "atom-id",
        "name" => "string-name",
        :name => "atom-name",
        "input" => %{"source" => "string"},
        :input => %{"source" => "atom"}
      },
      %{
        "type" => "tool_use",
        :id => "atom-only-id",
        :name => "atom-only-name",
        :input => %{"source" => "atom-only"}
      }
    ]

    {[root_id], [], blobs} =
      HistoryEncoder.encode([Message.assistant_blocks(content)], nil, Blobs.new())

    assert {:ok, %{"content" => [mixed, atom_only]}} =
             blobs |> Blobs.fetch(root_id) |> Handbean.JSON.decode()

    assert mixed == %{
             "type" => "tool_use",
             "id" => "string-id",
             "name" => "string-name",
             "input" => %{"source" => "string"}
           }

    assert atom_only == %{
             "type" => "tool_use",
             "id" => nil,
             "name" => nil,
             "input" => %{}
           }
  end

  test "tool result encoder keeps last duplicate and preserves shell stream frame order" do
    messages = [
      Message.tool_result(%{type: "tool_result", tool_use_id: "call", content: "old"}),
      Message.assistant_blocks([
        %{"type" => "tool_result", "tool_use_id" => "call", "content" => "new"}
      ])
    ]

    assert ToolResultEncoder.from_messages(messages) == %{"call" => {"new", false}}

    exec = %{id: 7, exec_id: "exec-7", kind: :shell_stream, result_field: 13}
    payloads = ToolResultEncoder.client_payloads(exec, "stdout", false)

    assert Enum.map(payloads, &outer_field/1) == [2, 2, 2, 5]

    assert Enum.map(Enum.take(payloads, 3), fn payload ->
             payload |> fields() |> field(2) |> fields() |> field(1)
           end) == [7, 7, 7]
  end

  defp outer_field(payload) do
    payload
    |> fields()
    |> hd()
    |> elem(0)
  end

  defp fields(payload), do: IndependentProto.decode_fields(payload)
  defp field(decoded, number), do: IndependentProto.field(decoded, number)
end
