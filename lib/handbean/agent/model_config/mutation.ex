defmodule Handbean.Agent.ModelConfig.Mutation do
  @moduledoc false

  alias Handbean.Agent.ModelCapabilities
  alias Handbean.Agent.ModelConfig.Loader

  require Logger

  @config_path_env "HANDBEAN_MODELS_FILE"
  @global_config_path "~/.handbean/models.json"

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
    with_config_lock(fn ->
      path = config_file_path()

      if File.exists?(path) do
        upgrade_stepfun_preview()
      else
        with {:ok, body} <- initial_config_body(),
             :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- atomic_write(path, body) do
          :ok
        else
          {:error, reason} -> {:error, "Failed to create model config: #{inspect(reason)}"}
        end
      end
    end)
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
    lock = {{Handbean.Agent.ModelConfig, config_file_path()}, self()}

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

    with :ok <- write_private_temp(tmp_path, content) do
      try do
        File.chmod!(tmp_path, mode)
        File.rename!(tmp_path, path)
        :ok
      rescue
        e in File.Error ->
          File.rm(tmp_path)
          {:error, e}
      end
    end
  end

  defp write_private_temp(tmp_path, content) do
    case File.open(tmp_path, [:write, :exclusive], fn device ->
           try do
             File.chmod!(tmp_path, 0o600)
             IO.binwrite(device, content)
           rescue
             e in File.Error ->
               {:error, e}

             e in ErlangError ->
               {:error, %File.Error{reason: e.original, action: "write to file", path: tmp_path}}
           end
         end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, %File.Error{} = error}} ->
        File.rm(tmp_path)
        {:error, error}

      {:error, reason} ->
        {:error, %File.Error{reason: reason, action: "open", path: tmp_path}}
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
        |> Loader.enabled_models()
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
