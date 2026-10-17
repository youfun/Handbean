defmodule Handbeam.Agent.ReasoningTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.Reasoning

  describe "supported_levels/1" do
    test "returns an empty list for non-reasoning models" do
      assert Reasoning.supported_levels(%{reasoning: false}) == []
    end

    test "infers Step Router / StepFun models when the flag is omitted" do
      levels = Reasoning.supported_levels(%{id: "step-router-v1", name: "Step Router v1"})

      assert "off" in levels
      assert "medium" in levels
      assert "high" in levels
    end

    test "infers provider_id stepfun when the flag is omitted" do
      levels = Reasoning.supported_levels(%{provider_id: "stepfun-anthropic", model_id: "other"})
      assert "medium" in levels
    end

    test "infers grok models when the flag is omitted and hides unsupported levels" do
      levels = Reasoning.supported_levels(%{id: "xai/grok-4.7", model_id: "grok-4.7"})

      assert levels == ["low", "medium", "high", "xhigh"]
      refute "off" in levels
      refute "minimal" in levels
    end

    test "keeps an explicit thinking map for grok, minus unsupported levels" do
      levels =
        Reasoning.supported_levels(%{
          id: "grok-4.7",
          reasoning: true,
          thinking_level_map: %{"low" => nil, "xhigh" => "xhigh"}
        })

      assert levels == ["medium", "high", "xhigh"]
    end

    test "uses catalog reasoning levels instead of the generic list" do
      levels =
        Reasoning.supported_levels(%{
          id: "gpt-6.1-sol",
          reasoning: true,
          reasoning_levels: ["low", "medium", "high", "xhigh", "max"]
        })

      assert levels == ["off", "low", "medium", "high", "xhigh", "max"]
    end

    test "includes off and hides levels mapped to nil" do
      model = %{
        reasoning: true,
        thinking_level_map: %{
          "minimal" => "low",
          "low" => nil,
          "medium" => "medium",
          "high" => "high",
          "xhigh" => nil
        }
      }

      assert Reasoning.supported_levels(model) == ["off", "minimal", "medium", "high"]
    end
  end

  describe "default_level/1" do
    test "uses model default when supported" do
      assert Reasoning.default_level(%{reasoning: true, default_reasoning: "high"}) == "high"
    end

    test "falls back to medium for reasoning models" do
      assert Reasoning.default_level(%{reasoning: true}) == "medium"
    end

    test "defaults grok to high when the catalog omits a default" do
      assert Reasoning.default_level(%{id: "grok-4.7", reasoning: true}) == "high"
    end

    test "defaults grok 4.3 to low and allows reasoning to be turned off" do
      model = %{
        id: "grok-4.3",
        reasoning: true,
        reasoning_levels: ["none", "low", "medium", "high", "xhigh"]
      }

      assert Reasoning.supported_levels(model) == [
               "off",
               "none",
               "low",
               "medium",
               "high",
               "xhigh"
             ]

      assert Reasoning.default_level(model) == "low"
    end

    test "returns off for non-reasoning models" do
      assert Reasoning.default_level(%{reasoning: false}) == "off"
    end
  end

  describe "catalog_fields/2" do
    test "builds catalog fields for a manually configured grok model" do
      fields =
        Reasoning.catalog_fields(%{id: "grok-4.7", provider_id: "xai"}, ["low", "high", "xhigh"])

      assert fields["reasoning"] == true
      assert fields["defaultReasoning"] == "high"
      assert fields["thinkingLevelMap"]["low"] == "low"
      assert fields["thinkingLevelMap"]["medium"] == nil
      assert fields["thinkingLevelMap"]["xhigh"] == "high"
      refute Map.has_key?(fields["thinkingLevelMap"], "off")
    end

    test "keeps the full level list when a manual model does not select levels" do
      fields = Reasoning.catalog_fields(%{id: "custom-reasoner"}, [])

      assert fields["defaultReasoning"] == "medium"
      assert fields["thinkingLevelMap"]["minimal"] == "low"
      assert fields["thinkingLevelMap"]["xhigh"] == "high"
    end
  end

  describe "resolve/2" do
    test "maps xhigh to high unless explicitly overridden" do
      assert Reasoning.resolve(%{reasoning: true}, "xhigh") == {:ok, "high"}

      assert Reasoning.resolve(
               %{reasoning: true, thinking_level_map: %{"xhigh" => "max"}},
               "xhigh"
             ) == {:ok, "max"}
    end

    test "returns :off for off" do
      assert Reasoning.resolve(%{reasoning: true}, "off") == :off
    end
  end

  describe "apply_provider_options/3" do
    test "does not mutate config for off" do
      config = %{api: :openai_responses, model: "gpt-5.4"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "off") == config
    end

    test "adds OpenAI Responses reasoning effort" do
      config = %{api: :openai_responses, model: "gpt-5.4"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "high") ==
               %{
                 api: :openai_responses,
                 model: "gpt-5.4",
                 reasoning: %{effort: "high"},
                 include: ["reasoning.encrypted_content"]
               }
    end

    test "adds xAI Responses reasoning effort for grok" do
      config = %{api: :openai_responses, provider: "openai", model: "grok-4.7"}

      assert Reasoning.apply_provider_options(config, %{id: "grok-4.7", reasoning: true}, "high") ==
               %{
                 api: :openai_responses,
                 provider: "openai",
                 model: "grok-4.7",
                 reasoning: %{effort: "high"},
                 include: ["reasoning.encrypted_content"]
               }
    end

    test "does not send an unsupported grok level" do
      config = %{api: :openai_responses, model: "grok-4.7"}

      assert Reasoning.apply_provider_options(config, %{id: "grok-4.7"}, "off") == config
      assert Reasoning.apply_provider_options(config, %{id: "grok-4.7"}, "minimal") == config
    end

    test "adds OpenAI-compatible reasoning_effort" do
      config = %{api: :openai, model: "gpt-5.4"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "medium") ==
               %{api: :openai, model: "gpt-5.4", reasoning_effort: "medium"}
    end

    test "adds DeepSeek thinking fields" do
      config = %{provider: "deepseek", model: "deepseek-v4-pro"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "high") ==
               %{
                 provider: "deepseek",
                 model: "deepseek-v4-pro",
                 thinking: %{type: "enabled"},
                 reasoning_effort: "high"
               }
    end
  end
end
