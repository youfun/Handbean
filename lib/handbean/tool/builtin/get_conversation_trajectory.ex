defmodule Handbean.Tool.Builtin.GetConversationTrajectory do
  @moduledoc "Read a durable conversation's structured execution trajectory."

  use Handbean.Tool.ConversationTool,
    name: "get_conversation_trajectory",
    module: Handbean.Conversations,
    action: :trajectory,
    description:
      "Read a versioned, structured execution trajectory for an authorized durable conversation. Use summary for runs/turns, compact for bounded record metadata, and full only when redacted persisted inputs/outputs are needed. Full never means unbounded raw output. Record pages are capped at 50 records and 16,000 characters; any source change invalidates the cursor.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["conversation"],
      properties: %{
        conversation: %{
          type: "string",
          description: "Conversation id in the same workspace. Not a title."
        },
        run_id: %{type: "string", description: "Optional durable run id filter."},
        turn: %{
          type: "integer",
          minimum: 1,
          description: "Optional provider-turn number; run_id is required when set."
        },
        detail_level: %{
          type: "string",
          enum: ["summary", "compact", "full"],
          description: "Defaults to compact."
        },
        kinds: %{
          type: "array",
          maxItems: 4,
          uniqueItems: true,
          items: %{type: "string", enum: ["user", "assistant", "tool", "system"]}
        },
        errors_only: %{type: "boolean"},
        limit: %{type: "integer", minimum: 1, maximum: 50},
        max_chars: %{type: "integer", minimum: 2_000, maximum: 16_000},
        cursor: %{type: "string"}
      }
    }

  def deferred?, do: true
  def max_result_chars, do: 20_000
end
