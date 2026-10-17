defmodule Handbean.WebFetch.Desktop do
  @moduledoc false

  alias Handbean.WebFetch.{Address, HTTP}
  alias Handbean.WebFetch.Desktop.{Proxy, Route}

  # System route and proxy discovery. DNS answers in 198.18.0.0/15 are routing
  # tokens, not origin addresses. They are dialed only when a TUN owns that
  # range, the system HTTP proxy will carry the hostname, or the resolver
  # itself issues 198.18/15 for an unrelated name. They never become public.
  def get(uri, deadline, opts) do
    resolve = Keyword.get(opts, :resolve, &Address.resolve/2)
    request = Keyword.get(opts, :request, &HTTP.get/3)

    with {:ok, ips} <- Address.resolve_with(uri.host, deadline, resolve),
         {:ok, target} <- destination(uri, ips, opts) do
      request.(uri, target, deadline)
    end
  end

  defp destination(uri, ips, opts) do
    cond do
      literal?(uri.host) or Enum.all?(ips, &Address.public?/1) ->
        Address.select_public(ips)

      ips != [] and Enum.all?(ips, &Address.fake_ip?/1) ->
        fake_ip_target(uri.scheme, ips, opts)

      true ->
        {:error, "Destination is not exclusively public unicast addresses"}
    end
  end

  defp literal?(host) do
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp fake_ip_target(scheme, ips, opts) do
    takeover = Keyword.get(opts, :takeover, &system_takeover/1)

    case takeover.(scheme) do
      :tun ->
        {:ok, hd(ips)}

      {:proxy, {proxy_scheme, address, port, proxy_opts}}
      when proxy_scheme in [:http, :https] and is_integer(port) and port in 1..65_535 and
             (is_binary(address) or is_tuple(address)) and is_list(proxy_opts) ->
        {:ok, {:proxy, {proxy_scheme, address, port, proxy_opts}}}

      _ ->
        {:error, "Destination is not exclusively public unicast addresses"}
    end
  end

  # True when `lookup` returns only 198.18.0.0/15. A normal resolver does not
  # map an unrelated name into that range; a Fake-IP resolver does.
  def resolver_fake_ip?(lookup) when is_function(lookup, 0) do
    case lookup.() do
      {:ok, ips} when is_list(ips) and ips != [] -> Enum.all?(ips, &Address.fake_ip?/1)
      _ -> false
    end
  end

  defp system_takeover(scheme) do
    cond do
      Route.system_tun?() ->
        :tun

      true ->
        case Proxy.system(scheme) do
          {:ok, proxy} -> {:proxy, proxy}
          :error -> if resolver_fake_ip?(&canary_lookup/0), do: :tun, else: :none
        end
    end
  end

  defp canary_lookup do
    host = "hb-fakeip-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".com"
    Address.resolve(host, System.monotonic_time(:millisecond) + 5_000)
  end
end

defmodule Handbean.WebFetch.Desktop.Route do
  @moduledoc false

  import Bitwise

  @probe {198, 18, 0, 1}

  def system_tun? do
    case :os.type() do
      {:unix, :darwin} -> run("/sbin/route", ["-n", "get", "198.18.0.1"], &darwin?/1)
      {:unix, :linux} -> linux_system()
      _ -> false
    end
  end

  def darwin?(output) when is_binary(output) do
    fields = fields(output)

    with true <- tunnel?(fields["interface"]),
         {:ok, dest} <- parse_ip(fields["destination"]),
         {:ok, mask} <- parse_ip(fields["mask"]),
         prefix when prefix >= 15 and prefix <= 32 <- prefix_len(mask),
         true <- contains?(dest, prefix, @probe) do
      true
    else
      _ -> false
    end
  end

  def linux?(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(nil, fn line, best ->
      case linux_route(line) do
        %{prefix: prefix} = route ->
          if best == nil or prefix > best.prefix, do: route, else: best

        _ ->
          best
      end
    end)
    |> case do
      %{dev: dev} -> tunnel?(dev)
      _ -> false
    end
  end

  defp linux_system do
    Enum.find_value(["/sbin/ip", "/usr/sbin/ip", "/bin/ip"], false, fn path ->
      case run(path, ["-4", "route", "show", "match", "198.18.0.1"], &linux?/1) do
        true -> true
        false -> nil
      end
    end) || false
  end

  defp run(path, args, parse) do
    case System.cmd(path, args, stderr_to_stdout: true) do
      {output, 0} -> parse.(output)
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  defp linux_route(line) do
    with [dest | _] <- String.split(line, " ", trim: true),
         true <- dest != "default",
         [ip_s, prefix_s] <- split_dest(dest),
         {:ok, network} <- parse_ip(ip_s),
         {prefix, ""} when prefix in 15..32 <- Integer.parse(prefix_s),
         true <- contains?(network, prefix, @probe),
         [_, dev] <- Regex.run(~r/\bdev\s+(\S+)/, line) do
      %{prefix: prefix, dev: dev}
    else
      _ -> nil
    end
  end

  defp split_dest(dest) do
    case String.split(dest, "/", parts: 2) do
      [_, _] = parts -> parts
      [ip] -> [ip, "32"]
    end
  end

  defp fields(output) do
    Regex.scan(~r/^\s*([A-Za-z]+):\s*(\S+)/m, output)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end

  defp tunnel?(iface) when is_binary(iface),
    do: String.match?(iface, ~r/\A(?:utun|tun|tap|wg|tailscale)\d*\z/)

  defp tunnel?(_), do: false

  defp contains?(network, prefix, ip) do
    shift = 32 - prefix
    ipv4(network) >>> shift == ipv4(ip) >>> shift
  end

  defp prefix_len(mask) do
    bits = ipv4(mask)

    Enum.reduce_while(0..31, 0, fn index, _ ->
      if (bits &&& 1 <<< (31 - index)) == 0, do: {:halt, index}, else: {:cont, index + 1}
    end)
  end

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _} = ip} -> {:ok, ip}
      _ -> :error
    end
  end

  defp parse_ip(_), do: :error

  defp ipv4({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d
end

defmodule Handbean.WebFetch.Desktop.Proxy do
  @moduledoc false

  def system(scheme) when scheme in ["http", "https"] do
    case env(scheme) do
      {:ok, _} = ok -> ok
      :error -> macos(scheme)
    end
  end

  def parse(value) when is_binary(value) do
    with {:ok, uri} <- URI.new(String.trim(value)),
         scheme when scheme in ["http", "https"] <- uri.scheme,
         true <- is_binary(uri.host) and uri.host != "" and is_nil(uri.fragment),
         port when port in 1..65_535 <- uri.port || default_port(scheme),
         {:ok, opts} <- auth_opts(uri) do
      {:ok, {String.to_existing_atom(scheme), uri.host, port, opts}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  def from_scutil(text, scheme) when is_binary(text) and scheme in ["http", "https"] do
    keys =
      if scheme == "https" do
        ["HTTPS", "HTTP"]
      else
        ["HTTP"]
      end

    Enum.find_value(keys, fn key ->
      with "1" <- field(text, key <> "Enable"),
           host when is_binary(host) <- field(text, key <> "Proxy"),
           {port, ""} when port in 1..65_535 <-
             Integer.parse(to_string(field(text, key <> "Port"))) do
        {:ok, {:http, host, port, []}}
      else
        _ -> nil
      end
    end)
  end

  defp env("https"), do: first(~w(https_proxy HTTPS_PROXY all_proxy ALL_PROXY))
  defp env("http"), do: first(~w(http_proxy HTTP_PROXY all_proxy ALL_PROXY))

  defp first(names) do
    Enum.find_value(names, :error, fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" ->
          case parse(value) do
            {:ok, _} = ok -> ok
            :error -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp macos(scheme) do
    if :os.type() == {:unix, :darwin} do
      case System.cmd("/usr/sbin/scutil", ["--proxy"], stderr_to_stdout: true) do
        {output, 0} -> from_scutil(output, scheme) || :error
        _ -> :error
      end
    else
      :error
    end
  rescue
    ErlangError -> :error
  end

  defp auth_opts(%URI{userinfo: nil}), do: {:ok, []}

  defp auth_opts(%URI{userinfo: userinfo}) do
    with [user, pass] <- String.split(userinfo, ":", parts: 2),
         true <- user != "" and not String.match?(user <> pass, ~r/[\r\n]/) do
      token = Base.encode64(user <> ":" <> pass)
      {:ok, [proxy_headers: [{"proxy-authorization", "Basic " <> token}]]}
    else
      _ -> :error
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp field(text, key) do
    case Regex.run(~r/^\s*#{Regex.escape(key)}\s*:\s*(\S+)/m, text) do
      [_, value] -> value
      _ -> nil
    end
  end
end
