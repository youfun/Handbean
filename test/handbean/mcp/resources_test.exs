defmodule Handbean.MCP.ResourcesTest do
  use ExUnit.Case, async: false

  alias Handbean.MCP.{Access, Resources, ServerConfig, ServerRuntime}
  alias Handbean.Tool.Builtin.{ListMCPResources, ListMCPResourceTemplates, ReadMCPResource}

  setup do
    start_supervised!(Handbean.MCP.RuntimeSupervisor)
    start_supervised!(Handbean.MCP)
    Req.Test.set_req_test_to_shared()
    old = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    root = Path.join(System.tmp_dir!(), "mcp-resources-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    opts = [user_config_path: Path.join(root, "mcp.json"), workspace_id: "a"]
    write_config(opts)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Handbean.JSON.decode!(body)
      send(owner, {:rpc, conn.host, message["method"], message["params"]})

      if get_in(message, ["params", "uri"]) == "memo://gate" or
           (conn.host == "slow.example" and message["method"] == "server/discover") do
        send(owner, {:resource_gate, self()})

        receive do
          :release_resource -> :ok
        end
      end

      response(conn, message, opts)
    end)

    on_exit(fn ->
      Req.default_options(old)
      File.rm_rf!(root)
    end)

    %{root: root, opts: opts, context: %{mcp_scope: opts}}
  end

  test "server directory comes only from effective scope and never starts a connection", %{
    context: context,
    opts: opts
  } do
    assert {:ok, %{"servers" => ["docs"]}} = Resources.list_resources(%{}, context)

    assert {:ok, %{"servers" => []}} =
             Resources.list_resources(%{}, %{mcp_scope: Keyword.put(opts, :workspace_id, "b")})

    assert {:error, _} = Resources.list_resources(%{}, %{})
    assert {:error, _} = Resources.list_resources(%{"cursor" => "second"}, context)
    assert {:error, _} = Resources.read_resource(%{"server" => "docs", "uri" => "file:///x"}, %{})
    refute_received {:rpc, _, _, _}
  end

  test "HTTP resource-only server remains usable and pages preserve opaque cursors", %{
    context: context,
    opts: opts
  } do
    assert {:ok, text} = ListMCPResources.execute(%{"server" => "docs"}, context)

    assert %{
             "resources" => [%{"uri" => "memo://first", "title" => "First"}],
             "nextCursor" => "opaque+/second="
           } = Handbean.JSON.decode!(text)

    assert_receive {:rpc, "docs.example", "resources/list", %{}}
    refute_received {:rpc, _, "tools/list", _}

    assert {:ok, %{"resources" => [%{"uri" => "memo://second"}]}} =
             Resources.list_resources(
               %{"server" => "docs", "cursor" => "opaque+/second="},
               context
             )

    assert_receive {:rpc, "docs.example", "resources/list", %{"cursor" => "opaque+/second="}}
    assert {:ok, _} = Resources.list_resources(%{"server" => "docs", "cursor" => "  "}, context)
    assert_receive {:rpc, "docs.example", "resources/list", %{"cursor" => "  "}}
    assert {:ok, boot} = Handbean.MCP.bootstrap(opts)
    assert boot.registered == []
    assert length(boot.runtime_pids) == 1
  end

  test "template pages can be expanded and read through the selected server", %{context: context} do
    assert {:ok, text} = ListMCPResourceTemplates.execute(%{"server" => "docs"}, context)

    assert %{
             "resourceTemplates" => [%{"uriTemplate" => "memo://{name}"}],
             "nextCursor" => "templates-next"
           } = Handbean.JSON.decode!(text)

    assert {:ok, %{"resourceTemplates" => []}} =
             Resources.list_templates(
               %{"server" => "docs", "cursor" => "templates-next"},
               context
             )

    assert {:ok, text} =
             ReadMCPResource.execute(%{"server" => "docs", "uri" => "memo://expanded"}, context)

    assert %{"contents" => [%{"text" => "remote:memo://expanded"}]} = Handbean.JSON.decode!(text)
    assert_receive {:rpc, "docs.example", "resources/read", %{"uri" => "memo://expanded"}}
  end

  test "file URIs are resolved remotely without reading local files", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "private.txt")
    File.write!(path, "host-only-secret")
    uri = "file://" <> path
    assert {:ok, text} = ReadMCPResource.execute(%{"server" => "docs", "uri" => uri}, context)
    assert text =~ "remote:"
    refute text =~ "host-only-secret"
    assert_receive {:rpc, "docs.example", "resources/read", %{"uri" => ^uri}}
  end

  test "text is UTF-8 safe and bounded across contents; binary bytes are never projected", %{
    context: context
  } do
    assert {:ok, text} =
             ReadMCPResource.execute(%{"server" => "docs", "uri" => "memo://mixed"}, context)

    assert %{"contents" => [first, second, binary]} = Handbean.JSON.decode!(text)
    assert String.valid?(first["text"])
    assert byte_size(first["text"]) == 48_000
    assert first["truncated"]
    assert second["text"] == ""
    assert second["truncated"]
    assert binary["kind"] == "binary"
    assert binary["bytes"] == 4
    assert binary["mimeType"] == "application/octet-stream"
    assert binary["omitted"]
    refute text =~ "AAECAw=="
    refute Map.has_key?(binary, "blob")
    assert byte_size(text) < 98_304

    assert {:ok, %{"contents" => [%{"text" => prefix, "truncated" => true}]}} =
             Resources.read_resource(
               %{"server" => "docs", "uri" => "memo://utf8-boundary"},
               context
             )

    assert byte_size(prefix) == 47_999
    assert String.valid?(prefix)

    assert {:error, "MCP resource contents exceed the 96 KiB output limit"} =
             Resources.read_resource(
               %{"server" => "docs", "uri" => "memo://escaped-overflow"},
               context
             )
  end

  test "malformed and oversized pages fail explicitly without dropping entries or exposing raw payloads",
       %{context: context} do
    for cursor <- ["too-many", "too-large", "bad-entry", "bad-metadata", "repeated"] do
      assert {:error, _} =
               Resources.list_resources(%{"server" => "docs", "cursor" => cursor}, context)
    end

    for uri <- [
          "memo://invalid-base64",
          "memo://both",
          "memo://invalid-contents",
          "memo://too-many-contents"
        ] do
      assert {:error, _} = Resources.read_resource(%{"server" => "docs", "uri" => uri}, context)
    end
  end

  test "unsupported capability and protocol errors are distinguished", %{
    context: context,
    opts: opts
  } do
    write_config(opts, "https://no-resources.example/mcp")

    assert {:error, "MCP server does not support resources"} =
             Resources.list_resources(%{"server" => "docs"}, context)

    refute_received {:rpc, _, "resources/list", _}

    write_config(opts)

    assert {:error, "MCP resource was not found"} =
             Resources.read_resource(%{"server" => "docs", "uri" => "memo://missing"}, context)

    assert {:error, "MCP server does not support this resource operation"} =
             Resources.list_templates(%{"server" => "docs", "cursor" => "unsupported"}, context)

    assert {:error, "MCP resource request failed"} =
             Resources.read_resource(%{"server" => "docs", "uri" => "memo://error"}, context)
  end

  test "OAuth bootstrap errors direct the model to settings without exposing credentials", %{
    context: context,
    opts: opts
  } do
    File.write!(
      opts[:user_config_path],
      Handbean.JSON.encode!(%{
        "mcpServers" => %{
          "docs" => %{
            "url" => "https://docs.example/mcp",
            "oauth" => %{"client_id" => "resource-fixture-public-client"}
          }
        }
      })
    )

    assert {:error, error} = Resources.list_resources(%{"server" => "docs"}, context)

    assert error ==
             "MCP authorization required. Authorize or reconnect this server in plugin settings."

    refute_received {:rpc, _, _, _}
  end

  test "revocation blocks listing and reads before dispatch and discards in-flight results", %{
    context: context,
    opts: opts
  } do
    assert {:ok, _} = Resources.list_resources(%{"server" => "docs"}, context)
    write_config(opts, "https://docs.example/mcp", ["b"])

    assert {:error, _} =
             Resources.read_resource(%{"server" => "docs", "uri" => "memo://blocked"}, context)

    assert {:error, _} = Resources.list_templates(%{"server" => "docs"}, context)
    refute_received {:rpc, _, "resources/read", _}
    refute_received {:rpc, _, "resources/templates/list", _}

    write_config(opts)

    assert {:error, error} =
             Resources.read_resource(%{"server" => "docs", "uri" => "memo://revoke"}, context)

    assert error =~ "disabled, changed, or not allowed"
    refute error =~ "sensitive-response"
  end

  test "changed config replaces runtime and model-supplied scope fields cannot select another workspace",
       %{context: context, opts: opts} do
    assert {:ok, _} = Resources.list_resources(%{"server" => "docs"}, context)
    write_config(opts, "https://replacement.example/mcp")
    assert {:ok, _} = Resources.list_resources(%{"server" => "docs"}, context)
    assert_receive {:rpc, "replacement.example", "resources/list", _}

    assert {:error, _} =
             Resources.list_resources(
               %{
                 "server" => "docs",
                 "project" => "/",
                 "workspace_id" => "a",
                 "user_config_path" => opts[:user_config_path]
               },
               %{mcp_scope: Keyword.put(opts, :workspace_id, "b")}
             )

    refute_received {:rpc, _, "resources/read", _}
  end

  test "modern HTTP sends resource routing metadata and consumes SSE content", %{
    context: context,
    opts: opts
  } do
    write_config(opts, "https://modern.example/mcp")

    assert {:ok, %{"contents" => [%{"text" => "event-stream"}]}} =
             Resources.read_resource(%{"server" => "docs", "uri" => "memo://sse"}, context)

    assert_receive {:rpc, "modern.example", "resources/read", %{"_meta" => meta}}
    assert meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
    refute_received {:rpc, _, "initialize", _}
    refute_received {:rpc, _, "tools/list", _}
  end

  test "fingerprint excludes runtime scope/capabilities but preserves connection identity" do
    cfg = %ServerConfig{name: "docs", url: "https://docs.example/mcp"}

    augmented =
      cfg
      |> Map.put(:runtime_capabilities, %{"resources" => %{}})
      |> Map.put(:oauth_scope, workspace_id: "b")

    assert Access.fingerprint(cfg) == Access.fingerprint(augmented)

    refute Access.fingerprint(cfg) ==
             Access.fingerprint(Map.put(cfg, :oauth, %{"client_id" => "changed"}))

    refute Access.fingerprint(cfg) ==
             Access.fingerprint(%{cfg | url: "https://other.example/mcp"})
  end

  test "stdio resource-only server supports list, templates, reads and request timeout", %{
    root: root,
    opts: opts,
    context: context
  } do
    script = Path.join(root, "resources.sh")
    File.write!(script, stdio_script())
    File.chmod!(script, 0o700)

    File.write!(
      opts[:user_config_path],
      Handbean.JSON.encode!(%{"mcpServers" => %{"stdio" => %{"command" => script}}})
    )

    assert {:ok, %{"resources" => [%{"uri" => "memo://stdio"}], "nextCursor" => "next"}} =
             Resources.list_resources(%{"server" => "stdio"}, context)

    assert {:ok, %{"resources" => []}} =
             Resources.list_resources(%{"server" => "stdio", "cursor" => "next"}, context)

    assert {:ok, %{"resourceTemplates" => [%{"uriTemplate" => "memo://{name}"}]}} =
             Resources.list_templates(%{"server" => "stdio"}, context)

    assert {:ok, %{"contents" => [%{"text" => "stdio"}]}} =
             Resources.read_resource(%{"server" => "stdio", "uri" => "memo://stdio"}, context)

    assert {:ok, boot} = Handbean.MCP.bootstrap(opts)
    assert boot.registered == []

    assert {:error, {:mcp_timeout, _}} =
             ServerRuntime.resource_request(
               boot.servers["stdio"].pid,
               "resources/read",
               %{uri: "memo://timeout"},
               30
             )

    assert {:ok, _} =
             Resources.read_resource(%{"server" => "stdio", "uri" => "memo://stdio"}, context)

    assert {:error, "MCP resource was not found"} =
             Resources.read_resource(%{"server" => "stdio", "uri" => "memo://missing"}, context)

    runtime = boot.servers["stdio"].pid
    monitor = Process.monitor(runtime)

    assert {:error, "MCP resource request failed"} =
             Resources.read_resource(%{"server" => "stdio", "uri" => "memo://malformed"}, context)

    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}

    for uri <- ["memo://exit", "memo://oversize"] do
      assert {:ok, _} =
               Resources.read_resource(%{"server" => "stdio", "uri" => "memo://stdio"}, context)

      assert {:ok, fresh} = Handbean.MCP.bootstrap(opts)
      next_runtime = fresh.servers["stdio"].pid
      refute next_runtime == runtime
      next_monitor = Process.monitor(next_runtime)
      assert {:error, _} = Resources.read_resource(%{"server" => "stdio", "uri" => uri}, context)
      assert_receive {:DOWN, ^next_monitor, :process, ^next_runtime, :normal}
    end

    assert {:ok, _} =
             Resources.read_resource(%{"server" => "stdio", "uri" => "memo://stdio"}, context)
  end

  test "expired budgets do not dispatch and bootstrap consumes the same budget", %{
    context: context,
    opts: opts
  } do
    expired = Map.put(context, :run_deadline, System.monotonic_time(:millisecond) - 1)

    assert {:error, "MCP resource request timed out"} =
             Resources.list_resources(%{"server" => "docs"}, expired)

    refute_received {:rpc, _, _, _}

    write_config(opts, "https://slow.example/mcp")

    caller =
      Task.async(fn ->
        Resources.list_resources(%{"server" => "docs"}, Map.put(context, :tool_timeout, 100))
      end)

    assert_receive {:resource_gate, gate}, 1_000
    assert {:error, "MCP resource request timed out"} = Task.await(caller)
    send(gate, :release_resource)
    assert {:ok, _} = Handbean.MCP.bootstrap(opts)
    refute_received {:rpc, _, "resources/list", _}
  end

  test "queued HTTP calls are discarded after their caller times out", %{
    context: context,
    opts: opts
  } do
    assert {:ok, boot} = Handbean.MCP.bootstrap(opts)
    runtime = boot.servers["docs"].pid

    first =
      Task.async(fn ->
        Resources.read_resource(%{"server" => "docs", "uri" => "memo://gate"}, context)
      end)

    assert_receive {:resource_gate, gate}, 1_000
    second = queue_read(runtime, Map.put(context, :tool_timeout, 100))
    assert {:error, "MCP resource request timed out"} = Task.await(second, 2_000)
    send(gate, :release_resource)
    assert {:ok, _} = Task.await(first)
    assert {:ok, []} = ServerRuntime.tools(runtime)
    refute_received {:rpc, _, "resources/read", %{"uri" => "memo://queued"}}
  end

  test "queued HTTP calls recheck authorization at dispatch", %{context: context, opts: opts} do
    assert {:ok, boot} = Handbean.MCP.bootstrap(opts)
    runtime = boot.servers["docs"].pid

    first =
      Task.async(fn ->
        Resources.read_resource(%{"server" => "docs", "uri" => "memo://gate"}, context)
      end)

    assert_receive {:resource_gate, gate}, 1_000
    second = queue_read(runtime, context)
    write_config(opts, "https://docs.example/mcp", ["b"])
    send(gate, :release_resource)
    assert {:error, _} = Task.await(first)
    assert {:error, _} = Task.await(second)
    assert {:ok, []} = ServerRuntime.tools(runtime)
    refute_received {:rpc, _, "resources/read", %{"uri" => "memo://queued"}}
  end

  defp queue_read(runtime, context) do
    task =
      Task.async(fn ->
        receive do
          :begin_resource ->
            Resources.read_resource(%{"server" => "docs", "uri" => "memo://queued"}, context)
        end
      end)

    :erlang.trace(task.pid, true, [:send])
    send(task.pid, :begin_resource)
    pid = task.pid

    assert_receive {:trace, ^pid, :send, {:"$gen_call", _, {:resource_request, _, _, _, _}},
                    ^runtime},
                   1_000

    :erlang.trace(pid, false, [:send])
    task
  end

  defp write_config(opts, url \\ "https://docs.example/mcp", workspaces \\ ["a"]) do
    File.write!(
      opts[:user_config_path],
      Handbean.JSON.encode!(%{
        "mcpServers" => %{
          "docs" => %{
            "url" => url,
            "workspace_access" => %{"mode" => "selected", "workspace_ids" => workspaces}
          }
        }
      })
    )
  end

  defp response(%{host: "modern.example"} = conn, %{"method" => "server/discover"} = message, _),
    do:
      rpc(conn, message, %{
        resultType: "complete",
        supportedVersions: ["2026-07-28"],
        capabilities: %{resources: %{}}
      })

  defp response(conn, %{"method" => "server/discover"}, _), do: Plug.Conn.send_resp(conn, 400, "")

  defp response(conn, %{"method" => "notifications/initialized"}, _),
    do: Plug.Conn.send_resp(conn, 202, "")

  defp response(conn, %{"method" => "initialize"} = message, _) do
    capabilities = if conn.host == "no-resources.example", do: %{}, else: %{"resources" => %{}}
    rpc(conn, message, %{protocolVersion: "2025-11-25", capabilities: capabilities})
  end

  defp response(conn, %{"method" => "tools/list"} = message, _),
    do: rpc(conn, message, %{tools: []})

  defp response(conn, %{"method" => "resources/list", "params" => params} = message, _) do
    result =
      case params["cursor"] do
        "opaque+/second=" ->
          %{resources: [%{uri: "memo://second", name: "Second"}]}

        "too-many" ->
          %{resources: List.duplicate(%{uri: "memo://a", name: "a"}, 101)}

        "too-large" ->
          %{
            resources: [%{uri: "memo://a", name: "a", description: String.duplicate("x", 70_000)}]
          }

        "bad-metadata" ->
          %{resources: [%{uri: "memo://a", name: "a", description: %{blob: "AAECAw=="}}]}

        "bad-entry" ->
          %{resources: [%{name: "no URI"}]}

        "repeated" ->
          %{resources: [], nextCursor: "repeated"}

        _ ->
          %{
            resources: [%{uri: "memo://first", name: "first", title: "First"}],
            nextCursor: "opaque+/second="
          }
      end

    rpc(conn, message, result)
  end

  defp response(conn, %{"method" => "resources/templates/list", "params" => params} = message, _) do
    case params["cursor"] do
      "unsupported" ->
        rpc_error(conn, message, -32601)

      "templates-next" ->
        rpc(conn, message, %{resourceTemplates: []})

      _ ->
        rpc(conn, message, %{
          resourceTemplates: [%{name: "Memo", uriTemplate: "memo://{name}"}],
          nextCursor: "templates-next"
        })
    end
  end

  defp response(
         conn,
         %{"method" => "resources/read", "params" => %{"uri" => uri}} = message,
         opts
       ) do
    case uri do
      "memo://sse" ->
        assert Plug.Conn.get_req_header(conn, "mcp-method") == ["resources/read"]
        assert Plug.Conn.get_req_header(conn, "mcp-name") == [uri]

        body =
          "data: " <>
            Handbean.JSON.encode!(%{
              jsonrpc: "2.0",
              method: "notifications/resources/list_changed"
            }) <>
            "\n\ndata: " <>
            Handbean.JSON.encode!(%{
              jsonrpc: "2.0",
              id: message["id"],
              result: %{contents: [%{uri: uri, text: "event-stream"}]}
            }) <> "\n\n"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)

      "memo://missing" ->
        rpc_error(conn, message, -32002)

      "memo://error" ->
        rpc_error(conn, message, -32603)

      "memo://revoke" ->
        write_config(opts, "https://docs.example/mcp", ["b"])
        rpc(conn, message, %{contents: [%{uri: uri, text: "sensitive-response"}]})

      "memo://mixed" ->
        rpc(conn, message, %{
          contents: [
            %{uri: uri, text: String.duplicate("中", 20_000)},
            %{uri: uri, text: "tail"},
            %{uri: "memo://binary", mimeType: "application/octet-stream", blob: "AAECAw=="}
          ]
        })

      "memo://utf8-boundary" ->
        rpc(conn, message, %{contents: [%{uri: uri, text: String.duplicate("x", 47_999) <> "中"}]})

      "memo://escaped-overflow" ->
        rpc(conn, message, %{contents: [%{uri: uri, text: String.duplicate("\u0001", 48_000)}]})

      "memo://invalid-base64" ->
        rpc(conn, message, %{contents: [%{uri: uri, blob: "not/base64"}]})

      "memo://both" ->
        rpc(conn, message, %{contents: [%{uri: uri, text: "x", blob: "AAECAw=="}]})

      "memo://invalid-contents" ->
        rpc(conn, message, %{contents: "bad"})

      "memo://too-many-contents" ->
        rpc(conn, message, %{contents: List.duplicate(%{uri: uri, text: "x"}, 65)})

      _ ->
        rpc(conn, message, %{contents: [%{uri: uri, text: "remote:" <> uri}]})
    end
  end

  defp rpc(conn, message, result),
    do: Req.Test.json(conn, %{jsonrpc: "2.0", id: message["id"], result: result})

  defp rpc_error(conn, message, code),
    do:
      Req.Test.json(conn, %{
        jsonrpc: "2.0",
        id: message["id"],
        error: %{code: code, message: "untrusted error with sensitive payload"}
      })

  defp stdio_script, do: File.read!(Path.expand("../../fixtures/mcp/resource_server.sh", __DIR__))
end
