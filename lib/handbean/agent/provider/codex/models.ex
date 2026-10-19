defmodule Handbean.Agent.Provider.Codex.Models do
  @moduledoc "Authenticated Codex catalog; never uses the Platform API model list."

  alias Handbean.Agent.Auth.CodexCredential
  alias Handbean.Agent.Provider.{Codex, ModelCatalog}
  alias Handbean.LlmDbDefaults

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
          if model["visibility"] == "hide", do: [], else: [{id, model}]

        _ ->
          []
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    case visible do
      [] ->
        {:error, "No Codex models were returned. The existing model list was kept."}

      entries ->
        fallbacks =
          entries
          |> Enum.map(fn {id, model} -> {id, model["display_name"] || id} end)
          |> LlmDbDefaults.enrich_models()

        catalog =
          Enum.map(entries, fn {id, model} ->
            fallback = fallbacks |> Map.fetch!(id) |> Map.delete("cost")
            ModelCatalog.normalize_entry(model, fallback)
          end)

        {:ok, catalog}
    end
  end

  @doc """
  Keep enabled flags from the stored catalog when a refresh replaces rows.

  Remote order and metadata win. Models the account no longer returns are
  dropped, matching the subscription catalog rather than a local union.
  """
  def preserve_enabled(models, existing) when is_list(models) and is_list(existing) do
    ModelCatalog.refresh_merge(existing, models, missing: :drop)
  end
end
