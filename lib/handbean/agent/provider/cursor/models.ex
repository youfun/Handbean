defmodule Handbean.Agent.Provider.Cursor.Models do
  @moduledoc """
  Discovers usable Cursor models and their current parameter variants.

  Failures are explicit. This never falls back to another provider or a
  hard-coded substitute model. Cost is omitted here and filled in by settings
  after the models are saved, never written as 0.
  """

  alias Handbean.Agent.Auth.CursorCredential
  alias Handbean.Agent.Provider.Cursor.{Proto, Transport}
  alias Handbean.Agent.Provider.ModelCatalog
  alias Handbean.LlmDbDefaults

  @preferred "composer-2.5"

  @spec discover(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def discover(opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id, "cursor")

    with {:ok, %{api_key: token}} <- CursorCredential.resolve_transport_key(provider_id, opts),
         {:ok, usable_body, available_body} <- fetch_models(token, opts),
         models when models != [] <- build_catalog(usable_body, available_body) do
      {:ok, models}
    else
      [] -> {:error, "Cursor returned no usable models for this account."}
      {:error, :not_found} -> {:error, "Sign in with a Cursor subscription to connect."}
      {:error, message} when is_binary(message) -> {:error, classify(message)}
      {:error, message} -> {:error, classify(inspect(message))}
    end
  end

  @spec preferred_id([map()]) :: String.t() | nil
  def preferred_id(models) do
    ids = Enum.map(models, & &1["id"])

    cond do
      @preferred in ids -> @preferred
      true -> List.first(ids)
    end
  end

  defp fetch_models(token, opts) do
    transport_mod = Keyword.get(opts, :transport_mod, Transport)

    with {:ok, transport} <- transport_mod.connect(Keyword.get(opts, :transport_opts, [])),
         {:ok, transport, usable_body} <-
           transport_mod.get_usable_models(transport, token, opts),
         {:ok, transport, available_body} <-
           transport_mod.available_models(transport, token, opts) do
      _ = transport_mod.close(transport)
      {:ok, usable_body, available_body}
    else
      {:error, reason} ->
        {:error, to_string_reason(reason)}

      {:error, transport, reason} ->
        _ = transport_mod.close(transport)
        {:error, to_string_reason(reason)}
    end
  end

  defp build_catalog(usable_body, available_body) do
    usable =
      usable_body
      |> Proto.decode_models_response()
      |> Enum.map(&to_catalog/1)

    parameterized =
      available_body
      |> Proto.decode_available_models_response()
      |> Enum.flat_map(&parameterized_catalog/1)

    (usable ++ parameterized)
    |> Map.new(&{&1["id"], &1})
    |> Map.values()
    |> Enum.sort_by(& &1["name"])
  end

  defp parameterized_catalog(model) do
    model.variants
    |> Enum.reject(&(&1.parameters == []))
    |> Enum.map(&variant_catalog(model, &1))
    |> Enum.uniq_by(& &1["id"])
  end

  defp variant_catalog(model, variant) do
    context = parameter(variant, "context")
    context_window = context_window(context, model, variant)
    id = variant_id(model.name, variant, context)

    fallback = LlmDbDefaults.enrich_model(model.name, variant_name(model, variant, context))

    fallback
    |> Map.delete("cost")
    |> Map.put("id", id)
    |> Map.put("name", variant_name(model, variant, context))
    |> put_reasoning(reasoning_variant?(variant))
    |> Map.put("input", if(model.supports_images?, do: ["text", "image"], else: ["text"]))
    |> Map.put("cursorRequestedModel", %{
      "modelId" => model.name,
      "maxMode" => variant.max_mode?,
      "parameters" => Enum.map(variant.parameters, &stringify_parameter/1)
    })
    |> maybe_put("contextWindow", context_window)
    |> ModelCatalog.put_upstream(%{available: model, variant: variant})
  end

  defp variant_id(base, variant, context) do
    effort = parameter(variant, "reasoning") || parameter(variant, "effort")
    thinking = parameter(variant, "thinking")
    fast = parameter(variant, "fast")

    remaining =
      variant.parameters
      |> Enum.reject(&(&1.id in ["context", "reasoning", "effort", "thinking", "fast"]))
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&"#{&1.id}-#{&1.value}")

    [
      base,
      if(context in [nil, "", "200k", "272k", "300k"], do: nil, else: context),
      if(variant.max_mode? and context != "1m", do: "max", else: nil),
      effort,
      if(thinking == "true", do: "thinking", else: nil),
      if(fast == "true", do: "fast", else: nil),
      remaining
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("-")
  end

  defp variant_name(model, variant, context) do
    base =
      Enum.find(
        [
          variant.outside_picker_name,
          variant.display_name,
          model.client_display_name,
          model.name
        ],
        &(&1 != "")
      ) || model.name

    base
    |> maybe_append_label(context == "1m", ~r/\b1M\b/i, "1M")
    |> maybe_append_label(parameter(variant, "fast") == "true", ~r/\bfast\b/i, "Fast")
  end

  defp maybe_append_label(base, false, _pattern, _label), do: base

  defp maybe_append_label(base, true, pattern, label) do
    if String.match?(base, pattern), do: base, else: base <> " " <> label
  end

  defp context_window("1m", _model, _variant), do: 1_000_000

  defp context_window(context, model, variant) when is_binary(context) do
    case Regex.run(~r/^(\d+)(k|m)$/i, context) do
      [_, amount, unit] ->
        String.to_integer(amount) * if(String.downcase(unit) == "m", do: 1_000_000, else: 1_000)

      _ ->
        model_context_window(model, variant)
    end
  end

  defp context_window(_context, model, variant), do: model_context_window(model, variant)

  defp model_context_window(model, %{max_mode?: true}) do
    model.max_context_token_limit || model.context_token_limit
  end

  defp model_context_window(model, _variant), do: model.context_token_limit

  defp reasoning_variant?(variant) do
    Enum.any?(variant.parameters, &(&1.id in ["reasoning", "effort"]))
  end

  defp parameter(variant, id) do
    case Enum.find(variant.parameters, &(&1.id == id)) do
      %{value: value} -> value
      nil -> nil
    end
  end

  defp stringify_parameter(parameter) do
    %{"id" => parameter.id, "value" => parameter.value}
  end

  defp to_catalog(model) do
    model.id
    |> LlmDbDefaults.enrich_model(model.name || model.id)
    |> Map.delete("cost")
    |> Map.put("id", model.id)
    |> Map.put("name", model.name || model.id)
    |> put_reasoning(model.thinking?)
    |> ModelCatalog.put_upstream(%{usable: model})
  end

  defp put_reasoning(model, true), do: Map.put(model, "reasoning", true)

  defp put_reasoning(model, false) do
    model
    |> Map.put("reasoning", false)
    |> Map.delete("reasoningLevels")
    |> Map.delete("defaultReasoning")
    |> Map.delete("thinkingLevelMap")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp classify(message) do
    down = String.downcase(message)

    cond do
      String.contains?(down, "429") or String.contains?(down, "rate") ->
        "Cursor rate limited this account. Try again later."

      String.contains?(down, "401") or String.contains?(down, "403") or
          String.contains?(down, "expired") ->
        "Cursor subscription expired. Sign in with Cursor to reconnect."

      String.contains?(down, "no usable") ->
        message

      true ->
        "Cursor model discovery failed: #{message}"
    end
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end
