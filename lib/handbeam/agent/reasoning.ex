defmodule Handbeam.Agent.Reasoning do
  @moduledoc """
  Provider-neutral reasoning level helpers.

  Models opt in with `reasoning: true`. Optional `defaultReasoning` and
  `thinkingLevelMap` values from models.json refine the UI and provider
  request mapping.
  """

  @levels ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
  @reasoning_levels ["minimal", "low", "medium", "high", "xhigh"]
  @catalog_levels ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
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

  @doc "All Handbeam reasoning levels."
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

  `off` is always visible for reasoning-capable models, except models that
  cannot disable reasoning. `thinkingLevelMap` entries set to `nil` hide that
  level. Known model families fill in the levels their API actually accepts
  when the catalog omits the map.
  """
  @spec supported_levels(model_entry()) :: [level()]
  def supported_levels(model_entry) do
    if reasoning?(model_entry) do
      map = thinking_level_map(model_entry)
      family = family_levels(model_entry)

      levels =
        catalog_levels(model_entry)
        |> Kernel.||(@reasoning_levels)
        |> Enum.reject(&(Map.get(map, &1, :supported) == nil))
        |> Enum.filter(&(family == [] or &1 in family))

      if disableable?(model_entry), do: ["off" | levels], else: levels
    else
      []
    end
  end

  @doc """
  Levels a manually configured model can expose.

  Known families such as Grok keep their API-supported set. Other reasoning
  models expose the full Handbeam list, including off.
  """
  @spec configurable_levels(model_entry()) :: [level()]
  def configurable_levels(model_entry) do
    case family_levels(model_entry) do
      [] -> @levels
      family -> if(disableable?(model_entry), do: ["off" | family], else: family)
    end
  end

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
      default in levels and default != "off" -> default
      "low" in levels and grok_4_3?(model_entry) -> "low"
      "high" in levels and not disableable?(model_entry) -> "high"
      "medium" in levels -> "medium"
      true -> List.first(levels) || "off"
    end
  end

  @doc """
  Resolves a Handbeam level to provider effort.

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
        {:ok, Map.get(map, level, Map.fetch!(@default_map, level))}
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

  defp reasoning?(model_entry) do
    case map_get(model_entry, :reasoning, "reasoning") do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> infer_reasoning_support(model_entry)
    end
  end

  # xAI reasoning models reject requests that omit effort, and do not accept
  # "off" or "minimal". Keep the picker aligned with the API.
  defp family_levels(model_entry) do
    cond do
      grok_4_3?(model_entry) -> ["none", "low", "medium", "high", "xhigh"]
      grok_reasoning?(model_entry) -> ["low", "medium", "high", "xhigh"]
      true -> []
    end
  end

  defp disableable?(model_entry), do: not grok_reasoning?(model_entry) or grok_4_3?(model_entry)

  defp grok_4_3?(model_entry) do
    tokens = identity_tokens(model_entry)
    String.contains?(tokens, "grok-4.3") or String.contains?(tokens, "grok-4-3")
  end

  defp grok_reasoning?(model_entry) do
    tokens = identity_tokens(model_entry)

    String.contains?(tokens, "grok") and
      (String.contains?(tokens, "xai") or String.contains?(tokens, "grok-4"))
  end

  # Existing configs often omit `reasoning`. Infer for Step Router / StepFun /
  # Anthropic-compatible entries so the composer picker still appears.
  defp infer_reasoning_support(model_entry) do
    tokens = identity_tokens(model_entry)

    String.contains?(tokens, "step-router") or
      String.contains?(tokens, "stepfun") or
      String.contains?(tokens, "anthropic") or
      grok_reasoning?(model_entry)
  end

  defp identity_tokens(model_entry) do
    [
      map_get(model_entry, :id, "id"),
      map_get(model_entry, :model_id, "model_id"),
      map_get(model_entry, :name, "name"),
      map_get(model_entry, :provider_id, "provider_id"),
      map_get(model_entry, :provider, "provider"),
      map_get(model_entry, :api, "api")
    ]
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
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
    preferred =
      cond do
        grok_4_3?(model_entry) -> "low"
        grok_reasoning?(model_entry) -> "high"
        true -> "medium"
      end

    cond do
      preferred in enabled -> preferred
      true -> List.first(enabled) || "off"
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
