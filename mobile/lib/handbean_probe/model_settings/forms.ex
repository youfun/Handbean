defmodule HandbeanProbe.ModelSettings.Forms do
  @moduledoc """
  Form constructors and catalog lookups for the native model settings.

  Pure helpers shared by `HandbeanProbe.ModelSettings.Providers` (actions) and the
  render modules: build model/provider forms from `models.json` entries, fill
  names from the LLMDB catalog, and generate provider ids. Reading the stored
  catalog goes through `Handbean.Agent.ModelConfig.read_config/0` only.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  alias Handbean.Agent.ModelConfig
  alias Handbean.Settings.ModelCatalog
  alias HandbeanProbe.Bridge.Payload

  @default_api "openai-chat-completions"

  @doc "Read the stored catalog. Errors are mapped to one user-facing notice."
  @spec read_config() :: {:ok, map()} | {:error, String.t()}
  def read_config do
    case ModelConfig.read_config() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> {:error, gettext("Could not read model configuration")}
    end
  end

  @doc "Stored provider entry, or `nil` when missing or unreadable."
  def provider_entry(provider_id) do
    case read_config() do
      {:ok, config} -> config["providers"][provider_id]
      _ -> nil
    end
  end

  def new_model_form(provider) do
    %{
      provider: provider.id,
      provider_name: provider.name,
      model: "",
      name: "",
      reasoning: false,
      context_window: "",
      max_tokens: "",
      catalog_models: catalog_models(provider.id)
    }
  end

  def model_form(entry, meta) do
    %{
      provider: "",
      provider_name: entry["name"] || "",
      model: "",
      name: Payload.first(meta, ["name", "id"]) || "",
      reasoning: meta["reasoning"] == true,
      context_window: optional_int_string(meta["contextWindow"]),
      max_tokens: optional_int_string(meta["maxTokens"]),
      catalog_models: []
    }
  end

  def provider_form(nil, nil) do
    %{
      provider: nil,
      name: "",
      base_url: "",
      api_key: "",
      api: @default_api,
      key_status: :missing,
      key_preview: nil
    }
  end

  def provider_form(provider, entry) do
    %{
      provider: provider,
      name: entry["name"] || provider,
      base_url: entry["baseUrl"] || "",
      api_key: "",
      api: entry["api"] || @default_api,
      key_status: ModelCatalog.key_status(entry),
      key_preview: key_preview(entry["apiKey"])
    }
  end

  def default_api, do: @default_api

  def protocols do
    [
      "openai-chat-completions",
      "openai-responses",
      "anthropic-messages",
      "stepfun-step-plan",
      "ollama-cloud",
      "opencode-go"
    ]
  end

  @doc "Fill the display name from the catalog when the user picks a known model."
  def hydrate(form, :model, value) do
    case Enum.find(form[:catalog_models] || [], &(&1.id == value)) do
      nil -> form
      entry -> maybe_fill(form, :name, entry.name)
    end
  end

  def hydrate(form, _field, _value), do: form

  def catalog_model_name(form, model) do
    case Enum.find(form.catalog_models || [], &(&1.id == model)) do
      nil -> form.name
      entry -> entry.name
    end
  end

  def catalog_model_label(%{model: model, catalog_models: models}) do
    case Enum.find(models, &(&1.id == model)) do
      nil -> if(model in [nil, ""], do: gettext("Custom name"), else: model)
      entry -> entry.name
    end
  end

  def catalog_models(provider_id) when is_binary(provider_id) and provider_id != "" do
    atom =
      try do
        String.to_existing_atom(provider_id)
      rescue
        ArgumentError -> nil
      end

    if atom && Code.ensure_loaded?(LLMDB) do
      try do
        LLMDB.models(atom)
        |> Enum.take(40)
        |> Enum.map(fn model ->
          %{id: to_string(model.id), name: to_string(Map.get(model, :name) || model.id)}
        end)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  def catalog_models(_), do: []

  def generate_provider_id(name, existing) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    base = if base == "", do: "provider", else: base
    unique_provider_id(base, MapSet.new(existing))
  end

  def put_optional_int(map, _key, :omit), do: map
  def put_optional_int(map, key, value), do: Map.put(map, key, value)

  def maybe_put_key(provider, api_key) do
    if String.trim(api_key) == "",
      do: provider,
      else: Map.put(provider, "apiKey", String.trim(api_key))
  end

  def optional_int_string(n) when is_integer(n), do: Integer.to_string(n)
  def optional_int_string(_), do: ""

  defp key_preview(""), do: nil
  defp key_preview("env:" <> _var), do: "••••••••"

  defp key_preview(key) when is_binary(key) do
    if String.length(key) <= 4,
      do: "••••••••",
      else: "••••" <> String.slice(key, -4, 4)
  end

  defp key_preview(_), do: nil

  defp unique_provider_id(base, existing) do
    if MapSet.member?(existing, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{base}-#{n}"
        unless MapSet.member?(existing, candidate), do: candidate
      end)
    else
      base
    end
  end

  defp maybe_fill(form, field, value) do
    current = String.trim(to_string(Map.get(form, field) || ""))

    if current == "" and value not in [nil, ""],
      do: Map.put(form, field, value),
      else: form
  end
end
