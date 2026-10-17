defmodule Handbean.Tool.Builtin.FindThread do
  @moduledoc "Find durable threads in the current workspace."

  use Handbean.Tool.ThreadTool,
    name: "find_thread",
    module: Handbean.Threads,
    action: :find,
    description:
      "Search durable threads in the current workspace by a required title substring, excluding internal tasks. Returns persistent summaries only. Use list_threads when browsing without a known keyword. Cursors expire on snapshot changes; restart the search.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["query"],
      properties: %{
        query: %{type: "string", minLength: 1, maxLength: 200},
        archived: %{
          type: "string",
          enum: ["active", "archived", "all"],
          description: "Which threads to search (default active)."
        },
        updated_after: %{type: "string", description: "Inclusive ISO-8601 timestamp."},
        limit: %{type: "integer", minimum: 1, maximum: 20},
        cursor: %{type: "string"}
      }
    }
end
