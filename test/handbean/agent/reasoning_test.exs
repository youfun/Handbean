defmodule Handbean.Agent.ReasoningTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Reasoning

  describe "supported_levels/1" do
    test "returns an empty list for non-reasoning models" do
      assert Reasoning.supported_levels(%{reasoning: false}) == []
    end

    test "does not infer capabilities from model or provider names" do
      assert Reasoning.supported_levels(%{id: "step-router-v1", name: "Step Router v1"}) == []

      assert Reasoning.supported_levels(%{
               provider_id: "stepfun-anthropic",
               model_id: "other"
             }) == []

      assert Reasoning.supported_levels(%{id: "xai/grok-4.7", model_id: "grok-4.7"}) ==
               []
    end

    test "keeps an explicit thinking map for grok, minus unsupported levels" do
      levels =
        Reasoning.supported_levels(%{
          id: "grok-4.7",
          reasoning: true,
          thinking_level_map: %{"low" => nil, "xhigh" => "xhigh"}
        })

      assert levels == ["off", "xhigh"]
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

    test "includes provider default and hides levels mapped to nil" do
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
      assert Reasoning.default_level(%{
               reasoning: true,
               reasoning_levels: ["low", "high"],
               default_reasoning: "high"
             }) == "high"
    end

    test "does not choose an effort when the provider omits a default" do
      assert Reasoning.default_level(%{reasoning: true}) == "off"
    end

    test "does not infer defaults from a model family name" do
      assert Reasoning.default_level(%{id: "grok-4.7", reasoning: true}) == "off"
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

      assert Reasoning.default_level(model) == "off"
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
      assert fields["reasoningLevels"] == ["low", "high", "xhigh"]
      assert fields["defaultReasoning"] == "low"
      assert fields["thinkingLevelMap"]["low"] == "low"
      assert fields["thinkingLevelMap"]["medium"] == nil
      assert fields["thinkingLevelMap"]["xhigh"] == "high"
      refute Map.has_key?(fields["thinkingLevelMap"], "off")
    end

    test "keeps the full level list when a manual model does not select levels" do
      fields = Reasoning.catalog_fields(%{id: "custom-reasoner"}, [])

      assert fields["defaultReasoning"] == "medium"
      assert fields["reasoningLevels"] == Reasoning.levels()
      assert fields["thinkingLevelMap"]["minimal"] == "low"
      assert fields["thinkingLevelMap"]["xhigh"] == "high"
    end
  end

  describe "resolve/2" do
    test "uses exact declared effort unless an explicit map overrides it" do
      assert Reasoning.resolve(
               %{reasoning: true, reasoning_levels: ["xhigh"]},
               "xhigh"
             ) == {:ok, "xhigh"}

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
      model = %{reasoning: true, reasoning_levels: ["high"]}

      assert Reasoning.apply_provider_options(config, model, "high") ==
               %{
                 api: :openai_responses,
                 model: "gpt-5.4",
                 reasoning: %{effort: "high"},
                 include: ["reasoning.encrypted_content"]
               }
    end

    test "sends explicit none for a Responses model that declares it" do
      config = %{api: :openai_responses, model: "deepseek/deepseek-v4.1-flash"}
      model = %{reasoning: true, reasoning_levels: ["none", "low", "high", "max"]}

      assert Reasoning.apply_provider_options(config, model, "none") ==
               %{
                 api: :openai_responses,
                 model: "deepseek/deepseek-v4.1-flash",
                 reasoning: %{effort: "none"},
                 include: ["reasoning.encrypted_content"]
               }
    end

    test "adds xAI Responses reasoning effort for grok" do
      config = %{api: :openai_responses, provider: "openai", model: "grok-4.7"}

      model = %{id: "grok-4.7", reasoning: true, reasoning_levels: ["high"]}

      assert Reasoning.apply_provider_options(config, model, "high") ==
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
      model = %{reasoning: true, reasoning_levels: ["low", "high"]}

      assert Reasoning.apply_provider_options(config, model, "off") == config
      assert Reasoning.apply_provider_options(config, model, "minimal") == config
    end

    test "adds OpenAI-compatible reasoning_effort" do
      config = %{api: :openai, model: "gpt-5.4"}

      model = %{reasoning: true, reasoning_levels: ["medium"]}

      assert Reasoning.apply_provider_options(config, model, "medium") ==
               %{api: :openai, model: "gpt-5.4", reasoning_effort: "medium"}
    end

    test "adds DeepSeek thinking fields" do
      config = %{provider: "deepseek", model: "deepseek-v4-pro"}

      model = %{reasoning: true, reasoning_levels: ["high"]}

      assert Reasoning.apply_provider_options(config, model, "high") ==
               %{
                 provider: "deepseek",
                 model: "deepseek-v4-pro",
                 thinking: %{type: "enabled"},
                 reasoning_effort: "high"
               }
    end
  end
end
