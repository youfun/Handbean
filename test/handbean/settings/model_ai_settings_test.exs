defmodule Handbean.Settings.ModelAISettingsTest do
  use ExUnit.Case, async: true

  alias Handbean.Settings.ModelAISettings

  describe "defaults/0" do
    test "returns sensible default values" do
      defaults = ModelAISettings.defaults()

      assert defaults.default_model == nil
      assert defaults.reasoning == "medium"
      assert defaults.om_model == nil
      assert defaults.om_reasoning == nil
      assert defaults.om_memory_scope == "workspace"
      assert defaults.om_privacy_mode == "standard"
      assert defaults.om_max_recent_context == 5
      assert defaults.om_message_tokens == 30_000
      assert defaults.om_buffer_tokens == 10_000
      assert defaults.om_observation_tokens == 40_000
    end
  end

  describe "new/1 with empty map" do
    test "returns defaults" do
      settings = ModelAISettings.new(%{})
      assert settings == ModelAISettings.defaults()
    end
  end

  describe "new/1 with valid partial overrides" do
    test "overrides only specified fields" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "stepfun/step-router-v1",
          "reasoning" => "medium",
          "om_memory_scope" => "both"
        })

      assert settings.default_model == "stepfun/step-router-v1"
      assert settings.reasoning == "medium"
      assert settings.om_memory_scope == "both"
      # Unspecified fields stay at defaults
      assert settings.om_model == nil
      assert settings.om_privacy_mode == "standard"
    end
  end

  describe "new/1 normalizes string keys" do
    test "handles map with all string keys" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "reasoning" => "high",
          "observational_memory" => %{
            "enabled" => true,
            "model" => "claude-opus",
            "reasoning" => "low",
            "memory_scope" => "global"
          },
          "advisor" => %{"model" => "anthropic/claude-opus", "reasoning" => "high"}
        })

      assert settings.default_model == "claude-sonnet-4"
      assert settings.reasoning == "high"
      assert settings.om_model == "claude-opus"
      assert settings.om_reasoning == "low"
      assert settings.om_memory_scope == "global"
      assert settings.advisor_model == "anthropic/claude-opus"
      assert settings.advisor_reasoning == "high"
    end

    test "does not read removed observer and reflector model fields" do
      settings =
        ModelAISettings.new(%{
          "observational_memory" => %{
            "observer_model" => "old/observer",
            "reflector_model" => "old/reflector"
          }
        })

      assert settings.om_model == nil
    end
  end

  describe "to_runtime_opts/1" do
    test "default medium and explicit off survive runtime conversion" do
      for level <- ["medium", "off", "high"] do
        settings =
          if level == "medium",
            do: ModelAISettings.new(%{}),
            else: ModelAISettings.new(%{"reasoning" => level})

        opts = ModelAISettings.to_runtime_opts(settings)
        assert opts[:reasoning_level] == level
        assert Handbean.Agent.Config.from_opts(opts).reasoning_level == level
        assert ModelAISettings.new(ModelAISettings.to_json_map(settings)).reasoning == level
      end

      assert Handbean.Agent.Config.from_opts([]).reasoning_level == "medium"
    end

    test "converts to Coordinator-ready keyword opts" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "stepfun/step-router-v1",
          "reasoning" => "medium",
          "observational_memory" => %{
            "enabled" => true,
            "model" => "anthropic/claude-opus",
            "reasoning" => "high"
          }
        })

      opts = ModelAISettings.to_runtime_opts(settings)

      assert Keyword.get(opts, :model) == "stepfun/step-router-v1"
      assert Keyword.get(opts, :reasoning_level) == "medium"

      om = Keyword.get(opts, :om)
      refute Map.has_key?(om, :enabled)
      assert om[:model] == "anthropic/claude-opus"
      assert om[:reasoning] == "high"
    end

    test "legacy enablement is no longer part of Model / AI runtime settings" do
      settings =
        ModelAISettings.new(%{
          "observational_memory" => %{"enabled" => false, "model" => "memory/model"}
        })

      om = settings |> ModelAISettings.to_runtime_opts() |> Keyword.fetch!(:om)
      refute Map.has_key?(om, :enabled)
      assert om.model == "memory/model"
      refute get_in(ModelAISettings.to_json_map(settings), ["observational_memory", "enabled"])
    end

    test "model is nil when not set" do
      settings = ModelAISettings.defaults()
      opts = ModelAISettings.to_runtime_opts(settings)
      assert Keyword.get(opts, :model) == nil
    end

    test "memory model falls back to default_model when not set" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "stepfun/step-router-v1"
        })

      opts = ModelAISettings.to_runtime_opts(settings)
      om = Keyword.get(opts, :om)
      assert om[:model] == "stepfun/step-router-v1"
    end

    test "memory model is nil when both are nil" do
      settings = ModelAISettings.new(%{})

      opts = ModelAISettings.to_runtime_opts(settings)
      om = Keyword.get(opts, :om)
      assert om[:model] == nil
    end
  end

  describe "to_json_map/1" do
    test "round-trips through new/1" do
      original =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "reasoning" => "medium",
          "observational_memory" => %{
            "enabled" => true,
            "model" => "anthropic/claude-haiku",
            "reasoning" => "low"
          },
          "advisor" => %{"model" => "openai/gpt-5", "reasoning" => "high"}
        })

      json_map = ModelAISettings.to_json_map(original)
      reloaded = ModelAISettings.new(json_map)

      assert reloaded.default_model == original.default_model
      assert reloaded.reasoning == original.reasoning
      assert reloaded.om_model == original.om_model
      assert reloaded.om_reasoning == original.om_reasoning
      assert reloaded.advisor_model == original.advisor_model
      assert reloaded.advisor_reasoning == original.advisor_reasoning
    end

    test "excludes nil default and memory models" do
      settings = ModelAISettings.defaults()
      json_map = ModelAISettings.to_json_map(settings)

      refute Map.has_key?(json_map, "default_model")
      refute Map.has_key?(Map.get(json_map, "observational_memory", %{}), "model")
    end
  end

  describe "diff/2" do
    test "returns only fields that differ from base" do
      base = ModelAISettings.defaults()

      override =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "om_memory_scope" => "both"
        })

      diff = ModelAISettings.diff(base, override)

      assert Map.has_key?(diff, :default_model)
      assert Map.has_key?(diff, :om_memory_scope)
      refute Map.has_key?(diff, :reasoning)
    end

    test "returns empty map when identical" do
      base = ModelAISettings.defaults()
      diff = ModelAISettings.diff(base, base)
      assert diff == %{}
    end
  end

  describe "merge/2" do
    test "base + override yields override values for specified fields" do
      base = ModelAISettings.defaults()

      override =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "om_memory_scope" => "both"
        })

      merged = ModelAISettings.merge(base, override)

      assert merged.default_model == "claude-sonnet-4"
      assert merged.om_memory_scope == "both"
      assert merged.reasoning == "medium"
    end
  end

  describe "validate/1" do
    test "accepts valid privacy_mode values" do
      assert ModelAISettings.validate(%{"om_privacy_mode" => "standard"}) == :ok
      assert ModelAISettings.validate(%{"om_privacy_mode" => "local_only"}) == :ok
    end

    test "rejects invalid privacy_mode" do
      assert ModelAISettings.validate(%{"om_privacy_mode" => "invalid"}) ==
               {:error, "om_privacy_mode must be 'standard' or 'local_only'"}
    end

    test "rejects invalid memory_scope" do
      assert ModelAISettings.validate(%{"om_memory_scope" => "unknown"}) ==
               {:error, "om_memory_scope must be 'workspace', 'global', or 'both'"}
    end

    test "accepts valid memory_scope values" do
      assert ModelAISettings.validate(%{"om_memory_scope" => "workspace"}) == :ok
      assert ModelAISettings.validate(%{"om_memory_scope" => "global"}) == :ok
      assert ModelAISettings.validate(%{"om_memory_scope" => "both"}) == :ok
    end

    test "rejects negative max_recent_context" do
      assert ModelAISettings.validate(%{"om_max_recent_context" => -1}) ==
               {:error, "om_max_recent_context must be >= 0"}
    end

    test "rejects non-positive token thresholds" do
      assert ModelAISettings.validate(%{"om_message_tokens" => 0}) ==
               {:error, "om_message_tokens must be > 0"}
    end

    test "accepts valid full config" do
      assert ModelAISettings.validate(%{
               "default_model" => "claude-sonnet-4",
               "observational_memory" => %{
                 "enabled" => true,
                 "model" => "anthropic/claude-haiku",
                 "reasoning" => "medium",
                 "memory_scope" => "workspace",
                 "privacy_mode" => "standard",
                 "max_recent_context" => 5
               }
             }) == :ok
    end

    test "validates with atom keys too" do
      assert ModelAISettings.validate(%{om_privacy_mode: "local_only"}) == :ok

      assert ModelAISettings.validate(%{om_privacy_mode: "bad"}) ==
               {:error, "om_privacy_mode must be 'standard' or 'local_only'"}
    end
  end

  describe "drop_unknown_memory_model/2" do
    test "clears a removed model and its reasoning level" do
      settings = %ModelAISettings{
        om_model: "xai/grok-4.7",
        om_reasoning: "high"
      }

      known? = &(&1 == "openai_codex/gpt-6-sol")
      updated = ModelAISettings.drop_unknown_memory_model(settings, known?)

      assert updated.om_model == nil
      assert updated.om_reasoning == nil
    end
  end
end
