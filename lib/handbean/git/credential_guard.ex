defmodule Handbean.Git.CredentialGuard do
  @moduledoc false

  @mismatch "Git credential endpoint does not match the remote host"

  @spec assert_https_destinations([String.t()], String.t()) :: :ok | {:error, String.t()}
  def assert_https_destinations(urls, endpoint) when is_list(urls) and is_binary(endpoint) do
    if urls == [] do
      {:error, @mismatch}
    else
      Enum.reduce_while(urls, :ok, fn url, :ok ->
        case match_one(url, endpoint) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  def assert_https_destinations(_, _), do: {:error, @mismatch}

  @spec match_one(String.t(), String.t()) :: :ok | {:error, String.t()}
  def match_one(url, endpoint) when is_binary(url) and is_binary(endpoint) do
    url_uri = URI.parse(url)
    end_uri = URI.parse(endpoint)
    url_host = url_uri.host && String.downcase(url_uri.host)
    end_host = end_uri.host && String.downcase(end_uri.host)

    cond do
      url_uri.scheme != "https" or end_uri.scheme != "https" ->
        {:error, @mismatch}

      url_uri.userinfo not in [nil, ""] or end_uri.userinfo not in [nil, ""] ->
        {:error, @mismatch}

      url_host in [nil, ""] or end_host in [nil, ""] or url_host != end_host ->
        {:error, @mismatch}

      true ->
        :ok
    end
  end

  def match_one(_, _), do: {:error, @mismatch}

  @spec host_from_endpoint(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def host_from_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, userinfo: userinfo}
      when is_binary(host) and host != "" and userinfo in [nil, ""] ->
        {:ok, String.downcase(host)}

      _ ->
        {:error, @mismatch}
    end
  end

  def host_from_endpoint(_), do: {:error, @mismatch}

  @spec mismatch_message() :: String.t()
  def mismatch_message, do: @mismatch
end
