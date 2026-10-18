defmodule Handbean.Settings.ModelRefs do
  @moduledoc """
  Find and rewrite settings that reference a catalog provider or model.

  Scans `models.json` defaults, global `settings.json` Model/AI fields, and
  every registered workspace's `.handbean/settings.jsonc` (Model/AI fields and the
  policy default). Used before deleting a catalog entry so the user can pick a
  replacement.

  A workspace whose settings file cannot be read is skipped, reported in
  `:errors`, and logged; it never aborts the scan.
  """

  alias Handbean.Agent.ModelConfig
  alias Handbean.Settings
  alias Handbean.Settings.{ModelAIOverride, ModelAISettings, ModelPolicy}
  alias Handbean.WorkspaceStore

  require Logger

  @type ref :: %{
          required(:source) =>
            :catalog_default_provider
            | :catalog_default_model
            | :global_model_ai
            | :workspace_model_ai
            | :workspace_policy_default,
          optional(atom()) => term()
        }

  @type scan_error :: %{workspace_id: term(), path: Path.t(), reason: term()}

  @type result :: %{refs: [ref()], errors: [scan_error()]}

  @doc """
  Find references to a provider (`model_id` ignored) or to one model.

  Returns `%{refs: refs, errors: errors}` where `errors` lists workspaces
  that were skipped because their settings file could not be read.
  """
  @spec find(:provider | :model, String.t(), String.t() | nil) :: result()
  def find(:provider, provider_id, _model_id) do
    models =
      ModelConfig.all_global_models()
      |> Enum.filter(&(&1.provider_id == provider_id))
      |> Enum.map(& &1.id)

    catalog = catalog_refs(provider_id, nil)
    %{refs: settings, errors: errors} = settings_refs(&(&1 in models or prefix?(&1, provider_id)))
    %{refs: catalog ++ settings, errors: errors}
  end

  def find(:model, provider_id, model_id) do
    composite = "#{provider_id}/#{model_id}"
    catalog = catalog_refs(provider_id, model_id)
    %{refs: settings, errors: errors} = settings_refs(&(&1 == composite))
    %{refs: catalog ++ settings, errors: errors}
  end

  @doc """
  References that block deletion until replaced.

  Catalog defaults are not blocking: `ModelConfig` reassigns them on delete.
  """
  @spec blocking([ref()]) :: [ref()]
  def blocking(refs) when is_list(refs) do
    Enum.reject(refs, &(&1.source in [:catalog_default_provider, :catalog_default_model]))
  end

  @doc """
  Point every ref at `replacement` (a composite `provider/model` id).

  Stops at the first failure.
  """
  @spec replace_all([ref()], String.t()) :: :ok | {:error, term()}
  def replace_all(refs, replacement) when is_list(refs) and is_binary(replacement) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case replace(ref, replacement) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp catalog_refs(provider_id, model_id) do
    case ModelConfig.read_config() do
      {:ok, config} ->
        provider_ref =
          if config["defaultProvider"] == provider_id,
            do: [%{source: :catalog_default_provider, provider_id: provider_id}],
            else: []

        model_ref =
          if model_id && config["defaultProvider"] == provider_id &&
               config["defaultModel"] == model_id,
             do: [
               %{source: :catalog_default_model, provider_id: provider_id, model_id: model_id}
             ],
             else: []

        model_ref ++ provider_ref

      {:error, _reason} ->
        []
    end
  end

  defp settings_refs(match?) do
    {:ok, global} = Settings.load_global()

    global_refs =
      global
      |> Map.get("model_ai", %{})
      |> model_ai_values()
      |> Enum.filter(fn {_field, value} -> match?.(value) end)
      |> Enum.map(fn {field, value} ->
        %{source: :global_model_ai, field: field, value: value}
      end)

    {workspace_refs, errors} =
      WorkspaceStore.list()
      |> Enum.reduce({[], []}, fn workspace, {refs, errors} ->
        case workspace_refs(workspace, match?) do
          {:ok, found} -> {refs ++ found, errors}
          {:error, error} -> {refs, errors ++ [error]}
        end
      end)

    refs = Enum.uniq(global_refs ++ workspace_refs)
    %{refs: refs, errors: errors}
  end

  defp workspace_refs(workspace, match?) do
    path = workspace["path"]

    case Settings.load_workspace(path) do
      {:ok, settings} ->
        model_ai = Map.get(settings, "model_ai", %{})

        ai_refs =
          model_ai
          |> model_ai_values()
          |> Enum.filter(fn {_field, value} -> match?.(value) end)
          |> Enum.map(fn {field, value} ->
            %{
              source: :workspace_model_ai,
              workspace_id: workspace["id"],
              path: path,
              field: field,
              value: value
            }
          end)

        {:ok, ai_refs ++ policy_refs(workspace, settings, match?)}

      {:error, reason} ->
        Logger.warning(
          "[ModelRefs] Skipping workspace #{inspect(workspace["id"])} (#{path}): #{inspect(reason)}"
        )

        {:error, %{workspace_id: workspace["id"], path: path, reason: reason}}
    end
  end

  defp policy_refs(workspace, settings, match?) do
    with %{} = policy <- Map.get(settings, "models"),
         value when is_binary(value) <- ModelPolicy.default_model(policy),
         true <- match?.(value) do
      [
        %{
          source: :workspace_policy_default,
          workspace_id: workspace["id"],
          path: workspace["path"],
          value: value
        }
      ]
    else
      _ -> []
    end
  end

  defp model_ai_values(map) when is_map(map) do
    om = Map.get(map, "observational_memory") || %{}

    [
      {:default_model, map["default_model"]},
      {:om_model, om["model"]},
      {:advisor_model, get_in(map, ["advisor", "model"])}
    ]
    |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)
  end

  defp model_ai_values(_), do: []

  defp replace(%{source: :catalog_default_provider}, replacement) do
    case String.split(replacement, "/", parts: 2) do
      [provider, _model] -> ModelConfig.set_default_provider(provider)
      _ -> {:error, :invalid_replacement}
    end
  end

  defp replace(%{source: :catalog_default_model}, replacement) do
    case String.split(replacement, "/", parts: 2) do
      [provider, model] -> ModelConfig.set_default_model(provider, model)
      _ -> {:error, :invalid_replacement}
    end
  end

  defp replace(%{source: :global_model_ai, field: field}, replacement) do
    {:ok, global} = Settings.load_global()
    current = ModelAISettings.new(Map.get(global, "model_ai", %{}))
    ModelAIOverride.save(:global, Map.put(current, field, replacement))
  end

  defp replace(%{source: :workspace_model_ai, path: path, field: field}, replacement) do
    current = Settings.effective_model_ai(path)
    ModelAIOverride.save({:workspace, path}, Map.put(current, field, replacement))
  end

  defp replace(%{source: :workspace_policy_default, path: path}, replacement) do
    form = ModelPolicy.form(path)
    ModelPolicy.save(path, %{form | default_model: replacement})
  end

  defp replace(_ref, _replacement), do: :ok

  defp prefix?(id, provider_id) when is_binary(id) and is_binary(provider_id) do
    String.starts_with?(id, provider_id <> "/")
  end

  defp prefix?(_, _), do: false
end
