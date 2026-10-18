defmodule Handbean.Tool.Builtin.CreateConversation do
  @moduledoc "Create a persistent delegated conversation in the current workspace."

  use Handbean.Tool.ConversationTool,
    name: "create_conversation",
    module: Handbean.Conversations.Collaboration,
    action: :create,
    description:
      "Delegate a persistent task in this workspace. Shared directory is NOT an isolated checkout. The child is a separate persistent conversation and uses this workspace's permission mode. mode read_only (default) can only read; mode write may edit this workspace. Omit model or pass current to inherit this conversation's current model. To use another model, call list_models and pass its complete id. May incur provider charges. Reuse request_id on retry; a different mode or model under the same request_id conflicts.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["title", "message", "request_id"],
      properties: %{
        title: %{type: "string", maxLength: 200},
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        model: %{
          type: "string",
          maxLength: 256,
          description:
            "current to inherit this conversation's current model, or a complete id returned by list_models. Omit to inherit."
        },
        mode: %{
          type: "string",
          enum: ["read_only", "write"],
          description: "read_only (default) or write. write edits the shared workspace."
        }
      }
    }
end
