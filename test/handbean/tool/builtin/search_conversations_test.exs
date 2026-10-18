defmodule Handbean.Tool.Builtin.SearchConversationsTest do
  use Handbean.DataCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore}
  alias Handbean.Tool.Builtin.SearchConversations

  setup do
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "search-conversations-tool-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      System.put_env("HOME", old_home)
      File.rm_rf!(home)
    end)

    {:ok, source} = ConversationStore.create("search-tool-workspace", title: "Source")
    {:ok, target} = ConversationStore.create("search-tool-workspace", title: "Target")

    context = %{
      conversation_id: source["id"],
      workspace_id: "search-tool-workspace",
      run_id: "source-run"
    }

    %{context: context, target: target["id"]}
  end

  test "declares the deferred tool identity, guidance, and result cap" do
    assert SearchConversations.name() == "search_conversations"
    assert SearchConversations.deferred?()
    assert SearchConversations.max_result_chars() == 20_000

    description = SearchConversations.description()
    assert description =~ "redacted persisted messages and tool records"
    assert description =~ "stable conversation/run/turn/sequence/entry anchors"
    assert description =~ "read_conversation"
    assert description =~ "get_conversation_trajectory"
    assert description =~ "literal, not fuzzy"
    assert description =~ "Cursors invalidate on source changes"
  end

  test "declares the bounded search schema" do
    schema = SearchConversations.input_schema()

    assert schema.type == "object"
    assert schema.additionalProperties == false
    assert schema.required == ["query"]

    assert Map.keys(schema.properties) |> Enum.sort() ==
             ~w(archived conversation cursor errors_only file_path kinds limit max_chars query run_id tool_name updated_after)a
             |> Enum.sort()

    assert schema.properties.query == %{type: "string", minLength: 1, maxLength: 200}
    assert schema.properties.conversation.maxLength == 256
    assert schema.properties.run_id.maxLength == 256
    assert schema.properties.updated_after.description =~ "ISO-8601"

    assert schema.properties.kinds == %{
             type: "array",
             maxItems: 4,
             uniqueItems: true,
             items: %{type: "string", enum: ["user", "assistant", "tool", "system"]}
           }

    assert schema.properties.tool_name.maxLength == 128
    assert schema.properties.file_path.maxLength == 1_000
    assert schema.properties.errors_only.type == "boolean"
    assert schema.properties.archived.enum == ["active", "archived", "all"]
    assert schema.properties.archived.default == "all"
    assert schema.properties.limit.minimum == 1
    assert schema.properties.limit.maximum == 20
    assert schema.properties.max_chars.minimum == 2_000
    assert schema.properties.max_chars.maximum == 16_000
    assert schema.properties.cursor.type == "string"
  end

  test "encodes core search results and translates core errors", %{
    context: context,
    target: target
  } do
    assert {:ok, _entry} =
             ConversationTranscriptStore.append(target, %{
               "id" => "adapter-entry",
               "role" => "assistant",
               "run_id" => "adapter-run",
               "turn_number" => 2,
               "content" => "adapter round-trip evidence"
             })

    assert {:ok, encoded} =
             SearchConversations.execute(
               %{"query" => "round-trip evidence", "conversation" => target},
               context
             )

    assert %{
             "filters" => %{"archived" => "all"},
             "matches" => [
               %{
                 "conversation_id" => ^target,
                 "entry_id" => "adapter-entry",
                 "run_id" => "adapter-run",
                 "turn" => 2
               }
             ]
           } = Handbean.JSON.decode!(encoded)

    assert {:error, "invalid_input"} = SearchConversations.execute(%{}, context)
    assert {:error, "unauthorized"} = SearchConversations.execute(%{"query" => "evidence"}, %{})
  end
end
