defmodule Handbean.Tool.Builtin.CreateThread do
  @moduledoc "Create a persistent delegated thread in the current workspace."

  use Handbean.Tool.ThreadTool,
    name: "create_thread",
    module: Handbean.Threads.Collaboration,
    action: :create,
    description:
      "Delegate a persistent task in this workspace. Shared directory is NOT an isolated checkout. mode read_only (default) can only read; mode write may edit this workspace. Write does not raise a separate approval: approval defaults to auto_review (smart review) and may be yolo. yolo skips prompts for that child only and does not change workspace settings; sensitive-path denies still apply. Omit model or pass current to inherit this thread's current model. To use another model, call list_models and pass its complete id. May incur provider charges. Reuse request_id on retry; a different mode, approval, or model under the same request_id conflicts.",
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
            "current to inherit this thread's current model, or a complete id returned by list_models. Omit to inherit."
        },
        mode: %{
          type: "string",
          enum: ["read_only", "write"],
          description: "read_only (default) or write. write edits the shared workspace."
        },
        approval: %{
          type: "string",
          enum: ["auto_review", "yolo"],
          description:
            "Write threads only. Default auto_review. yolo skips prompts except built-in sensitive-path denies."
        }
      }
    }
end
