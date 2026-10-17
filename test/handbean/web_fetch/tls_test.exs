defmodule Handbean.WebFetch.TLSTest do
  # Temporarily load a test CA into OTP's trust store; never changes verification
  # options in the production transport. Restore the exact prior certificates.
  use ExUnit.Case, async: false

  alias Handbean.WebFetch.HTTP

  setup_all do
    dir = Path.join(System.tmp_dir!(), "handbean-fetch-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original = :public_key.cacerts_get()

    original_pem =
      Enum.map(original, fn {:cert, der, _} -> {:Certificate, der, :not_encrypted} end)

    File.write!(Path.join(dir, "original.pem"), :public_key.pem_encode(original_pem))

    on_exit(fn ->
      :public_key.cacerts_clear()
      :ok = :public_key.cacerts_load(String.to_charlist(Path.join(dir, "original.pem")))
      File.rm_rf!(dir)
    end)

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          Path.join(dir, "ca-key.pem"),
          "-out",
          Path.join(dir, "ca.pem"),
          "-days",
          "1",
          "-subj",
          "/CN=Handbean Test CA",
          "-addext",
          "basicConstraints=critical,CA:TRUE"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-new",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          Path.join(dir, "key.pem"),
          "-out",
          Path.join(dir, "request.pem"),
          "-subj",
          "/CN=docs.test"
        ],
        stderr_to_stdout: true
      )

    File.write!(
      Path.join(dir, "extensions.cnf"),
      "subjectAltName=DNS:docs.test\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n"
    )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          Path.join(dir, "request.pem"),
          "-CA",
          Path.join(dir, "ca.pem"),
          "-CAkey",
          Path.join(dir, "ca-key.pem"),
          "-CAcreateserial",
          "-out",
          Path.join(dir, "cert.pem"),
          "-days",
          "1",
          "-extfile",
          Path.join(dir, "extensions.cnf")
        ],
        stderr_to_stdout: true
      )

    :ok = :public_key.cacerts_load(String.to_charlist(Path.join(dir, "ca.pem")))
    %{dir: dir}
  end

  test "pinned IP retains original TLS SNI and hostname verification", %{dir: dir} do
    port = serve_tls(dir)
    uri = URI.parse("https://docs.test:#{port}/")
    assert {:ok, %{body: "secure"}} = HTTP.get(uri, {127, 0, 0, 1}, deadline())
    assert_receive {:tls_sni, ~c"docs.test"}

    port = serve_tls(dir)
    uri = URI.parse("https://wrong.test:#{port}/")

    assert {:error, "Connection or TLS verification failed"} =
             HTTP.get(uri, {127, 0, 0, 1}, deadline())
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp serve_tls(dir) do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true,
        certfile: String.to_charlist(Path.join(dir, "cert.pem")),
        keyfile: String.to_charlist(Path.join(dir, "key.pem"))
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 5_000)

        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} ->
            {:ok, info} = :ssl.connection_information(socket, [:sni_hostname])
            send(parent, {:tls_sni, info[:sni_hostname]})
            {:ok, _request} = :ssl.recv(socket, 0, 5_000)
            :ssl.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecure")
            :ssl.close(socket)

          {:error, _} ->
            :ssl.close(socket)
        end
      end)

    on_exit(fn ->
      :ssl.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    port
  end
end
