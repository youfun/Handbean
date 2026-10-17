defmodule Handbean.Tool.Builtin.SendThreadMessage do
  @moduledoc "Send a message to an authorized peer thread."

  use Handbean.Tool.ThreadTool,
    name: "send_thread_message",
    module: Handbean.Threads.Collaboration,
    action: :send_message,
    description:
      "Send a task or result to an authorized thread whose id is known. The target is always the explicit thread argument; creation relationships never choose a recipient. Omit handoff_id for a new task; pass an existing receipt/read_thread handoff_id to continue that exchange with the same peer. Defaults to steer so a running recipient sees it before the next provider step; pass deliver_as follow_up only to wait until that run ends. An idle recipient is woken with a new run. Reuse request_id on retry; do not retry delivery_unknown with a new ID. Do not send an empty acknowledgment.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["thread", "message", "request_id"],
      properties: %{
        thread: %{
          type: "string",
          description:
            "Target conversation id in the same workspace. Not a title. Free chats and internal tasks are not addressable."
        },
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        handoff_id: %{
          type: "string",
          maxLength: 128,
          description:
            "Existing runtime-issued handoff ID for continuing an exchange. For a new exchange, omit this field entirely; do not pass an empty string or a placeholder such as 'new'."
        },
        deliver_as: %{type: "string", enum: ["follow_up", "steer"]}
      }
    }
end
