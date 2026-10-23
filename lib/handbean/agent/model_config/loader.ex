defmodule Handbean.Agent.ModelConfig.Loader do
  @moduledoc false

  alias Handbean.Agent.Auth.{CodexCredential, CursorCredential, XaiCredential}

  require Logger

  @default_base_url "https://api.stepfun.com/step_plan/v1"
  @default_model "step-5-preview"
  @config_filenames ["models.json"]
  @global_config_path "~/.handbean/models.json"
  @config_path_env "HANDBEAN_MODELS_FILE"

  @typedoc """
  Result of loading model configuration.
  """
  @type config_map :: %{
          required(:base_url) => String.t(),
          required(:model) => String.t(),
          required(:api) => atom(),
          optional(:api_key) => String.t() | nil,
          optional(:max_tokens) => pos_integer(),
          optional(:temperature) => float(),
          optional(:provider_key) => String.t(),
          optional(:model_meta) => map(),
          optional(:auth_type) => :api_key | :oauth
        }
  @doc """
  Load provider config.

  Returns a map with keys `:base_url`, `:model` and optionally `:api_key`,
  `:max_tokens`, `:temperature`.

  Lookup order:

    1. `HANDBEAN_MODELS_FILE` if set
    2. `~/.handbean/models.json`
      3. Handbean built-in defaults (StepFun Step Plan v1)

  Non-secret environment variables may override file values for runtime testing,
  but API keys come from `models.json` only.
  """
  @spec provider_config(Path.t()) :: config_map()
  def provider_config(working_directory \\ File.cwd!()) do
    file_config = load_file_config(working_directory)

    %{
      base_url: resolve_base_url(file_config),
      api: Map.get(file_config, :api, :openai),
      api_key: resolve_api_key(file_config),
      model: resolve_model(file_config),
      max_tokens: resolve_max_tokens(file_config),
      temperature: resolve_temperature(file_config),
      provider_key: file_config[:provider_key],
      provider: file_config[:provider],
      model_meta: Map.get(file_config, :model_meta, %{}),
      use_previous_response_id: file_config[:use_previous_response_id],
      previous_response_id: file_config[:previous_response_id],
      store: file_config[:store],
      include: file_config[:include],
      receive_timeout: file_config[:receive_timeout],
      connect_timeout: file_config[:connect_timeout],
      max_retries: file_config[:max_retries],
      retry_delay_base_ms: file_config[:retry_delay_base_ms],
      tool_choice: file_config[:tool_choice],
      parallel_tool_calls: file_config[:parallel_tool_calls],
      built_in_tools: file_config[:built_in_tools],
      req_options: build_req_options(file_config),
      web_search: file_config[:web_search],
      x_search: file_config[:x_search],
      auth_type: Map.get(file_config, :auth_type, :api_key)
    }
    |> maybe_resolve_oauth_api_key(file_config[:provider_key])
    |> drop_oauth_error()
    |> drop_nils()
  end

  defp drop_oauth_error(%{oauth_error: _} = config), do: Map.delete(config, :oauth_error)
  defp drop_oauth_error(config), do: config

  @doc """
  List available models from the configuration.

  Returns a list of maps, each with at least `:id` and `:name` keys.
  """
  @spec available_models(Path.t()) :: [map()]
  def available_models(working_directory \\ File.cwd!()) do
    file_config = load_file_config(working_directory)
    Map.get(file_config, :available_models, [])
  end

  # ──────────────────────────────────────────────────────────────
  # Internal: load and parse model config files
  # ──────────────────────────────────────────────────────────────

  defp load_file_config(working_directory) do
    working_directory
    |> config_paths()
    |> Enum.find_value(&read_config_path/1)
    |> Kernel.||(defaults())
  end

  defp config_paths(working_directory) do
    case System.get_env(@config_path_env) do
      path when is_binary(path) and path != "" ->
        [Handbean.Home.expand(path)]

      _ ->
        _ = working_directory
        [Handbean.Home.expand(@global_config_path)]
    end
  end

  defp read_config_path(path) do
    case File.read(path) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, json} ->
            parse_json_config(json)

          {:error, reason} ->
            Logger.warning("[ModelConfig] Failed to parse #{path}: #{inspect(reason)}")
            nil
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("[ModelConfig] Failed to read #{path}: #{inspect(reason)}")
        nil
    end
  end

  # ──────────────────────────────────────────────────────────────
  # JSON → internal map
  # ──────────────────────────────────────────────────────────────

  defp parse_json_config(json) do
    default_provider_key = resolve_default_provider_key(json)
    provider_config = get_provider(json, default_provider_key)

    provider = Map.get(provider_config, "provider")
    base_url = Map.get(provider_config, "baseUrl") || default_base_url_for_provider(provider)
    api = Map.get(provider_config, "api")
    normalized_url = normalize_base_url(base_url, api)

    provider_models = enabled_models(Map.get(provider_config, "models", []))
    default_model = resolve_default_model(json, default_provider_key, provider_models)

    model_meta = find_model_meta(provider_models, default_model)

    %{
      base_url: normalized_url,
      api: api_to_atom(api),
      api_key: resolve_json_api_key(provider_config),
      model: default_model,
      provider_key: default_provider_key,
      model_meta: model_meta,
      max_tokens: Map.get(provider_config, "maxTokens"),
      temperature: Map.get(provider_config, "temperature"),
      available_models: Enum.map(provider_models, &model_summary/1),
      provider: provider,
      auth_type: auth_type_from_provider(provider_config)
    }
    |> merge_provider_options(provider_config, model_meta)
  end

  # ──────────────────────────────────────────────────────────────
  # Resolution helpers (JSON layer)
  # ──────────────────────────────────────────────────────────────

  defp resolve_default_provider_key(json) do
    case Map.get(json, "defaultProvider") do
      nil ->
        providers = Map.get(json, "providers", %{})
        keys = Map.keys(providers)
        List.first(keys)

      key when is_binary(key) ->
        key
    end
  end

  defp get_provider(json, provider_key) do
    providers = Map.get(json, "providers", %{})

    case Map.get(providers, provider_key) do
      nil ->
        providers |> Map.values() |> List.first() || %{}

      config when is_map(config) ->
        config
    end
  end

  defp resolve_default_model(json, _provider_key, provider_models) do
    case Map.get(json, "defaultModel") do
      nil ->
        provider_models
        |> Enum.map(&Map.get(&1, "id"))
        |> List.first()

      model when is_binary(model) ->
        model
    end
  end

  defp resolve_json_api_key(provider_config) do
    case Map.get(provider_config, "apiKey") do
      "env:" <> var_name ->
        System.get_env(var_name)

      key when is_binary(key) ->
        key

      nil ->
        nil
    end
  end

  defp find_model_meta(provider_models, model_id) do
    Enum.find(provider_models, fn m -> Map.get(m, "id") == model_id end) || %{}
  end

  # Missing `enabled` stays on so existing catalogs keep working.
  defp model_enabled?(%{"enabled" => false}), do: false
  defp model_enabled?(_model), do: true

  @doc false
  def enabled_models(models) when is_list(models), do: Enum.filter(models, &model_enabled?/1)
  def enabled_models(_), do: []

  defp model_summary(model) do
    %{
      id: Map.get(model, "id"),
      name: Map.get(model, "name"),
      input: Map.get(model, "input", []),
      reasoning: Map.get(model, "reasoning"),
      reasoning_levels: Map.get(model, "reasoningLevels", []),
      default_reasoning: Map.get(model, "defaultReasoning"),
      thinking_level_map: Map.get(model, "thinkingLevelMap", %{}),
      context_window: Map.get(model, "contextWindow"),
      max_tokens: Map.get(model, "maxTokens"),
      cost: Map.get(model, "cost", %{})
    }
  end

  # ──────────────────────────────────────────────────────────────
  # Normalize base URL
  # ──────────────────────────────────────────────────────────────

  @doc """
  Normalize a provider base URL for use by OpenAI-compatible clients.

  ## Rules in priority order

  1. If `base_url` is `nil`, returns the StepFun default.
  2. If `api` is `"anthropic-messages"`, returns `base_url` as-is (provider adds its own
     path, e.g. `/v1/messages`).
  3. Otherwise returns `base_url` as-is.
  """
  @spec normalize_base_url(String.t() | nil, String.t() | nil) :: String.t()
  def normalize_base_url(nil, _api), do: @default_base_url

  def normalize_base_url(base_url, nil), do: base_url

  def normalize_base_url(base_url, "anthropic-messages"), do: base_url

  def normalize_base_url(base_url, api) when api in ["openai", "openai-responses"] do
    base_url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1/responses", "")
    |> String.replace_suffix("/v1", "")
  end

  def normalize_base_url(base_url, _api), do: base_url

  defp default_base_url_for_provider("zenmux"), do: "https://zenmux.ai/api/v1"
  defp default_base_url_for_provider("openrouter"), do: "https://openrouter.ai/api/v1"
  defp default_base_url_for_provider("deepseek"), do: "https://api.deepseek.com"
  defp default_base_url_for_provider("ollama"), do: "https://ollama.com/v1"
  defp default_base_url_for_provider("opencode-go"), do: "https://opencode.ai/zen/go/v1"
  defp default_base_url_for_provider("xai"), do: "https://api.x.ai/v1"
  defp default_base_url_for_provider("cursor"), do: "https://api2.cursor.sh"
  defp default_base_url_for_provider(_provider), do: nil

  defp assemble_provider_config(
         provider_id,
         provider_config,
         model_id,
         normalized_url,
         api,
         provider,
         model_meta
       ) do
    config =
      %{
        base_url: normalized_url,
        api: api_to_atom(api),
        api_key: resolve_json_api_key(provider_config),
        provider: provider,
        provider_key: provider_id,
        model: model_id,
        model_meta: model_meta,
        max_tokens: Map.get(provider_config, "maxTokens", Map.get(model_meta, "maxTokens")),
        temperature: Map.get(provider_config, "temperature"),
        auth_type: auth_type_from_provider(provider_config)
      }
      |> merge_provider_options(provider_config, model_meta)

    case maybe_resolve_oauth_api_key(config, provider_id) do
      %{oauth_error: message} -> {:error, message}
      resolved -> {:ok, drop_nils(resolved)}
    end
  end

  defp auth_type_from_provider(%{"authType" => "oauth"}), do: :oauth
  defp auth_type_from_provider(_), do: :api_key

  defp maybe_resolve_oauth_api_key(%{auth_type: :oauth} = config, provider_id)
       when is_binary(provider_id) do
    case resolve_oauth_credential(provider_id) do
      {:ok, %{api_key: api_key} = auth} ->
        config
        |> Map.merge(Map.take(auth, [:api_key, :auth_generation, :account_id]))
        |> Map.put(:api_key, api_key)
        |> maybe_put_auth_generation(provider_id, auth)

      {:error, message} ->
        config |> Map.delete(:api_key) |> Map.put(:oauth_error, message)
    end
  end

  defp maybe_resolve_oauth_api_key(config, _provider_id), do: config

  defp resolve_oauth_credential("cursor"), do: CursorCredential.resolve_transport_key("cursor")

  defp resolve_oauth_credential("openai_codex"),
    do: CodexCredential.resolve_transport_key("openai_codex")

  defp resolve_oauth_credential(provider_id), do: XaiCredential.resolve_transport_key(provider_id)

  defp maybe_put_auth_generation(config, "cursor", %{auth_generation: generation})
       when is_integer(generation) do
    Map.put(config, :auth_generation, generation)
  end

  defp maybe_put_auth_generation(config, _provider_id, _auth), do: config

  # ──────────────────────────────────────────────────────────────
  # Env override layer
  # ──────────────────────────────────────────────────────────────

  defp resolve_base_url(file_config) do
    base_url =
      System.get_env("OPENAI_BASE_URL") || Map.get(file_config, :base_url, @default_base_url)

    api = Map.get(file_config, :api, :openai)

    normalize_runtime_base_url(base_url, api)
  end

  defp normalize_runtime_base_url(base_url, :anthropic),
    do: strip_anthropic_messages_suffix(base_url)

  defp normalize_runtime_base_url(base_url, "anthropic-messages"),
    do: strip_anthropic_messages_suffix(base_url)

  defp normalize_runtime_base_url(base_url, _api), do: base_url

  defp strip_anthropic_messages_suffix(base_url) when is_binary(base_url) do
    base_url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/v1/messages", "")
    |> String.replace_suffix("/v1", "")
  end

  defp resolve_model(file_config) do
    System.get_env("OPENAI_MODEL") || Map.get(file_config, :model, @default_model)
  end

  defp resolve_api_key(file_config) do
    Map.get(file_config, :api_key)
  end

  defp resolve_max_tokens(file_config) do
    case System.get_env("OPENAI_MAX_TOKENS") do
      nil ->
        Map.get(file_config, :max_tokens)

      val when is_binary(val) ->
        case Integer.parse(val) do
          {int, _} -> int
          :error -> nil
        end
    end
  end

  defp resolve_temperature(file_config) do
    case System.get_env("OPENAI_TEMPERATURE") do
      nil ->
        Map.get(file_config, :temperature)

      val when is_binary(val) ->
        case Float.parse(val) do
          {float, _} -> float
          :error -> nil
        end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Defaults
  # ──────────────────────────────────────────────────────────────

  defp defaults do
    %{
      base_url: @default_base_url,
      api: :openai,
      model: @default_model,
      api_key: nil,
      provider_key: nil,
      model_meta: %{},
      available_models: []
    }
  end

  @doc """
  Convert JSON `"api"` string to internal atom.

  Mapping:
    - `"openai-chat-completions"` → `:openai`
    - `"openai"` → `:openai_responses`
    - `"anthropic-messages"` → `:anthropic`
    - `"stepfun"` / `"stepfun-step-plan"` → `:stepfun`
    - `"openai-responses"` → `:openai_responses`
    - anything else → `:openai`
  """
  @spec api_to_atom(String.t() | nil) :: atom()
  def api_to_atom("openai-chat-completions"), do: :openai
  def api_to_atom("openai"), do: :openai_responses
  def api_to_atom("anthropic-messages"), do: :anthropic
  def api_to_atom("stepfun"), do: :stepfun
  def api_to_atom("stepfun-step-plan"), do: :stepfun
  def api_to_atom("ollama-cloud"), do: :openai
  def api_to_atom("opencode-go"), do: :openai
  def api_to_atom("openai-responses"), do: :openai_responses
  def api_to_atom("cursor-agent"), do: :cursor_agent
  def api_to_atom("openai-codex-responses"), do: :openai_codex_responses
  def api_to_atom(_), do: :openai

  @doc """
  Returns the list of configuration file names tried in priority order.
  """
  def config_filenames, do: @config_filenames

  # ──────────────────────────────────────────────────────────────

  @doc """
  Get provider config for a specific provider id from the global config.
  """
  @spec provider_config_for(Path.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def provider_config_for(working_directory \\ File.cwd!(), provider_id, model_id \\ nil)

  def provider_config_for(scope, "ext:" <> _ = provider_id, model_id),
    do: Handbean.Extension.Provider.config(scope, provider_id, model_id)

  def provider_config_for(working_directory, provider_id, model_id) do
    _ = working_directory
    raw_json = load_raw_global_config()

    if raw_json do
      providers = Map.get(raw_json, "providers", %{})

      case Map.get(providers, provider_id) do
        nil ->
          {:error, "Provider #{provider_id} not found in global config"}

        %{} = provider_config ->
          provider = Map.get(provider_config, "provider")

          base_url =
            Map.get(provider_config, "baseUrl") || default_base_url_for_provider(provider)

          api = Map.get(provider_config, "api")
          normalized_url = normalize_base_url(base_url, api)
          provider_models = Map.get(provider_config, "models", [])
          model_meta = find_model_meta(provider_models, model_id)

          if model_id && not model_enabled?(model_meta) do
            {:error, "Model #{model_id} is disabled"}
          else
            case test_provider_override(provider_id, model_id) do
              {:ok, _config} = overridden ->
                overridden

              :passthrough ->
                case assemble_provider_config(
                       provider_id,
                       provider_config,
                       model_id,
                       normalized_url,
                       api,
                       provider,
                       model_meta
                     ) do
                  {:ok, config} -> {:ok, config}
                  {:error, _} = error -> error
                end
            end
          end
      end
    else
      {:error, "No global model configuration found"}
    end
  end

  # Tests set this so a LiveView send resolves to FakeProvider instead of the
  # catalog adapter. Production never sets it, so a normal resolve still reads
  # models.json and can reach a real provider.
  defp test_provider_override(provider_id, model_id) do
    case Application.get_env(:handbean, :test_provider) do
      %{module: module, scenario: scenario} = override ->
        config = %{
          provider: "fake",
          api: :openai,
          model: model_id,
          provider_key: provider_id,
          scenario: scenario,
          base_url: "http://127.0.0.1"
        }

        config =
          case override[:provider_config] do
            extra when is_map(extra) -> Map.merge(config, extra)
            _ -> config
          end

        _ = module
        {:ok, config}

      _ ->
        :passthrough
    end
  end

  @doc "Return the explicitly configured global default composite model id."
  @spec configured_default_model() :: String.t() | nil
  def configured_default_model do
    case load_raw_global_config() do
      %{"defaultProvider" => provider, "defaultModel" => model}
      when is_binary(provider) and provider != "" and is_binary(model) and model != "" ->
        provider <> "/" <> model

      _ ->
        nil
    end
  end

  @doc """
  Returns all models from all providers in the global config.

  Each model entry has `:id` (composite `provider_id/model_id`), `:name`,
  `:provider_id`, and `:model_id`.
  """
  @spec all_global_models() :: [map()]
  def all_global_models do
    (load_raw_global_config()
     |> extract_all_models()
     |> Enum.reject(&String.starts_with?(&1.provider_id, "ext:"))) ++
      Handbean.Extension.Provider.models(:global)
  end

  @doc "Models visible to a workspace before its allowlist is applied."
  def models_for_workspace(workspace) do
    Enum.reject(all_global_models(), &String.starts_with?(&1.provider_id, "ext:")) ++
      Handbean.Extension.Provider.models(workspace)
  end

  @doc """
  Whether a composite or bare model id is still in the global catalog.

  Disabled entries count. A deleted provider does not. Callers use this to
  tell a removed reference apart from a model the workspace allowlist rejects.
  """
  @spec model_in_catalog?(String.t()) :: boolean()
  def model_in_catalog?(model_id) when is_binary(model_id) do
    Enum.any?(catalog_models(), &model_matches?(&1, model_id))
  end

  def model_in_catalog?(_), do: false

  @doc """
  Every catalog model, including ones with `"enabled" => false`.

  Chat and workspace choices use `all_global_models/0`, which drops disabled
  entries. Settings rows use this list so a disabled model can be turned back on.
  Missing `enabled` is treated as on.
  """
  @spec catalog_models() :: [map()]
  def catalog_models do
    load_raw_global_config() |> extract_catalog_models()
  end

  @doc """
  Returns whether the global model configuration file exists and parses.
  """
  @spec global_config_status() :: :ok | {:error, String.t()}
  def global_config_status do
    path = global_config_path()

    case File.read(path) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, _json} -> :ok
          {:error, reason} -> {:error, "Failed to parse #{path}: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, "Model configuration not found at #{path}"}

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  # ── Workspace policy internals ──────────────────────────────────

  defp load_raw_global_config do
    path = global_config_path()

    case File.read(path) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, json} -> json
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp global_config_path do
    case System.get_env(@config_path_env) do
      path when is_binary(path) and path != "" ->
        Handbean.Home.expand(path)

      _ ->
        case Application.get_env(:handbean, :models_file) do
          path when is_binary(path) and path != "" -> Handbean.Home.expand(path)
          _ -> Handbean.Home.expand(@global_config_path)
        end
    end
  end

  defp extract_all_models(nil), do: []

  defp extract_all_models(json) do
    json
    |> extract_catalog_models()
    |> Enum.filter(& &1.enabled)
  end

  defp extract_catalog_models(nil), do: []

  defp extract_catalog_models(json) do
    providers = Map.get(json, "providers", %{})

    Enum.flat_map(providers, fn {provider_id, provider_config} ->
      provider_config
      |> Map.get("models", [])
      |> Enum.map(&catalog_model_summary(provider_id, &1))
    end)
  end

  defp catalog_model_summary(provider_id, model) do
    model_id = Map.get(model, "id")

    %{
      id: "#{provider_id}/#{model_id}",
      name: Map.get(model, "name", model_id),
      provider_id: provider_id,
      model_id: model_id,
      input: Map.get(model, "input", []),
      reasoning: Map.get(model, "reasoning"),
      reasoning_levels: Map.get(model, "reasoningLevels", []),
      default_reasoning: Map.get(model, "defaultReasoning"),
      thinking_level_map: Map.get(model, "thinkingLevelMap", %{}),
      context_window: Map.get(model, "contextWindow"),
      max_tokens: Map.get(model, "maxTokens"),
      cost: Map.get(model, "cost", %{}),
      enabled: model_enabled?(model)
    }
  end

  # ──────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────

  defp merge_provider_options(config, provider_config, model_meta) do
    config
    |> maybe_put_config_option(
      :use_previous_response_id,
      json_option(
        provider_config,
        model_meta,
        "usePreviousResponseId",
        "use_previous_response_id"
      )
    )
    |> maybe_put_config_option(
      :previous_response_id,
      json_option(provider_config, model_meta, "previousResponseId", "previous_response_id")
    )
    |> maybe_put_config_option(:store, json_option(provider_config, model_meta, "store"))
    |> maybe_put_config_option(:include, json_option(provider_config, model_meta, "include"))
    |> maybe_put_config_option(
      :receive_timeout,
      json_option(provider_config, model_meta, "receiveTimeout", "receive_timeout")
    )
    |> maybe_put_config_option(
      :connect_timeout,
      json_option(provider_config, model_meta, "connectTimeout", "connect_timeout")
    )
    |> maybe_put_config_option(
      :max_retries,
      json_option(provider_config, model_meta, "maxRetries", "max_retries")
    )
    |> maybe_put_config_option(
      :retry_delay_base_ms,
      json_option(provider_config, model_meta, "retryDelayBaseMs", "retry_delay_base_ms")
    )
    |> maybe_put_config_option(
      :tool_choice,
      json_option(provider_config, model_meta, "toolChoice", "tool_choice")
    )
    |> maybe_put_config_option(
      :parallel_tool_calls,
      json_option(provider_config, model_meta, "parallelToolCalls", "parallel_tool_calls")
    )
    |> maybe_put_config_option(
      :built_in_tools,
      json_option(provider_config, model_meta, "builtInTools", "built_in_tools")
    )
    |> maybe_put_config_option(
      :web_search,
      json_option(provider_config, model_meta, "webSearch", "web_search")
    )
    |> maybe_put_config_option(
      :x_search,
      json_option(provider_config, model_meta, "xSearch", "x_search")
    )
  end

  defp json_option(provider_config, model_meta, camel_key, snake_key \\ nil) do
    keys = [camel_key, snake_key] |> Enum.reject(&is_nil/1)

    case find_json_option(model_meta, keys) do
      :missing -> find_json_option(provider_config, keys)
      value -> value
    end
  end

  defp find_json_option(map, keys) when is_map(map) do
    Enum.reduce_while(keys, :missing, fn key, _acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, :missing}
      end
    end)
  end

  defp find_json_option(_map, _keys), do: :missing

  defp maybe_put_config_option(config, _key, :missing), do: config
  defp maybe_put_config_option(config, key, value), do: Map.put(config, key, value)

  defp build_req_options(file_config) do
    opts =
      []
      |> maybe_put_req_option(:receive_timeout, file_config[:receive_timeout])
      |> maybe_put_connect_timeout(file_config[:connect_timeout])

    if opts == [], do: nil, else: opts
  end

  defp maybe_put_req_option(opts, _key, nil), do: opts
  defp maybe_put_req_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_connect_timeout(opts, nil), do: opts

  defp maybe_put_connect_timeout(opts, timeout) do
    Keyword.put(opts, :connect_options, timeout: timeout)
  end

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp model_matches?(model, model_id) do
    model.id == model_id or model.model_id == model_id
  end
end
