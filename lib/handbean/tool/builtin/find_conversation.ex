defmodule Handbean.Tool.Builtin.FindConversation do
  @moduledoc "Find durable conversations in the current workspace."

  use Handbean.Tool.ConversationTool,
    name: "find_conversation",
    module: Handbean.Conversations,
    action: :find,
    description:
      "Search durable conversations in the current workspace by a required title substring, excluding internal tasks. Returns persistent summaries only. Use list_conversations when browsing without a known keyword. Cursors expire on snapshot changes; restart the search.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["query"],
      properties: %{
        query: %{type: "string", minLength: 1, maxLength: 200},
        archived: %{
          type: "string",
          enum: ["active", "archived", "all"],
          description: "Which conversations to search (default active)."
        },
        updated_after: %{type: "string", description: "Inclusive ISO-8601 timestamp."},
        limit: %{type: "integer", minimum: 1, maximum: 20},
        cursor: %{type: "string"}
      }
    }
end
