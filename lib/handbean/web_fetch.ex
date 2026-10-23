defmodule Handbean.WebFetch do
  @moduledoc """
  Bounded public-web GET and local document extraction.

  Every redirect is parsed and checked again. Loopback, private literals,
  link-local and cloud-metadata addresses are never requested.

  Desktop does not assume a DNS answer is the origin address. Public answers
  are still pinned. `198.18.0.0/15` stays non-public and is used only as a
  Fake-IP routing token when the system TUN owns that range, the resolver
  issues that range for an unrelated name, or the hostname is sent through
  the system HTTP proxy instead of dialing the token.
  A host that supplies `dns_resolver` keeps the pinned public-address path.
  """

  alias Handbean.WebFetch.{Address, Document}

  @doc "Fetch text from a public HTTP(S) URL. Options inject resolver/transport for tests."
  def fetch(url, max_chars \\ 20_000, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)

    if is_integer(max_chars) and max_chars in 1..50_000 and is_integer(offset) and offset >= 0 do
      deadline = System.monotonic_time(:millisecond) + 30_000

      with {:ok, uri} <- Address.parse(url),
           {:ok, final_uri, response} <- follow(uri, deadline, 3, opts),
           {:ok, document} <-
             Document.extract(response.body, response.headers, final_uri, max_chars,
               offset: offset,
               timeout: max(0, deadline - System.monotonic_time(:millisecond))
             ) do
        {:ok,
         Map.merge(document, %{
           requested_url: URI.to_string(uri),
           final_url: URI.to_string(final_uri),
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
         })}
      end
    else
      {:error,
       "max_chars must be an integer between 1 and 50000; offset must be a non-negative integer"}
    end
  end

  defp follow(uri, deadline, redirects, opts) do
    with {:ok, response} <- backend(opts).get(uri, deadline, opts) do
      cond do
        response.status in [301, 302, 303, 307, 308] ->
          redirect(uri, response.headers, deadline, redirects, opts)

        response.status in 200..299 ->
          {:ok, uri, response}

        true ->
          {:error, "HTTP status #{response.status}"}
      end
    end
  end

  defp backend(opts) do
    case Keyword.get(opts, :network) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> if host_network?(), do: Handbean.WebFetch.HostNetwork, else: Handbean.WebFetch.Desktop
    end
  end

  defp host_network? do
    is_function(Handbean.Host.get(:dns_resolver), 1)
  end

  defp redirect(_uri, _headers, _deadline, 0, _opts),
    do: {:error, "Too many redirects (maximum 3)"}

  defp redirect(uri, headers, deadline, redirects, opts) do
    with {"location", location} <- List.keyfind(headers, "location", 0),
         {:ok, relative} <- URI.new(location),
         {:ok, target} <- Address.parse(uri |> URI.merge(relative) |> URI.to_string()) do
      follow(target, deadline, redirects - 1, opts)
    else
      _ -> {:error, "Invalid redirect destination"}
    end
  end
end
