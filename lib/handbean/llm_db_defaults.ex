defmodule Handbean.LlmDbDefaults do
  @moduledoc """
  Adapter layer for pulling provider and model defaults from `llm_db`.

  The settings UI uses this to prefill metadata. Provider fields match a
  catalog provider id, display name, or base URL. Model fields match a model id.
  """

  alias Handbean.Agent.{BuiltinModels, ModelCapabilities}

  @type provider_defaults :: %{
          optional(:provider_name) => String.t(),
          optional(:base_url) => String.t(),
          optional(:api) => String.t(),
          optional(:provider_runtime) => String.t()
        }

  @type model_defaults :: %{
          optional(:model_name) => String.t(),
          optional(:context_window) => integer(),
          optional(:max_tokens) => integer(),
          optional(:price_input) => number(),
          optional(:price_output) => number(),
          optional(:price_cache_read) => number(),
          optional(:price_cache_write) => number(),
          optional(:price_reasoning) => number()
        }

  @spec defaults_for(String.t() | nil, String.t() | nil) :: %{
          provider: provider_defaults(),
          model: model_defaults()
        }
  def defaults_for(provider_id, model_id) do
    defaults_for(provider_id, nil, nil, model_id)
  end

  @doc """
  Prefill from a catalog provider matched by id, display name, or base URL.

  Name and URL are only used when the typed id is blank or is not itself a
  catalog id, so an explicit id still wins.
  """
  @spec defaults_for(String.t() | nil, String.t() | nil, String.t() | nil, String.t() | nil) :: %{
          provider: provider_defaults(),
          model: model_defaults(),
          provider_id: String.t() | nil
        }
  def defaults_for(provider_id, name, base_url, model_id) do
    with :ok <- ensure_loaded() do
      resolved = resolve_provider(provider_id, name, base_url)
      catalog_id = if(resolved, do: Atom.to_string(resolved.id))

      %{
        provider: provider_defaults_from(resolved),
        model: model_defaults(catalog_id, model_id),
        provider_id: catalog_id
      }
    else
      _ -> %{provider: %{}, model: %{}, provider_id: nil}
    end
  end

  @spec provider_defaults(String.t() | nil) :: provider_defaults()
  def provider_defaults(provider_id) do
    with {:ok, provider_atom} <- normalize_provider(provider_id),
         {:ok, provider} <- LLMDB.provider(provider_atom) do
      provider_defaults_from(provider)
    else
      _ -> %{}
    end
  end

  defp provider_defaults_from(nil), do: %{}

  defp provider_defaults_from(provider) do
    %{}
    |> maybe_put(:provider_name, provider.name)
    |> maybe_put(:base_url, provider_base_url(provider))
    |> maybe_put(:api, api_type_for(provider.id))
    |> maybe_put(:provider_runtime, runtime_provider_for(provider.id))
  end

  # Exact id first. A typed id that is already in the catalog is never
  # replaced by a name or URL that points somewhere else.
  defp resolve_provider(provider_id, name, base_url) do
    providers = LLMDB.providers()

    find_provider_by_id(providers, provider_id) ||
      find_provider_by_name(providers, name) ||
      find_provider_by_url(providers, base_url)
  end

  defp find_provider_by_id(_providers, id) when not is_binary(id), do: nil

  defp find_provider_by_id(providers, id) do
    needle = String.trim(id)
    if needle == "", do: nil, else: Enum.find(providers, &(Atom.to_string(&1.id) == needle))
  end

  defp find_provider_by_name(_providers, name) when not is_binary(name), do: nil

  defp find_provider_by_name(providers, name) do
    needle = normalize_label(name)
    if needle == "", do: nil, else: Enum.find(providers, &(normalize_label(&1.name) == needle))
  end

  defp find_provider_by_url(_providers, url) when not is_binary(url), do: nil

  defp find_provider_by_url(providers, url) do
    needle = normalize_url(url)

    if needle == "" do
      nil
    else
      Enum.find(providers, fn provider -> normalize_url(provider_base_url(provider)) == needle end)
    end
  end

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp normalize_label(_value), do: ""

  defp normalize_url(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp normalize_url(_value), do: ""

  @spec model_defaults(String.t() | nil, String.t() | nil) :: model_defaults()
  def model_defaults(provider_id, model_id) do
    with {:ok, provider_atom} <- normalize_provider(provider_id),
         {:ok, model_id} <- normalize_model_id(model_id),
         {:ok, model} <- LLMDB.model(provider_atom, model_id) do
      model_defaults_from(model)
    else
      _ -> %{}
    end
  end

  @doc """
  Form defaults for a model id, independent of the local provider id.

  The catalog is searched by model id and alias. A miss returns an empty map
  so the form keeps what the user typed.
  """
  @spec model_form_defaults(String.t() | nil) :: model_defaults()
  def model_form_defaults(model_id) do
    with :ok <- ensure_loaded(),
         {:ok, model_id} <- normalize_model_id(model_id),
         %{} = model <- find_catalog_model(catalog_index(), model_id) do
      model_defaults_from(model)
    else
      _ -> %{}
    end
  end

  @doc """
  Catalog fields for a discovered model id.

  Gateway ids are `provider/model`. The prefix is tried as an llm_db provider,
  then the bare id is tried across the loaded catalog. A miss returns only the
  id and display name so discovery can still save the row.
  """
  @spec enrich_model(String.t(), String.t() | nil, (-> :ok | {:error, term()})) :: map()
  def enrich_model(model_id, name \\ nil, load \\ &ensure_loaded/0)

  def enrich_model(model_id, name, load) when is_binary(model_id) and is_function(load, 0) do
    enrich_models([{model_id, name}], load) |> Map.fetch!(model_id)
  end

  @doc """
  Enrich many discovered model ids from one catalog load.

  `enrich_model/3` reloads and scans the catalog per id. A provider list of a
  few dozen models then spends about a second per row, so discovery looks stuck.
  """
  @spec enrich_models([{String.t(), String.t() | nil}], (-> :ok | {:error, term()})) :: %{
          optional(String.t()) => map()
        }
  def enrich_models(entries, load \\ &ensure_loaded/0) when is_list(entries) do
    index = catalog_index(load)

    Map.new(entries, fn {model_id, name} ->
      {model_id, enriched_model(index, model_id, name)}
    end)
  end

  defp enriched_model(_index, model_id, name) when not is_binary(model_id) do
    %{"id" => model_id, "name" => present_name(name, to_string(model_id)), "input" => ["text"]}
  end

  defp enriched_model(index, model_id, name) do
    builtin_fields = model_id |> BuiltinModels.find() |> catalog_fields()
    catalog_fields = index |> find_catalog_model(model_id) |> catalog_fields()

    model =
      %{"id" => model_id, "input" => ["text"]}
      |> Map.merge(builtin_fields)
      |> Map.merge(catalog_fields)

    Map.put(model, "name", present_name(name, model["name"] || model_id))
  end

  # Built once per discovery. LLMDB.models/0 walks every provider, and calling
  # it once per remote id is what made "拉取模型" take tens of seconds.
  defp catalog_index(load \\ &ensure_loaded/0) do
    try do
      case load.() do
        :ok ->
          LLMDB.models()
          |> Enum.reduce(%{}, fn model, index ->
            index
            |> Map.put_new(model.id, model)
            |> put_aliases(model)
          end)

        _ ->
          %{}
      end
    rescue
      # Android flattens Hex apps onto the code path. llm_db then raises
      # `unknown application` from Application.app_dir/1 while loading its
      # snapshot. Discovery must still keep the remote id.
      ArgumentError ->
        %{}
    end
  end

  defp put_aliases(index, model) do
    Enum.reduce(model.aliases || [], index, fn alias_id, index ->
      if is_binary(alias_id) and alias_id != "",
        do: Map.put_new(index, alias_id, model),
        else: index
    end)
  end

  defp find_catalog_model(index, model_id) when is_map(index) do
    {provider_hint, bare_id} = split_gateway_id(model_id)

    cond do
      model = Map.get(index, model_id) -> model
      model = hinted_model(index, provider_hint, bare_id) -> model
      true -> Map.get(index, bare_id)
    end
  end

  defp hinted_model(_index, nil, _bare_id), do: nil

  defp hinted_model(index, provider_hint, bare_id) do
    index
    |> Map.values()
    |> Enum.find(fn model ->
      Atom.to_string(model.provider) == provider_hint and
        (model.id == bare_id or bare_id in (model.aliases || []))
    end)
  end

  defp catalog_fields(nil), do: %{}

  defp catalog_fields(%LLMDB.Model{} = model) do
    limits = model.limits || %{}
    reasoning = reasoning_fields(model.capabilities && model.capabilities.reasoning)

    %{}
    |> maybe_put("name", model.name)
    |> maybe_put("input", input_modalities(model.modalities))
    |> maybe_put("contextWindow", Map.get(limits, :context))
    |> maybe_put("maxTokens", Map.get(limits, :output))
    |> maybe_put_cost(model)
    |> Map.merge(reasoning)
  end

  defp catalog_fields(%{} = model) do
    Map.take(model, [
      "name",
      "input",
      "reasoning",
      "contextWindow",
      "maxTokens",
      "cost",
      "reasoningLevels",
      "defaultReasoning"
    ])
  end

  defp catalog_fields(_model), do: %{}

  defp input_modalities(%{input: modalities}) when is_list(modalities) do
    modalities
    |> Enum.flat_map(fn
      modality when is_atom(modality) -> [Atom.to_string(modality)]
      modality when is_binary(modality) -> [modality]
      _ -> []
    end)
    |> Enum.filter(&(&1 in ModelCapabilities.supported_input_types()))
    |> Enum.uniq()
  end

  defp input_modalities(_modalities), do: nil

  defp reasoning_fields(%{enabled: true} = reasoning) do
    effort = Map.get(reasoning, :effort) || %{}

    %{}
    |> Map.put("reasoning", true)
    |> maybe_put("reasoningLevels", present_list(Map.get(effort, :values)))
    |> maybe_put("defaultReasoning", Map.get(effort, :default))
  end

  defp reasoning_fields(_reasoning), do: %{}

  defp maybe_put_cost(fields, model) do
    case catalog_cost(model) do
      nil -> fields
      cost -> Map.put(fields, "cost", cost)
    end
  end

  defp split_gateway_id(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [provider, id] when provider != "" and id != "" -> {provider, id}
      _ -> {nil, model_id}
    end
  end

  defp present_name(name, fallback) when is_binary(name) do
    case String.trim(name) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp present_name(_name, fallback), do: fallback

  defp present_list(values) when is_list(values) do
    case Enum.filter(values, &(is_binary(&1) and &1 != "")) do
      [] -> nil
      levels -> levels
    end
  end

  defp present_list(_values), do: nil

  @doc """
  Official upstream price for a model id.

  Cursor is not an llm_db provider. Its catalog ids are upstream models plus
  effort suffixes (`gpt-5.3-codex-low-fast`, `claude-opus-4-6`). Strip the
  suffix and read the vendor catalog (OpenAI / Anthropic), not a reseller:
  reseller prices disagree. Missing prices stay absent — never invent 0.
  """
  @spec price_for_model_id(String.t() | nil) :: map() | nil
  def price_for_model_id(model_id) do
    with :ok <- ensure_loaded(),
         {:ok, model_id} <- normalize_model_id(model_id),
         cost when is_map(cost) <- lookup_cost(model_id) do
      cost
    else
      _ -> nil
    end
  end

  @doc """
  Prices for many model ids from one catalog load.

  `price_for_model_id/1` loads the catalog on every call. Settings renders a
  row per model, and that load takes a cluster-wide lock, so calling it once
  per unpriced model stalls the LiveView until the page looks blank.
  """
  @spec prices_for_model_ids([String.t()]) :: %{optional(String.t()) => map()}
  def prices_for_model_ids(model_ids) when is_list(model_ids) do
    with :ok <- ensure_loaded() do
      Map.new(model_ids, fn model_id ->
        cost =
          case normalize_model_id(model_id) do
            {:ok, id} -> lookup_cost(id)
            _ -> nil
          end

        {model_id, cost}
      end)
    else
      _ -> %{}
    end
  end

  defp model_defaults_from(model) do
    cost = Map.get(model, :cost) || %{}
    limits = Map.get(model, :limits) || %{}

    %{}
    |> maybe_put(:model_name, Map.get(model, :name))
    |> maybe_put(:context_window, Map.get(limits, :context))
    |> maybe_put(:max_tokens, Map.get(limits, :output))
    |> maybe_put(:price_input, numeric_cost(cost, :input))
    |> maybe_put(:price_output, numeric_cost(cost, :output))
    |> maybe_put(:price_cache_read, numeric_cost(cost, :cache_read))
    |> maybe_put(:price_cache_write, numeric_cost(cost, :cache_write))
    |> maybe_put(:price_reasoning, numeric_cost(cost, :reasoning))
  end

  @effort_suffixes ["-xhigh", "-high", "-medium", "-low", "-fast", "-thinking"]
  @openai_prefixes ["gpt-", "o1", "o3", "o4", "chatgpt-"]
  @anthropic_prefixes ["claude-"]

  defp lookup_cost(model_id) do
    case vendor_cost(model_id) do
      %{} = cost ->
        cost

      nil ->
        case strip_effort(model_id) do
          ^model_id -> nil
          base -> vendor_cost(base)
        end
    end
  end

  defp vendor_cost(model_id) do
    model_id
    |> vendor_provider()
    |> case do
      nil ->
        nil

      provider ->
        case LLMDB.model(provider, vendor_model_id(provider, model_id)) do
          {:ok, model} -> catalog_cost(model)
          _ -> nil
        end
    end
  end

  defp vendor_model_id(:anthropic, model_id), do: String.replace(model_id, ".", "-")
  defp vendor_model_id(_provider, model_id), do: model_id

  defp vendor_provider(model_id) do
    cond do
      String.starts_with?(model_id, @openai_prefixes) -> :openai
      String.starts_with?(model_id, @anthropic_prefixes) -> :anthropic
      true -> nil
    end
  end

  defp catalog_cost(model) do
    cost = Map.get(model, :cost) || %{}

    %{}
    |> maybe_put("input", numeric_cost(cost, :input))
    |> maybe_put("output", numeric_cost(cost, :output))
    |> maybe_put("cache_read", numeric_cost(cost, :cache_read))
    |> maybe_put("cache_write", numeric_cost(cost, :cache_write))
    |> maybe_put("reasoning", numeric_cost(cost, :reasoning))
    |> case do
      cost when map_size(cost) == 0 -> nil
      cost -> cost
    end
  end

  defp strip_effort(model_id) do
    Enum.reduce(@effort_suffixes, model_id, fn suffix, id ->
      String.replace(id, suffix, "")
    end)
  end

  defp ensure_loaded do
    case Code.ensure_loaded(LLMDB) do
      {:module, LLMDB} ->
        case LLMDB.load() do
          {:ok, _snapshot} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :llm_db_unavailable}
    end
  end

  defp normalize_provider(provider_id) when is_binary(provider_id) do
    case String.trim(provider_id) do
      "" ->
        {:error, :blank_provider}

      value ->
        LLMDB.providers()
        |> Enum.find(fn provider -> Atom.to_string(provider.id) == value end)
        |> case do
          nil -> {:error, :unknown_provider}
          provider -> {:ok, provider.id}
        end
    end
  end

  defp normalize_provider(_), do: {:error, :invalid_provider}

  defp normalize_model_id(model_id) when is_binary(model_id) do
    model_id
    |> String.trim()
    |> case do
      "" -> {:error, :blank_model}
      value -> {:ok, value}
    end
  end

  defp normalize_model_id(_), do: {:error, :invalid_model}

  defp provider_base_url(%{runtime: %{base_url: base_url}})
       when is_binary(base_url) and base_url != "",
       do: base_url

  defp provider_base_url(%{base_url: base_url}) when is_binary(base_url) and base_url != "",
    do: base_url

  defp provider_base_url(%{id: :stepfun}), do: "https://api.stepfun.com/step_plan/v1"
  defp provider_base_url(_provider), do: nil

  defp api_type_for(:openai), do: "openai"
  defp api_type_for(:anthropic), do: "anthropic-messages"
  defp api_type_for(:stepfun), do: "stepfun-step-plan"
  defp api_type_for(:ollama_cloud), do: "ollama-cloud"
  defp api_type_for(:opencode_go), do: "opencode-go"
  defp api_type_for(_provider), do: "openai-compatible"

  defp runtime_provider_for(:openai), do: "openai"
  defp runtime_provider_for(:anthropic), do: "anthropic"
  defp runtime_provider_for(:stepfun), do: "stepfun"
  defp runtime_provider_for(:zenmux), do: "zenmux"
  defp runtime_provider_for(:openrouter), do: "openrouter"
  defp runtime_provider_for(:deepseek), do: "deepseek"
  defp runtime_provider_for(:ollama_cloud), do: "ollama"
  defp runtime_provider_for(:opencode_go), do: "opencode-go"
  defp runtime_provider_for(_provider), do: "openai-compat"

  defp numeric_cost(cost, key) do
    case Map.get(cost, key) do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
