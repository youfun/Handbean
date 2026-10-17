defmodule Handbean.Tool.Builtin.ReplyToParentThread do
  @moduledoc "Explicitly send a message to the thread that created this one."

  use Handbean.Tool.ThreadTool,
    name: "reply_to_parent_thread",
    module: Handbean.Threads.Collaboration,
    action: :reply,
    description:
      "Explicitly message the thread recorded as this thread's creator. This is a convenience operation chosen by the agent, not an automatic completion route. Inherits the current run's handoff_id when present; pass an existing handoff_id to continue another exchange. Use send_thread_message when the target is any other known thread id. Do not add an empty acknowledgment.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["message", "request_id"],
      properties: %{
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        handoff_id: %{type: "string", maxLength: 128}
      }
    }
end
