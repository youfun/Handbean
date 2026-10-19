defmodule Handbean.Agent.ModelConfig do
  @moduledoc """
  Global model configuration from `~/.handbean/models.json`.

  Reads one shared model configuration file (like pi agent) to produce a provider
  config. Workspace-level restrictions live in `.handbean/settings.jsonc`, not in
  provider config files.

  ## Configuration format (`models.json`)

      {
        "defaultProvider": "stepfun",
        "defaultModel": "step-5-preview",
        "providers": {
          "stepfun": {
            "baseUrl": "https://api.stepfun.com/step_plan/v1",
            "api": "stepfun-step-plan",
            "apiKey": "env:OPENAI_API_KEY",
            "provider": "stepfun",
            "models": [
              { "id": "step-router-v1", "name": "Step Router v1", ... }
            ]
          }
        }
      }

  ## Priority (highest wins)

      1. `models.json` values
      2. Explicit env vars for non-secret runtime overrides only
         (OPENAI_BASE_URL, OPENAI_MODEL, OPENAI_MAX_TOKENS, OPENAI_TEMPERATURE)
      3. Handbean built-in defaults (StepFun Step Plan v1)

  `OPENAI_API_KEY` is not read implicitly by ModelConfig. Put the key in
  `models.json`, or explicitly opt into env resolution with `"apiKey": "env:VAR"`.

  ## `apiKey` resolution

    - `"env:OPENAI_API_KEY"` → reads `System.get_env("OPENAI_API_KEY")`
    - any other string → used literally
    - `"authType": "oauth"` → resolve/refresh from `~/.handbean/auth.json`
      and never fall back to an unrelated environment API key
  """

  alias Handbean.Agent.Auth.{CodexCredential, CursorCredential, XaiCredential}
  alias Handbean.Agent.ModelCapabilities

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

  defp enabled_models(models) when is_list(models), do: Enum.filter(models, &model_enabled?/1)
  defp enabled_models(_), do: []

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
  # Workspace-level model access policy
  # ──────────────────────────────────────────────────────────────

  @doc """
  Returns the path to the workspace-level settings file that contains model policy.
  """
  @spec workspace_policy_path(Path.t()) :: Path.t()
  def workspace_policy_path(workspace_root) do
    Handbean.WorkspaceSettings.path(workspace_root)
  end

  @doc """
  Load the workspace-level model access policy.

  Returns:
    - `:unrestricted` when settings or `models` are absent → all global models allowed
    - `{:ok, policy_map}` when a valid `models` settings block exists
    - `{:error, reason}` when the settings file is malformed (no fallback!)
  """
  @spec load_workspace_policy(Path.t()) :: :unrestricted | {:ok, map()} | {:error, String.t()}
  def load_workspace_policy(workspace_root) do
    Handbean.WorkspaceSettings.models_policy(workspace_root)
  end

  @doc """
  List available models for a workspace, respecting the policy if present.

  Returns a list of model maps with `:id` (composite `provider_id/model_id`),
  `:name`, `:provider_id`, and `:model_id` keys.
  """
  @spec available_models_for_workspace(Path.t()) :: [map()]
  def available_models_for_workspace(workspace_root) do
    all_models = all_global_models()

    case load_workspace_policy(workspace_root) do
      :unrestricted ->
        all_models

      {:ok, policy} ->
        filter_models_by_policy(all_models, policy)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Returns the default model id for a workspace.

  - Unrestricted → global default model (from provider_config)
  - Restricted with valid policy default in allowlist → composite id
  - Restricted, default not in allowlist → first allowed model
  - Restricted, no allowed models → nil
  - Malformed policy → nil
  """
  @spec default_model_for_workspace(Path.t()) :: String.t() | nil
  def default_model_for_workspace(workspace_root) do
    available = available_models_for_workspace(workspace_root)

    case load_workspace_policy(workspace_root) do
      :unrestricted ->
        config = provider_config(workspace_root)
        default_provider = config[:provider_key]
        default_model = config[:model]

        composite =
          if default_provider && default_model, do: "#{default_provider}/#{default_model}"

        if composite && Enum.any?(available, &(&1.id == composite)) do
          composite
        else
          available |> List.first() |> then(&if &1, do: &1.id)
        end

      {:ok, policy} ->
        default = Map.get(policy, "default", %{})
        default_provider = Map.get(default, "provider")
        default_model_id = Map.get(default, "model")

        if default_provider && default_model_id do
          composite = "#{default_provider}/#{default_model_id}"

          if Enum.any?(available, &(&1.id == composite)) do
            composite
          else
            available |> List.first() |> then(&if(&1, do: &1.id))
          end
        else
          available |> List.first() |> then(&if(&1, do: &1.id))
        end

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Check whether a composite model id is allowed in the workspace.
  """
  @spec model_allowed_for_workspace?(Path.t(), String.t()) :: boolean()
  def model_allowed_for_workspace?(workspace_root, model_id) do
    available = available_models_for_workspace(workspace_root)
    Enum.any?(available, &model_matches?(&1, model_id))
  end

  defp model_matches?(model, model_id) do
    model.id == model_id or model.model_id == model_id
  end

  @doc """
  Resolve a composite model id to the actual model_id and provider config.

  Returns `{:ok, provider_config, actual_model_id}` or `{:error, reason}`.
  """
  @spec resolve_model_for_workspace(Path.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def resolve_model_for_workspace(workspace_root, composite_id) do
    available = available_models_for_workspace(workspace_root)

    model_entry = Enum.find(available, &(&1.id == composite_id))

    if model_entry do
      provider_id = model_entry.provider_id
      actual_model_id = model_entry.model_id

      case provider_config_for(workspace_root, provider_id, actual_model_id) do
        {:ok, provider_config} ->
          {:ok, provider_config, actual_model_id}

        {:error, _} = error ->
          error
      end
    else
      {:error, "Model #{composite_id} is not allowed in this workspace"}
    end
  end

  @doc """
  Resolve a composite model id from the unrestricted global catalog.

  Returns `{:ok, provider_config, actual_model_id}` or `{:error, reason}`.
  """
  @spec resolve_global_model(String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def resolve_global_model(composite_id) do
    case Enum.find(all_global_models(), &(&1.id == composite_id)) do
      nil ->
        {:error, "Model #{composite_id} is not available"}

      model_entry ->
        case provider_config_for(File.cwd!(), model_entry.provider_id, model_entry.model_id) do
          {:ok, provider_config} -> {:ok, provider_config, model_entry.model_id}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Get provider config for a specific provider id from the global config.
  """
  @spec provider_config_for(Path.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def provider_config_for(working_directory \\ File.cwd!(), provider_id, model_id \\ nil) do
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

  @doc """
  Returns all models from all providers in the global config.

  Each model entry has `:id` (composite `provider_id/model_id`), `:name`,
  `:provider_id`, and `:model_id`.
  """
  @spec all_global_models() :: [map()]
  def all_global_models do
    load_raw_global_config() |> extract_all_models()
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

  defp filter_models_by_policy(all_models, policy) do
    allow = Map.get(policy, "allow", %{})
    allowed_providers = allowed_providers_from_allow(allow)

    if allowed_providers == %{} do
      all_models
    else
      Enum.filter(all_models, fn model ->
        case Map.get(allowed_providers, model.provider_id) do
          %{"models" => allowed_model_ids} when is_list(allowed_model_ids) ->
            model.model_id in allowed_model_ids

          _ ->
            false
        end
      end)
    end
  end

  defp allowed_providers_from_allow(%{"providers" => providers}) when is_map(providers),
    do: providers

  defp allowed_providers_from_allow(allow) when is_map(allow), do: allow
  defp allowed_providers_from_allow(_allow), do: %{}

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

  # ──────────────────────────────────────────────────────────────
  # Write methods (CRUD for models.json)
  # ──────────────────────────────────────────────────────────────

  @valid_provider_name_re ~r/^[a-z0-9_-]+$/

  @stepfun_reasoning_levels ["minimal", "medium", "high"]
  @stepfun_thinking_level_map %{
    "minimal" => "low",
    "medium" => "medium",
    "high" => "high"
  }

  @stepfun_router_model %{
    "id" => "step-router-v1",
    "name" => "Step Router v1",
    "reasoning" => true,
    "reasoningLevels" => @stepfun_reasoning_levels,
    "defaultReasoning" => "medium",
    "thinkingLevelMap" => @stepfun_thinking_level_map,
    "input" => ["text"],
    "contextWindow" => 256_000
  }

  @stepfun_preview_model %{
    "id" => "step-5-preview",
    "name" => "Step 5 Preview",
    "reasoning" => true,
    "reasoningLevels" => @stepfun_reasoning_levels,
    "defaultReasoning" => "medium",
    "thinkingLevelMap" => @stepfun_thinking_level_map,
    "input" => ["text", "image"],
    "contextWindow" => 256_000
  }

  @default_config %{
    "defaultProvider" => "stepfun",
    "defaultModel" => "step-5-preview",
    "providers" => %{
      "stepfun" => %{
        "baseUrl" => "https://api.stepfun.com/step_plan/v1",
        "api" => "stepfun-step-plan",
        "apiKey" => "env:OPENAI_API_KEY",
        "provider" => "stepfun",
        "models" => [@stepfun_router_model, @stepfun_preview_model]
      }
    }
  }

  @doc """
  Returns the resolved path to the global model configuration file.

  Respects `HANDBEAN_MODELS_FILE` env var override.
  """
  @spec config_file_path() :: String.t()
  def config_file_path do
    case System.get_env(@config_path_env) do
      path when is_binary(path) and path != "" -> Handbean.Home.expand(path)
      _ -> Handbean.Home.expand(@global_config_path)
    end
  end

  @doc """
  Read the raw global model configuration (`models.json`) as a string-keyed map.

  This is the single read path for callers that need the catalog as stored,
  for example settings UIs. It resolves the file with `config_file_path/0`
  (`HANDBEAN_MODELS_FILE` or `~/.handbean/models.json`) and never applies env
  overrides, defaults, or secret resolution.

  Returns:

    - `{:ok, config}` — `config["providers"]` is guaranteed to be a map
    - `{:ok, %{"defaultProvider" => "", "providers" => %{}}}` when the file does
      not exist (an empty catalog, same shape the write path starts from)
    - `{:error, "Failed to read config: ..."}` for any other read error
    - `{:error, "Failed to parse config: ..."}` for invalid JSON
    - `{:error, "Config must be a JSON object"}` when the JSON is not an object
    - `{:error, "Config providers must be a JSON object"}` when `providers` is
      missing or not an object
  """
  @spec read_config() :: {:ok, map()} | {:error, String.t()}
  def read_config do
    case File.read(config_file_path()) do
      {:ok, content} ->
        case Handbean.JSON.decode(content) do
          {:ok, %{"providers" => providers} = json} when is_map(providers) -> {:ok, json}
          {:ok, json} when is_map(json) -> {:error, "Config providers must be a JSON object"}
          {:ok, _} -> {:error, "Config must be a JSON object"}
          {:error, reason} -> {:error, "Failed to parse config: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, %{"defaultProvider" => "", "providers" => %{}}}

      {:error, reason} ->
        {:error, "Failed to read config: #{inspect(reason)}"}
    end
  end

  @doc """
  Ensure the global model configuration file exists.

  Creates `~/.handbean/models.json` with a default StepFun provider configuration
  if the file does not already exist. If a StepFun catalog already exists without
  `step-5-preview`, that model is appended and set as the default. Other
  providers are left unchanged.

  Returns `:ok` if the file already exists or was created successfully.
  """
  @spec ensure_config() :: :ok | {:error, String.t()}
  def ensure_config do
    path = config_file_path()

    if File.exists?(path) do
      upgrade_stepfun_preview()
    else
      with {:ok, body} <- initial_config_body(),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, body),
           :ok <- File.chmod(path, 0o600) do
        :ok
      else
        {:error, reason} -> {:error, "Failed to create model config: #{inspect(reason)}"}
      end
    end
  rescue
    e in RuntimeError -> {:error, Exception.message(e)}
  end

  defp upgrade_stepfun_preview do
    with {:ok, json} <- read_config(),
         {:ok, updated} <- maybe_put_stepfun_preview(json),
         :ok <- persist_stepfun_preview(updated) do
      :ok
    else
      :unchanged ->
        :ok

      {:error, reason} ->
        Logger.warning("[Handbean] model catalog upgrade skipped: #{inspect(reason)}")
        :ok
    end
  end

  defp persist_stepfun_preview(config) do
    with :ok <- validate_config(config) do
      atomic_write(config_file_path(), Handbean.JSON.encode!(config, pretty: true))
    end
  end

  defp maybe_put_stepfun_preview(%{"providers" => providers} = json) when is_map(providers) do
    case Map.get(providers, "stepfun") do
      %{"models" => models} = stepfun when is_list(models) ->
        preview_missing? =
          not Enum.any?(models, &(is_map(&1) and &1["id"] == @stepfun_preview_model["id"]))

        upgraded_models =
          models
          |> Enum.map(&upgrade_stepfun_model/1)
          |> then(&if(preview_missing?, do: &1 ++ [@stepfun_preview_model], else: &1))

        cond do
          upgraded_models == models ->
            :unchanged

          preview_missing? ->
            stepfun = Map.put(stepfun, "models", upgraded_models)

            {:ok,
             json
             |> put_in(["providers", "stepfun"], stepfun)
             |> Map.put("defaultProvider", "stepfun")
             |> Map.put("defaultModel", @stepfun_preview_model["id"])}

          true ->
            {:ok, put_in(json, ["providers", "stepfun", "models"], upgraded_models)}
        end

      _ ->
        :unchanged
    end
  end

  defp maybe_put_stepfun_preview(_json), do: :unchanged

  defp upgrade_stepfun_model(%{"id" => "step-router-v1"} = model),
    do: Map.merge(@stepfun_router_model, model)

  defp upgrade_stepfun_model(%{"id" => "step-5-preview"} = model),
    do: Map.merge(@stepfun_preview_model, model)

  defp upgrade_stepfun_model(model), do: model

  defp initial_config_body do
    case System.get_env("HANDBEAN_MODELS_SEED") do
      path when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, body} ->
            case Handbean.JSON.decode(body) do
              {:ok, map} when is_map(map) -> {:ok, body}
              _ -> {:error, "invalid model seed"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, Handbean.JSON.encode!(@default_config, pretty: true)}
    end
  end

  @doc """
  Write a complete model configuration to the global config file.

  Validates the full config before writing. Uses atomic file write to prevent
  corruption. Broadcasts `{:models_updated}` on Phoenix.PubSub on success.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec write_config(map()) :: :ok | {:error, String.t()}
  def write_config(config) when is_map(config) do
    with_config_lock(fn -> write_config_unlocked(config) end)
  end

  def write_config(_other), do: {:error, "Config must be a JSON object (map)"}

  defp write_config_unlocked(config) do
    with :ok <- validate_config(config) do
      path = config_file_path()
      File.mkdir_p(Path.dirname(path))

      case atomic_write(path, Handbean.JSON.encode!(config, pretty: true)) do
        :ok ->
          broadcast_models_updated()
          :ok

        {:error, reason} ->
          {:error, "Failed to write config: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Add a new provider to the global config.

  Fails if the provider id already exists or is invalid.
  """
  @spec add_provider(String.t(), map()) :: :ok | {:error, String.t()}
  def add_provider(provider_id, provider_attrs) when is_map(provider_attrs) do
    provider_attrs = Map.put_new(provider_attrs, "models", [])

    with :ok <- validate_provider_name(provider_id),
         :ok <- validate_provider_attrs(provider_attrs) do
      update_config(fn config ->
        with :ok <- ensure_provider_not_exists(config, provider_id) do
          {:ok,
           config
           |> Map.put("providers", Map.put(config["providers"], provider_id, provider_attrs))
           |> ensure_default_provider(provider_id)}
        end
      end)
    end
  end

  @doc """
  Remove a provider and all its models from the global config.

  Fails if the provider does not exist.
  Automatically reassigns `defaultProvider` if the removed provider was the default.
  """
  @spec remove_provider(String.t()) :: :ok | {:error, String.t()}
  def remove_provider(provider_id) do
    update_config(fn config ->
      with :ok <- ensure_provider_exists(config, provider_id) do
        updated_providers = Map.delete(config["providers"], provider_id)

        {:ok,
         config
         |> Map.put("providers", updated_providers)
         |> reassign_default_provider(provider_id, updated_providers)}
      end
    end)
  end

  @doc """
  Add a model to an existing provider.

  Fails if the provider does not exist or if the model id is a duplicate.
  """
  @spec add_model(String.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def add_model(provider_id, model_id, model_attrs) when is_map(model_attrs) do
    with :ok <- validate_model_attrs(model_attrs) do
      update_config(fn config ->
        with :ok <- ensure_provider_exists(config, provider_id),
             :ok <- ensure_model_not_exists(config, provider_id, model_id) do
          full_model = Map.put(model_attrs, "id", model_id)
          provider = config["providers"][provider_id]
          models = Map.get(provider, "models", [])
          first_in_catalog? = catalog_has_no_models?(config)
          updated_provider = Map.put(provider, "models", models ++ [full_model])
          updated_providers = Map.put(config["providers"], provider_id, updated_provider)

          {:ok,
           config
           |> Map.put("providers", updated_providers)
           |> maybe_assign_first_model_defaults(provider_id, model_id, first_in_catalog?)}
        end
      end)
    end
  end

  @doc """
  Remove a model from a provider.

  Fails if the provider or model does not exist.
  """
  @spec remove_model(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove_model(provider_id, model_id) do
    update_config(fn config ->
      with :ok <- ensure_provider_exists(config, provider_id),
           :ok <- ensure_model_exists(config, provider_id, model_id) do
        provider = config["providers"][provider_id]
        models = Map.get(provider, "models", [])
        updated_models = Enum.reject(models, &(&1["id"] == model_id))
        updated_provider = Map.put(provider, "models", updated_models)
        updated_providers = Map.put(config["providers"], provider_id, updated_provider)

        {:ok,
         config
         |> Map.put("providers", updated_providers)
         |> reassign_default_model(provider_id, model_id)}
      end
    end)
  end

  @doc "Set the default provider using the latest persisted config."
  @spec set_default_provider(String.t()) :: :ok | {:error, String.t()}
  def set_default_provider(provider_id) when is_binary(provider_id) do
    update_config(fn config ->
      with :ok <- ensure_provider_exists(config, provider_id) do
        models = get_in(config, ["providers", provider_id, "models"]) || []
        current_model = config["defaultModel"]

        default_model =
          if Enum.any?(models, &(&1["id"] == current_model)) do
            current_model
          else
            models |> List.first(%{}) |> Map.get("id")
          end

        updated_config = Map.put(config, "defaultProvider", provider_id)

        {:ok,
         if(default_model,
           do: Map.put(updated_config, "defaultModel", default_model),
           else: Map.delete(updated_config, "defaultModel")
         )}
      end
    end)
  end

  @doc "Set the default provider and model using the latest persisted config."
  @spec set_default_model(String.t(), String.t()) :: :ok | {:error, String.t()}
  def set_default_model(provider_id, model_id)
      when is_binary(provider_id) and is_binary(model_id) do
    update_config(fn config ->
      with :ok <- ensure_provider_exists(config, provider_id),
           :ok <- ensure_model_exists(config, provider_id, model_id) do
        {:ok,
         config
         |> Map.put("defaultProvider", provider_id)
         |> Map.put("defaultModel", model_id)}
      end
    end)
  end

  @doc """
  Update provider-level settings (non-destructive merge).
  """
  @spec update_provider(String.t(), map()) :: :ok | {:error, String.t()}
  def update_provider(provider_id, attrs) when is_map(attrs) do
    update_config(fn config ->
      with :ok <- ensure_provider_exists(config, provider_id) do
        provider = config["providers"][provider_id]
        updated_provider = Map.merge(provider, attrs)
        updated_providers = Map.put(config["providers"], provider_id, updated_provider)
        {:ok, Map.put(config, "providers", updated_providers)}
      end
    end)
  end

  @doc """
  Turn off every model for one provider, keeping the rows so they can be
  turned back on individually.
  """
  @spec disable_provider_models(String.t()) :: :ok | {:error, String.t()}
  def disable_provider_models(provider_id) when is_binary(provider_id) do
    update_config(fn config ->
      with :ok <- ensure_provider_exists(config, provider_id) do
        provider = config["providers"][provider_id]

        models =
          provider
          |> Map.get("models", [])
          |> Enum.map(fn
            model when is_map(model) -> Map.put(model, "enabled", false)
            other -> other
          end)

        updated_provider = Map.put(provider, "models", models)
        updated_providers = Map.put(config["providers"], provider_id, updated_provider)
        {:ok, Map.put(config, "providers", updated_providers)}
      end
    end)
  end

  @doc """
  Update model-level settings (non-destructive merge).
  """
  @spec update_model(String.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def update_model(provider_id, model_id, attrs) when is_map(attrs) do
    update_config(fn config ->
      with :ok <- ensure_provider_exists(config, provider_id),
           :ok <- ensure_model_exists(config, provider_id, model_id) do
        provider = config["providers"][provider_id]
        models = Map.get(provider, "models", [])

        updated_models =
          Enum.map(models, fn
            %{"id" => ^model_id} = model -> Map.merge(model, attrs)
            other -> other
          end)

        updated_provider = Map.put(provider, "models", updated_models)
        updated_providers = Map.put(config["providers"], provider_id, updated_provider)
        {:ok, Map.put(config, "providers", updated_providers)}
      end
    end)
  end

  @doc """
  Update the API key for a provider.

  Supports literal keys and `env:VAR_NAME` references.
  """
  @spec update_api_key(String.t(), String.t()) :: :ok | {:error, String.t()}
  def update_api_key(provider_id, api_key) when is_binary(api_key) do
    update_provider(provider_id, %{"apiKey" => api_key})
  end

  # ──────────────────────────────────────────────────────────────
  # Write helpers: load / validate / write
  # ──────────────────────────────────────────────────────────────

  defp update_config(update) when is_function(update, 1) do
    with_config_lock(fn ->
      with {:ok, config} <- load_or_default_config(),
           {:ok, updated_config} <- update.(config) do
        write_config_unlocked(updated_config)
      end
    end)
  end

  defp with_config_lock(fun) when is_function(fun, 0) do
    lock = {{__MODULE__, config_file_path()}, self()}

    case :global.trans(lock, fun, [Node.self()]) do
      :aborted -> {:error, "Model config is busy. Try again."}
      result -> result
    end
  end

  defp load_or_default_config do
    path = config_file_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Handbean.JSON.decode(content) do
            {:ok, json} when is_map(json) -> {:ok, json}
            {:ok, _} -> {:error, "Config must be a JSON object"}
            {:error, reason} -> {:error, "Failed to parse config: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to read config: #{inspect(reason)}"}
      end
    else
      {:ok, %{"defaultProvider" => "", "providers" => %{}}}
    end
  end

  defp atomic_write(path, content) do
    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"
    mode = existing_mode_or_private(path)

    try do
      File.write!(tmp_path, content)
      File.chmod!(tmp_path, mode)
      File.rename!(tmp_path, path)
      :ok
    rescue
      e in File.Error ->
        File.rm(tmp_path)
        {:error, e}
    end
  end

  defp existing_mode_or_private(path) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o777)
      {:error, _reason} -> 0o600
    end
  end

  defp broadcast_models_updated do
    Phoenix.PubSub.broadcast(Handbean.PubSub, "models:updated", {:models_updated})
  end

  # ──────────────────────────────────────────────────────────────
  # Validation
  # ──────────────────────────────────────────────────────────────

  # Only reachable from `write_config/1`, whose map clause is guarded by
  # `is_map/1`; the non-map case is rejected there before validation runs.
  defp validate_config(json) when is_map(json) do
    with :ok <- validate_config_providers_exist(json),
         :ok <- validate_config_default_provider(json),
         :ok <- validate_config_all_providers(json) do
      validate_config_default_model(json)
    end
  end

  defp validate_config_providers_exist(json) do
    providers = Map.get(json, "providers", %{})

    if is_map(providers) and map_size(providers) > 0 do
      :ok
    else
      {:error, "At least one provider is required"}
    end
  end

  defp validate_config_default_provider(json) do
    default_provider = Map.get(json, "defaultProvider")

    cond do
      not is_binary(default_provider) or default_provider == "" ->
        {:error, "defaultProvider is required and must be a non-empty string"}

      not Map.has_key?(json["providers"], default_provider) ->
        {:error, "defaultProvider '#{default_provider}' not found in providers"}

      true ->
        :ok
    end
  end

  defp validate_config_all_providers(json) do
    providers = Map.get(json, "providers", %{})

    Enum.reduce_while(providers, :ok, fn {provider_id, provider_config}, :ok ->
      case validate_provider_entry(provider_id, provider_config) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_config_default_model(json) do
    default_model = Map.get(json, "defaultModel")

    if is_binary(default_model) and default_model != "" do
      default_provider = json["providers"][json["defaultProvider"]]
      models = Map.get(default_provider, "models", [])
      model_ids = Enum.map(models, & &1["id"])

      if default_model in model_ids do
        :ok
      else
        {:error,
         "defaultModel '#{default_model}' not found in provider '#{json["defaultProvider"]}'"}
      end
    else
      :ok
    end
  end

  defp validate_provider_entry(provider_id, provider_config) do
    with :ok <- validate_provider_name(provider_id),
         :ok <- validate_provider_is_map(provider_id, provider_config),
         :ok <- validate_provider_has_models(provider_config) do
      validate_provider_models(provider_config)
    end
  end

  defp validate_provider_name(name) do
    if is_binary(name) and String.match?(name, @valid_provider_name_re) do
      :ok
    else
      {:error,
       "Provider id must match #{inspect(@valid_provider_name_re)}, got: #{inspect(name)}"}
    end
  end

  defp validate_provider_is_map(_provider_id, provider_config) when is_map(provider_config),
    do: :ok

  defp validate_provider_is_map(provider_id, provider_config) do
    {:error,
     "Provider '#{provider_id}' config must be a JSON object, got: #{inspect(provider_config)}"}
  end

  defp validate_provider_attrs(attrs) do
    with :ok <- validate_provider_has_models(attrs) do
      validate_provider_models(attrs)
    end
  end

  defp validate_provider_has_models(provider_config) do
    case Map.get(provider_config, "models", []) do
      models when is_list(models) ->
        :ok

      _other ->
        {:error, "Provider models must be a JSON array"}
    end
  end

  defp validate_provider_models(provider_config) do
    models = Map.get(provider_config, "models", [])

    non_map_models = Enum.reject(models, &is_map/1)

    if non_map_models != [] do
      {:error, "Model entries must be JSON objects"}
    else
      missing_ids = Enum.filter(models, fn m -> not is_binary(m["id"]) or m["id"] == "" end)

      if missing_ids != [] do
        {:error, "Model id is required"}
      else
        model_ids = Enum.map(models, & &1["id"])

        with :ok <- ensure_no_duplicate_models(model_ids) do
          Enum.reduce_while(models, :ok, fn model, :ok ->
            case validate_model_attrs(model) do
              :ok -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end
          end)
        end
      end
    end
  end

  defp validate_model_attrs(model) do
    name = Map.get(model, "name")

    if not is_binary(name) or name == "" do
      {:error, "Model name is required"}
    else
      validate_model_input_types(model)
    end
  end

  defp validate_model_input_types(model) do
    input = Map.get(model, "input", ["text"])
    valid_input_types = ModelCapabilities.supported_input_types()

    cond do
      not is_list(input) or input == [] ->
        {:error, "Model input must be a non-empty list"}

      not Enum.all?(input, &(&1 in valid_input_types)) ->
        invalid = Enum.reject(input, &(&1 in valid_input_types))

        {:error,
         "Invalid input types: #{inspect(invalid)}. Valid types: #{inspect(valid_input_types)}"}

      true ->
        :ok
    end
  end

  defp ensure_no_duplicate_models(model_ids) do
    duplicates = model_ids -- Enum.uniq(model_ids)

    if duplicates == [] do
      :ok
    else
      {:error, "Duplicate model ids: #{inspect(duplicates)}"}
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Write helpers: guard checks
  # ──────────────────────────────────────────────────────────────

  defp ensure_provider_exists(config, provider_id) do
    if Map.has_key?(config["providers"], provider_id) do
      :ok
    else
      {:error, "Provider '#{provider_id}' does not exist"}
    end
  end

  defp ensure_provider_not_exists(config, provider_id) do
    if Map.has_key?(config["providers"], provider_id) do
      {:error, "Provider '#{provider_id}' already exists"}
    else
      :ok
    end
  end

  defp ensure_model_exists(config, provider_id, model_id) do
    provider = config["providers"][provider_id]
    models = Map.get(provider, "models", [])

    if Enum.any?(models, &(&1["id"] == model_id)) do
      :ok
    else
      {:error, "Model '#{model_id}' does not exist in provider '#{provider_id}'"}
    end
  end

  defp ensure_model_not_exists(config, provider_id, model_id) do
    provider = config["providers"][provider_id]
    models = Map.get(provider, "models", [])

    if Enum.any?(models, &(&1["id"] == model_id)) do
      {:error, "Model '#{model_id}' already exists in provider '#{provider_id}'"}
    else
      :ok
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Write helpers: reassign defaults
  # ──────────────────────────────────────────────────────────────

  defp ensure_default_provider(config, provider_id) do
    current = Map.get(config, "defaultProvider")

    if is_binary(current) and current != "" do
      config
    else
      first_model_id =
        get_in(config, ["providers", provider_id, "models", Access.at(0), "id"])

      config
      |> Map.put("defaultProvider", provider_id)
      |> then(fn c ->
        if first_model_id, do: Map.put(c, "defaultModel", first_model_id), else: c
      end)
    end
  end

  defp reassign_default_provider(config, removed_id, remaining_providers) do
    current = config["defaultProvider"]

    if current == removed_id do
      new_default =
        remaining_providers
        |> Map.keys()
        |> List.first()

      updated = Map.put(config, "defaultProvider", new_default)

      # Also reset defaultModel if it was pointing to the old provider
      if config["defaultModel"] != nil do
        new_model =
          remaining_providers
          |> Map.get(new_default, %{})
          |> Map.get("models", [])
          |> Enum.map(& &1["id"])
          |> List.first()

        Map.put(updated, "defaultModel", new_model)
      else
        updated
      end
    else
      config
    end
  end

  defp reassign_default_model(config, _provider_id, removed_model_id) do
    current = config["defaultModel"]

    if current == removed_model_id do
      default_provider = config["providers"][config["defaultProvider"]]

      new_model =
        default_provider
        |> Map.get("models", [])
        |> enabled_models()
        |> Enum.map(& &1["id"])
        |> List.first()

      Map.put(config, "defaultModel", new_model)
    else
      config
    end
  end

  defp catalog_has_no_models?(config) do
    (config["providers"] || %{})
    |> Enum.all?(fn {_id, entry} -> Map.get(entry, "models", []) == [] end)
  end

  defp maybe_assign_first_model_defaults(config, provider_id, model_id, first_in_catalog?) do
    if first_in_catalog? do
      config
      |> Map.put("defaultProvider", provider_id)
      |> Map.put("defaultModel", model_id)
    else
      config
    end
  end
end
