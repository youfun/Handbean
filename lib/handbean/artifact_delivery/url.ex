defmodule Handbean.ArtifactDelivery.Url do
  @moduledoc """
  Absolute http(s) URLs for the system browser. Not the Agent WebView.
  """

  @max_len 2048

  @spec parse(term()) :: {:ok, String.t()} | {:error, atom()}
  def parse(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" ->
        {:error, :empty}

      byte_size(trimmed) > @max_len ->
        {:error, :too_long}

      String.contains?(trimmed, ["\n", "\r", "\0"]) ->
        {:error, :invalid_url}

      true ->
        case URI.parse(trimmed) do
          %URI{scheme: scheme, host: host, userinfo: nil} = uri
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            if uri_absolute?(uri) do
              {:ok, URI.to_string(uri)}
            else
              {:error, :not_absolute}
            end

          %URI{userinfo: userinfo} when is_binary(userinfo) and userinfo != "" ->
            {:error, :userinfo}

          _ ->
            {:error, :invalid_url}
        end
    end
  end

  def parse(_), do: {:error, :invalid_url}

  defp uri_absolute?(%URI{scheme: scheme, host: host})
       when is_binary(scheme) and is_binary(host) and host != "",
       do: true

  defp uri_absolute?(_), do: false
end
