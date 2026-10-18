defmodule Handbean.Tool.Builtin.SearchConversations do
  @moduledoc "Search persisted entries across authorized durable conversations."

  use Handbean.Tool.ConversationTool,
    name: "search_conversations",
    module: Handbean.Conversations,
    action: :search_entries,
    description:
      "Search redacted persisted messages and tool records across authorized durable conversations in the current workspace. The invoking run is excluded so the current request and completed search tool calls cannot become their own evidence or invalidate pagination. Returns bounded snippets with stable conversation/run/turn/sequence/entry anchors; continue with read_conversation or get_conversation_trajectory. Excludes free and internal task conversations. Matching is literal, not fuzzy. Cursors invalidate on searched source changes.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["query"],
      properties: %{
        query: %{type: "string", minLength: 1, maxLength: 200},
        conversation: %{
          type: "string",
          maxLength: 256,
          description: "Optional conversation id in the same workspace. Not a title."
        },
        run_id: %{type: "string", maxLength: 256, description: "Optional durable run id."},
        updated_after: %{type: "string", description: "Inclusive ISO-8601 timestamp."},
        kinds: %{
          type: "array",
          maxItems: 4,
          uniqueItems: true,
          items: %{type: "string", enum: ["user", "assistant", "tool", "system"]}
        },
        tool_name: %{type: "string", maxLength: 128},
        file_path: %{type: "string", maxLength: 1_000},
        errors_only: %{type: "boolean"},
        archived: %{
          type: "string",
          enum: ["active", "archived", "all"],
          default: "all",
          description: "Which conversations to search (default all)."
        },
        limit: %{type: "integer", minimum: 1, maximum: 20},
        max_chars: %{type: "integer", minimum: 2_000, maximum: 16_000},
        cursor: %{type: "string"}
      }
    }

  def deferred?, do: true
  def max_result_chars, do: 20_000
end
