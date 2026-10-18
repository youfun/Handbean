defmodule HandbeanProbe.ReqDNS do
  @moduledoc """
  Resolve request hostnames through `Mob.DNS` before Finch/Mint connect.

  On Android, BEAM's `:native` / `:dns` lookups return `:nxdomain` even when
  the OS resolver works. `Mob.DNS.resolve/1` uses the in-process NIF, then
  seeds `:inet_db` so the rest of the HTTP stack can connect.
  """

  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = request) do
    Req.Request.prepend_request_steps(request, mob_dns: &resolve_host/1)
  end

  @doc "Native address for direct, IP-pinned HTTP; Mob 0.7 returns one IPv4 address."
  def resolve(host) do
    case Mob.DNS.resolve(host) do
      {:ok, ip} -> {:ok, [ip]}
      {:error, _} = error -> error
    end
  end

  defp resolve_host(%Req.Request{url: %URI{host: host}} = request)
       when is_binary(host) and host != "" do
    _ = Mob.DNS.resolve(host)
    request
  end

  defp resolve_host(request), do: request
end
