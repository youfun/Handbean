defmodule Handbean.Agent.ModelConfig do
  @moduledoc """
  Global model configuration from `~/.handbean/models.json`.

  This module is the stable public facade for loading, resolving, filtering, and
  mutating the shared model catalog. Workspace restrictions remain in
  `.handbean/settings.jsonc`; provider credentials remain in `models.json` or
  explicitly referenced environment variables. Workspace catalog and resolution
  functions accept `checkout_path: path` for project extension capabilities;
  model allowlists continue to belong to the workspace root.
  """

  alias Handbean.Agent.ModelConfig.{Loader, Mutation, Policy}

  @typedoc "Result of loading model configuration."
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

  @doc "Load the active provider configuration."
  @spec provider_config(Path.t()) :: config_map()
  def provider_config(working_directory \\ File.cwd!()),
    do: Loader.provider_config(working_directory)

  @doc "List enabled models from the active provider."
  @spec available_models(Path.t()) :: [map()]
  def available_models(working_directory \\ File.cwd!()),
    do: Loader.available_models(working_directory)

  @doc "Normalize a provider base URL for the configured API."
  @spec normalize_base_url(String.t() | nil, String.t() | nil) :: String.t()
  def normalize_base_url(base_url, api), do: Loader.normalize_base_url(base_url, api)

  @doc "Convert a JSON API identifier to its internal atom."
  @spec api_to_atom(String.t() | nil) :: atom()
  def api_to_atom(api), do: Loader.api_to_atom(api)

  @doc "Return supported model configuration filenames in priority order."
  @spec config_filenames() :: [String.t()]
  def config_filenames, do: Loader.config_filenames()

  @doc "Return the workspace settings path that owns model policy."
  @spec workspace_policy_path(Path.t()) :: Path.t()
  def workspace_policy_path(workspace_root), do: Policy.workspace_policy_path(workspace_root)

  @doc "Load workspace model policy without falling back on malformed settings."
  @spec load_workspace_policy(Path.t()) :: :unrestricted | {:ok, map()} | {:error, String.t()}
  def load_workspace_policy(workspace_root), do: Policy.load_workspace_policy(workspace_root)

  @doc "List enabled global models allowed by a workspace policy."
  @spec available_models_for_workspace(Path.t()) :: [map()]
  def available_models_for_workspace(workspace_root, opts \\ []),
    do: Policy.available_models_for_workspace(workspace_root, opts)

  @doc "Return the effective default composite model id for a workspace."
  @spec default_model_for_workspace(Path.t()) :: String.t() | nil
  def default_model_for_workspace(workspace_root, opts \\ []),
    do: Policy.default_model_for_workspace(workspace_root, opts)

  @doc "Return the explicitly configured default only when it is currently available."
  @spec strict_default_model_for_workspace(Path.t()) :: String.t() | nil
  def strict_default_model_for_workspace(workspace_root, opts \\ []),
    do: Policy.strict_default_model_for_workspace(workspace_root, opts)

  @doc "Return whether a model is allowed by a workspace policy."
  @spec model_allowed_for_workspace?(Path.t(), String.t()) :: boolean()
  def model_allowed_for_workspace?(workspace_root, model_id, opts \\ []),
    do: Policy.model_allowed_for_workspace?(workspace_root, model_id, opts)

  @doc "Resolve an allowed workspace model to provider configuration."
  @spec resolve_model_for_workspace(Path.t(), String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def resolve_model_for_workspace(workspace_root, composite_id, opts \\ []),
    do: Policy.resolve_model_for_workspace(workspace_root, composite_id, opts)

  @doc "Resolve a composite model id from the unrestricted global catalog."
  @spec resolve_global_model(String.t()) ::
          {:ok, map(), String.t()} | {:error, String.t()}
  def resolve_global_model(composite_id), do: Policy.resolve_global_model(composite_id)

  @doc "Resolve provider configuration for a specific provider and optional model."
  @spec provider_config_for(Path.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def provider_config_for(working_directory \\ File.cwd!(), provider_id, model_id \\ nil),
    do: Loader.provider_config_for(working_directory, provider_id, model_id)

  @doc "Return all enabled models from every provider in the global catalog."
  @spec all_global_models() :: [map()]
  def all_global_models, do: Loader.all_global_models()

  @doc "Return whether a composite or bare model id remains in the catalog."
  @spec model_in_catalog?(term()) :: boolean()
  def model_in_catalog?(model_id), do: Loader.model_in_catalog?(model_id)

  @doc "Return every catalog model, including disabled models."
  @spec catalog_models() :: [map()]
  def catalog_models, do: Loader.catalog_models()

  @doc "Return whether the global model configuration exists and parses."
  @spec global_config_status() :: :ok | {:error, String.t()}
  def global_config_status, do: Loader.global_config_status()

  @doc "Return the resolved path to the global model configuration file."
  @spec config_file_path() :: String.t()
  def config_file_path, do: Mutation.config_file_path()

  @doc "Read the raw string-keyed global model configuration."
  @spec read_config() :: {:ok, map()} | {:error, String.t()}
  def read_config, do: Mutation.read_config()

  @doc "Ensure the global model configuration file exists and is current."
  @spec ensure_config() :: :ok | {:error, String.t()}
  def ensure_config, do: Mutation.ensure_config()

  @doc "Validate and atomically replace the complete global model configuration."
  @spec write_config(map()) :: :ok | {:error, String.t()}
  def write_config(config), do: Mutation.write_config(config)

  @doc "Add a provider to the global model configuration."
  @spec add_provider(String.t(), map()) :: :ok | {:error, String.t()}
  def add_provider(provider_id, provider_attrs),
    do: Mutation.add_provider(provider_id, provider_attrs)

  @doc "Remove a provider and its models from the global configuration."
  @spec remove_provider(String.t()) :: :ok | {:error, String.t()}
  def remove_provider(provider_id), do: Mutation.remove_provider(provider_id)

  @doc "Add a model to an existing provider."
  @spec add_model(String.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def add_model(provider_id, model_id, model_attrs),
    do: Mutation.add_model(provider_id, model_id, model_attrs)

  @doc "Remove a model from an existing provider."
  @spec remove_model(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove_model(provider_id, model_id), do: Mutation.remove_model(provider_id, model_id)

  @doc "Set the default provider using the latest persisted configuration."
  @spec set_default_provider(String.t()) :: :ok | {:error, String.t()}
  def set_default_provider(provider_id), do: Mutation.set_default_provider(provider_id)

  @doc "Set the default provider and model using the latest persisted configuration."
  @spec set_default_model(String.t(), String.t()) :: :ok | {:error, String.t()}
  def set_default_model(provider_id, model_id),
    do: Mutation.set_default_model(provider_id, model_id)

  @doc "Merge provider-level settings into the latest persisted configuration."
  @spec update_provider(String.t(), map()) :: :ok | {:error, String.t()}
  def update_provider(provider_id, attrs), do: Mutation.update_provider(provider_id, attrs)

  @doc "Disable every model for a provider while retaining its catalog rows."
  @spec disable_provider_models(String.t()) :: :ok | {:error, String.t()}
  def disable_provider_models(provider_id), do: Mutation.disable_provider_models(provider_id)

  @doc "Merge model-level settings into the latest persisted configuration."
  @spec update_model(String.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def update_model(provider_id, model_id, attrs),
    do: Mutation.update_model(provider_id, model_id, attrs)

  @doc "Update a provider API key or explicit environment reference."
  @spec update_api_key(String.t(), String.t()) :: :ok | {:error, String.t()}
  def update_api_key(provider_id, api_key), do: Mutation.update_api_key(provider_id, api_key)
end
