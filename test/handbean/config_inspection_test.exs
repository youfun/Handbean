defmodule Handbean.ConfigInspectionTest do
  use ExUnit.Case, async: false

  alias Handbean.{ConfigInspection, Host, Settings}
  alias Handbean.Agent.{Config, HostEnvironment}
  alias Handbean.Tool.Registry

  setup do
    root = Path.join(System.tmp_dir!(), "host-inspection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".handbean"))

    keys =
      ~w(HANDBEAN_MODELS_FILE HANDBEAN_GLOBAL_SETTINGS_FILE OPENAI_MODEL OPENAI_BASE_URL PATH)

    env = Map.new(keys, &{&1, System.get_env(&1)})
    app = Application.get_all_env(:handbean)
    System.put_env("HANDBEAN_MODELS_FILE", Path.join(root, "models.json"))
    System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", Path.join(root, "global.json"))
    System.delete_env("OPENAI_MODEL")
    System.delete_env("OPENAI_BASE_URL")
    Host.put!(%{})

    on_exit(fn ->
      Enum.each(env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      for {key, _} <- Application.get_all_env(:handbean),
          do: Application.delete_env(:handbean, key)

      for {key, value} <- app, do: Application.put_env(:handbean, key, value)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "settings values and winning sources use defaults < global < workspace", %{root: root} do
    write(root, "global.json", %{
      "model_ai" => %{"om_message_tokens" => 7001}
    })

    write(root, ".handbean/settings.jsonc", %{
      "memory" => %{"builtin_enabled" => false},
      "model_ai" => %{"om_message_tokens" => 8003}
    })

    report = ConfigInspection.report(workspace: root)
    assert report.memory == %{builtin_enabled: false, source: :workspace_settings}
    refute Map.has_key?(report.model_ai, :om_enabled)
    assert report.model_ai.om_message_tokens == %{value: 8003, source: :workspace_settings}
    assert report.model_ai.om_buffer_tokens == %{value: 10_000, source: :model_ai_defaults}
    assert report.model_ai.reasoning == %{value: "medium", source: :model_ai_defaults}
    refute Handbean.WorkspaceSettings.builtin_memory_enabled(root)
    assert Settings.effective_model_ai(root).om_message_tokens == 8003
  end

  test "malformed settings and invalid approval mode report denial without exception data", %{
    root: root
  } do
    write(root, "global.json", %{"model_ai" => "private malformed content"})

    write(root, ".handbean/settings.jsonc", %{
      "tools" => %{"default_mode" => "private invalid mode"}
    })

    report = ConfigInspection.report(workspace: root)
    assert report.model_ai == %{status: :invalid_settings_shape, effective: :unknown}
    assert report.approval.source == :tool_policy_default
    assert report.approval.effective_default == :deny
    refute Handbean.JSON.encode!(report) =~ "private"
  end

  test "explicit backends stay independent and report their source", %{root: root} do
    Host.put!(%{shell: false, browser_backend: :cli, host_script: false})
    report = ConfigInspection.report(workspace: root)
    assert report.host.shell == %{configured: false, source: :application_host}
    assert report.host.browser_backend.backend == :cli
    assert report.host.browser_backend.source == :application_host
    assert report.host.artifact_delivery_backend.backend == :none
    assert report.host.host_script == %{configured: false, source: :application_host}
    assert report.host.terminal.source == :host_default
    assert tool(report, "bash").disabled_reason == :host_capability_disabled
    assert tool(report, "browser").configured
    refute tool(report, "run_elixir_script").configured
    refute tool(report, "open_url").configured
  end

  test "configured tools are neither dependency availability nor actual registration", %{
    root: root
  } do
    # Registration reflects the existing VM, not the Host values changed after startup.
    names = Registry.list()
    Host.put!(%{shell: false, browser_backend: :webview})
    report = ConfigInspection.report(workspace: root)
    refute tool(report, "bash").configured
    refute tool(report, "run_elixir_script").configured
    assert tool(report, "browser").configured
    assert tool(report, "browser").registered == "browser" in names
    assert tool(report, "run_elixir_script").dependency_available == :unknown
    assert tool(report, "run_elixir_script").run_authorized == :unknown
    assert report.model_visibility.status == :unknown
    assert report.execution.shell.executable_found == :not_checked
    assert report.execution.browser.backend == :webview
    assert report.execution.browser.operational == :unknown
    assert report.execution.git.backend == :none
    assert report.execution.git.source == :host_default
    assert report.execution.mix_project.backend == :none
    assert report.execution.mix_project.source == :host_default
  end

  test "missing executables have a reason without being executed", %{root: root} do
    System.put_env("PATH", root)
    report = ConfigInspection.report(workspace: root)
    refute report.execution.shell.bash_in_path
    assert report.execution.shell.reason == :settings_and_fallback_paths_not_resolved
    assert report.execution.shell.dependency_available == :unknown
    assert report.execution.browser.reason == :executable_missing
    assert report.execution.shell.operational == :unknown
  end

  test "secrets in arbitrary fields, errors, URLs and paths cannot enter the report", %{
    root: root
  } do
    secret = "private-fixture-value-never-export"
    System.put_env("OPENAI_MODEL", secret)
    System.put_env("OPENAI_BASE_URL", "https://user:#{secret}@example.org")
    Host.put!(%{data_dir: Path.join(root, secret), dns_resolver: fn _ -> raise secret end})

    write(root, "models.json", %{
      "providers" => %{"private" => %{"apiKey" => secret, "Authorization" => secret}}
    })

    write(root, "global.json", %{
      "model_ai" => %{"default_model" => secret, "reasoning" => secret},
      "secret" => secret
    })

    write(root, ".handbean/settings.jsonc", %{
      "tools" => %{"allow" => [secret], "per_tool" => %{secret => "prompt"}}
    })

    :ok =
      Registry.register_virtual(secret, secret, %{}, fn _, _ ->
        flunk("executed inspection tool")
      end)

    on_exit(fn -> Registry.unregister(secret) end)
    report = ConfigInspection.report(workspace: root)
    refute Handbean.JSON.encode!(report) =~ secret
    assert report.model_ai.default_model.value == :withheld
    assert report.model_catalog.credentials == :not_resolved
    assert report.model_catalog.runtime_overrides["OPENAI_MODEL"]
    assert report.approval.allow_rules == 1
    File.write!(Path.join(root, ".handbean/settings.jsonc"), "{\"#{secret}\": broken")
    report = ConfigInspection.report(workspace: root)
    assert report.approval.status == :workspace_settings_error
    assert report.approval.effective_default == :deny
    refute Handbean.JSON.encode!(report) =~ secret
  end

  test "inspection leaves runtime configuration, registry and files unchanged", %{root: root} do
    Host.put!(%{directory_picker: fn _ -> flunk("inspection invoked a callback") end, mcp: true})
    write(root, ".handbean/settings.jsonc", %{"tools" => %{"default_mode" => "deny"}})
    config = Application.get_all_env(:handbean) |> Enum.sort()
    registry = :sys.get_state(Registry)
    files = files(root)
    report = ConfigInspection.report(workspace: root)
    assert report.approval.effective_default == :deny
    assert report.approval.call_decision == :unknown
    assert report.execution.mcp.reason == :not_probed
    assert Enum.sort(Application.get_all_env(:handbean)) == config
    assert :sys.get_state(Registry) == registry
    assert files(root) == files
  end

  for platform <- [:android, :ios] do
    @tag platform: platform
    test "#{platform} no-shell host facts reach default and custom model prompts", %{root: root} do
      # Both native entry points install these same Host capabilities. No OS sniffing.
      Host.put!(%{
        shell: false,
        terminal: false,
        browser_backend: :webview,
        artifact_delivery_backend: Handbean.ArtifactDelivery,
        host_script: true,
        packaged_mix_toolchain: true
      })

      for extra <- [[], [system_prompt: "Custom instructions."], [system_prompt: nil]] do
        config =
          Config.from_opts(
            [
              working_directory: root,
              provider: Handbean.TestSupport.FakeProvider,
              provider_config: %{notify: self()},
              middleware: []
            ] ++ extra
          )

        state = Handbean.Agent.State.init(config, "Check the host facts")
        assert Handbean.Agent.Turn.run_loop(state, []).status == :completed
        assert_receive {:provider_config, provider_config}
        prompt = provider_config.system_prompt
        assert prompt == config.system_prompt
        assert prompt =~ "There is no Unix shell on this host"
        assert prompt =~ "host WebView session"
        assert prompt =~ "`run_elixir_script`"
        assert prompt =~ "Mix.install/2"
        assert prompt =~ "arbitrary NIFs and external builds are not supported"
        assert prompt =~ "Follow the script tool environment for Mix/Hex availability"
        refute prompt =~ "The `bash` tool runs commands"
        refute prompt =~ "The host permits the bash backend"
        refute prompt =~ "backend is agent-browser CLI"
        assert length(String.split(prompt, "## Host execution environment")) == 2
      end

      assert ConfigInspection.report(workspace: root).prompt.environment_sections ==
               HostEnvironment.sections()
    end
  end

  test "Web does not replace the desktop host or imply Linux; headless disables UI independently",
       %{root: root} do
    Application.put_env(:handbean, HandbeanWeb.Endpoint, server: true)
    prompt = Config.from_opts(working_directory: root).system_prompt
    assert prompt =~ "The host permits the bash backend"
    assert prompt =~ "repository's documented command-line workflow"
    refute prompt =~ "machine's `mix`"
    assert prompt =~ "backend is agent-browser CLI"
    assert prompt =~ "installed on the computer running this conversation"
    assert prompt =~ "login-shell and current workspace environments"
    assert prompt =~ "Web is an entry surface, not a Linux execution host"
    refute prompt =~ "There is no Unix shell"

    Host.put!(%{
      shell: true,
      browser_backend: nil,
      artifact_delivery_backend: nil,
      host_script: false
    })

    prompt = Config.from_opts(working_directory: root).system_prompt
    assert prompt =~ "Neither desktop nor WebView browser"
    refute prompt =~ "`run_elixir_script`"
    report = ConfigInspection.report(workspace: root)
    assert report.ui.web_server_configured
    assert report.ui.active_surface == :unknown
    assert report.host.shell.configured
    refute tool(report, "browser").configured
  end

  defp tool(report, name), do: Enum.find(report.tools, &(&1.name == name))

  defp write(root, path, value),
    do: File.write!(Path.join(root, path), Handbean.JSON.encode!(value))

  defp files(root),
    do:
      Map.new(
        Path.wildcard(Path.join(root, "**/*"), match_dot: true) |> Enum.filter(&File.regular?/1),
        &{&1, File.read!(&1)}
      )
end
