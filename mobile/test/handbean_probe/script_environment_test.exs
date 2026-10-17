defmodule HandbeanProbe.ScriptEnvironmentTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.{Registry, ScriptEnvironment}
  alias Handbean.Tool.Builtin.RunElixirScript

  setup do
    host = Application.get_env(:handbean, :host)
    prior_tool = Registry.get("run_elixir_script")

    on_exit(fn ->
      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      if prior_tool == :error, do: Registry.unregister("run_elixir_script")
    end)

    Handbean.Host.put!(%{shell: false, host_script: true, terminal: false, mcp: false})
    :ok
  end

  test "curated snapshot reflects actual APIs without guessing HTTP host configuration" do
    info = ScriptEnvironment.snapshot()
    assert info.elixir == System.version()
    assert info.otp == to_string(:erlang.system_info(:otp_release))
    assert Enum.all?(info.available, fn {_, available} -> available end)
    refute info.http_configured?
    description = ScriptEnvironment.describe(info)
    assert description =~ "Req.get"
    assert description =~ "NimbleCSV.RFC4180"
    assert description =~ "[full_match, capture]"
    assert description =~ ":zlib.gzip"
    assert description =~ "not a sandbox"
    assert description =~ "No host-specific Req DNS/CA configuration"
  end

  test "missing APIs are omitted, Mix.install is unavailable when Mix is absent, host claims are gated" do
    info = ScriptEnvironment.snapshot()

    unavailable = %{info | available: Map.new(info.available, fn {k, _} -> {k, false} end)}
    description = ScriptEnvironment.describe(%{unavailable | mix?: false, hex?: false})
    refute description =~ "CSV: NimbleCSV"
    refute description =~ "HTTPS: Req.get"
    refute description =~ "JSON: Jason"
    assert description =~ "Mix absent, Hex absent"
    assert description =~ "Mix.install is unavailable"
    assert description =~ "Do not call Mix.install"
    refute description =~ "This tool does not provide a dependency installer"

    Handbean.Host.put!(%{script_http: :platform_dns_ca})
    assert ScriptEnvironment.describe() =~ "host has configured Req with platform DNS"

    refute ScriptEnvironment.describe(%{unavailable | http_configured?: true}) =~
             "host has configured Req"
  end

  for mode <- [:default, :custom], protocol <- [:anthropic, :openai] do
    @tag capture_log: true
    test "#{mode} system prompt sends complete script guidance in #{protocol} provider JSON" do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        {system, tools} =
          case unquote(protocol) do
            :anthropic ->
              {payload["system"], payload["tools"]}

            :openai ->
              system = Enum.find(payload["messages"], &(&1["role"] == "system"))
              {system["content"], Enum.map(payload["tools"], & &1["function"])}
          end

        tool = Enum.find(tools, &(&1["name"] == "run_elixir_script"))
        send(owner, {:outbound_script, system, tool["description"]})

        response = %{
          "id" => "script-env-check",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }

        response =
          if unquote(protocol) == :openai do
            %{
              "choices" => [
                %{
                  "message" => %{"role" => "assistant", "content" => "ok"},
                  "finish_reason" => "stop"
                }
              ],
              "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
            }
          else
            response
          end

        Req.Test.json(conn, response)
      end)

      provider =
        if unquote(protocol) == :openai,
          do: Handbean.Agent.Provider.StepFun,
          else: Handbean.Agent.Provider.Anthropic

      opts = [
        provider: provider,
        model: "fixture",
        tools: [RunElixirScript],
        working_directory: System.tmp_dir!(),
        streaming: false,
        max_turns: 2,
        provider_config: %{
          api_key: "fixture-only",
          cache: false,
          req_options: [plug: {Req.Test, __MODULE__}, retry: false]
        }
      ]

      opts =
        if unquote(mode) == :custom,
          do: Keyword.put(opts, :system_prompt, "Custom prompt only."),
          else: opts

      assert {:ok, %{status: :completed}} = Handbean.Agent.run("Check environment", opts)
      assert_received {:outbound_script, system, description}
      assert description == RunElixirScript.description()
      assert description =~ "NimbleCSV.RFC4180"
      assert description =~ "Req.get"
      assert description =~ "NOT automatically workspace-relative"
      refute system =~ "NimbleCSV.RFC4180"

      if unquote(mode) == :custom do
        assert String.starts_with?(system, "Custom prompt only.\n")
        assert system =~ "## Host execution environment"
        assert system =~ "There is no Unix shell on this host available to the agent."
        assert system =~ "These host capabilities do not grant permission."
      end
    end
  end
end
