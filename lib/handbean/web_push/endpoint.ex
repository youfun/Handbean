defmodule Handbean.WebPush.Endpoint do
  @moduledoc """
  Restricts outbound Web Push requests to supported public push services.

  Callers must also disable HTTP redirects so that a trusted endpoint cannot
  redirect delivery to a different destination.
  """

  @max_url_bytes 4096
  @hostname ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/

  @doc """
  Validates an HTTPS push endpoint on port 443 against the provider allowlist.

      iex> Handbean.WebPush.Endpoint.validate("https://fcm.googleapis.com/fcm/send/token")
      :ok

      iex> Handbean.WebPush.Endpoint.validate("https://localhost/push")
      {:error, :invalid_endpoint}
  """
  @spec validate(term()) :: :ok | {:error, :invalid_endpoint}
  def validate(url) when is_binary(url) and byte_size(url) in 1..@max_url_bytes do
    with true <- safe_url?(url),
         {:ok, uri} <- URI.new(url),
         %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil}
         when is_binary(host) <- uri,
         true <- valid_authority?(url, host),
         true <- allowed_host?(String.downcase(host)) do
      :ok
    else
      _ -> {:error, :invalid_endpoint}
    end
  end

  def validate(_url), do: {:error, :invalid_endpoint}

  defp safe_url?(url) do
    # Reject parser ambiguities, including backslashes and raw whitespace.
    String.valid?(url) and not Regex.match?(~r/[\x00-\x20\x7f-\xff\\]/, url) and
      not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, url)
  end

  defp valid_authority?("https://" <> rest, host) do
    [authority | _rest] = String.split(rest, ["/", "?", "#"], parts: 2)
    authority in [host, host <> ":443"]
  end

  defp valid_authority?(_url, _host), do: false

  defp allowed_host?(host) do
    byte_size(host) <= 253 and Regex.match?(@hostname, host) and
      (host in ["fcm.googleapis.com", "web.push.apple.com", "updates.push.services.mozilla.com"] or
         String.ends_with?(host, ".updates.push.services.mozilla.com") or
         String.ends_with?(host, ".notify.windows.com"))
  end
end
