defmodule Handbean.E2E.OpenAICompatibleExternalTest do
  @moduledoc """
  External smoke tests for a real OpenAI-compatible `/v1/chat/completions` endpoint.

  Defaults target StepFun Step Plan:

      OPENAI_API_KEY=... mix test test/handbean/e2e/openai_compatible_external_test.exs --include external_api

  Optional env:

      OPENAI_BASE_URL=https://api.stepfun.com/step_plan/v1
      OPENAI_MODEL=step-router-v1
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Handbean.Agent
  alias Handbean.Agent.Provider.OpenAICompatible

  @moduletag :external_api

  defp external_config do
    %{
      api_key: System.fetch_env!("OPENAI_API_KEY"),
      base_url: System.get_env("OPENAI_BASE_URL") || "https://api.stepfun.com/step_plan/v1",
      model: System.get_env("OPENAI_MODEL") || "step-router-v1",
      max_tokens: 1024,
      temperature: 0.1,
      max_retries: 1,
      retry_delay_base_ms: 200
    }
  end

  describe "real OpenAI-compatible provider" do
    test "completes a simple non-tool turn" do
      config = external_config()

      {result, _log} =
        with_log(fn ->
          OpenAICompatible.complete(
            [Handbean.Agent.Message.user("Reply with exactly: handbean-stepfun-ok")],
            [],
            config
          )
        end)

      assert {:ok, response} = result
      assert response.stop_reason == :end_turn

      [assistant] = response.messages
      assert assistant.role == :assistant
      assert is_binary(assistant.content)
      assert assistant.content =~ "handbean-stepfun-ok"
    end

    test "completes a real Agent.run with read tool loop" do
      config = external_config()

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_stepfun_external_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "fact.txt"), "sigil external tool loop fact: papaya\n")

      try do
        {result, _log} =
          with_log(fn ->
            Agent.run(
              "Use the read tool to read fact.txt, then answer with the fruit word from the file.",
              provider: OpenAICompat,
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
          Enum.filter(state.messages, &(&1.role == :assistant and is_binary(&1.content)))

        final = List.last(assistant_msgs)
        assert final.content =~ "papaya"
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end
end
