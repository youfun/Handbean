defmodule Handbean.Tool.Extension.Beam.DbSchema do
  @moduledoc """
  Read-only database schema introspection for configured Ecto repositories.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Tool.Extension.Beam.Database
  alias Handbean.Tool.Extension.Beam.DbSchema.Query

  @schema_row_limit 500

  @impl true
  def name, do: "ext__beam__db_schema"

  @impl true
  def description do
    "Inspect Ecto repositories and database schemas without writing adapter-specific metadata SQL. " <>
      "Use list_repos first in projects with multiple repositories."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        operation: %{
          type: "string",
          enum: [
            "list_repos",
            "list_tables",
            "describe_table",
            "list_indexes",
            "list_foreign_keys"
          ],
          description: "Schema operation to perform"
        },
        repo: %{
          type: "string",
          description: "Ecto Repo module name; required when multiple repos are available"
        },
        schema: %{
          type: "string",
          description: "Optional database schema; defaults to the adapter's primary schema"
        },
        table: %{
          type: "string",
          description: "Table or view name for table-specific operations"
        }
      },
      required: ["operation"],
      additionalProperties: false
    }
  end

  @impl true
  def execute(%{"operation" => "list_repos"}, _context) do
    repos = Enum.map(Database.list_repos(), &Database.metadata/1)
    encode(%{"operation" => "list_repos", "repos" => repos})
  end

  def execute(%{"operation" => operation} = input, context) do
    with {:ok, normalized_operation} <- normalize_operation(operation),
         :ok <- validate_table(normalized_operation, input),
         {:ok, repo_info} <- Database.resolve_repo(input["repo"], context),
         {:ok, query, params} <-
           Query.build(repo_info.dialect, normalized_operation, query_args(input)),
         {:ok, result} <- Database.query(repo_info, query, params) do
      {rows, truncated?} = Database.result_rows(result, @schema_row_limit)

      encode(%{
        "operation" => operation,
        "database" => Database.metadata(repo_info),
        result_key(normalized_operation) => rows,
        "truncated" => truncated?
      })
    end
  end

  def execute(_input, _context), do: {:error, "operation is required"}

  defp normalize_operation("list_tables"), do: {:ok, :list_tables}
  defp normalize_operation("describe_table"), do: {:ok, :describe_table}
  defp normalize_operation("list_indexes"), do: {:ok, :list_indexes}
  defp normalize_operation("list_foreign_keys"), do: {:ok, :list_foreign_keys}

  defp normalize_operation(operation),
    do: {:error, "Unsupported schema operation: #{inspect(operation)}"}

  defp validate_table(:list_tables, _input), do: :ok

  defp validate_table(operation, %{"table" => table})
       when operation in [:describe_table, :list_indexes, :list_foreign_keys] and
              is_binary(table) and byte_size(table) > 0,
       do: :ok

  defp validate_table(operation, _input),
    do: {:error, "Operation #{operation} requires a non-empty table argument"}

  defp query_args(input) do
    %{
      schema: empty_to_nil(input["schema"]),
      table: input["table"]
    }
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp result_key(:list_tables), do: "tables"
  defp result_key(:describe_table), do: "columns"
  defp result_key(:list_indexes), do: "indexes"
  defp result_key(:list_foreign_keys), do: "foreign_keys"

  defp encode(value) do
    case Handbean.JSON.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "Failed to encode schema result: #{inspect(reason)}"}
    end
  end
end
