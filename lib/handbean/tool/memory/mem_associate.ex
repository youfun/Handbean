defmodule Handbean.Tool.Memory.MemAssociate do
  @moduledoc """
  Memory associate tool — links two engrams with a synapse.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "mem_associate"

  @impl true
  def description do
    "Associate two memories together. " <>
      "Use to link related facts, patterns, or preferences."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        source_id: %{type: "integer", description: "ID of the source engram"},
        target_id: %{type: "integer", description: "ID of the target engram"},
        kind: %{
          type: "string",
          description: "Relationship: related, contradicts, example_of, context_for, reinforces"
        }
      },
      required: ["source_id", "target_id", "kind"]
    }
  end

  @impl true
  def max_result_chars, do: 500

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"source_id" => source_id, "target_id" => target_id, "kind" => kind_str}, context) do
    with {:ok, kind} <- parse_kind(kind_str),
         {:ok, source} <- fetch_engram(source_id),
         {:ok, target} <- fetch_engram(target_id),
         :ok <- ensure_accessible(source, context),
         :ok <- ensure_accessible(target, context) do
      case Handbean.Memory.MemoryStore.associate(source, target, kind) do
        {:ok, _synapse} ->
          {:ok, "Associated engram #{source_id} #{kind} #{target_id}"}

        {:error, _} ->
          {:ok, "Association already exists or failed."}
      end
    else
      {:error, :invalid_kind} ->
        {:error, "Invalid kind. Use: related, contradicts, example_of, context_for, reinforces"}

      {:error, :not_found} ->
        {:error, "One or both engrams not found"}

      {:error, :not_accessible} ->
        {:error, "One or both engrams are not accessible from this memory scope"}
    end
  end

  def execute(_input, _context), do: {:error, "source_id, target_id, and kind are required"}

  defp parse_kind(kind_str) when is_binary(kind_str) do
    kind = String.to_existing_atom(kind_str)

    if kind in [:related, :contradicts, :example_of, :context_for, :reinforces] do
      {:ok, kind}
    else
      {:error, :invalid_kind}
    end
  rescue
    ArgumentError -> {:error, :invalid_kind}
  end

  defp parse_kind(_kind_str), do: {:error, :invalid_kind}

  defp fetch_engram(id) do
    case Handbean.Repo.get(Handbean.Memory.Engram, id) do
      nil -> {:error, :not_found}
      engram -> {:ok, engram}
    end
  end

  defp ensure_accessible(engram, context) do
    if accessible?(engram, context), do: :ok, else: {:error, :not_accessible}
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
