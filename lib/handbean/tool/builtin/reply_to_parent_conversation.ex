defmodule Handbean.Tool.Builtin.ReplyToParentConversation do
  @moduledoc "Explicitly send a message to the conversation that created this one."

  use Handbean.Tool.ConversationTool,
    name: "reply_to_parent_conversation",
    module: Handbean.Conversations.Collaboration,
    action: :reply,
    description:
      "Explicitly message this conversation's recorded creator. This convenience target does not override the request source and is not an automatic completion route. Inherits the current run's handoff_id when present; pass an existing handoff_id for another exchange. purpose follows send_conversation_message: only request expects a report, only result fulfills consumed requests, and reverse questions or answers must set it explicitly. Use send_conversation_message for every other target.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["message", "request_id"],
      properties: %{
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        handoff_id: %{type: "string", maxLength: 128},
        purpose: %{
          type: "string",
          enum: ["request", "progress", "result", "notification"],
          description:
            "request expects a terminal report; result fulfills matching requests already consumed by this run; progress and notification do neither."
        }
      }
    }
end
