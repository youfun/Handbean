# Probe-only Hex 2.4.1 adapter. Public, read-only Hex downloads use the
# already configured Req transport; do not start :inets in the mobile host.
defmodule HandbeanMixProbe.HexApplication do
  use Application

  def start(_, _) do
    Mix.SCM.append(Hex.SCM)
    Mix.RemoteConverger.register(Hex.RemoteConverger)

    Supervisor.start_link(
      [
        Hex.Netrc.Cache,
        Hex.OAuth,
        Hex.Repo,
        Hex.State,
        Hex.Server,
        {Hex.Parallel, [:hex_fetcher]},
        Hex.Registry.Server,
        Hex.UpdateChecker
      ],
      strategy: :one_for_one,
      name: Hex.Supervisor
    )
  end
end

# Hex hardcodes this adapter; this override is ONLY for a disposable probe.
# It deliberately does not support publish/auth/proxies/arbitrary requests.
defmodule Hex.HTTP do
  def config, do: Map.put(:mix_hex_core.default_config(), :http_adapter, {__MODULE__, %{}})
  def request(method, url, headers, body), do: request(method, url, headers, body, %{})

  def request(method, url, headers, body, _config) do
    uri = URI.parse(to_string(url))

    if method in [:get, "GET", "get"] and body in [nil, :undefined, ""] and
         uri.scheme == "https" and uri.host in ["repo.hex.pm", "hex.pm"] do
      case Req.get(to_string(url),
             headers: Enum.to_list(headers),
             decode_body: false,
             retry: false,
             redirect: false,
             receive_timeout: 30_000
           ) do
        {:ok, response} ->
          headers = Map.new(response.headers, fn {k, v} -> {k, Enum.join(v, ", ")} end)
          {:ok, {response.status, headers, response.body}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unsupported_probe_request}
    end
  end

  def request_to_file(method, url, headers, body, filename, config) do
    with {:ok, {status, response_headers, bytes}} <- request(method, url, headers, body, config),
         :ok <- File.write(filename, bytes) do
      {:ok, {status, response_headers}}
    end
  end
end

defmodule HandbeanMixProbe.Shell do
  def info(message), do: IO.puts(message)
  def error(message), do: IO.puts(:stderr, message)
  def prompt(_), do: raise("interactive prompts are not supported by the probe")
  def yes?(_), do: false
  def yes?(_, _), do: false
  def cmd(_, _), do: raise("external commands are not supported by the probe")
  def print_app, do: :ok
end
