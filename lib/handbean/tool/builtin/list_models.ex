defmodule Handbean.Tool.Builtin.ListModels do
  @moduledoc "Search models available to the current or an explicitly authorized workspace."

  @behaviour Handbean.Agent.Tool

  alias Handbean.Agent.{ModelConfig, Reasoning}
  alias Handbean.Conversations
  alias Handbean.Permissions.Boundary
  alias Handbean.WorkspaceStore

  @max_limit 20

  @impl true
  def name, do: "list_models"

  @impl true
  def description do
    "Search workspace-allowed models when create_conversation needs an explicit model. " <>
      "Omit workspace for the current workspace. An exact different workspace id requires boundary approval. " <>
      "Results include supported and default reasoning levels, are bounded and paginated, and expose no provider credentials."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        workspace: %{
          type: "string",
          maxLength: 256,
          description:
            "Optional exact registered workspace id. Cross-workspace catalog access requires approval unless the run is yolo."
        },
        query: %{
          type: "string",
          maxLength: 200,
          description: "Optional case-insensitive model id or name search"
        },
        offset: %{type: "integer", minimum: 0},
        limit: %{type: "integer", minimum: 1, maximum: @max_limit}
      }
    }
  end

  @impl true
  def max_result_chars, do: 8_000

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with :ok <- Conversations.validate(input, ~w(workspace query offset limit)),
         {:ok, query} <- query(input),
         {:ok, offset} <- integer(input, "offset", 0, 0, :infinity),
         {:ok, limit} <- integer(input, "limit", 10, 1, @max_limit),
         {:ok, target} <- target_workspace(input["workspace"], context),
         true <- Boundary.workspace_allowed?(context, target.id, :list_models) do
      all_models = ModelConfig.available_models_for_workspace(target.path)
      models = filter(all_models, query)
      page = Enum.slice(models, offset, limit)
      next_offset = if offset + length(page) < length(models), do: offset + length(page)

      {:ok,
       Handbean.JSON.encode!(%{
         "workspace" => target.id,
         "current" => current_model(all_models, context, target.current?),
         "default" => ModelConfig.default_model_for_workspace(target.path),
         "models" => Enum.map(page, &project_model/1),
         "next_offset" => next_offset
       })}
    else
      false -> {:error, "not_accessible"}
      {:error, reason} when is_atom(reason) -> {:error, Atom.to_string(reason)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "invalid_input"}
    end
  end

  def execute(_, _), do: {:error, "invalid_input"}

  defp target_workspace(requested, context) when requested in [nil, ""] do
    id = context[:workspace_id]
    path = workspace_path(context)

    if is_binary(id) and id != "" and is_binary(path) and path != "" do
      {:ok, %{id: id, path: path, current?: true}}
    else
      {:error, :not_accessible}
    end
  end

  defp target_workspace(requested, context) when is_binary(requested) do
    if requested == context[:workspace_id] do
      target_workspace(nil, context)
    else
      case WorkspaceStore.get(requested) do
        {:ok, workspace} ->
          {:ok, %{id: workspace["id"], path: workspace["path"], current?: false}}

        _ ->
          {:error, :not_accessible}
      end
    end
  end

  defp target_workspace(_requested, _context), do: {:error, :invalid_input}

  defp project_model(model) do
    %{
      "id" => model.id,
      "name" => model.name,
      "reasoning_levels" => Reasoning.supported_levels(model),
      "default_reasoning_level" => Reasoning.default_level(model)
    }
  end

  defp query(input) do
    case Map.get(input, "query", "") do
      query when is_binary(query) ->
        if String.valid?(query) and String.length(query) <= 200,
          do: {:ok, String.downcase(String.trim(query))},
          else: {:error, :invalid_input}

      _ ->
        {:error, :invalid_input}
    end
  end

  defp integer(input, key, default, minimum, maximum) do
    value = Map.get(input, key, default)

    if is_integer(value) and value >= minimum and (maximum == :infinity or value <= maximum),
      do: {:ok, value},
      else: {:error, :invalid_input}
  end

  defp workspace_path(context) do
    opts = context[:conversation_run_opts] || []
    context[:workspace_path] || Keyword.get(opts, :workspace_path)
  end

  defp filter(models, ""), do: models

  defp filter(models, query) do
    Enum.filter(models, fn model ->
      [model.id, model.name, model.provider_id, model.model_id]
      |> Enum.filter(&is_binary/1)
      |> Enum.any?(&(String.downcase(&1) |> String.contains?(query)))
    end)
  end

  defp current_model(_models, _context, false), do: nil

  defp current_model(models, context, true) do
    opts = context[:conversation_run_opts] || []
    model_id = Keyword.get(opts, :model)
    provider_config = Keyword.get(opts, :provider_config, %{})
    provider_id = provider_config[:provider_key] || provider_config["provider_key"]

    Enum.find_value(models, fn model ->
      if model.provider_id == provider_id and model.model_id == model_id, do: model.id
    end)
  end
end
