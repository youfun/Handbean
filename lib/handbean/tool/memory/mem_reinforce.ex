defmodule Handbean.Tool.Memory.MemReinforce do
  @moduledoc """
  Memory reinforce tool — promotes short-term memory to long-term.

  Increments the reinforcement counter and prevents auto-expiry.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "mem_reinforce"

  @impl true
  def description do
    "Reinforce a memory, promoting it from short-term to long-term. " <>
      "Use when you encounter information worth remembering permanently."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        id: %{type: "integer", description: "ID of the engram to reinforce"},
        query: %{
          type: "string",
          description: "Alternative: reinforce by content match (use most recent match)"
        }
      },
      required: []
    }
  end

  @impl true
  def max_result_chars, do: 500

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"id" => id}, context) do
    case Handbean.Repo.get(Handbean.Memory.Engram, id) do
      nil ->
        {:error, "No engram found with id #{id}"}

      engram ->
        if accessible?(engram, context) do
          reinforce_accessible(engram)
        else
          {:error, "No accessible engram found with id #{id}"}
        end
    end
  end

  def execute(%{"query" => query}, context) do
    case Handbean.Memory.MemoryStore.recall(query, recall_opts(context, 1)) do
      [engram | _] ->
        reinforce_accessible(engram)

      [] ->
        {:error, "No memory found matching '#{query}'"}
    end
  end

  def execute(_input, _context), do: {:error, "Provide id or query of the memory to reinforce"}

  defp reinforce_accessible(engram) do
    case Handbean.Memory.MemoryStore.reinforce(engram) do
      {:ok, reinforced} ->
        {:ok, "Reinforced: [#{reinforced.kind}] #{reinforced.content} (now long-term)"}

      {:error, _} ->
        {:error, "Failed to reinforce engram #{engram.id}"}
    end
  end

  defp accessible?(engram, context) do
    scope = metadata_value(engram, "scope")
    engram_workspace_id = metadata_value(engram, "workspace_id")
    workspace_id = context_value(context, :workspace_id)
    memory_scope = normalize_scope(context_value(context, :memory_scope))
    privacy_mode = normalize_privacy_mode(context_value(context, :privacy_mode))

    cond do
      privacy_mode == :local_only and is_binary(workspace_id) ->
        scope == "workspace" and engram_workspace_id == workspace_id

      memory_scope == :workspace and is_binary(workspace_id) ->
        scope == "workspace" and engram_workspace_id == workspace_id

      memory_scope == :global ->
        scope == "global"

      memory_scope == :both and is_binary(workspace_id) ->
        scope == "global" or (scope == "workspace" and engram_workspace_id == workspace_id)

      true ->
        true
    end
  end

  defp recall_opts(context, limit) when is_map(context) do
    [
      limit: limit,
      workspace_id: context_value(context, :workspace_id),
      memory_scope: context_value(context, :memory_scope),
      privacy_mode: context_value(context, :privacy_mode)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp recall_opts(_context, limit), do: [limit: limit]

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))

  defp context_value(_context, _key), do: nil

  defp metadata_value(%{metadata: metadata}, key) when is_map(metadata),
    do: Handbean.Utils.SafeMap.get(metadata, key)

  defp metadata_value(_, _), do: nil

  defp normalize_scope(scope) when scope in [:global, :workspace, :both], do: scope
  defp normalize_scope("global"), do: :global
  defp normalize_scope("workspace"), do: :workspace
  defp normalize_scope("both"), do: :both
  defp normalize_scope(_), do: nil

  defp normalize_privacy_mode(mode) when mode in [:standard, :local_only], do: mode
  defp normalize_privacy_mode("standard"), do: :standard
  defp normalize_privacy_mode("local_only"), do: :local_only
  defp normalize_privacy_mode(_), do: nil
end
