defmodule Handbean.E2E.ReasoningExternalTest do
  @moduledoc """
  Real provider smoke test for models.json reasoning configuration.

  Run explicitly:

      mix test test/handbean/e2e/reasoning_external_test.exs --include external_api
  """

  use ExUnit.Case, async: false

  @moduletag :external_api

  alias Handbean.Agent.{Message, ModelConfig, Reasoning}

  test "current reasoning-capable models.json model returns a real response" do
    workspace = File.cwd!()
    selected_model = ModelConfig.default_model_for_workspace(workspace)
    assert is_binary(selected_model)

    assert model_entry =
             workspace
             |> ModelConfig.available_models_for_workspace()
             |> Enum.find(&(&1.id == selected_model))

    assert model_entry.reasoning == true

    assert {:ok, provider_config, model_id} =
             ModelConfig.resolve_model_for_workspace(workspace, selected_model)

    reasoning_level = Reasoning.default_level(model_entry)

    provider_config =
      provider_config
      |> Map.put(:model, model_id)
      |> Map.put(:max_tokens, min(Map.get(provider_config, :max_tokens, 2048) || 2048, 2048))
      |> Reasoning.apply_provider_options(model_entry, reasoning_level)

    provider =
      Handbean.Agent.Config.resolve_provider_from_api(
        provider_config[:api],
        model_id,
        provider_config[:provider]
      )

    assert {:ok, result} =
             provider.complete(
               [Message.user("Reply with exactly: reasoning-ok")],
               [],
               provider_config
             )

    assert result.stop_reason == :end_turn
    text = result.messages |> List.first() |> Message.text()
    assert is_binary(text)
    assert String.length(String.trim(text)) > 0
    assert result.usage.input_tokens >= 0
    assert result.usage.output_tokens >= 0
  end
end
