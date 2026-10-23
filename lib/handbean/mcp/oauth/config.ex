defmodule Handbean.MCP.OAuth.Config do
  @moduledoc "Validation for explicitly enabled MCP OAuth public clients."

  alias Handbean.WebFetch.Address

  @keys ~w(client_id issuer scopes resource_metadata_url)

  def validate(%{"oauth" => oauth, "url" => url} = raw) when is_map(oauth) do
    headers = Map.get(raw, "headers", %{})

    with true <- Map.keys(oauth) -- @keys == [],
         true <- text?(oauth["client_id"]),
         true <-
           Enum.all?(["issuer", "resource_metadata_url"], &(is_nil(oauth[&1]) or url?(oauth[&1]))),
         true <- valid_scopes?(Map.get(oauth, "scopes", [])),
         true <- url?(url),
         true <- is_map(headers) and map_size(headers) == 0 do
      :ok
    else
      _ ->
        {:error,
         "OAuth requires an HTTP URL, public client_id, optional issuer/metadata URL and scopes; secret fields and custom headers are not supported"}
    end
  end

  def validate(%{"oauth" => _}), do: {:error, "OAuth is supported only for HTTP public clients"}
  def validate(_), do: :ok

  def url?(value) do
    case Address.parse(value) do
      {:ok, uri} ->
        uri.fragment == nil and URI.parse(value).fragment == nil and uri.query == nil and
          (uri.scheme == "https" or loopback?(uri))

      _ ->
        false
    end
  end

  def loopback?(%URI{host: host}), do: host in ["127.0.0.1", "::1"]
  def origin(%URI{} = uri), do: {uri.scheme, uri.host, uri.port}

  defp valid_scopes?(scopes),
    do:
      is_list(scopes) and Enum.all?(scopes, &text?/1) and
        Enum.all?(scopes, &(not String.contains?(&1, " ")))

  defp text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..2048 and
        not String.match?(value, ~r/[\x00-\x20\x7f]/)
end
