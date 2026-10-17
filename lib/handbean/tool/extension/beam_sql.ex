defmodule Handbean.Tool.Extension.Beam.Sql do
  @moduledoc """
  Execute raw SQL through a configured Ecto repository.

  This tool can mutate application data and database schemas. It is registered
  separately from safe read-only BEAM introspection and is guarded by the normal
  workspace approval policy.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Tool.Extension.Beam.Database

  @impl true
  def name, do: "ext__beam__sql"

  @impl true
  def description do
    "Execute raw SQL through a configured Ecto Repo. This tool can mutate data and schemas and " <>
      "requires approval unless explicitly allowed or the workspace is in yolo mode. The SQL " <>
      "dialect and parameter syntax come from the selected Repo; use ext__beam__db_schema first " <>
      "when unsure. Results are limited to 50 rows."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "SQL query to execute in the selected Repo's dialect"
        },
        repo: %{
          type: "string",
          description: "Ecto Repo module name; required when multiple repos are available"
        },
        params: %{
          type: "array",
          description: "Query parameters",
          items: %{}
        }
      },
      required: ["query"],
      additionalProperties: false
    }
  end

  @impl true
  def execute(%{"query" => query} = input, context) do
    params = Map.get(input, "params", [])

    with :ok <- validate_params(params),
         {:ok, repo_info} <- Database.resolve_repo(input["repo"], context) do
      execute_query(repo_info, query, params)
    end
  end

  def execute(_input, _context), do: {:error, "query is required"}

  defp validate_params(params) when is_list(params), do: :ok
  defp validate_params(_params), do: {:error, "params must be an array"}

  defp execute_query(repo_info, query, params) do
    metadata = Database.format_metadata(repo_info)

    case Database.query(repo_info, query, params) do
      {:ok, result} -> {:ok, metadata <> "\n\n" <> Database.format_result(result)}
      {:error, message} -> {:error, metadata <> "\n\nSQL error: " <> message}
    end
  end
end
