defmodule Handbean.MCP.OAuth.Discovery do
  @moduledoc false

  alias Handbean.MCP.OAuth.{Config, Network}

  def discover(cfg) do
    with {:ok, metadata_url, challenged_scopes} <- resource_location(cfg),
         {:ok, resource} <- fetch_first(metadata_url, cfg.url),
         true <- resource["resource"] == cfg.url,
         true <- strings?(Map.get(resource, "scopes_supported", [])),
         {:ok, issuer} <- issuer(resource, cfg.oauth),
         {:ok, metadata} <- fetch_first(issuer_urls(issuer), cfg.url),
         :ok <- validate_metadata(metadata, issuer, cfg.url) do
      {:ok,
       %{
         "issuer" => issuer,
         "authorization_endpoint" => metadata["authorization_endpoint"],
         "token_endpoint" => metadata["token_endpoint"],
         "revocation_endpoint" => metadata["revocation_endpoint"],
         "authorization_response_iss_parameter_supported" =>
           metadata["authorization_response_iss_parameter_supported"] == true,
         "scopes" =>
           Map.get(
             cfg.oauth,
             "scopes",
             challenged_scopes || Map.get(resource, "scopes_supported", [])
           )
       }}
    else
      _ -> {:error, :oauth_discovery_failed}
    end
  end

  defp resource_location(cfg) do
    if cfg.oauth["resource_metadata_url"] do
      {:ok, [cfg.oauth["resource_metadata_url"]], nil}
    else
      case Network.request(:get, cfg.url, cfg.url, headers: %{"accept" => "application/json"}) do
        {:ok, %{status: 401} = response} ->
          challenge =
            Req.Response.get_header(response, "www-authenticate")
            |> Enum.find("", &String.match?(&1, ~r/^Bearer\s/i))

          url = parameter(challenge, "resource_metadata")
          scope = parameter(challenge, "scope")
          urls = if url, do: [url], else: resource_urls(cfg.url)
          {:ok, urls, if(scope, do: String.split(scope), else: nil)}

        {:ok, _} ->
          {:ok, resource_urls(cfg.url), nil}

        error ->
          error
      end
    end
  end

  defp parameter(header, name) do
    case Regex.run(
           Regex.compile!("(?:^Bearer\\s+|,\\s*|\\s+)" <> name <> "=\"([^\"\\\\]*)\"", "i"),
           header
         ) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp resource_urls(url) do
    uri = URI.parse(url)

    Enum.uniq([
      "/.well-known/oauth-protected-resource" <> (uri.path || ""),
      "/.well-known/oauth-protected-resource"
    ])
    |> Enum.map(&URI.to_string(%{uri | path: &1, query: nil}))
  end

  defp issuer_urls(issuer) do
    uri = URI.parse(issuer)
    path = if uri.path == "/", do: "", else: uri.path || ""

    [
      "/.well-known/oauth-authorization-server" <> path,
      "/.well-known/openid-configuration" <> path,
      path <> "/.well-known/openid-configuration"
    ]
    |> Enum.uniq()
    |> Enum.map(&URI.to_string(%{uri | path: &1}))
  end

  defp issuer(%{"authorization_servers" => issuers}, oauth) when is_list(issuers) do
    selected = oauth["issuer"] || List.first(issuers)

    if is_binary(selected) and selected in issuers and Config.url?(selected),
      do: {:ok, selected},
      else: {:error, :invalid_issuer}
  end

  defp issuer(_, _), do: {:error, :invalid_issuer}

  defp fetch_first(urls, resource) do
    Enum.reduce_while(urls, {:error, :metadata_unavailable}, fn url, _acc ->
      case Network.request(:get, url, resource, headers: %{"accept" => "application/json"}) do
        {:ok, %{status: 200, body: body}} ->
          case Handbean.JSON.decode(body) do
            {:ok, data} when is_map(data) -> {:halt, {:ok, data}}
            _ -> {:halt, {:error, :invalid_metadata}}
          end

        {:ok, %{status: status}} when status in [404, 405] ->
          {:cont, {:error, :metadata_unavailable}}

        _ ->
          {:halt, {:error, :metadata_unavailable}}
      end
    end)
  end

  defp supported?(values, value), do: strings?(values) and value in values

  defp strings?(values),
    do:
      is_list(values) and length(values) <= 100 and
        Enum.all?(
          values,
          &(is_binary(&1) and byte_size(&1) in 1..2048 and
              not String.match?(&1, ~r/[\x00-\x20\x7f]/))
        )

  defp validate_metadata(metadata, issuer, resource) do
    endpoints =
      Enum.reject(
        [
          metadata["authorization_endpoint"],
          metadata["token_endpoint"],
          metadata["revocation_endpoint"]
        ],
        &is_nil/1
      )

    iss_supported = metadata["authorization_response_iss_parameter_supported"]

    if metadata["issuer"] == issuer and is_binary(metadata["authorization_endpoint"]) and
         is_binary(metadata["token_endpoint"]) and iss_supported in [nil, false, true] and
         supported?(metadata["code_challenge_methods_supported"], "S256") and
         supported?(metadata["response_types_supported"], "code") and
         supported?(metadata["token_endpoint_auth_methods_supported"], "none") and
         Enum.all?(
           endpoints,
           &(Config.url?(&1) and match?({:ok, _, _}, Network.destination(&1, resource)))
         ) do
      :ok
    else
      {:error, :invalid_metadata}
    end
  end
end
