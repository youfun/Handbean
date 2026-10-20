defmodule Handbean.Agent.ModelConfigTest do
  @moduledoc """
  Tests for Handbean.Agent.ModelConfig.

  Covers:
    1. No models.json → StepFun defaults
    2. defaultProvider / defaultModel reading
    3. defaultProvider missing → first provider key
    4. defaultModel missing → provider's first model id
    5. apiKey from models.json
    6. OPENAI_API_KEY does not implicitly override models.json apiKey
    7. OPENAI_BASE_URL env overrides models.json baseUrl
    8. OPENAI_MODEL env overrides models.json defaultModel
    9. StepFun /step_plan + anthropic-messages → /v1 normalization
    10. Already /v1 → no double append
    11. Invalid JSON → fallback to defaults
    12. apiKey values never appear in test output (no printing keys)
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.ModelConfig

  @tmp_dir Path.join(System.tmp_dir!(), "sigil_model_config_test")
  @filenames ["models.json", "modejs.json"]

  setup do
    old_models_file = System.get_env("HANDBEAN_MODELS_FILE")

    File.mkdir_p!(@tmp_dir)
    delete_config()
    System.put_env("HANDBEAN_MODELS_FILE", config_path())

    on_exit(fn ->
      delete_config()
      File.rm_rf(@tmp_dir)

      if old_models_file,
        do: System.put_env("HANDBEAN_MODELS_FILE", old_models_file),
        else: System.delete_env("HANDBEAN_MODELS_FILE")
    end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────

  defp write_config(json, filename \\ "models.json") do
    path = Path.join(@tmp_dir, filename)
    File.write!(path, Jason.encode!(json))
  end

  defp delete_config do
    Enum.each(@filenames, fn name ->
      File.rm(Path.join(@tmp_dir, name))
    end)
  catch
    :error, _ -> :ok
  end

  defp config_path(filename \\ "models.json"), do: Path.join(@tmp_dir, filename)

  defp with_env(key, value, fun) do
    old = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      if old, do: System.put_env(key, old), else: System.delete_env(key)
    end
  end

  defp without_env(key, fun) do
    old = System.get_env(key)

    try do
      System.delete_env(key)
      fun.()
    after
      if old, do: System.put_env(key, old)
    end
  end

  # ══════════════════════════════════════════════════════════
  # 1. No models.json → StepFun defaults
  # ══════════════════════════════════════════════════════════

  describe "no models.json" do
    test "returns StepFun defaults when config file is absent" do
      result =
        without_env("OPENAI_API_KEY", fn ->
          without_env("OPENAI_BASE_URL", fn ->
            without_env("OPENAI_MODEL", fn ->
              ModelConfig.provider_config(@tmp_dir)
            end)
          end)
        end)

      assert result[:base_url] == "https://api.stepfun.com/step_plan/v1"
      assert result[:model] == "step-5-preview"
      refute Map.has_key?(result, :api_key)
    end

    test "created default catalog declares StepFun reasoning levels" do
      assert :ok = ModelConfig.ensure_config()
      assert {:ok, config} = ModelConfig.read_config()

      for model <- config["providers"]["stepfun"]["models"] do
        assert model["reasoning"] == true
        assert model["reasoningLevels"] == ["minimal", "medium", "high"]
        assert model["defaultReasoning"] == "medium"
        assert model["thinkingLevelMap"]["minimal"] == "low"
      end
    end

    test "upgrades exact existing StepFun defaults without replacing user fields" do
      write_config(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "provider" => "stepfun",
            "models" => [
              %{"id" => "step-router-v1", "name" => "My Router"},
              %{"id" => "step-5-preview", "name" => "My Preview"}
            ]
          }
        }
      })

      assert :ok = ModelConfig.ensure_config()
      assert {:ok, config} = ModelConfig.read_config()

      models = config["providers"]["stepfun"]["models"]
      router = Enum.find(models, &(&1["id"] == "step-router-v1"))
      preview = Enum.find(models, &(&1["id"] == "step-5-preview"))

      assert router["name"] == "My Router"
      assert preview["name"] == "My Preview"
      assert router["reasoningLevels"] == ["minimal", "medium", "high"]
      assert preview["reasoningLevels"] == ["minimal", "medium", "high"]
      assert config["defaultModel"] == "step-router-v1"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 2. defaultProvider / defaultModel reading
  # ══════════════════════════════════════════════════════════

  describe "defaultProvider / defaultModel" do
    test "reads explicit defaultProvider and defaultModel" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "defaultModel" => "my-model-v2",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-fake-test-key",
            "models" => [
              %{"id" => "my-model-v1", "name" => "Model V1"},
              %{"id" => "my-model-v2", "name" => "Model V2"}
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:base_url] == "https://api.example.com/v1"
      assert result[:model] == "my-model-v2"
      assert result[:api_key] == "sk-fake-test-key"
      assert result[:provider_key] == "my-provider"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 3. defaultProvider missing → first provider key
  # ══════════════════════════════════════════════════════════

  describe "defaultProvider missing" do
    test "falls back to first provider key" do
      write_config(%{
        "providers" => %{
          "alpha-provider" => %{
            "baseUrl" => "https://alpha.example.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-alpha-test",
            "models" => [
              %{"id" => "alpha-model", "name" => "Alpha"}
            ]
          },
          "beta-provider" => %{
            "baseUrl" => "https://beta.example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "beta-model", "name" => "Beta"}
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:base_url] == "https://alpha.example.com/v1"
      assert result[:provider_key] == "alpha-provider"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 4. defaultModel missing → provider's first model id
  # ══════════════════════════════════════════════════════════

  describe "defaultModel missing" do
    test "falls back to provider's first model id" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "first-model", "name" => "First"},
              %{"id" => "second-model", "name" => "Second"}
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:model] == "first-model"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 5. apiKey from models.json
  # ══════════════════════════════════════════════════════════

  describe "apiKey from models.json" do
    test "reads apiKey directly from config" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-direct-key-12345",
            "models" => [
              %{"id" => "test-model", "name" => "Test"}
            ]
          }
        }
      })

      result =
        without_env("OPENAI_API_KEY", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:api_key] == "sk-direct-key-12345"
    end

    test "resolves env:VAR notation to environment variable" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "env:CUSTOM_API_KEY_VAR",
            "models" => [
              %{"id" => "test-model", "name" => "Test"}
            ]
          }
        }
      })

      result =
        with_env("CUSTOM_API_KEY_VAR", "resolved-from-env-key", fn ->
          without_env("OPENAI_API_KEY", fn ->
            ModelConfig.provider_config(@tmp_dir)
          end)
        end)

      assert result[:api_key] == "resolved-from-env-key"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 6. OPENAI_API_KEY does not implicitly override models.json apiKey
  # ══════════════════════════════════════════════════════════

  describe "OPENAI_API_KEY handling" do
    test "OPENAI_API_KEY env var does not implicitly override models.json apiKey" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-from-config",
            "models" => [
              %{"id" => "test-model", "name" => "Test"}
            ]
          }
        }
      })

      result =
        with_env("OPENAI_API_KEY", "sk-from-env-override", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:api_key] == "sk-from-config"
    end

    test "OPENAI_API_KEY env var is ignored when apiKey is absent" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "test-model", "name" => "Test"}
            ]
          }
        }
      })

      result =
        with_env("OPENAI_API_KEY", "sk-from-env-override", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      refute Map.has_key?(result, :api_key)
    end
  end

  # ══════════════════════════════════════════════════════════
  # 7. OPENAI_BASE_URL overrides models.json baseUrl
  # ══════════════════════════════════════════════════════════

  describe "OPENAI_BASE_URL override" do
    test "OPENAI_BASE_URL env var overrides models.json baseUrl" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "test-model", "name" => "Test"}
            ]
          }
        }
      })

      result =
        with_env("OPENAI_BASE_URL", "https://custom-override.example.com/v2", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:base_url] == "https://custom-override.example.com/v2"
    end

    test "OPENAI_BASE_URL strips /v1 suffix for anthropic messages" do
      write_config(%{
        "defaultProvider" => "stepfun-anthropic",
        "providers" => %{
          "stepfun-anthropic" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan",
            "api" => "anthropic-messages",
            "models" => [
              %{"id" => "step-router-v1", "name" => "Step", "maxTokens" => 256_000}
            ]
          }
        }
      })

      result =
        with_env("OPENAI_BASE_URL", "https://api.stepfun.com/step_plan/v1", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:base_url] == "https://api.stepfun.com/step_plan"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 8. OPENAI_MODEL overrides models.json defaultModel
  # ══════════════════════════════════════════════════════════

  describe "OPENAI_MODEL override" do
    test "OPENAI_MODEL env var overrides models.json defaultModel" do
      write_config(%{
        "defaultProvider" => "my-provider",
        "defaultModel" => "config-model",
        "providers" => %{
          "my-provider" => %{
            "baseUrl" => "https://api.example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "config-model", "name" => "Config Model"}
            ]
          }
        }
      })

      result =
        with_env("OPENAI_MODEL", "env-override-model", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:model] == "env-override-model"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 9. StepFun baseUrl normalization
  # ══════════════════════════════════════════════════════════

  describe "StepFun baseUrl normalization" do
    test "preserves StepFun anthropic-messages URL as-is" do
      write_config(%{
        "defaultProvider" => "stepfun-anthropic",
        "providers" => %{
          "stepfun-anthropic" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan",
            "api" => "anthropic-messages",
            "models" => [
              %{"id" => "step-router-v1", "name" => "Step Router v1"}
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:base_url] == "https://api.stepfun.com/step_plan"
    end

    test "normalize_base_url preserves StepFun anthropic URL as-is" do
      result =
        ModelConfig.normalize_base_url("https://api.stepfun.com/step_plan", "anthropic-messages")

      assert result == "https://api.stepfun.com/step_plan"
    end

    test "normalize_base_url handles nil + anthropic-messages" do
      result = ModelConfig.normalize_base_url(nil, "anthropic-messages")
      assert result == "https://api.stepfun.com/step_plan/v1"
    end

    test "normalize_base_url passes through non-StepFun anthropic URL" do
      result = ModelConfig.normalize_base_url("https://api.anthropic.com", "anthropic-messages")
      assert result == "https://api.anthropic.com"
    end

    test "normalize_base_url passes through openai-compatible URLs" do
      result =
        ModelConfig.normalize_base_url("https://api.openai.com/v1", "openai-chat-completions")

      assert result == "https://api.openai.com/v1"
    end

    test "normalize_base_url passes through nil api" do
      result = ModelConfig.normalize_base_url("https://example.com/v1", nil)
      assert result == "https://example.com/v1"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 10. Already /v1 → no double append
  # ══════════════════════════════════════════════════════════

  describe "no double /v1 append" do
    test "does not double append when URL already ends with /v1" do
      write_config(%{
        "defaultProvider" => "stepfun-anthropic",
        "providers" => %{
          "stepfun-anthropic" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "anthropic-messages",
            "models" => [
              %{"id" => "step-router-v1", "name" => "Step Router v1"}
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:base_url] == "https://api.stepfun.com/step_plan"
    end

    test "does not double append with trailing slash + /v1" do
      result =
        ModelConfig.normalize_base_url(
          "https://api.stepfun.com/step_plan/v1/",
          "anthropic-messages"
        )

      assert result == "https://api.stepfun.com/step_plan/v1/"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 11. Invalid JSON → fallback
  # ══════════════════════════════════════════════════════════

  describe "invalid JSON" do
    test "returns StepFun defaults when models.json is malformed" do
      path = config_path()
      File.write!(path, "{not valid json !!!!")

      result =
        without_env("OPENAI_API_KEY", fn ->
          without_env("OPENAI_BASE_URL", fn ->
            ModelConfig.provider_config(@tmp_dir)
          end)
        end)

      assert result[:base_url] == "https://api.stepfun.com/step_plan/v1"
      assert result[:model] == "step-5-preview"
    end
  end

  # ══════════════════════════════════════════════════════════
  # 12. Model metadata and available models
  # ══════════════════════════════════════════════════════════

  describe "model metadata" do
    test "includes model_meta for the selected model" do
      write_config(%{
        "defaultProvider" => "test-provider",
        "defaultModel" => "target-model",
        "providers" => %{
          "test-provider" => %{
            "baseUrl" => "https://example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "other-model", "name" => "Other", "contextWindow" => 8192},
              %{
                "id" => "target-model",
                "name" => "Target",
                "reasoning" => true,
                "contextWindow" => 128_000,
                "maxTokens" => 64000
              }
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:model] == "target-model"
      assert result[:model_meta]["id"] == "target-model"
      assert result[:model_meta]["name"] == "Target"
      assert result[:model_meta]["reasoning"] == true
      assert result[:model_meta]["contextWindow"] == 128_000
      refute Map.has_key?(result, :max_tokens)
    end

    test "uses provider maxTokens as request output budget" do
      write_config(%{
        "defaultProvider" => "test-provider",
        "defaultModel" => "target-model",
        "providers" => %{
          "test-provider" => %{
            "baseUrl" => "https://example.com/v1",
            "api" => "openai-chat-completions",
            "maxTokens" => 2048,
            "models" => [
              %{
                "id" => "target-model",
                "name" => "Target",
                "contextWindow" => 128_000,
                "maxTokens" => 64000
              }
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:max_tokens] == 2048
    end
  end

  describe "available models" do
    test "lists all models from the active provider" do
      write_config(%{
        "defaultProvider" => "test-provider",
        "providers" => %{
          "test-provider" => %{
            "baseUrl" => "https://example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "model-a", "name" => "Model A"},
              %{"id" => "model-b", "name" => "Model B"}
            ]
          }
        }
      })

      models = ModelConfig.available_models(@tmp_dir)

      assert length(models) == 2
      assert [%{id: "model-a", name: "Model A"}, %{id: "model-b", name: "Model B"}] = models
    end

    test "returns empty list when no models.json exists" do
      models = ModelConfig.available_models(@tmp_dir)
      assert models == []
    end
  end

  # ══════════════════════════════════════════════════════════
  # 13. models.json filename
  # ══════════════════════════════════════════════════════════

  describe "models.json support" do
    test "models.json is read from working directory" do
      write_config(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "provider" => "stepfun",
            "models" => [
              %{"id" => "step-router-v1", "name" => "Step Router v1"}
            ]
          }
        }
      })

      result =
        without_env("OPENAI_API_KEY", fn ->
          without_env("OPENAI_BASE_URL", fn ->
            ModelConfig.provider_config(@tmp_dir)
          end)
        end)

      assert result[:base_url] == "https://api.stepfun.com/step_plan/v1"
      assert result[:model] == "step-router-v1"
      assert result[:api] == :stepfun
      assert result[:provider] == "stepfun"
    end

    test "config_filenames returns models.json" do
      names = ModelConfig.config_filenames()
      assert "models.json" in names
      assert length(names) == 1
    end
  end
end
