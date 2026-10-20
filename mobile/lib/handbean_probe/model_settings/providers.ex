defmodule HandbeanProbe.ModelSettings.Providers do
  @moduledoc """
  Provider / model catalog actions for the native model settings.

  Owns the editor state transitions (add, edit, save, delete with reference
  replacement) and persists through `Handbean.Agent.ModelConfig`. Reference
  scanning is `Handbean.Settings.ModelRefs`. Every function takes and returns the
  `HandbeanProbe.ModelSettings` state map.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  alias Handbean.Agent.ModelConfig
  alias Handbean.Settings.{ModelCatalog, ModelRefs}
  alias HandbeanProbe.ModelSettings
  alias HandbeanProbe.ModelSettings.Forms
  alias HandbeanProbe.SettingsSupport

  @doc """
  Providers of the stored catalog, sorted by display name.

  Each entry carries `key_status` and `max_tokens` so rendering never reads
  `models.json` again.
  """
  def list do
    case Forms.read_config() do
      {:ok, config} ->
        (config["providers"] || %{})
        |> Enum.map(fn {id, entry} ->
          %{
            id: id,
            name: display_name(id, entry),
            model_count: length(entry["models"] || []),
            key_status: ModelCatalog.key_status(entry),
            max_tokens: entry["maxTokens"],
            fetchable: Handbean.Agent.Provider.ModelCatalog.fetchable?(entry)
          }
        end)
        |> Enum.sort_by(& &1.name)

      _ ->
        []
    end
  end

  def pick_selected([], _previous), do: nil

  def pick_selected(providers, previous) do
    if Enum.any?(providers, &(&1.id == previous)),
      do: previous,
      else: hd(providers).id
  end

  def selected_entry(state), do: Enum.find(state.providers, &(&1.id == state.selected_provider))

  def label(state, provider_id) do
    case Enum.find(state.providers, &(&1.id == provider_id)) do
      nil -> provider_id
      provider -> provider.name
    end
  end

  # ── editor actions ──

  def add_provider(state) do
    %{
      state
      | editing: :new_provider,
        notice: nil,
        confirm: nil,
        form: Forms.provider_form(nil, nil)
    }
  end

  def select(state, provider) do
    if Enum.any?(state.providers, &(&1.id == provider)),
      do: %{state | selected_provider: provider, notice: nil},
      else: state
  end

  def add_model(state) do
    case selected_entry(state) do
      nil ->
        %{state | notice: gettext("Add a provider first")}

      provider ->
        %{state | editing: :new, notice: nil, confirm: nil, form: Forms.new_model_form(provider)}
    end
  end

  def edit_model(state, provider, model) do
    with {:ok, config} <- Forms.read_config(),
         %{} = entry <- config["providers"][provider],
         %{} = meta <- Enum.find(entry["models"], &(&1["id"] == model)) do
      %{
        state
        | editing: {provider, model},
          selected_provider: provider,
          notice: nil,
          confirm: nil,
          form:
            Forms.model_form(entry, meta)
            |> Map.merge(%{
              provider: provider,
              provider_name: entry["name"] || provider,
              model: model,
              catalog_models: Forms.catalog_models(provider)
            })
      }
    else
      _ -> %{state | notice: gettext("Could not read model configuration")}
    end
  end

  def edit_provider(state, provider) do
    with {:ok, config} <- Forms.read_config(),
         %{} = entry <- config["providers"][provider] do
      %{
        state
        | editing: {:provider, provider},
          selected_provider: provider,
          notice: nil,
          confirm: nil,
          form: Forms.provider_form(provider, entry)
      }
    else
      _ -> %{state | notice: gettext("Could not read model configuration")}
    end
  end

  def catalog_model(%{form: nil} = state, _model), do: state

  def catalog_model(state, model) do
    form = Forms.hydrate(%{state.form | model: model}, :model, model)

    name =
      if String.trim(form.name) == "", do: Forms.catalog_model_name(form, model), else: form.name

    %{state | form: %{form | name: name}}
  end

  def set_api(state, api), do: put_in(state, [:form, :api], api)

  def toggle_reasoning(state), do: put_in(state, [:form, :reasoning], not state.form.reasoning)

  def cancel(state), do: %{state | editing: nil, form: nil, notice: nil, confirm: nil}

  # ── persistence ──

  def save_model(state, workspace) do
    case persist_model(state) do
      :ok -> ModelSettings.reload(state, workspace, gettext("Model saved"))
      {:error, reason} -> %{state | notice: to_string(reason)}
    end
  end

  def toggle_enabled(state, provider_id, model_id, enabled, workspace) when is_boolean(enabled) do
    case ModelConfig.update_model(provider_id, model_id, %{"enabled" => enabled}) do
      :ok ->
        ModelSettings.reload(state, workspace, nil)

      {:error, reason} ->
        %{state | notice: to_string(reason)}
    end
  end

  def save_provider(state, workspace) do
    case persist_provider(state) do
      {:ok, provider_id} ->
        %{
          ModelSettings.reload(state, workspace, gettext("Provider saved"))
          | selected_provider: provider_id
        }

      {:error, reason} ->
        %{state | notice: to_string(reason)}
    end
  end

  defp persist_model(state) do
    f = state.form
    provider_id = String.trim(f.provider || "")
    model_id = String.trim(f.model || "")
    display_name = String.trim(f.name || "")
    display_name = if display_name == "", do: model_id, else: display_name

    with :ok <- require_model(provider_id, model_id),
         {:ok, context_window} <- SettingsSupport.parse_optional_positive(f.context_window),
         {:ok, max_tokens} <- SettingsSupport.parse_optional_positive(f.max_tokens),
         {:ok, config} <- Forms.read_config(),
         %{} = provider <- config["providers"][provider_id] do
      models = provider["models"] || []
      existing = Enum.find(models, &(&1["id"] == model_id))

      if state.editing == :new and existing do
        {:error, gettext("This model already exists. Use edit instead.")}
      else
        attrs =
          (existing || %{})
          |> Map.merge(%{"name" => display_name, "reasoning" => f.reasoning})
          |> Forms.put_optional_int("contextWindow", context_window)
          |> Forms.put_optional_int("maxTokens", max_tokens)
          |> Map.delete("id")

        if existing do
          ModelConfig.update_model(provider_id, model_id, attrs)
        else
          ModelConfig.add_model(provider_id, model_id, attrs)
        end
      end
    else
      nil -> {:error, gettext("Add a provider first")}
      other -> other
    end
  end

  defp persist_provider(state) do
    f = state.form
    name = String.trim(f.name || "")
    base_url = String.trim(f.base_url || "")

    with :ok <- require_display_name(name),
         :ok <- require_https(base_url),
         {:ok, config} <- Forms.read_config() do
      providers = config["providers"] || %{}

      attrs =
        %{
          "name" => name,
          "baseUrl" => base_url,
          "api" => f.api || Forms.default_api()
        }
        |> Forms.maybe_put_key(f.api_key)

      case state.editing do
        :new_provider ->
          provider_id = Forms.generate_provider_id(name, Map.keys(providers))

          case ModelConfig.add_provider(provider_id, Map.put(attrs, "models", [])) do
            :ok -> {:ok, provider_id}
            other -> other
          end

        {:provider, provider_id} ->
          if Map.has_key?(providers, provider_id) do
            case ModelConfig.update_provider(provider_id, attrs) do
              :ok -> {:ok, provider_id}
              other -> other
            end
          else
            {:error, gettext("Could not read model configuration")}
          end

        _ ->
          {:error, gettext("Could not read model configuration")}
      end
    end
  end

  # ── delete flow ──

  @doc "Scan references synchronously and open the delete confirmation."
  def ask_delete(state, :delete_model, provider, model) do
    delete_confirm(state, :delete_model, provider, model, ModelRefs.find(:model, provider, model))
  end

  def ask_delete(state, :delete_provider, provider, _model) do
    delete_confirm(
      state,
      :delete_provider,
      provider,
      nil,
      ModelRefs.find(:provider, provider, nil)
    )
  end

  @doc """
  Open the delete confirmation from a finished reference scan.

  `refs_result` is `Handbean.Settings.ModelRefs.find/3` output; skipped workspaces
  land in `confirm.ref_errors` so the sheet can say the scan was incomplete.
  """
  def delete_confirm(state, :delete_model, provider, model, %{refs: refs, errors: errors}) do
    last? = Enum.count(state.models, &(&1.provider_id == provider)) == 1

    %{
      state
      | confirm: %{
          kind: :delete_model,
          provider: provider,
          model: model,
          refs: refs,
          ref_errors: errors,
          replacement: nil,
          last_model?: last?
        }
    }
  end

  def delete_confirm(state, :delete_provider, provider, _model, %{refs: refs, errors: errors}) do
    count = Enum.count(state.models, &(&1.provider_id == provider))
    last_provider? = length(state.providers) == 1

    %{
      state
      | confirm: %{
          kind: :delete_provider,
          provider: provider,
          models_count: count,
          refs: refs,
          ref_errors: errors,
          replacement: nil,
          last_provider?: last_provider?
        }
    }
  end

  def set_replacement(%{confirm: nil} = state, _id), do: state
  def set_replacement(state, id), do: %{state | confirm: Map.put(state.confirm, :replacement, id)}

  def confirm_delete(%{confirm: %{kind: kind, refs: refs} = confirm} = state, workspace) do
    blocking = ModelRefs.blocking(refs)

    cond do
      confirm[:last_model?] ->
        %{
          state
          | notice: gettext("This is the provider's only model. Delete the provider instead.")
        }

      confirm[:last_provider?] ->
        %{
          state
          | notice: gettext("This is the only provider. The catalog must keep at least one.")
        }

      blocking != [] and !confirm.replacement ->
        %{state | notice: gettext("Choose a replacement before deleting a referenced entry")}

      blocking != [] ->
        case ModelRefs.replace_all(blocking, confirm.replacement) do
          :ok -> do_delete(state, workspace, kind, confirm)
          {:error, reason} -> %{state | notice: to_string(reason)}
        end

      true ->
        do_delete(state, workspace, kind, confirm)
    end
  end

  def confirm_delete(state, _workspace), do: state

  defp do_delete(state, workspace, :delete_model, confirm) do
    case ModelConfig.remove_model(confirm.provider, confirm.model) do
      :ok -> ModelSettings.reload(state, workspace, gettext("Model deleted"))
      {:error, reason} -> %{state | notice: to_string(reason)}
    end
  end

  defp do_delete(state, workspace, :delete_provider, confirm) do
    case ModelConfig.remove_provider(confirm.provider) do
      :ok -> ModelSettings.reload(state, workspace, gettext("Provider deleted"))
      {:error, reason} -> %{state | notice: to_string(reason)}
    end
  end

  # ── validation ──

  defp require_model("", _), do: {:error, gettext("Add a provider first")}
  defp require_model(_, ""), do: {:error, gettext("Enter a model name, for example gpt-4o")}
  defp require_model(_, _), do: :ok

  defp require_display_name(""), do: {:error, gettext("Display name is required")}
  defp require_display_name(_), do: :ok

  defp require_https(url) when is_binary(url) do
    case URI.new(url) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         userinfo: nil,
         query: nil,
         fragment: nil
       }}
      when is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, gettext("Enter a valid HTTPS Base URL")}
    end
  end

  defp require_https(_), do: {:error, gettext("Enter a valid HTTPS Base URL")}

  defp display_name(id, entry) when is_map(entry) do
    case String.trim(to_string(entry["name"] || "")) do
      "" -> id
      name -> name
    end
  end

  defp display_name(id, _), do: id
end
