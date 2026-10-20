defmodule Handbean.Tool.Builtin.SendConversationMessage do
  @moduledoc "Send a message to an authorized peer conversation."

  use Handbean.Tool.ConversationTool,
    name: "send_conversation_message",
    module: Handbean.Conversations.Collaboration,
    action: :send_message,
    description:
      "Send a request, progress update, result, or notification to an authorized conversation whose id is known. The target is always explicit; creation relationships never choose it. Omit handoff_id for a new request; pass an existing receipt/read_conversation handoff_id to continue that exchange. purpose defaults to request for a new handoff and for its original initiator, and to result for the original responder. In reverse multi-round questions and answers, always set purpose explicitly. Only request expects an automatic terminal report; only result fulfills requests consumed by the current run. progress and notification do neither. Defaults to steer; use follow_up to wait until the current run ends. Reuse request_id on retry; do not retry delivery_unknown with a new ID.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["conversation", "message", "request_id"],
      properties: %{
        conversation: %{
          type: "string",
          description:
            "Exact target conversation id. A different workspace requires per-call approval unless the run is yolo. Not a title. Free chats and internal tasks are not addressable."
        },
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        handoff_id: %{
          type: "string",
          maxLength: 128,
          description:
            "Existing runtime-issued handoff ID for continuing an exchange. For a new exchange, omit this field entirely; do not pass an empty string or a placeholder such as 'new'."
        },
        deliver_as: %{type: "string", enum: ["follow_up", "steer"]},
        purpose: %{
          type: "string",
          enum: ["request", "progress", "result", "notification"],
          description:
            "request expects a terminal report; result fulfills matching requests already consumed by this run; progress and notification do neither. Set explicitly for reverse questions or answers on an existing handoff."
        }
      }
    }
end
