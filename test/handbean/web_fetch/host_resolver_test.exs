defmodule Handbean.WebFetch.HostResolverTest do
  use ExUnit.Case, async: false

  alias Handbean.WebFetch
  alias Handbean.WebFetch.Address

  setup do
    host = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)
    end)
  end

  test "native host resolution is still validated and pinned, including on redirects" do
    parent = self()

    Handbean.Host.put!(%{
      dns_resolver: fn host ->
        send(parent, {:resolved, host})
        {:ok, [{8, 8, 8, 8}]}
      end
    })

    request = fn uri, ip, _ ->
      assert ip == {8, 8, 8, 8}

      case uri.path do
        "/start" -> {:ok, %{status: 302, headers: [{"location", "/end"}], body: ""}}
        "/end" -> {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "native"}}
      end
    end

    assert {:ok, %{content: "native"}} =
             WebFetch.fetch("https://native.test/start", 100, request: request)

    assert_received {:resolved, "native.test"}
    assert_received {:resolved, "native.test"}

    Handbean.Host.put!(%{dns_resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end})
    assert {:error, _} = WebFetch.fetch("https://native.test/start", 100, request: request)

    Handbean.Host.put!(%{dns_resolver: fn _ -> {:ok, [{198, 18, 0, 4}]} end})

    assert {:error, _} =
             WebFetch.fetch("https://native.test/start", 100,
               takeover: fn _ -> :tun end,
               request: fn _, _, _ -> flunk("host network dialed a fake-ip") end
             )
  end

  test "native resolution deadline stops waiting and literal IPs bypass the callback" do
    parent = self()

    Handbean.Host.put!(%{
      dns_resolver: fn _ ->
        send(parent, {:resolver, self()})

        receive do
          :never_sent -> {:ok, [{8, 8, 8, 8}]}
        end
      end
    })

    assert {:error, _} = Address.resolve("native.test", System.monotonic_time(:millisecond) + 100)
    assert_receive {:resolver, pid}
    refute Process.alive?(pid)
    assert {:ok, [{8, 8, 8, 8}]} = Address.resolve("8.8.8.8", 0)
    refute_received {:resolver, _}
  end
end
