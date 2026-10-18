defmodule Handbean.Tool.Builtin.ReadConversation do
  @moduledoc "Read authorized transcript messages from a conversation."

  use Handbean.Tool.ConversationTool,
    name: "read_conversation",
    module: Handbean.Conversations,
    action: :read,
    description:
      "Read authorized transcript messages, with stable IDs and Unicode character offsets. Defaults to text messages only; set include_tools: true to include tool call summaries and outputs. Zero-based inclusive message range. Follow next_cursor with identical inputs to read long messages fully. Any snapshot change requires restarting.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["conversation"],
      properties: %{
        conversation: %{
          type: "string",
          description: "Conversation id in the same workspace. Not a title."
        },
        start_message: %{type: "integer", minimum: 0},
        end_message: %{type: "integer", minimum: 0},
        max_chars: %{type: "integer", minimum: 1, maximum: 16_000},
        include_tools: %{
          type: "boolean",
          description:
            "Include tool call summaries and outputs (default false: text messages only)."
        },
        cursor: %{type: "string"}
      }
    }
end
