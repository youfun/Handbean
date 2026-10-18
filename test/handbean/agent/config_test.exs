defmodule Handbean.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Config
  alias Handbean.Agent.Tool.Executor

  describe "provider resolution" do
    test "uses ZenMux adapter when provider field is zenmux" do
      config = Config.from_opts(provider_config: %{provider: "zenmux", api: :openai})

      assert config.provider == Handbean.Agent.Provider.ZenMux
    end

    test "uses OpenRouter adapter when provider field is openrouter" do
      config = Config.from_opts(provider_config: %{provider: "openrouter", api: :openai})

      assert config.provider == Handbean.Agent.Provider.OpenRouter
    end

    test "uses Ollama adapter when provider field is ollama" do
      config = Config.from_opts(provider_config: %{provider: "ollama", api: :openai})

      assert config.provider == Handbean.Agent.Provider.Ollama
    end

    test "uses OpenCode Go adapter when provider field is opencode-go" do
      config = Config.from_opts(provider_config: %{provider: "opencode-go", api: :openai})

      assert config.provider == Handbean.Agent.Provider.OpenCodeGo
    end

    test "uses DeepSeek adapter when provider field is deepseek" do
      config = Config.from_opts(provider_config: %{provider: "deepseek", api: :openai})

      assert config.provider == Handbean.Agent.Provider.DeepSeek
    end

    test "uses StepFun adapter when provider field is stepfun" do
      config = Config.from_opts(provider_config: %{provider: "stepfun", api: :openai})

      assert config.provider == Handbean.Agent.Provider.StepFun
    end

    test "uses Anthropic adapter when StepFun provider declares anthropic messages API" do
      config = Config.from_opts(provider_config: %{provider: "stepfun", api: :anthropic})

      assert config.provider == Handbean.Agent.Provider.Anthropic
    end

    test "uses StepFun adapter when api field is :stepfun" do
      config = Config.from_opts(provider_config: %{api: :stepfun})

      assert config.provider == Handbean.Agent.Provider.StepFun
    end

    test "uses OpenAI Responses adapter when provider field is openai" do
      config = Config.from_opts(provider_config: %{provider: "openai", api: :openai_responses})

      assert config.provider == Handbean.Agent.Provider.OpenAI
    end

    test "uses OpenAI Responses adapter when api field is :openai_responses" do
      config = Config.from_opts(provider_config: %{api: :openai_responses})

      assert config.provider == Handbean.Agent.Provider.OpenAI
    end

    test "uses Anthropic adapter when api field is :anthropic" do
      config = Config.from_opts(provider_config: %{api: :anthropic})

      assert config.provider == Handbean.Agent.Provider.Anthropic
    end

    test "openai-compat provider field keeps chat completions routing" do
      config =
        Config.from_opts(provider_config: %{provider: "openai-compat", api: :openai_responses})

      assert config.provider == Handbean.Agent.Provider.OpenAICompat
    end

    test "uses OpenAI-compatible adapter by default" do
      config = Config.from_opts(provider_config: %{api: :openai})

      assert config.provider == Handbean.Agent.Provider.OpenAICompat
    end

    test "uses Step Router as the built-in model default" do
      config = Config.from_opts([])

      assert config.model == "step-router-v1"
    end
  end

  test "runs are unlimited unless the caller sets max_turns" do
    for source <- [nil, :live_view, :native, :cli, :sns, :webhook, :schedule] do
      assert Config.from_opts(source: source).max_turns == nil
    end

    assert Config.from_opts(source: :live_view, max_turns: 3).max_turns == 3
  end

  describe "context window" do
    test "uses the selected model contextWindow" do
      config =
        Config.from_opts(
          provider_config: %{
            model_meta: %{"contextWindow" => 272_000},
            max_tokens: 32_000
          }
        )

      assert config.max_tokens == 272_000
      assert config.provider_config.max_tokens == 32_000
    end

    test "keeps the default for unknown models and honors an explicit override" do
      assert Config.from_opts(provider_config: %{max_tokens: 32_000}).max_tokens == 200_000

      assert Config.from_opts(provider_config: %{model_meta: %{"contextWindow" => 0}}).max_tokens ==
               200_000

      assert Config.from_opts(
               max_tokens: 128_000,
               provider_config: %{model_meta: %{"contextWindow" => 272_000}}
             ).max_tokens == 128_000
    end
  end

  test "workspace memory switch controls prompt, observation, and built-in memory tools" do
    workspace =
      Path.join(System.tmp_dir!(), "handbean-config-memory-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    try do
      assert :ok = Handbean.WorkspaceSettings.update_builtin_memory_enabled(workspace, false)

      disabled = Config.from_opts(working_directory: workspace)
      refute disabled.builtin_memory_enabled
      refute disabled.system_prompt =~ "mem_recall"
      refute Handbean.Agent.Middleware.ObservationalSessionStart in disabled.middleware

      authorized = Executor.authorized_tools(disabled)
      refute "mem_recall" in authorized
      refute "mem_learn" in authorized
      assert "read" in authorized

      assert :ok = Handbean.WorkspaceSettings.update_builtin_memory_enabled(workspace, true)

      enabled = Config.from_opts(working_directory: workspace)
      assert enabled.builtin_memory_enabled
      assert enabled.system_prompt =~ "mem_recall"
      assert Handbean.Agent.Middleware.ObservationalSessionStart in enabled.middleware
      assert "mem_recall" in Executor.authorized_tools(enabled)
    after
      File.rm_rf(workspace)
    end
  end

  test "appends task_instructions after the default prompt and workspace contract" do
    workspace =
      Path.join(System.tmp_dir!(), "handbean-config-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    try do
      config =
        Config.from_opts(
          working_directory: workspace,
          task_instructions: "Write only visible facts."
        )

      assert config.system_prompt =~ "Current checkout: #{workspace}"
      assert config.system_prompt =~ "## Task instructions"
      assert config.system_prompt =~ "Write only visible facts."
      refute config.system_prompt =~ "IGNORE ALL PRIOR"
    after
      File.rm_rf(workspace)
    end
  end

  test "blank task_instructions is a no-op" do
    config = Config.from_opts(task_instructions: "   ")
    refute config.system_prompt =~ "## Task instructions"
  end

  test "custom system_prompt still receives task_instructions as an appendix" do
    config =
      Config.from_opts(
        system_prompt: "Custom only.",
        task_instructions: "Keep negatives."
      )

    assert config.system_prompt =~ "Custom only."
    assert config.system_prompt =~ "Keep negatives."
    refute config.system_prompt =~ "Current checkout"
  end

  describe "workspace prompt contract" do
    test "injects the current workspace as the default command directory" do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "handbean-config-workspace-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace)

      try do
        config = Config.from_opts(working_directory: workspace, conversation_id: "root-thread")

        assert config.working_directory == workspace
        assert config.system_prompt =~ "Current checkout: #{workspace}"
        assert config.system_prompt =~ "## Current thread"
        assert config.system_prompt =~ "conversation_id: root-thread"
        refute config.system_prompt =~ "created_by_conversation_id:"
        assert config.system_prompt =~ "Prefer checkout-relative file paths"
        assert config.system_prompt =~ "`bash`, `grep`, `file_search`"
        assert config.system_prompt =~ "checkout is NOT the filesystem root"
        assert config.system_prompt =~ "runs commands from the current checkout by default"
        assert config.system_prompt =~ "Do not prefix commands with `cd #{workspace} &&`"
        refute config.system_prompt =~ "do not ask the user to switch workspaces"
        refute config.system_prompt =~ "This session runs on a phone"
      after
        File.rm_rf(workspace)
      end
    end

    test "names a distinct workspace when the checkout is a linked worktree" do
      workspace =
        Path.join(System.tmp_dir!(), "handbean-config-ws-#{System.unique_integer([:positive])}")

      checkout =
        Path.join(System.tmp_dir!(), "handbean-config-co-#{System.unique_integer([:positive])}")

      try do
        config =
          Config.from_opts(workspace_path: workspace, working_directory: checkout)

        assert config.system_prompt =~ "Current checkout: #{checkout}"
        assert config.system_prompt =~ "Workspace: #{workspace}"
        assert config.system_prompt =~ "do not ask the user to switch workspaces"
      after
        File.rm_rf(workspace)
        File.rm_rf(checkout)
      end
    end

    test "host without shell injects the no-shell tool contract" do
      previous = Application.get_env(:handbean, :host)

      Handbean.Host.put!(%{
        data_dir: "/tmp/mob-data",
        shell: false,
        terminal: false,
        browser_backend: :webview,
        host_script: true,
        beam_eval: false
      })

      try do
        config = Config.from_opts(working_directory: "/tmp/mob-data/workspace")
        assert config.system_prompt =~ "There is no Unix shell on this host"
        assert config.system_prompt =~ "Browser availability is independent of shell access"
        assert config.system_prompt =~ "run_elixir_script"
        assert config.system_prompt =~ "Mix.install/2"

        assert config.system_prompt =~
                 "Follow the script tool environment for Mix/Hex availability"

        refute config.system_prompt =~ "NimbleCSV.RFC4180"
        refute config.system_prompt =~ "Req.get"

        refute config.system_prompt =~ "Do not call `bash` or `browser`"
        refute config.system_prompt =~ "The `bash` tool runs commands"
      after
        if previous,
          do: Application.put_env(:handbean, :host, previous),
          else: Application.delete_env(:handbean, :host)
      end
    end

    test "script and delivery prompt text follow their own backends, not the browser" do
      previous = Application.get_env(:handbean, :host)

      try do
        Handbean.Host.put!(%{
          shell: false,
          terminal: false,
          browser_backend: nil,
          artifact_delivery_backend: nil,
          host_script: true
        })

        config = Config.from_opts(working_directory: "/tmp/mob-data/workspace")
        assert config.system_prompt =~ "There is no Unix shell on this host"
        assert config.system_prompt =~ "`run_elixir_script`"
        assert config.system_prompt =~ "high-privilege host BEAM code"
        refute config.system_prompt =~ "open_url"

        Handbean.Host.put!(%{
          shell: false,
          terminal: false,
          browser_backend: :webview,
          artifact_delivery_backend: Handbean.ArtifactDelivery,
          host_script: false
        })

        config = Config.from_opts(working_directory: "/tmp/mob-data/workspace")
        assert config.system_prompt =~ "There is no Unix shell on this host"
        assert config.system_prompt =~ "open_url"
        assert config.system_prompt =~ "device_calendar"
        assert config.system_prompt =~ "device_alarm"
        assert config.system_prompt =~ "not a silent alarm write"
        assert config.system_prompt =~ "iOS does not support device_calendar"
        refute config.system_prompt =~ "run_elixir_script"
        refute config.system_prompt =~ "high-privilege host BEAM code"
        refute config.system_prompt =~ "must use git"
        refute config.system_prompt =~ "must use mix"
      after
        if previous,
          do: Application.put_env(:handbean, :host, previous),
          else: Application.delete_env(:handbean, :host)
      end
    end
  end
end
