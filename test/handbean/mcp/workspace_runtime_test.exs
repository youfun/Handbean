defmodule Handbean.MCP.WorkspaceRuntimeTest do
  use ExUnit.Case, async: false
  alias Handbean.MCP.{Access, Settings, ServerRuntime}

  setup do
    start_supervised!(Handbean.MCP.RuntimeSupervisor)
    start_supervised!(Handbean.MCP)
    Req.Test.set_req_test_to_shared()
    old = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    root = Path.join(System.tmp_dir!(), "mcp-runtime-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      send(owner, {:request, conn.host, message["method"]})
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json, text/event-stream"]

      case message["method"] do
        "server/discover" ->
          if conn.host == "slow.example" do
            send(owner, {:slow_discovery, self()})

            receive do
              :release_slow_discovery -> :ok
            end
          end

          if conn.host == "modern.example" do
            assert Plug.Conn.get_req_header(conn, "mcp-protocol-version") == ["2026-07-28"]
            assert Plug.Conn.get_req_header(conn, "mcp-method") == ["server/discover"]

            Req.Test.json(conn, %{
              jsonrpc: "2.0",
              id: message["id"],
              result: %{
                resultType: "complete",
                supportedVersions: ["2026-07-28"]
              }
            })
          else
            Plug.Conn.send_resp(conn, 400, "")
          end

        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-#{conn.host}")
          |> Req.Test.json(%{
            jsonrpc: "2.0",
            id: message["id"],
            result: %{protocolVersion: "2025-11-25"}
          })

        "notifications/initialized" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-#{conn.host}"]
          Plug.Conn.send_resp(conn, 202, "")

        "tools/list" ->
          version =
            if conn.host == "modern.example", do: "2026-07-28", else: "2025-11-25"

          assert Plug.Conn.get_req_header(conn, "mcp-protocol-version") == [version]

          Req.Test.json(conn, %{
            jsonrpc: "2.0",
            id: message["id"],
            result: %{
              tools: [%{name: "echo", description: "Echo", inputSchema: %{type: "object"}}]
            }
          })

        "tools/call" ->
          if conn.host == "modern.example" do
            assert Plug.Conn.get_req_header(conn, "mcp-protocol-version") == ["2026-07-28"]
            assert Plug.Conn.get_req_header(conn, "mcp-method") == ["tools/call"]
            assert Plug.Conn.get_req_header(conn, "mcp-name") == ["echo"]

            assert message["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] ==
                     "2026-07-28"
          else
            assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-#{conn.host}"]
          end

          result = %{
            content: [%{type: "text", text: conn.host}],
            isError: message["params"]["arguments"]["fail"] == true
          }

          body =
            "event: message\ndata: " <>
              Jason.encode!(%{jsonrpc: "2.0", method: "notifications/progress"}) <>
              "\n\n" <>
              "data: " <>
              Jason.encode!(%{jsonrpc: "2.0", id: message["id"], result: result}) <> "\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)
      end
    end)

    on_exit(fn ->
      Req.default_options(old)
      File.rm_rf!(root)
    end)

    %{root: root, opts: [user_config_path: Path.join(root, "mcp.json")]}
  end

  test "default MCP exposure is deferred and direct still declares tools", %{opts: opts} do
    File.write!(
      opts[:user_config_path],
      Jason.encode!(%{
        "mcpServers" => %{
          "docs" => %{"url" => "https://one.example/mcp", "name" => "Docs"},
          "shown" => %{
            "url" => "https://two.example/mcp",
            "name" => "Shown",
            "exposure" => "direct"
          }
        }
      })
    )

    a = Keyword.put(opts, :workspace_id, "a")
    {:ok, boot} = Handbean.MCP.bootstrap(a)

    entries =
      Enum.map(boot.registered, fn name ->
        {:ok, entry} = Handbean.Tool.Registry.get(name)
        entry
      end)

    hidden = Enum.find(entries, &(&1.meta.server == "docs"))
    shown = Enum.find(entries, &(&1.meta.server == "shown"))
    assert hidden.deferred?
    refute hidden.nested_only?
    refute shown.deferred?
    refute shown.nested_only?

    defs = Handbean.Tool.Registry.tool_defs()
    refute Enum.any?(defs, &(&1.name == hidden.name))
    assert Enum.any?(defs, &(&1.name == shown.name))
    assert {:ok, "one.example", _} = hidden.executor.(%{}, %{mcp_scope: a})
  end

  test "two workspaces keep independent runtimes; revoke blocks discovery AND captured executors",
       %{opts: opts} do
    form =
      Settings.new_form("a")
      |> Map.merge(%{
        "name" => "Docs",
        "url" => "https://one.example/mcp",
        "workspace_ids" => ["a", "b"]
      })

    {:ok, id} = Settings.save(form, opts)
    a = Keyword.put(opts, :workspace_id, "a")
    b = Keyword.put(opts, :workspace_id, "b")
    {:ok, first} = Handbean.MCP.bootstrap(a)
    {:ok, second} = Handbean.MCP.bootstrap(b)
    assert Enum.all?(first.runtime_pids, &Process.alive?/1)
    assert first.registered != second.registered
    [name] = first.registered
    assert byte_size(name) <= 64
    {:ok, tool} = Handbean.Tool.Registry.get(name)
    assert {:ok, "one.example", _} = tool.executor.(%{}, %{mcp_scope: a})
    assert {:error, _} = tool.executor.(%{}, %{mcp_scope: b})
    definitions = Enum.map(first.registered ++ second.registered, &%{name: &1})
    assert [%{name: ^name}] = Access.filter(definitions, %{mcp_scope: a})
    assert [] = Access.filter([%{name: name}], %{})

    {:ok, edit} = Settings.edit(id, opts)
    {:ok, ^id} = Settings.save(%{edit | "workspace_ids" => ["b"]}, opts)
    assert {:error, _} = tool.executor.(%{}, %{mcp_scope: a})
    assert [] = Access.filter([%{name: name}], %{mcp_scope: a})
    {:ok, other_tool} = Handbean.Tool.Registry.get(hd(second.registered))
    assert {:ok, "one.example", _} = other_tool.executor.(%{}, %{mcp_scope: b})
    {:ok, empty} = Handbean.MCP.bootstrap(a)
    assert empty.registered == []
    assert Enum.all?(second.runtime_pids, &Process.alive?/1)
  end

  test "bootstrap is single-flight per scope and a slow workspace does not block another", %{
    opts: opts
  } do
    File.write!(
      opts[:user_config_path],
      Jason.encode!(%{
        "mcpServers" => %{
          "slow" => %{
            "url" => "https://slow.example/mcp",
            "workspace_access" => %{"mode" => "selected", "workspace_ids" => ["a"]}
          },
          "fast" => %{
            "url" => "https://fast.example/mcp",
            "workspace_access" => %{"mode" => "selected", "workspace_ids" => ["b"]}
          }
        }
      })
    )

    a = Keyword.put(opts, :workspace_id, "a")
    b = Keyword.put(opts, :workspace_id, "b")
    first = Task.async(fn -> Handbean.MCP.bootstrap(a) end)
    assert_receive {:slow_discovery, gate}, 1_000
    on_exit(fn -> send(gate, :release_slow_discovery) end)

    parent = self()

    second =
      Task.async(fn ->
        send(parent, :second_bootstrap_started)
        Handbean.MCP.bootstrap(a)
      end)

    assert_receive :second_bootstrap_started

    assert {:ok, fast_result} = Task.await(Task.async(fn -> Handbean.MCP.bootstrap(b) end), 1_000)
    assert length(fast_result.registered) == 1

    send(gate, :release_slow_discovery)
    assert {:ok, slow_result} = Task.await(first, 1_000)
    assert {:ok, ^slow_result} = Task.await(second, 1_000)
    assert_receive {:request, "slow.example", "server/discover"}
    refute_received {:request, "slow.example", "server/discover"}
  end

  test "a delayed candidate-start message cannot retire an already committed runtime", %{
    opts: opts
  } do
    write_server!(opts, "docs", "https://fast.example/mcp")
    scope_opts = Keyword.put(opts, :workspace_id, "a")
    assert {:ok, result} = Handbean.MCP.bootstrap(scope_opts)
    [runtime] = result.runtime_pids
    runtime_ref = Process.monitor(runtime)

    send(Handbean.MCP, {:mcp_candidate_started, make_ref(), runtime})
    :sys.get_state(Handbean.MCP)

    assert Process.alive?(runtime)
    refute_receive {:DOWN, ^runtime_ref, :process, ^runtime, _reason}, 100
    assert Enum.all?(result.registered, &(Handbean.Tool.Registry.get(&1) != :error))
  end

  test "teardown detaches a stale flight so the same scope can bootstrap immediately", %{
    opts: opts
  } do
    write_server!(opts, "slow", "https://slow.example/mcp")
    scope_opts = Keyword.put(opts, :workspace_id, "a")
    bootstrap = Task.async(fn -> Handbean.MCP.bootstrap(scope_opts) end)
    assert_receive {:slow_discovery, gate}, 1_000
    on_exit(fn -> send(gate, :release_slow_discovery) end)

    [{_, old_runtime, :worker, _}] =
      DynamicSupervisor.which_children(Handbean.MCP.RuntimeSupervisor)

    old_runtime_ref = Process.monitor(old_runtime)
    assert :ok = Handbean.MCP.teardown_previous()
    assert {:error, :teardown} = Task.await(bootstrap, 1_000)

    write_server!(opts, "fast", "https://fast.example/mcp")
    assert {:ok, fresh} = Handbean.MCP.bootstrap(scope_opts)
    assert length(fresh.runtime_pids) == 1
    assert Process.alive?(hd(fresh.runtime_pids))

    send(gate, :release_slow_discovery)
    assert_receive {:DOWN, ^old_runtime_ref, :process, ^old_runtime, :normal}, 1_000
    assert Enum.all?(fresh.registered, &(Handbean.Tool.Registry.get(&1) != :error))
  end

  test "teardown retires the previous scope while its replacement is still starting", %{
    opts: opts
  } do
    write_server!(opts, "docs", "https://one.example/mcp")
    scope_opts = Keyword.put(opts, :workspace_id, "a")
    assert {:ok, previous} = Handbean.MCP.bootstrap(scope_opts)
    [previous_runtime] = previous.runtime_pids
    previous_ref = Process.monitor(previous_runtime)

    write_server!(opts, "docs", "https://slow.example/mcp")
    replacement = Task.async(fn -> Handbean.MCP.bootstrap(scope_opts) end)
    assert_receive {:slow_discovery, gate}, 1_000
    on_exit(fn -> send(gate, :release_slow_discovery) end)

    replacement_runtime =
      Handbean.MCP.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(&elem(&1, 1))
      |> Enum.find(&(&1 != previous_runtime))

    replacement_ref = Process.monitor(replacement_runtime)
    assert :ok = Handbean.MCP.teardown_previous()
    assert {:error, :teardown} = Task.await(replacement, 1_000)
    assert_receive {:DOWN, ^previous_ref, :process, ^previous_runtime, :normal}, 1_000

    send(gate, :release_slow_discovery)
    assert_receive {:DOWN, ^replacement_ref, :process, ^replacement_runtime, :normal}, 1_000
  end

  test "a crashed multi-server bootstrap cleans partial runtimes without blocking MCP", %{
    opts: opts
  } do
    File.write!(
      opts[:user_config_path],
      Jason.encode!(%{
        "mcpServers" => %{
          "fast" => %{"url" => "https://one.example/mcp"},
          "slow" => %{"url" => "https://slow.example/mcp"}
        }
      })
    )

    scope_opts = Keyword.put(opts, :workspace_id, "a")
    mcp = Process.whereis(Handbean.MCP)
    :erlang.trace(mcp, true, [:receive])

    on_exit(fn ->
      if Process.alive?(mcp), do: :erlang.trace(mcp, false, [:receive])
    end)

    caller =
      Task.Supervisor.async_nolink(Handbean.AgentRunTaskSupervisor, fn ->
        Handbean.MCP.bootstrap(scope_opts)
      end)

    assert_receive {:trace, ^mcp, :receive, {:mcp_candidate_started, flight_id, _pid}}, 1_000
    assert_receive {:slow_discovery, gate}, 1_000
    on_exit(fn -> send(gate, :release_slow_discovery) end)
    :erlang.trace(mcp, false, [:receive])

    scope = Access.scope(scope_opts)
    flight = :sys.get_state(mcp).flights[scope]
    assert flight.id == flight_id
    assert MapSet.size(flight.candidate_pids) >= 1

    partial_runtimes =
      Handbean.MCP.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.map(&elem(&1, 1))

    runtime_refs = Map.new(partial_runtimes, &{&1, Process.monitor(&1)})
    Process.exit(flight.task.pid, :kill)
    assert {:error, :killed} = Task.await(caller, 1_000)

    write_server!(opts, "fresh", "https://fast.example/mcp")
    assert {:ok, fresh} = Handbean.MCP.bootstrap(Keyword.put(opts, :workspace_id, "b"))
    assert length(fresh.runtime_pids) == 1

    send(gate, :release_slow_discovery)

    Enum.each(runtime_refs, fn {runtime, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^runtime, _reason}, 1_000
    end)
  end

  test "A then B then A preserves request order instead of joining the first A", %{opts: opts} do
    write_server!(opts, "docs", "https://slow.example/mcp")
    scope_opts = Keyword.put(opts, :workspace_id, "a")
    first = Task.async(fn -> Handbean.MCP.bootstrap(scope_opts) end)
    assert_receive {:slow_discovery, first_gate}, 1_000
    on_exit(fn -> send(first_gate, :release_slow_discovery) end)

    mcp = Process.whereis(Handbean.MCP)
    scope = Access.scope(scope_opts)
    :erlang.trace(mcp, true, [:receive])

    on_exit(fn ->
      if Process.alive?(mcp), do: :erlang.trace(mcp, false, [:receive])
    end)

    write_server!(opts, "docs", "https://two.example/mcp")
    second = Task.async(fn -> Handbean.MCP.bootstrap(scope_opts) end)

    assert_receive {:trace, ^mcp, :receive, {:"$gen_call", _, {:bootstrap, _}}}, 1_000
    assert length(:sys.get_state(mcp).flights[scope].queued) == 1

    write_server!(opts, "docs", "https://slow.example/mcp")
    third = Task.async(fn -> Handbean.MCP.bootstrap(scope_opts) end)

    assert_receive {:trace, ^mcp, :receive, {:"$gen_call", _, {:bootstrap, _}}}, 1_000
    assert length(:sys.get_state(mcp).flights[scope].queued) == 2
    :erlang.trace(mcp, false, [:receive])

    send(first_gate, :release_slow_discovery)
    assert {:ok, first_result} = Task.await(first, 1_000)
    assert {:ok, second_result} = Task.await(second, 1_000)
    assert_receive {:slow_discovery, third_gate}, 1_000
    on_exit(fn -> send(third_gate, :release_slow_discovery) end)
    send(third_gate, :release_slow_discovery)
    assert {:ok, third_result} = Task.await(third, 1_000)

    assert first_result.config != second_result.config
    assert first_result.config == third_result.config
    assert first_result.runtime_pids != third_result.runtime_pids
  end

  test "same ID with a changed URL replaces connection; successful config is reused", %{
    opts: opts
  } do
    form =
      Settings.new_form("a") |> Map.merge(%{"name" => "Docs", "url" => "https://one.example/mcp"})

    {:ok, id} = Settings.save(form, opts)
    a = Keyword.put(opts, :workspace_id, "a")
    {:ok, first} = Handbean.MCP.bootstrap(a)
    assert {:ok, ^first} = Handbean.MCP.bootstrap(a)
    {:ok, edit} = Settings.edit(id, opts)
    {:ok, ^id} = Settings.save(%{edit | "url" => "https://two.example/mcp"}, opts)
    {:ok, second} = Handbean.MCP.bootstrap(a)
    assert first.runtime_pids != second.runtime_pids
    [pid] = second.runtime_pids
    assert {:ok, "two.example", _} = ServerRuntime.call_tool(pid, "echo", %{})
    assert {:error, "two.example", _} = ServerRuntime.call_tool(pid, "echo", %{"fail" => true})
  end

  test "a 2026-07-28 server is used without the initialize handshake", %{opts: opts} do
    form =
      Settings.new_form("a")
      |> Map.merge(%{"name" => "Modern", "url" => "https://modern.example/mcp"})

    {:ok, _} = Settings.save(form, opts)
    {:ok, result} = Handbean.MCP.bootstrap(Keyword.put(opts, :workspace_id, "a"))
    assert_received {:request, "modern.example", "server/discover"}
    refute_received {:request, "modern.example", "initialize"}
    [pid] = result.runtime_pids
    assert {:ok, "modern.example", _} = ServerRuntime.call_tool(pid, "echo", %{})
  end

  test "test connection uses draft credentials but never registers or persists tools", %{
    opts: opts
  } do
    original = Handbean.Tool.Registry.list()

    form =
      Settings.new_form("a")
      |> Map.merge(%{"name" => "Docs", "url" => "https://draft.example/mcp"})

    assert {:ok, %{tool_count: 1}} = Settings.test_connection(form, opts)
    assert Handbean.Tool.Registry.list() == original
    refute File.exists?(Settings.path(opts))
  end

  test "mobile host refuses stdio even when asked directly", %{opts: opts} do
    previous = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{shell: false, mcp: true})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    File.write!(
      Settings.path(opts),
      Jason.encode!(%{"mcpServers" => %{"local" => %{"command" => "echo"}}})
    )

    assert Access.config(opts).servers == %{}

    assert {:error, :unsupported_transport} =
             Handbean.MCP.start_runtime(
               server_config: %Handbean.MCP.ServerConfig{name: "local", command: "echo"}
             )
  end

  defp write_server!(opts, name, url) do
    File.write!(
      opts[:user_config_path],
      Jason.encode!(%{"mcpServers" => %{name => %{"url" => url}}})
    )
  end
end
