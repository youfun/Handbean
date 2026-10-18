defmodule Handbean.Tool.Builtin.ListModels do
  @moduledoc "Search the models available to the current workspace."

  @behaviour Handbean.Agent.Tool

  alias Handbean.Agent.ModelConfig
  alias Handbean.Conversations

  @max_limit 20

  @impl true
  def name, do: "list_models"

  @impl true
  def description do
    "Search workspace-allowed models when you need create_conversation to use a model other than current. Results are bounded and paginated; pass a returned complete id as create_conversation.model."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
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
  def max_result_chars, do: 6_000

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with :ok <- Conversations.validate(input, ~w(query offset limit)),
         {:ok, query} <- query(input),
         {:ok, offset} <- integer(input, "offset", 0, 0, :infinity),
         {:ok, limit} <- integer(input, "limit", 10, 1, @max_limit),
         path when is_binary(path) and path != "" <- workspace_path(context) do
      all_models = ModelConfig.available_models_for_workspace(path)
      models = filter(all_models, query)
      page = Enum.slice(models, offset, limit)
      next_offset = if offset + length(page) < length(models), do: offset + length(page)

      {:ok,
       Handbean.JSON.encode!(%{
         "current" => current_model(all_models, context),
         "models" => Enum.map(page, &%{"id" => &1.id, "name" => &1.name}),
         "next_offset" => next_offset
       })}
    else
      _ -> {:error, "invalid_input"}
    end
  end

  def execute(_, _), do: {:error, "invalid_input"}

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

  defp current_model(models, context) do
    opts = context[:conversation_run_opts] || []
    model_id = Keyword.get(opts, :model)
    provider_config = Keyword.get(opts, :provider_config, %{})
    provider_id = provider_config[:provider_key] || provider_config["provider_key"]

    Enum.find_value(models, fn model ->
      if model.provider_id == provider_id and model.model_id == model_id, do: model.id
    end)
  end
end
