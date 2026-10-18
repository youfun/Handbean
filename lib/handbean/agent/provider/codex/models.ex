defmodule Handbean.Agent.Provider.Codex.Models do
  @moduledoc "Authenticated Codex catalog; never uses the Platform API model list."

  alias Handbean.Agent.Auth.CodexCredential
  alias Handbean.Agent.Provider.Codex

  # Codex filters /models by this query param. The live catalog can hide a
  # model even when the advertised client is above that model's
  # minimal_client_version. Keep this on the current stable Codex CLI:
  # 0.156.1 omitted gpt-6.1-sol, while rust-v0.163.0 returns it.
  @client_version "0.163.0"

  def discover(opts \\ []) do
    with {:ok, auth} <- CodexCredential.resolve_transport_key("openai_codex", opts) do
      req =
        Keyword.get(
          opts,
          :req_module,
          Application.get_env(:handbean, :codex_models_req_module, Req)
        )

      headers = List.keyreplace(Codex.headers(auth), "accept", 0, {"accept", "application/json"})

      case req.get("https://chatgpt.com/backend-api/codex/models",
             headers: headers,
             params: [client_version: @client_version],
             retry: false,
             redirect: false,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000]
           ) do
        {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
          parse_models(models)

        {:ok, %{status: status}} ->
          {:error,
           "Codex model discovery failed (HTTP #{status}). The existing model list was kept."}

        {:error, _} ->
          {:error, "Codex model discovery unavailable. The existing model list was kept."}
      end
    end
  end

  defp parse_models(models) do
    visible =
      Enum.flat_map(models, fn
        %{"slug" => id} = model when is_binary(id) and id != "" ->
          if model["visibility"] == "hide" do
            []
          else
            [catalog_model(id, model)]
          end

        _ ->
          []
      end)

    case visible do
      [] -> {:error, "No Codex models were returned. The existing model list was kept."}
      models -> {:ok, Enum.uniq_by(models, & &1["id"])}
    end
  end

  @doc """
  Keep enabled flags from the stored catalog when a refresh replaces rows.

  Remote order and metadata win. Models the account no longer returns are
  dropped, matching the subscription catalog rather than a local union.
  """
  def preserve_enabled(models, existing) when is_list(models) and is_list(existing) do
    enabled =
      Map.new(existing, fn
        %{"id" => id, "enabled" => enabled} when is_binary(id) and is_boolean(enabled) ->
          {id, enabled}

        _ ->
          {nil, nil}
      end)

    Enum.map(models, fn model ->
      case Map.get(enabled, model["id"]) do
        enabled when is_boolean(enabled) -> Map.put(model, "enabled", enabled)
        _ -> model
      end
    end)
  end

  defp catalog_model(id, model) do
    levels = reasoning_levels(model["supported_reasoning_levels"])

    %{
      "id" => id,
      "name" => model["display_name"] || id,
      "reasoning" => levels != [],
      "input" => model["input_modalities"] || ["text"],
      "contextWindow" => model["context_window"]
    }
    |> maybe_put("reasoningLevels", levels)
    |> maybe_put("defaultReasoning", model["default_reasoning_level"])
  end

  defp reasoning_levels(levels) when is_list(levels) do
    levels
    |> Enum.flat_map(fn
      %{"effort" => effort} when is_binary(effort) and effort != "" -> [effort]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp reasoning_levels(_), do: []

  defp maybe_put(model, _key, value) when value in [nil, ""], do: model
  defp maybe_put(model, _key, []), do: model
  defp maybe_put(model, key, value), do: Map.put(model, key, value)
end
