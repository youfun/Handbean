defmodule Handbean.WebFetch.HostNetwork do
  @moduledoc false

  alias Handbean.WebFetch.{Address, HTTP}

  # Mobile and any other host that injects `dns_resolver` keeps pinned
  # public-address connects. Fake-IP is not treated as reachable here.
  def get(uri, deadline, opts) do
    resolve = Keyword.get(opts, :resolve, &Address.resolve/2)
    request = Keyword.get(opts, :request, &HTTP.get/3)

    with {:ok, ips} <- Address.resolve_with(uri.host, deadline, resolve),
         {:ok, ip} <- Address.select_public(ips) do
      request.(uri, ip, deadline)
    end
  end
end
