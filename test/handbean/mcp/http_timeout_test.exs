defmodule Handbean.MCP.HTTPTimeoutTest do
  use ExUnit.Case, async: false

  alias Handbean.MCP.{HTTP, ServerConfig}

  defmodule Once do
    def post(url, opts) do
      parent = :persistent_term.get({__MODULE__, :parent})
      calls = :persistent_term.get({__MODULE__, :calls})
      :counters.add(calls, 1, 1)
      send(parent, {:mcp_http, url, Keyword.take(opts, [:retry, :receive_timeout])})
      Process.sleep(opts[:receive_timeout] || 30)
      {:error, :timeout}
    end
  end

  setup do
    previous = Application.get_env(:handbean, :mcp_http_req, Req)
    Application.put_env(:handbean, :mcp_http_req, Once)
    :persistent_term.put({Once, :parent}, self())
    calls = :counters.new(1, [])
    :persistent_term.put({Once, :calls}, calls)

    on_exit(fn ->
      if previous == Req do
        Application.delete_env(:handbean, :mcp_http_req)
      else
        Application.put_env(:handbean, :mcp_http_req, previous)
      end
    end)

    {:ok, calls: calls}
  end

  test "a timed-out MCP HTTP call is not resent", %{calls: calls} do
    cfg = %ServerConfig{
      name: "timeout-mcp",
      transport: "http",
      url: "http://127.0.0.1:9/mcp",
      protocol_era: :legacy,
      runtime_headers: %{}
    }

    assert {:error, "MCP HTTP request failed"} =
             HTTP.call(cfg, "tools/call", %{"name" => "slow"}, 20)

    assert :counters.get(calls, 1) == 1
    assert_receive {:mcp_http, _url, opts}, 500
    assert opts[:retry] == false
    assert opts[:receive_timeout] == 20
    refute_receive {:mcp_http, _, _}, 40
  end
end
