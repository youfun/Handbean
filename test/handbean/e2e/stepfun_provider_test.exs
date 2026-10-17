defmodule Handbean.E2E.StepFunProviderTest do
  @moduledoc """
  External smoke tests for Handbean.Agent.Provider.StepFun.

  Reads API config from ~/.handbean/models.json (global model config).

  Run:

      mix test test/handbean/e2e/stepfun_provider_test.exs --include external_api

  Expects a valid StepFun Step Plan apiKey in ~/.handbean/models.json.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Handbean.Agent
  alias Handbean.Agent.ModelConfig
  alias Handbean.Agent.Provider.StepFun
  alias Handbean.Agent.Message

  @moduletag :external_api

  defp external_config do
    pc = ModelConfig.provider_config(File.cwd!())

    api_key = pc[:api_key]

    if is_nil(api_key) or api_key == "" do
      raise """
      No apiKey found in model config.

      Config source: #{config_source()}
      Provider config keys: #{inspect(Map.keys(pc))}

      Ensure ~/.handbean/models.json has a valid `apiKey` field.
      """
    end

    %{
      api_key: api_key,
      base_url: pc[:base_url] || "https://api.stepfun.com/step_plan/v1",
      model: pc[:model] || "step-router-v1",
      max_tokens: 1024,
      temperature: 0.1
    }
  end

  defp config_source do
    cond do
      env = System.get_env("HANDBEAN_MODELS_FILE") -> "HANDBEAN_MODELS_FILE=#{env}"
      File.exists?(Path.expand("~/.handbean/models.json")) -> "~/.handbean/models.json"
      true -> "built-in defaults (no config found)"
    end
  end

  describe "StepFun provider — basic text completion" do
    test "simple streaming text response" do
      config = external_config()
      chunks_ref = make_ref()

      on_chunk = fn chunk ->
        current = Process.get(chunks_ref, [])
        Process.put(chunks_ref, current ++ [chunk])
      end

      config = Map.merge(config, %{stream: true, on_chunk: on_chunk})

      {result, _log} =
        with_log(fn ->
          StepFun.complete(
            [Handbean.Agent.Message.user("Reply with exactly one word: handbean-stepfun-ok")],
            [],
            config
          )
        end)

      assert {:ok, response} = result
      assert response.stop_reason == :end_turn

      [assistant] = response.messages
      assert assistant.role == :assistant
      assert is_list(assistant.content)

      text = Message.text(assistant)
      assert text != "" and not is_nil(text)

      # Verify streaming worked — we should have received chunks
      chunks = Process.get(chunks_ref, [])
      assert chunks != []
      assert byte_size(text) > 0
    end
  end

  describe "StepFun provider — tool call completion" do
    test "read tool loop" do
      config = external_config()

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_stepfun_e2e_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "fruit.txt"), "sigil e2e fruit: mango\n")

      try do
        {result, _log} =
          with_log(fn ->
            Agent.run(
              "Use the read tool to read fruit.txt, then answer with the fruit word from the file.",
              provider: StepFun,
              provider_config: config,
              model: config.model,
              tools: [Handbean.Tool.Builtin.Read],
              working_directory: tmp_dir,
              max_turns: 5,
              streaming: false
            )
          end)

        assert {:ok, state} = result
        assert state.status == :completed
        assert Enum.any?(state.messages, &(&1.role == :tool_result))

        assistant_msgs =
          state.messages
          |> Enum.filter(&(&1.role == :assistant))
          |> Enum.map(&Message.text/1)
          |> Enum.reject(&is_nil/1)

        final = List.last(assistant_msgs)
        assert final =~ "mango"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "project status prompt asks bash to run git directly from workspace" do
      config = external_config()
      workspace = File.cwd!()

      {result, _log} =
        with_log(fn ->
          system_prompt =
            Handbean.Agent.Config.from_opts(
              working_directory: workspace,
              provider_config: config,
              model: config.model
            ).system_prompt

          StepFun.complete(
            [
              Message.user("""
              查看项目状态，使用 git 命令。
              必须调用 bash 工具。
              当前工作区已经是项目目录，不要在命令前添加 `cd #{workspace} &&`。
              只需要查看状态，不要修改文件。
              """)
            ],
            [bash_tool_def()],
            Map.put(config, :system_prompt, system_prompt)
          )
        end)

      assert {:ok, %{stop_reason: :tool_use, messages: [tool_use_msg]}} = result

      commands = bash_commands([tool_use_msg])
      assert Enum.any?(commands, &String.contains?(&1, "git"))

      refute Enum.any?(commands, fn command ->
               Regex.match?(~r/\A\s*cd\s+#{Regex.escape(workspace)}\s*&&/, command)
             end)
    end
  end

  describe "StepFun provider — Multi-turn conversation" do
    test "streaming multi-turn with tool calls" do
      config = external_config()

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_stepfun_multi_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "products.txt"), """
      Product list:
      - Apple Watch
      - iPhone
      - MacBook Pro
      """)

      try do
        {result, _log} =
          with_log(fn ->
            Agent.run(
              "Read products.txt and list the products you find.",
              provider: StepFun,
              provider_config: config,
              model: config.model,
              tools: [Handbean.Tool.Builtin.Read],
              working_directory: tmp_dir,
              max_turns: 5,
              streaming: false
            )
          end)

        assert {:ok, state} = result
        assert state.status == :completed

        # At least one tool_result means a tool call happened
        assert Enum.any?(state.messages, &(&1.role == :tool_result))

        # Final message should mention at least one product
        final_text =
          state.messages
          |> Enum.filter(&(&1.role == :assistant))
          |> Enum.map(&Message.text/1)
          |> Enum.reject(&is_nil/1)
          |> List.last()

        assert final_text =~ "Apple Watch" or final_text =~ "iPhone" or final_text =~ "MacBook"
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  defp bash_tool_def do
    %{
      name: Handbean.Tool.Builtin.Bash.name(),
      description: Handbean.Tool.Builtin.Bash.description(),
      input_schema: Handbean.Tool.Builtin.Bash.input_schema()
    }
  end

  defp bash_commands(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&Message.tool_calls/1)
    |> Enum.filter(&(&1.name == "bash"))
    |> Enum.map(& &1.input["command"])
  end
end
