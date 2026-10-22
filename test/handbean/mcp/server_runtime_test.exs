defmodule Handbean.MCP.ServerRuntimeTest do
  @moduledoc """
  Tests for MCP ServerRuntime (HTTP + stdio transports).

  HTTP tests hit the real StepFun search endpoint and are tagged :external_api.
  Run with: mix test test/handbean/mcp/server_runtime_test.exs --tag @external_api
  Skip them: mix test test/handbean/mcp/server_runtime_test.exs --exclude @external_api
  """
  use ExUnit.Case, async: false

  alias Handbean.MCP.{ServerConfig, ServerRuntime}

  describe "stdio lifecycle" do
    test "start_link returns before the initialize response arrives" do
      gate = Path.join(System.tmp_dir!(), "mcp_stdio_gate_#{System.unique_integer([:positive])}")
      {cfg, dir} = stdio_config("gated_initialize", [gate])
      {:ok, pid} = ServerRuntime.start_link(server_config: cfg)

      on_exit(fn ->
        ServerRuntime.shutdown(pid)
        File.rm_rf!(dir)
        File.rm(gate)
      end)

      tools_task = Task.async(fn -> ServerRuntime.tools(pid) end)

      assert {:error, "MCP server is still initializing"} =
               ServerRuntime.call_tool(pid, "echo", %{}, 100)

      File.write!(gate, "continue")
      assert {:ok, [%{name: "echo"}]} = Task.await(tools_task, 5_000)
    end

    test "routes concurrent out-of-order responses to their JSON-RPC callers" do
      pid = start_stdio_runtime!("out_of_order")

      tasks =
        for value <- ["first", "second"] do
          Task.async(fn -> ServerRuntime.call_tool(pid, "echo", %{"value" => value}, 500) end)
        end

      assert [{:ok, "first", _first_meta}, {:ok, "second", _second_meta}] =
               Enum.map(tasks, &Task.await(&1, 1_000))
    end
  end

  describe "stdio framing" do
    test "consumes coalesced notifications and unrelated responses before the matching response" do
      pid = start_stdio_runtime!("coalesced")

      assert {:ok, "coalesced", _meta} =
               ServerRuntime.call_tool(pid, "echo", %{}, 200)
    end

    test "retains a partial JSON message across port data chunks" do
      pid = start_stdio_runtime!("split")

      assert {:ok, text, _meta} = ServerRuntime.call_tool(pid, "echo", %{}, 500)
      assert byte_size(text) == 131_072
    end

    test "notifications do not reset the absolute request deadline" do
      pid = start_stdio_runtime!("notifications_until_timeout")
      started_at = System.monotonic_time(:millisecond)

      assert {:error, error} = ServerRuntime.call_tool(pid, "echo", %{}, 40)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert error =~ "mcp_timeout"
      assert elapsed_ms < 200
    end

    test "rejects a malformed complete line even when a valid response follows" do
      pid = start_stdio_runtime!("malformed")

      assert {:error, error} = ServerRuntime.call_tool(pid, "echo", %{}, 200)
      assert error =~ "invalid_stdio_message"
    end

    test "does not parse stderr output as protocol messages" do
      pid = start_stdio_runtime!("stderr")

      assert {:ok, "stderr-separated", _meta} =
               ServerRuntime.call_tool(pid, "echo", %{}, 200)
    end

    test "does not accept an unterminated response when the port exits" do
      pid = start_stdio_runtime!("exit_with_tail")

      assert {:error, error} = ServerRuntime.call_tool(pid, "echo", %{}, 200)
      assert error =~ "incomplete_stdio_message"
    end
  end

  describe "HTTP transport - stepsearch" do
    @tag :external_api
    test "start_link, tools, and call_tool end-to-end" do
      cfg = server_config("stepsearch")
      assert {:ok, pid} = Handbean.MCP.ServerRuntime.start_link(server_config: cfg)
      assert Process.alive?(pid)

      assert {:ok, tools} = Handbean.MCP.ServerRuntime.tools(pid)
      tool_names = Enum.map(tools, & &1.name)
      assert "web_search" in tool_names
      assert "web_fetch" in tool_names

      assert {:ok, text, _meta} =
               Handbean.MCP.ServerRuntime.call_tool(pid, "web_search", %{
                 "query" => "test",
                 "n" => 1
               })

      assert is_binary(text)
      assert String.length(text) > 0

      Handbean.MCP.ServerRuntime.shutdown(pid)
      refute Process.alive?(pid)
    end

    @tag :external_api
    test "call_tool returns 3-tuple" do
      cfg = server_config("stepsearch")
      {:ok, pid} = Handbean.MCP.ServerRuntime.start_link(server_config: cfg)

      assert {:ok, _text, _meta} =
               Handbean.MCP.ServerRuntime.call_tool(pid, "web_search", %{
                 "query" => "Elixir",
                 "n" => 1
               })

      Handbean.MCP.ServerRuntime.shutdown(pid)
    end

    @tag :external_api
    test "search returns structured results" do
      cfg = server_config("stepsearch")
      {:ok, pid} = Handbean.MCP.ServerRuntime.start_link(server_config: cfg)

      {:ok, text, _meta} =
        Handbean.MCP.ServerRuntime.call_tool(pid, "web_search", %{"query" => "Elixir", "n" => 2})

      result = Jason.decode!(text)
      assert result["query"] == "Elixir"
      assert length(result["results"]) <= 2
      assert Enum.all?(result["results"], &match?(%{"title" => _, "url" => _}, &1))

      Handbean.MCP.ServerRuntime.shutdown(pid)
    end

    @tag :external_api
    test "web_fetch retrieves page content" do
      cfg = server_config("stepsearch")
      {:ok, pid} = Handbean.MCP.ServerRuntime.start_link(server_config: cfg)

      {:ok, text, _meta} =
        Handbean.MCP.ServerRuntime.call_tool(pid, "web_fetch", %{
          "url" => "https://elixir-lang.org"
        })

      result = Jason.decode!(text)
      assert is_binary(result["content"])
      assert String.length(result["content"]) > 0

      Handbean.MCP.ServerRuntime.shutdown(pid)
    end
  end

  describe "bootstrap / teardown cycle" do
    setup do
      start_supervised!(Handbean.MCP.RuntimeSupervisor)
      start_supervised!(Handbean.MCP)
      orig_tools = Enum.filter(Handbean.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))

      on_exit(fn ->
        current = Enum.filter(Handbean.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))
        Enum.each(current -- orig_tools, &Handbean.Tool.Registry.unregister/1)
      end)

      :ok
    end

    test "teardown_previous removes all mcp__ tools" do
      for name <- ["mcp__fake__a", "mcp__fake__b"] do
        :ok =
          Handbean.Tool.Registry.register_virtual(name, "fake", %{}, fn _input, _ctx ->
            {:ok, "fake"}
          end)
      end

      assert length(Enum.filter(Handbean.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))) >=
               2

      Handbean.MCP.teardown_previous()

      remaining = Enum.filter(Handbean.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))
      assert remaining == []
    end

    test "double bootstrap does not duplicate tools" do
      dir = setup_temp_project(%{})
      on_exit(fn -> File.rm_rf!(dir) end)
      assert {:ok, first} = Handbean.MCP.bootstrap(project: dir, user_config_path: nil)
      assert {:ok, ^first} = Handbean.MCP.bootstrap(project: dir, user_config_path: nil)
      assert first.registered == []
    end

    test "bootstrap returns server_errors on failure" do
      dir = setup_temp_project(%{"broken" => %{"command" => "nonexistent_cmd_xyz"}})
      {:ok, result} = Handbean.MCP.bootstrap(project: dir, user_config_path: nil)
      errors = Map.get(result, :server_errors, [])
      assert Enum.any?(errors, &(&1.server == "broken"))
      File.rm_rf!(dir)
    end

    test "bootstrap records a server failure instead of raising" do
      dir = setup_temp_project(%{"broken" => %{"command" => "nonexistent_cmd_xyz"}})
      assert {:ok, result} = Handbean.MCP.bootstrap(project: dir, user_config_path: nil)
      assert Enum.any?(result.server_errors, &(&1.server == "broken"))
      File.rm_rf!(dir)
    end
  end

  describe "parse_http_response" do
    test "accepts already-decoded map from Req" do
      body = %{"id" => "1", "jsonrpc" => "2.0", "result" => %{"tools" => []}}
      assert {:ok, %{"tools" => []}} = Handbean.MCP.ServerRuntime.parse_http_response(body)
    end

    test "accepts binary JSON string" do
      body = ~s({"id":"1","jsonrpc":"2.0","result":{"tools":[]}})
      assert {:ok, %{"tools" => []}} = Handbean.MCP.ServerRuntime.parse_http_response(body)
    end

    test "returns error for JSON-RPC error response (map)" do
      body = %{"id" => "1", "jsonrpc" => "2.0", "error" => %{"message" => "not found"}}

      assert {:error, %{"message" => "not found"}} =
               Handbean.MCP.ServerRuntime.parse_http_response(body)
    end

    test "returns error for unexpected body" do
      assert {:error, _} = Handbean.MCP.ServerRuntime.parse_http_response(%{"random" => "data"})
    end
  end

  defp server_config(name) do
    %Handbean.MCP.ServerConfig{
      name: name,
      command: nil,
      args: [],
      env: %{},
      runtime_env: %{},
      disabled: false,
      cwd: nil,
      transport: "stdio",
      type: nil,
      url: "https://api.stepfun.com/step_plan/v1/mcp/web_search/mcp",
      headers: %{
        "Authorization" => "Bearer test-mcp-token"
      },
      runtime_headers: %{
        "Authorization" => "Bearer test-mcp-token"
      },
      source: "test",
      raw: %{}
    }
  end

  defp setup_temp_project(servers) do
    dir = Path.join(System.tmp_dir!(), "mcp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".mcp.json"), Jason.encode!(%{"mcpServers" => servers}))
    dir
  end

  defp start_stdio_runtime!(scenario) do
    {cfg, dir} = stdio_config(scenario)
    {:ok, pid} = ServerRuntime.start_link(server_config: cfg)

    on_exit(fn ->
      ServerRuntime.shutdown(pid)
      File.rm_rf!(dir)
    end)

    assert {:ok, _tools} = ServerRuntime.tools(pid)
    pid
  end

  defp stdio_config(scenario, extra_args \\ []) do
    dir = Path.join(System.tmp_dir!(), "mcp_stdio_#{System.unique_integer([:positive])}")
    script = Path.join(dir, "server.sh")
    File.mkdir_p!(dir)
    File.write!(script, stdio_server_script())
    File.chmod!(script, 0o700)

    cfg = %ServerConfig{
      name: "stdio-#{scenario}",
      command: script,
      args: [scenario | extra_args],
      runtime_env: %{}
    }

    {cfg, dir}
  end

  defp stdio_server_script do
    ~S"""
    #!/bin/sh
    scenario="$1"
    gate="$2"
    call_count=0

    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

      case "$line" in
        *'"method":"initialize"'*)
          if [ "$scenario" = "gated_initialize" ]; then
            while [ ! -f "$gate" ]; do
              sleep 0.01
            done
          fi

          if [ "$scenario" = "stderr" ]; then
            printf '{"jsonrpc":"2.0","id":"%s","error":{"message":"stderr is not protocol"}}\n' "$id" >&2
            printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
          else
            printf '{"jsonrpc":"2.0","id":"%s","result":{}}\n' "$id"
          fi
          ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":"%s","result":{"tools":[{"name":"echo","inputSchema":{}}]}}\n' "$id"
          ;;
        *'"method":"tools/call"'*)
          case "$scenario" in
            out_of_order)
              value=$(printf '%s\n' "$line" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
              call_count=$((call_count + 1))

              if [ "$call_count" -eq 1 ]; then
                first_id="$id"
                first_value="$value"
              else
                printf '{"jsonrpc":"2.0","id":"%s","result":{"content":"%s"}}\n{"jsonrpc":"2.0","id":"%s","result":{"content":"%s"}}\n' "$id" "$value" "$first_id" "$first_value"
              fi
              ;;
            coalesced)
              printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n{"jsonrpc":"2.0","id":"unrelated","result":{}}\n{"jsonrpc":"2.0","id":"%s","result":{"content":"coalesced"}}\n' "$id"
              ;;
            split)
              printf '{"jsonrpc":"2.0","id":"%s","result":{"content":"' "$id"
              awk 'BEGIN { for (i = 0; i < 131072; i++) printf "a" }'
              printf '"}}\n'
              ;;
            notifications_until_timeout)
              i=0
              while [ "$i" -lt 30 ]; do
                printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"n":%s}}\n' "$i" 2>/dev/null || exit 0
                sleep 0.01
                i=$((i + 1))
              done
              ;;
            malformed)
              printf 'not-json\n{"jsonrpc":"2.0","id":"%s","result":{"content":"must-not-pass"}}\n' "$id"
              ;;
            stderr)
              printf '{"jsonrpc":"2.0","id":"%s","result":{"content":"stderr-separated"}}\n' "$id"
              ;;
            exit_with_tail)
              printf '{"jsonrpc":"2.0","id":"%s","result":{"content":"must-not-pass"}}' "$id"
              exit 7
              ;;
          esac
          ;;
      esac
    done
    """
  end
end
