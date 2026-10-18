defmodule Handbean.Tool.Builtin.GetConversationStatus do
  @moduledoc "Read a durable conversation's runtime status."

  use Handbean.Tool.ConversationTool,
    name: "get_conversation_status",
    module: Handbean.Conversations,
    action: :status,
    description:
      "Read a durable conversation's runtime status, including historical conversations without a Session. Idle does not mean success.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["conversation"],
      properties: %{
        conversation: %{
          type: "string",
          description: "Conversation id in the same workspace. Not a title."
        }
      }
    }
end
