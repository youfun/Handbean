defmodule Handbean.Tool.Builtin.CreateConversation do
  @moduledoc "Create a persistent delegated conversation in an authorized workspace."

  use Handbean.Tool.ConversationTool,
    name: "create_conversation",
    module: Handbean.Conversations.Collaboration,
    action: :create,
    description:
      "Delegate a persistent task in the current or an explicitly authorized workspace. Shared directory is NOT an isolated checkout. The child is a separate persistent conversation and uses the target workspace's permission mode. mode read_only (default) can only read; mode write may edit that workspace. In the current workspace, omit model or pass current to inherit this conversation's model; if reasoning_level is also omitted, inherit this run's level when the model supports it. In another workspace, omit model or pass current to use the target workspace default model and omit reasoning_level to use that model's default. Use list_models with the target workspace to choose another model and supported reasoning_level. Cross-workspace creation requires approval unless yolo. Reuse request_id on retry; changed target, mode, model, or reasoning level conflicts.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["title", "message", "request_id"],
      properties: %{
        title: %{type: "string", maxLength: 200},
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        workspace: %{
          type: "string",
          maxLength: 256,
          description:
            "Optional exact registered target workspace id. Omit for the current workspace."
        },
        model: %{
          type: "string",
          maxLength: 256,
          description:
            "Complete model id returned by list_models. Omit or pass current to inherit in the current workspace, or use the target default across workspaces."
        },
        reasoning_level: %{
          type: "string",
          maxLength: 32,
          description:
            "Optional supported reasoning level. When omitted, inherit the current run's level in the current workspace when supported; across workspaces use the selected target model's default."
        },
        mode: %{
          type: "string",
          enum: ["read_only", "write"],
          description: "read_only (default) or write. write edits the target workspace."
        }
      }
    }
end
