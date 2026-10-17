defmodule Handbean.WebFetch.Address do
  @moduledoc false

  import Bitwise

  # Conservative public-unicast policy; special-use and transition networks
  # are not destinations for this tool, even when some addresses are routable.
  @blocked_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3}
  ]

  def parse(url) when is_binary(url) and byte_size(url) <= 8_192 do
    with true <- String.valid?(url) and not String.match?(url, ~r/[\x00-\x20\x7f\\]/),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"],
         true <- is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo),
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- String.match?(uri.host, ~r/\A[a-zA-Z0-9.:-]+\z/) do
      {:ok, %{uri | fragment: nil}}
    else
      _ -> {:error, "Expected an HTTP(S) URL without credentials, spaces or control characters"}
    end
  end

  def parse(_), do: {:error, "URL must be a string of at most 8192 bytes"}

  def resolve(host, deadline) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, [ip]}
      {:error, _} -> resolve_host(host, deadline)
    end
  end

  defp resolve_host(host, deadline) do
    case Handbean.Host.get(:dns_resolver) do
      nil ->
        resolve_name(host, deadline)

      resolver when is_function(resolver, 1) ->
        task =
          Task.Supervisor.async_nolink(Handbean.AgentRunTaskSupervisor, fn -> resolver.(host) end)

        timeout = min(5_000, max(0, deadline - System.monotonic_time(:millisecond)))

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, ips}} when is_list(ips) -> {:ok, ips}
          _ -> {:error, "Native DNS resolution failed or timed out"}
        end
    end
  end

  def select_public(addresses) when is_list(addresses) and addresses != [] do
    if Enum.all?(addresses, &public?/1),
      do: {:ok, hd(addresses)},
      else: {:error, "Destination is not exclusively public unicast addresses"}
  end

  def select_public(_), do: {:error, "DNS returned no usable addresses"}

  @doc "True only for the benchmarking range proxies use as a Fake-IP token. Not public."
  def fake_ip?({a, b, c, d} = ip)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    in_network?(ip, {198, 18, 0, 0}, 15)
  end

  def fake_ip?(_), do: false

  @doc "Resolve `host`, but an IP literal never reaches `resolver` or the network."
  def resolve_with(host, deadline, resolver) when is_function(resolver, 2) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, [ip]}
      {:error, _} -> resolver.(host, deadline)
    end
  end

  def public?({a, b, c, d} = ip)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    Enum.all?(@blocked_v4, fn {network, bits} -> not in_network?(ip, network, bits) end)
  end

  def public?({a, b, c, d, e, f, g, h})
      when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
             e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    a in 0x2000..0x3FFF and
      not (a == 0x2001 and (b < 0x0200 or b == 0x0DB8)) and
      a != 0x2002 and not (a == 0x3FFF and b < 0x1000)
  end

  def public?(_), do: false

  defp in_network?(ip, network, bits) do
    ipv4(ip) >>> (32 - bits) == ipv4(network) >>> (32 - bits)
  end

  defp ipv4({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp resolve_name(host, deadline) do
    Enum.reduce_while([:inet, :inet6], {:ok, []}, fn family, {:ok, addresses} ->
      timeout = min(5_000, deadline - System.monotonic_time(:millisecond))

      if timeout <= 0 do
        {:halt, {:error, "Fetch deadline exceeded"}}
      else
        case :inet.getaddrs(String.to_charlist(host), family, timeout) do
          {:ok, ips} -> {:cont, {:ok, addresses ++ ips}}
          {:error, :nxdomain} -> {:cont, {:ok, addresses}}
          {:error, _} -> {:halt, {:error, "DNS resolution failed"}}
        end
      end
    end)
  end
end
