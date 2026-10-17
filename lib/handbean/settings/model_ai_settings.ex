defmodule Handbean.Settings.ModelAISettings do
  @moduledoc """
  Model / AI settings schema — defaults, validation, serialisation.

  Stored in global `~/.handbean/settings.json` and/or workspace
  `.handbean/settings.jsonc` under the `model_ai` key.

  This module is backend configuration, not LiveView UI logic.
  """

  @fields ~w(
    default_model reasoning om_model om_reasoning
    om_memory_scope om_privacy_mode om_max_recent_context
    om_message_tokens om_buffer_tokens om_observation_tokens
  )a

  @atom_keys Map.new(@fields, &{Atom.to_string(&1), &1})

  defstruct [
    :default_model,
    reasoning: "medium",
    om_model: nil,
    om_reasoning: nil,
    om_memory_scope: "workspace",
    om_privacy_mode: "standard",
    om_max_recent_context: 5,
    om_message_tokens: 30_000,
    om_buffer_tokens: 10_000,
    om_observation_tokens: 40_000,
    # Advisor is not part of @fields. Generic diff/merge would turn a custom
    # model equal to the global value back into inherit, and has no disabled carrier.
    advisor_mode: :inherit,
    advisor_model: nil,
    advisor_reasoning: nil
  ]

  @type t :: %__MODULE__{
          default_model: String.t() | nil,
          reasoning: String.t(),
          om_model: String.t() | nil,
          om_reasoning: String.t() | nil,
          om_memory_scope: String.t(),
          om_privacy_mode: String.t(),
          om_max_recent_context: non_neg_integer(),
          om_message_tokens: pos_integer(),
          om_buffer_tokens: pos_integer(),
          om_observation_tokens: pos_integer(),
          advisor_mode: :inherit | :custom | :disabled,
          advisor_model: String.t() | nil,
          advisor_reasoning: String.t() | nil
        }

  @doc "Return the default settings struct."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc "Build full effective settings from a JSON-decoded map."
  @spec new(map()) :: t()
  def new(nil), do: defaults()

  def new(%{} = map) do
    base = defaults()
    override = normalize_override(map)

    merge_map =
      for field <- @fields, into: %{} do
        {field, Map.get(override, field, Map.get(base, field))}
      end

    struct!(__MODULE__, Map.merge(merge_map, advisor_fields(override)))
  end

  @doc "Normalize a partial settings map without filling defaults."
  @spec normalize_override(map()) :: map()
  def normalize_override(%{} = map) do
    map
    |> normalize_generic_override()
    |> Map.merge(normalize_advisor_override(map))
  end

  defp normalize_generic_override(%{} = map) do
    om_map = get_key(map, "observational_memory") || %{}

    %{}
    |> maybe_put(:default_model, raw_string(map, "default_model"))
    |> maybe_put(:reasoning, raw_string(map, "reasoning"))
    |> put_optional_string(
      :om_model,
      om_map,
      "model",
      map,
      "om_model"
    )
    |> put_optional_string(
      :om_reasoning,
      om_map,
      "reasoning",
      map,
      "om_reasoning"
    )
    |> maybe_put(
      :om_memory_scope,
      raw_string(om_map, "memory_scope") || raw_string(map, "om_memory_scope")
    )
    |> maybe_put(
      :om_privacy_mode,
      raw_string(om_map, "privacy_mode") || raw_string(map, "om_privacy_mode")
    )
    |> maybe_put(
      :om_max_recent_context,
      raw_int(om_map, "max_recent_context") || raw_int(map, "om_max_recent_context")
    )
    |> maybe_put(
      :om_message_tokens,
      raw_int(om_map, "message_tokens") || raw_int(map, "om_message_tokens")
    )
    |> maybe_put(
      :om_buffer_tokens,
      raw_int(om_map, "buffer_tokens") || raw_int(map, "om_buffer_tokens")
    )
    |> maybe_put(
      :om_observation_tokens,
      raw_int(om_map, "observation_tokens") || raw_int(map, "om_observation_tokens")
    )
  end

  @doc "Convert settings into the keyword opts expected by Coordinator.add_message/3."
  @spec to_runtime_opts(t()) :: keyword()
  def to_runtime_opts(%__MODULE__{} = settings) do
    opts = []

    opts =
      if settings.default_model, do: Keyword.put(opts, :model, settings.default_model), else: opts

    opts =
      if settings.reasoning,
        do: Keyword.put(opts, :reasoning_level, settings.reasoning),
        else: opts

    om_map = %{
      model: settings.om_model || settings.default_model,
      reasoning: settings.om_reasoning,
      memory_scope: settings.om_memory_scope,
      privacy_mode: settings.om_privacy_mode,
      max_recent_context: settings.om_max_recent_context,
      message_tokens: settings.om_message_tokens,
      buffer_tokens: settings.om_buffer_tokens,
      observation_tokens: settings.om_observation_tokens
    }

    opts = Keyword.put(opts, :om, om_map)
    Keyword.put(opts, :advisor, resolve_advisor(settings))
  end

  @doc "Drop a memory model that is no longer in the catalog."
  @spec drop_unknown_memory_model(t(), (String.t() -> boolean())) :: t()
  def drop_unknown_memory_model(%__MODULE__{} = settings, known?)
      when is_function(known?, 1) do
    model = settings.om_model

    if is_binary(model) and model != "" and not known?.(model) do
      %{settings | om_model: nil, om_reasoning: nil}
    else
      settings
    end
  end

  @doc """
  Resolve the advisor object carried by one settings layer.

  This does not apply workspace policy. Callers that need a runnable model
  re-check `ModelConfig.resolve_model_for_workspace/2`.
  """
  @spec resolve_advisor(t()) ::
          {:ok, %{model: String.t(), reasoning: String.t() | nil, source: :settings}}
          | :none
          | :disabled
          | {:error, term()}
  def resolve_advisor(%__MODULE__{advisor_mode: :disabled}), do: :disabled
  def resolve_advisor(%__MODULE__{advisor_mode: :inherit, advisor_model: nil}), do: :none

  def resolve_advisor(%__MODULE__{
        advisor_mode: :inherit,
        advisor_model: model,
        advisor_reasoning: reasoning
      })
      when is_binary(model) and model != "" do
    {:ok, %{model: model, reasoning: reasoning, source: :settings}}
  end

  def resolve_advisor(%__MODULE__{
        advisor_mode: :custom,
        advisor_model: model,
        advisor_reasoning: reasoning
      })
      when is_binary(model) and model != "" do
    if composite?(model),
      do: {:ok, %{model: model, reasoning: reasoning, source: :settings}},
      else: {:error, :bare_model_id}
  end

  def resolve_advisor(%__MODULE__{}), do: {:error, :invalid_advisor}

  @doc "Drop a workspace advisor override so the workspace inherits the global advisor."
  @spec clear_advisor(t()) :: t()
  def clear_advisor(%__MODULE__{} = settings) do
    %{settings | advisor_mode: :inherit, advisor_model: nil, advisor_reasoning: nil}
  end

  @doc "Serialise to a JSON-safe map (string keys, canonical nested OM structure)."
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = settings) do
    defaults()
    |> diff(settings)
    |> Map.put(:advisor_model, settings.advisor_model)
    |> Map.put(:advisor_reasoning, settings.advisor_reasoning)
    |> override_to_json_map()
  end

  @doc """
  Settings snapshot for one scope.

  Advisor is included even though it stays out of generic field diff.
  Global stores a model only. Workspace stores inherit by omitting the key,
  or custom / disabled explicitly.
  """
  def snapshot_model_ai(%__MODULE__{} = base, %__MODULE__{} = form, scope)
      when scope in [:global, :workspace] do
    base
    |> diff(form)
    |> override_to_json_map()
    |> put_saved_advisor(form, scope)
  end

  def put_saved_advisor(model_ai, %__MODULE__{} = form, scope) when is_map(model_ai) do
    model_ai = Map.delete(model_ai, "advisor")

    case {scope, form.advisor_mode, form.advisor_model} do
      {:global, :custom, model} when is_binary(model) and model != "" ->
        Map.put(model_ai, "advisor", advisor_json(model, form.advisor_reasoning))

      {:workspace, :custom, model} when is_binary(model) and model != "" ->
        Map.put(
          model_ai,
          "advisor",
          advisor_json(model, form.advisor_reasoning) |> Map.put("mode", "custom")
        )

      {:workspace, :disabled, _} ->
        Map.put(model_ai, "advisor", %{"mode" => "disabled"})

      _ ->
        model_ai
    end
  end

  @doc "Convert a partial override map with atom keys to JSON-safe storage shape."
  @spec override_to_json_map(map()) :: map()
  def override_to_json_map(%{} = override) do
    map = %{}

    map = put_if_present(map, override, :default_model, "default_model")
    map = put_if_present(map, override, :reasoning, "reasoning")

    om_map = %{}
    om_map = put_if_present(om_map, override, :om_model, "model")
    om_map = put_if_present(om_map, override, :om_reasoning, "reasoning")
    om_map = put_if_present(om_map, override, :om_memory_scope, "memory_scope")
    om_map = put_if_present(om_map, override, :om_privacy_mode, "privacy_mode")
    om_map = put_if_present(om_map, override, :om_max_recent_context, "max_recent_context")
    om_map = put_if_present(om_map, override, :om_message_tokens, "message_tokens")
    om_map = put_if_present(om_map, override, :om_buffer_tokens, "buffer_tokens")
    om_map = put_if_present(om_map, override, :om_observation_tokens, "observation_tokens")

    map = if map_size(om_map) > 0, do: Map.put(map, "observational_memory", om_map), else: map
    put_advisor_json(map, override)
  end

  @doc "Return atom-keyed fields in `override` that differ from `base`."
  @spec diff(t(), t()) :: map()
  def diff(%__MODULE__{} = base, %__MODULE__{} = override) do
    @fields
    |> Enum.reduce(%{}, fn field, acc ->
      base_val = Map.get(base, field)
      override_val = Map.get(override, field)

      if override_val != base_val, do: Map.put(acc, field, override_val), else: acc
    end)
  end

  @doc "Merge a base settings struct with an atom-keyed partial override map."
  @spec merge(t(), map() | t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = override),
    do: merge(base, Map.from_struct(override))

  def merge(%__MODULE__{} = base, %{} = override) do
    merge_map =
      for field <- @fields, into: %{} do
        {field, Map.get(override, field, Map.get(base, field))}
      end

    struct!(__MODULE__, Map.merge(merge_map, advisor_merge(base, override)))
  end

  @doc "Validate a map of settings changes (partial form input)."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{} = map) do
    with :ok <- validate_privacy_mode(map),
         :ok <- validate_memory_scope(map),
         :ok <- validate_max_recent_context(map),
         :ok <- validate_token_thresholds(map) do
      validate_advisor(map)
    end
  end

  def fields, do: @fields

  @doc "Advisor fields stay out of generic diff so custom-equal-to-global is not dropped."
  @spec advisor_fields(map() | t()) :: map()
  def advisor_fields(%__MODULE__{} = settings) do
    %{
      advisor_mode: settings.advisor_mode,
      advisor_model: settings.advisor_model,
      advisor_reasoning: settings.advisor_reasoning
    }
  end

  def advisor_fields(%{} = map) do
    Map.take(map, [:advisor_mode, :advisor_model, :advisor_reasoning])
  end

  defp advisor_merge(base, override) do
    mode = Map.get(override, :advisor_mode, base.advisor_mode)
    model = Map.get(override, :advisor_model, base.advisor_model)
    reasoning = Map.get(override, :advisor_reasoning, base.advisor_reasoning)

    %{
      advisor_mode: mode,
      advisor_model: if(mode == :custom, do: model, else: nil),
      advisor_reasoning: if(mode == :custom, do: reasoning, else: nil)
    }
  end

  defp normalize_advisor_override(map) do
    case get_key(map, "advisor") do
      nil ->
        %{}

      %{} = advisor ->
        mode = advisor_mode(advisor)
        model = raw_string(advisor, "model")
        reasoning = raw_string(advisor, "reasoning")

        case mode do
          :custom ->
            %{advisor_mode: :custom, advisor_model: model, advisor_reasoning: reasoning}

          :disabled ->
            %{advisor_mode: :disabled, advisor_model: nil, advisor_reasoning: nil}

          :inherit ->
            %{advisor_mode: :inherit, advisor_model: nil, advisor_reasoning: nil}

          _ ->
            %{advisor_mode: mode, advisor_model: model, advisor_reasoning: reasoning}
        end

      _ ->
        %{advisor_mode: :invalid, advisor_model: nil, advisor_reasoning: nil}
    end
  end

  defp advisor_mode(advisor) do
    case raw_string(advisor, "mode") do
      nil ->
        if(Map.has_key?(advisor, "model") or Map.has_key?(advisor, :model),
          do: :custom,
          else: :inherit
        )

      "inherit" ->
        :inherit

      "custom" ->
        :custom

      "disabled" ->
        :disabled

      _ ->
        :invalid
    end
  end

  defp put_advisor_json(json, override) do
    cond do
      Map.get(override, :advisor_mode) == :disabled ->
        Map.put(json, "advisor", %{"mode" => "disabled"})

      Map.get(override, :advisor_mode) == :custom ->
        Map.put(
          json,
          "advisor",
          advisor_json(Map.get(override, :advisor_model), Map.get(override, :advisor_reasoning))
          |> Map.put("mode", "custom")
        )

      is_binary(Map.get(override, :advisor_model)) and Map.get(override, :advisor_model) != "" ->
        Map.put(
          json,
          "advisor",
          advisor_json(Map.get(override, :advisor_model), Map.get(override, :advisor_reasoning))
        )

      true ->
        json
    end
  end

  defp composite?(model) do
    case String.split(model, "/", parts: 2) do
      [provider, id] when provider != "" and id != "" -> true
      _ -> false
    end
  end

  defp advisor_json(model, reasoning) do
    %{"model" => model}
    |> then(fn json ->
      if is_binary(reasoning) and reasoning != "",
        do: Map.put(json, "reasoning", reasoning),
        else: json
    end)
  end

  defp validate_advisor(map) do
    case get_key(map, "advisor") || get_key(map, "advisor_mode") do
      nil ->
        :ok

      mode when mode in [:inherit, :custom, :disabled, "inherit", "custom", "disabled"] ->
        :ok

      %{} = advisor ->
        case advisor_mode(advisor) do
          :invalid ->
            {:error, "advisor mode must be inherit, custom, or disabled"}

          :custom ->
            if(composite?(raw_string(advisor, "model") || ""),
              do: :ok,
              else: {:error, "advisor custom model must be a composite provider/model id"}
            )

          _ ->
            :ok
        end

      _ ->
        {:error, "advisor mode must be inherit, custom, or disabled"}
    end
  end

  # ── Private helpers ──

  defp get_key(map, key) do
    case fetch_key(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_key(map, key) do
    atom_key = Map.get(@atom_keys, key)

    cond do
      Map.has_key?(map, key) -> Map.fetch(map, key)
      atom_key && Map.has_key?(map, atom_key) -> Map.fetch(map, atom_key)
      true -> :error
    end
  end

  defp raw_string(map, key) do
    case get_key(map, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp raw_int(map, key) do
    case get_key(map, key) do
      v when is_integer(v) -> v
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_optional_string(map, field, primary, primary_key, fallback, fallback_key) do
    case fetch_key(primary, primary_key) do
      {:ok, value} ->
        put_optional_string_value(map, field, value)

      :error ->
        case fetch_key(fallback, fallback_key) do
          {:ok, value} -> put_optional_string_value(map, field, value)
          :error -> map
        end
    end
  end

  defp put_optional_string_value(map, field, value)
       when is_binary(value) and value != "",
       do: Map.put(map, field, value)

  defp put_optional_string_value(map, field, value) when value in [nil, ""],
    do: Map.put(map, field, nil)

  defp put_optional_string_value(map, _field, _value), do: map

  defp put_if_present(json, override, atom_key, json_key) do
    if Map.has_key?(override, atom_key),
      do: Map.put(json, json_key, Map.get(override, atom_key)),
      else: json
  end

  defp validate_privacy_mode(map) do
    val = get_key(map, "om_privacy_mode") || nested_om_value(map, "privacy_mode")

    if is_nil(val) || val in ~w(standard local_only),
      do: :ok,
      else: {:error, "om_privacy_mode must be 'standard' or 'local_only'"}
  end

  defp validate_memory_scope(map) do
    val = get_key(map, "om_memory_scope") || nested_om_value(map, "memory_scope")

    if is_nil(val) || val in ~w(workspace global both),
      do: :ok,
      else: {:error, "om_memory_scope must be 'workspace', 'global', or 'both'"}
  end

  defp validate_max_recent_context(map) do
    val = get_key(map, "om_max_recent_context") || nested_om_value(map, "max_recent_context")

    if is_nil(val) || (is_integer(val) && val >= 0),
      do: :ok,
      else: {:error, "om_max_recent_context must be >= 0"}
  end

  defp validate_token_thresholds(map) do
    for {flat_key, nested_key, label} <- [
          {"om_message_tokens", "message_tokens", "om_message_tokens"},
          {"om_buffer_tokens", "buffer_tokens", "om_buffer_tokens"},
          {"om_observation_tokens", "observation_tokens", "om_observation_tokens"}
        ] do
      val = get_key(map, flat_key) || nested_om_value(map, nested_key)

      if not is_nil(val) and (not is_integer(val) || val <= 0),
        do: throw({:error, "#{label} must be > 0"})
    end

    :ok
  catch
    {:error, reason} -> {:error, reason}
  end

  defp nested_om_value(map, key) do
    case get_key(map, "observational_memory") do
      %{} = om -> Handbean.Utils.SafeMap.get(om, key)
      _ -> nil
    end
  end
end
