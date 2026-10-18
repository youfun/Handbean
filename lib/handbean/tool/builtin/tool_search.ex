defmodule Handbean.Tool.Builtin.ToolSearch do
  @moduledoc """
  Loads deferred tools into the current conversation.

  The tool is omitted from a provider request when that run has no deferred
  tools. A hit is recorded on the conversation and declared on the next
  provider request.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Agent.Tool.Executor
  alias Handbean.Tool.Deferred

  @impl true
  def name, do: "tool_search"

  @impl true
  def description do
    "Search deferred tools by capability. Pass a short query naming the action or object. " <>
      "Up to 5 matches are loaded into the next request. Tools already declared do not need a search."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "What the tool should do, such as \"create a calendar event\""
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def max_result_chars, do: 4_000

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    query = input["query"] || input[:query] || ""
    conversation_id = context[:conversation_id]

    cond do
      not is_binary(query) or String.trim(query) == "" ->
        {:error, "query is required"}

      not is_binary(conversation_id) or conversation_id == "" ->
        {:error, "tool_search requires a conversation"}

      true ->
        search(query, context, conversation_id)
    end
  end

  def execute(_input, _context), do: {:error, "query is required"}

  defp search(query, context, conversation_id) do
    config = context[:delegation_config]
    authorized = if config, do: Executor.authorized_tools(config), else: []
    hits = context |> Deferred.candidates(authorized) |> then(&Deferred.search(query, &1))

    if hits == [] do
      {:ok, "No deferred tools matched."}
    else
      text = Deferred.format_hits(hits, conversation_id)

      case Deferred.remember(conversation_id, hits) do
        :ok -> {:ok, text}
        {:error, reason} -> {:error, "Could not load tools: #{inspect(reason)}"}
      end
    end
  end
end
