defmodule Handbean.Tool.Builtin.ListConversations do
  @moduledoc "List recent durable conversations in the current workspace."

  use Handbean.Tool.ConversationTool,
    name: "list_conversations",
    module: Handbean.Conversations,
    action: :list,
    description:
      "List recent durable conversations in the current workspace, excluding internal tasks. Returns persistent summaries only, not runtime state or transcript bodies. Cursors expire on snapshot changes; restart the listing.",
    schema: %{
      type: "object",
      additionalProperties: false,
      properties: %{
        archived: %{
          type: "string",
          enum: ["active", "archived", "all"],
          description: "Which conversations to list (default active)."
        },
        updated_after: %{type: "string", description: "Inclusive ISO-8601 timestamp."},
        limit: %{type: "integer", minimum: 1, maximum: 20},
        cursor: %{type: "string"}
      }
    }
end
