defmodule Handbean.Agent.Reasoning do
  @moduledoc """
  Provider-neutral reasoning level helpers.

  Models opt in with `reasoning: true`. Optional `defaultReasoning` and
  `thinkingLevelMap` values from models.json refine the UI and provider
  request mapping.
  """

  @levels ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
  @catalog_levels @levels
  @default_map %{
    "none" => "none",
    "minimal" => "low",
    "low" => "low",
    "medium" => "medium",
    "high" => "high",
    "xhigh" => "high",
    "max" => "max",
    "ultra" => "ultra"
  }

  @type level :: String.t()
  @type model_entry :: map()

  @doc "All Handbean reasoning levels."
  @spec levels() :: [level()]
  def levels, do: @levels

  @spec valid?(term()) :: boolean()
  def valid?(level), do: normalize(level) in @levels

  @spec normalize(term()) :: level()
  def normalize(level) when is_atom(level), do: level |> Atom.to_string() |> normalize()

  def normalize(level) when is_binary(level) do
    normalized = level |> String.trim() |> String.downcase()

    if normalized in @levels, do: normalized, else: "off"
  end

  def normalize(_level), do: "off"

  @doc """
  Returns visible reasoning levels for a model.

  Models expose only effort levels explicitly declared by `reasoningLevels` or
  `thinkingLevelMap`. The internal `off` value means “send no override and use
  the provider default”; a boolean `reasoning: true` alone still exposes no
  picker.
  """
  @spec supported_levels(model_entry()) :: [level()]
  def supported_levels(model_entry) do
    if reasoning?(model_entry) do
      map = thinking_level_map(model_entry)

      levels =
        model_entry
        |> catalog_levels()
        |> Kernel.||(mapped_levels(map))
        |> Enum.reject(&(Map.get(map, &1, :supported) == nil))

      maybe_prepend_provider_default(levels, map)
    else
      []
    end
  end

  @doc """
  Explicit levels a manually configured model can expose.
  """
  @spec configurable_levels(model_entry()) :: [level()]
  def configurable_levels(_model_entry), do: @levels

  @doc """
  Build the catalog fields for a manually configured reasoning model.

  `enabled_levels` selects which levels the composer may offer. An empty list
  keeps the family's defaults. Unknown levels are dropped.
  """
  @spec catalog_fields(model_entry(), [term()]) :: map()
  def catalog_fields(model_entry, enabled_levels) do
    allowed = configurable_levels(model_entry)
    enabled = normalize_enabled(enabled_levels, allowed)
    reasoning_levels = Enum.filter(enabled, &(&1 != "off"))

    fields = %{
      "reasoning" => true,
      "reasoningLevels" => enabled,
      "thinkingLevelMap" => thinking_level_map_for(reasoning_levels, allowed)
    }

    case default_for(model_entry, enabled) do
      "off" -> fields
      default -> Map.put(fields, "defaultReasoning", default)
    end
  end

  @doc "Default selected level for a model."
  @spec default_level(model_entry()) :: level()
  def default_level(model_entry) do
    levels = supported_levels(model_entry)
    default = normalize(map_get(model_entry, :default_reasoning, "defaultReasoning"))

    cond do
      levels == [] -> "off"
      default in levels -> default
      true -> "off"
    end
  end

  @doc """
  Resolves a Handbean level to provider effort.

  Returns `:off` for disabled reasoning and `{:error, :unsupported}` when the
  selected level is hidden by the model map.
  """
  @spec resolve(model_entry(), term()) :: {:ok, String.t()} | :off | {:error, :unsupported}
  def resolve(model_entry, selected_level) do
    level = normalize(selected_level)

    cond do
      level == "off" ->
        :off

      not reasoning?(model_entry) ->
        :off

      level not in supported_levels(model_entry) ->
        {:error, :unsupported}

      true ->
        map = thinking_level_map(model_entry)

        case Map.fetch(map, level) do
          {:ok, nil} -> {:error, :unsupported}
          {:ok, effort} -> {:ok, effort}
          :error -> {:ok, level}
        end
    end
  end

  @doc """
  Applies provider-specific request options for the selected reasoning level.
  """
  @spec apply_provider_options(map(), model_entry(), term()) :: map()
  def apply_provider_options(provider_config, model_entry, selected_level) do
    case resolve(model_entry, selected_level) do
      {:ok, effort} -> put_provider_effort(provider_config, effort)
      :off -> provider_config
      {:error, :unsupported} -> provider_config
    end
  end

  defp put_provider_effort(%{provider: "deepseek"} = config, effort) do
    config
    |> Map.put(:thinking, %{type: "enabled"})
    |> Map.put(:reasoning_effort, effort)
  end

  defp put_provider_effort(%{api: api} = config, effort)
       when api in [:openai_responses, :openai_codex_responses] do
    config
    |> Map.put(:reasoning, %{effort: effort})
    |> ensure_encrypted_reasoning_include()
  end

  defp put_provider_effort(%{api: :anthropic} = config, effort) do
    config
    |> Map.put(:thinking, %{type: "adaptive"})
    |> Map.put(:output_config, %{effort: effort})
  end

  defp put_provider_effort(%{api: :stepfun} = config, effort) do
    config
    |> Map.put(:thinking, %{type: "adaptive"})
    |> Map.put(:output_config, %{effort: effort})
  end

  defp put_provider_effort(config, effort) do
    Map.put(config, :reasoning_effort, effort)
  end

  # xAI and OpenAI Responses both require the encrypted item to be requested
  # before it can be replayed on the next turn. Missing it drops reasoning
  # context and is a common cause of degenerate repeated output.
  defp ensure_encrypted_reasoning_include(config) do
    include = List.wrap(Map.get(config, :include))

    if "reasoning.encrypted_content" in include do
      config
    else
      Map.put(config, :include, include ++ ["reasoning.encrypted_content"])
    end
  end

  defp maybe_prepend_provider_default([], _map), do: []

  defp maybe_prepend_provider_default(levels, map) do
    cond do
      "off" in levels -> levels
      Map.get(map, "off", :provider_default) == nil -> levels
      true -> ["off" | levels]
    end
  end

  defp reasoning?(model_entry) do
    map_get(model_entry, :reasoning, "reasoning") in [true, "true"]
  end

  defp mapped_levels(map) when is_map(map) do
    Enum.filter(@levels, fn level ->
      case Map.fetch(map, level) do
        {:ok, value} -> not is_nil(value)
        :error -> false
      end
    end)
  end

  defp normalize_enabled(levels, allowed) do
    enabled =
      levels
      |> List.wrap()
      |> Enum.map(&normalize/1)
      |> Enum.filter(&(&1 in allowed))
      |> Enum.uniq()

    case enabled do
      [] -> allowed
      selected -> Enum.filter(allowed, &(&1 in selected))
    end
  end

  defp thinking_level_map_for(enabled, allowed) do
    allowed
    |> Enum.reject(&(&1 == "off"))
    |> Map.new(fn level ->
      if level in enabled do
        {level, Map.fetch!(@default_map, level)}
      else
        {level, nil}
      end
    end)
  end

  defp default_for(model_entry, enabled) do
    configured = normalize(map_get(model_entry, :default_reasoning, "defaultReasoning"))

    cond do
      configured in enabled and configured != "off" -> configured
      "medium" in enabled -> "medium"
      true -> List.first(Enum.reject(enabled, &(&1 == "off"))) || "off"
    end
  end

  defp catalog_levels(model_entry) do
    case map_get(model_entry, :reasoning_levels, "reasoningLevels") do
      levels when is_list(levels) ->
        levels
        |> Enum.map(&normalize/1)
        |> Enum.filter(&(&1 in @catalog_levels))
        |> Enum.uniq()
        |> case do
          [] -> nil
          kept -> kept
        end

      _ ->
        nil
    end
  end

  defp thinking_level_map(model_entry) do
    case map_get(model_entry, :thinking_level_map, "thinkingLevelMap") do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp map_get(map, atom_key, string_key) when is_map(map) do
    Map.get(map, atom_key, Map.get(map, string_key))
  end

  defp map_get(_map, _atom_key, _string_key), do: nil
end
