defmodule Handbean.MCP.ResourceDeadlineTest do
  use ExUnit.Case, async: false

  alias Handbean.MCP.Resources

  defmodule StreamingServer do
    import Plug.Conn

    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)
      message = Handbean.JSON.decode!(body)

      case message["method"] do
        "server/discover" ->
          send_resp(conn, 400, "")

        "initialize" ->
          reply(conn, message, %{protocolVersion: "2025-11-25", capabilities: %{resources: %{}}})

        "notifications/initialized" ->
          send_resp(conn, 202, "")

        "resources/read" ->
          if message["params"]["uri"] == "memo://stream" do
            conn = conn |> put_resp_content_type("application/json") |> send_chunked(200)

            {:ok, conn} =
              chunk(
                conn,
                "{\"jsonrpc\":\"2.0\",\"id\":\"#{message["id"]}\",\"result\":{\"contents\":[{\"uri\":\"memo://stream\",\"text\":\""
              )

            drip(conn, owner)
          else
            reply(conn, message, %{contents: [%{uri: "memo://fast", text: "fast"}]})
          end
      end
    end

    defp drip(conn, owner) do
      Process.send_after(self(), :drip, 10)

      receive do
        :drip ->
          case chunk(conn, "x") do
            {:ok, conn} ->
              send(owner, :resource_stream_chunk)
              drip(conn, owner)

            {:error, _} ->
              send(owner, :resource_stream_closed)
              conn
          end
      end
    end

    defp reply(conn, message, result),
      do:
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Handbean.JSON.encode!(%{jsonrpc: "2.0", id: message["id"], result: result})
        )
  end

  test "a real slow chunked response is cancelled at the total deadline and releases runtime" do
    start_supervised!(Handbean.MCP.RuntimeSupervisor)
    start_supervised!(Handbean.MCP)

    server =
      start_supervised!(
        {Bandit, plug: {StreamingServer, self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    root = Path.join(System.tmp_dir!(), "mcp-deadline-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    config = Path.join(root, "mcp.json")

    File.write!(
      config,
      Handbean.JSON.encode!(%{mcpServers: %{stream: %{url: "http://127.0.0.1:#{port}/mcp"}}})
    )

    old = Req.default_options()
    Req.default_options(Keyword.delete(old, :plug))

    on_exit(fn ->
      Req.default_options(old)
      File.rm_rf!(root)
    end)

    scope = [user_config_path: config, workspace_id: "streaming-test"]
    assert {:ok, _} = Handbean.MCP.bootstrap(scope)
    context = %{mcp_scope: scope, tool_timeout: 150}

    assert {:error, "MCP resource request timed out"} =
             Resources.read_resource(%{"server" => "stream", "uri" => "memo://stream"}, context)

    assert_receive :resource_stream_chunk
    assert_receive :resource_stream_chunk
    assert_receive :resource_stream_closed, 1_000

    assert {:ok, %{"contents" => [%{"text" => "fast"}]}} =
             Resources.read_resource(%{"server" => "stream", "uri" => "memo://fast"}, %{
               mcp_scope: scope
             })
  end
end
