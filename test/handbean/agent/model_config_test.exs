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

  # ══════════════════════════════════════════════════════════
  # 14. provider field (maps to provider module)
  # ══════════════════════════════════════════════════════════

  describe "provider field" do
    test "reads ZenMux provider with provider-prefixed models from config" do
      write_config(%{
        "defaultProvider" => "zenmux",
        "defaultModel" => "openai/gpt-5",
        "providers" => %{
          "zenmux" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "env:ZENMUX_API_KEY",
            "provider" => "zenmux",
            "models" => [
              %{"id" => "openai/gpt-5", "name" => "ZenMux GPT-5", "reasoning" => true},
              %{
                "id" => "deepseek/deepseek-v4-pro",
                "name" => "ZenMux DeepSeek V4 Pro",
                "reasoning" => true
              }
            ]
          }
        }
      })

      result =
        with_env("ZENMUX_API_KEY", "sk-zenmux-test", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:base_url] == "https://zenmux.ai/api/v1"
      assert result[:model] == "openai/gpt-5"
      assert result[:api] == :openai
      assert result[:api_key] == "sk-zenmux-test"
      assert result[:provider] == "zenmux"
      assert result[:model_meta]["id"] == "openai/gpt-5"

      models = ModelConfig.available_models(@tmp_dir)
      assert Enum.map(models, & &1.id) == ["openai/gpt-5", "deepseek/deepseek-v4-pro"]
    end

    test "reads OpenRouter provider with provider-prefixed models from config" do
      write_config(%{
        "defaultProvider" => "openrouter",
        "defaultModel" => "openai/gpt-4o",
        "providers" => %{
          "openrouter" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "env:OPENROUTER_API_KEY",
            "provider" => "openrouter",
            "models" => [
              %{"id" => "openai/gpt-4o", "name" => "OpenRouter GPT-4o", "reasoning" => true},
              %{
                "id" => "anthropic/claude-sonnet-4",
                "name" => "OpenRouter Claude Sonnet 4",
                "reasoning" => true
              }
            ]
          }
        }
      })

      result =
        with_env("OPENROUTER_API_KEY", "sk-or-test", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:base_url] == "https://openrouter.ai/api/v1"
      assert result[:model] == "openai/gpt-4o"
      assert result[:api] == :openai
      assert result[:api_key] == "sk-or-test"
      assert result[:provider] == "openrouter"
      assert result[:model_meta]["id"] == "openai/gpt-4o"

      models = ModelConfig.available_models(@tmp_dir)
      assert Enum.map(models, & &1.id) == ["openai/gpt-4o", "anthropic/claude-sonnet-4"]
    end

    test "reads DeepSeek provider with v4 models from config" do
      write_config(%{
        "defaultProvider" => "deepseek",
        "defaultModel" => "deepseek-v4-flash",
        "providers" => %{
          "deepseek" => %{
            "baseUrl" => "https://api.deepseek.com",
            "api" => "openai-chat-completions",
            "apiKey" => "env:DEEPSEEK_API_KEY",
            "provider" => "deepseek",
            "models" => [
              %{"id" => "deepseek-v4-flash", "name" => "DeepSeek V4 Flash"},
              %{"id" => "deepseek-v4-pro", "name" => "DeepSeek V4 Pro", "reasoning" => true}
            ]
          }
        }
      })

      result =
        with_env("DEEPSEEK_API_KEY", "sk-deepseek-test", fn ->
          ModelConfig.provider_config(@tmp_dir)
        end)

      assert result[:base_url] == "https://api.deepseek.com"
      assert result[:model] == "deepseek-v4-flash"
      assert result[:api] == :openai
      assert result[:api_key] == "sk-deepseek-test"
      assert result[:provider] == "deepseek"
      assert result[:model_meta]["id"] == "deepseek-v4-flash"

      models = ModelConfig.available_models(@tmp_dir)
      assert Enum.map(models, & &1.id) == ["deepseek-v4-flash", "deepseek-v4-pro"]
    end

    test "reads provider field from config" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://example.com/v1",
            "api" => "openai-chat-completions",
            "provider" => "stepfun",
            "models" => [%{"id" => "m"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:provider] == "stepfun"
    end

    test "provider is nil when not set in config" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      refute Map.has_key?(result, :provider)
    end
  end

  # ══════════════════════════════════════════════════════════
  # 15. api field
  # ══════════════════════════════════════════════════════════

  describe "api field in provider config" do
    test "returns :openai for openai-chat-completions" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://example.com/v1",
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:api] == :openai
    end

    test "returns :anthropic for anthropic-messages" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://example.com",
            "api" => "anthropic-messages",
            "models" => [%{"id" => "m"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:api] == :anthropic
    end

    test "returns :stepfun for stepfun-step-plan" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "provider" => "stepfun",
            "models" => [%{"id" => "step-router-v1"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:api] == :stepfun
      assert result[:provider] == "stepfun"
    end

    test "returns :openai_responses for OpenAI Responses config" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://api.openai.com/v1",
            "api" => "openai-responses",
            "provider" => "openai",
            "models" => [%{"id" => "gpt-5.5"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:api] == :openai_responses
      assert result[:provider] == "openai"
      assert result[:base_url] == "https://api.openai.com"
    end

    test "returns :openai_responses for api openai shorthand" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://api.openai.com/v1",
            "api" => "openai",
            "models" => [%{"id" => "gpt-5.5"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:api] == :openai_responses
      assert result[:base_url] == "https://api.openai.com"
    end

    test "passes OpenAI Responses provider options from models json" do
      write_config(%{
        "defaultProvider" => "p",
        "defaultModel" => "gpt-5.4-mini",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://api.openai.com/v1",
            "api" => "openai",
            "usePreviousResponseId" => true,
            "parallelToolCalls" => false,
            "include" => ["reasoning.encrypted_content"],
            "models" => [
              %{
                "id" => "gpt-5.4-mini",
                "usePreviousResponseId" => false,
                "toolChoice" => "auto"
              }
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:use_previous_response_id] == false
      assert result[:parallel_tool_calls] == false
      assert result[:include] == ["reasoning.encrypted_content"]
      assert result[:tool_choice] == "auto"
    end

    test "passes provider HTTP timeout and retry options from models json" do
      write_config(%{
        "defaultProvider" => "p",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "receiveTimeout" => 180_000,
            "connectTimeout" => 45_000,
            "maxRetries" => 4,
            "retryDelayBaseMs" => 1_000,
            "models" => [%{"id" => "step-router-v1"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:receive_timeout] == 180_000
      assert result[:connect_timeout] == 45_000
      assert result[:max_retries] == 4
      assert result[:retry_delay_base_ms] == 1_000

      assert result[:req_options] == [
               connect_options: [timeout: 45_000],
               receive_timeout: 180_000
             ]
    end

    test "model HTTP timeout options override provider defaults" do
      write_config(%{
        "defaultProvider" => "p",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "receiveTimeout" => 180_000,
            "connectTimeout" => 45_000,
            "models" => [
              %{"id" => "step-router-v1", "receiveTimeout" => 240_000, "connectTimeout" => 60_000}
            ]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:receive_timeout] == 240_000
      assert result[:connect_timeout] == 60_000

      assert result[:req_options] == [
               connect_options: [timeout: 60_000],
               receive_timeout: 240_000
             ]
    end

    test "preserves model reasoning metadata in summaries" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://api.openai.com/v1",
            "api" => "openai",
            "models" => [
              %{
                "id" => "gpt-5.4-mini",
                "name" => "GPT-5.4 Mini",
                "reasoning" => true,
                "defaultReasoning" => "high",
                "thinkingLevelMap" => %{"minimal" => "low", "xhigh" => "max"}
              }
            ]
          }
        }
      })

      assert [model] = ModelConfig.all_global_models()
      assert model.reasoning == true
      assert model.default_reasoning == "high"
      assert model.thinking_level_map == %{"minimal" => "low", "xhigh" => "max"}

      assert [available] = ModelConfig.available_models(@tmp_dir)
      assert available.default_reasoning == "high"
      assert available.thinking_level_map == %{"minimal" => "low", "xhigh" => "max"}
    end

    test "returns :openai for unknown api strings" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://example.com/v1",
            "api" => "some-custom-api",
            "models" => [%{"id" => "m"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      # Unknown api should fallback to :openai (most common OpenAI-compatible)
      assert result[:api] == :openai
    end

    test "returns :openai when api field is missing from JSON" do
      write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "baseUrl" => "https://example.com/v1",
            "models" => [%{"id" => "m"}]
          }
        }
      })

      result = ModelConfig.provider_config(@tmp_dir)

      assert result[:api] == :openai
    end

    test "defaults (no file) include api field" do
      result =
        without_env("OPENAI_API_KEY", fn ->
          without_env("OPENAI_BASE_URL", fn ->
            without_env("OPENAI_MODEL", fn ->
              ModelConfig.provider_config(@tmp_dir)
            end)
          end)
        end)

      # Default should have an api value
      assert Map.has_key?(result, :api)
      assert result[:api] in [:openai, :anthropic]
    end
  end

  # ══════════════════════════════════════════════════════════
  # 16. Workspace-level model access policy
  # ══════════════════════════════════════════════════════════

  describe "workspace model policy" do
    setup do
      # Write a global config with multiple providers
      write_config(%{
        "defaultProvider" => "cloud-provider",
        "defaultModel" => "cloud-model-v1",
        "providers" => %{
          "cloud-provider" => %{
            "baseUrl" => "https://cloud.example.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-cloud",
            "models" => [
              %{"id" => "cloud-model-v1", "name" => "Cloud Model V1"},
              %{"id" => "cloud-model-v2", "name" => "Cloud Model V2"}
            ]
          },
          "local-llm" => %{
            "baseUrl" => "http://localhost:11434/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-local",
            "models" => [
              %{"id" => "qwen2.5-coder:7b", "name" => "Qwen 2.5 Coder 7B"},
              %{"id" => "deepseek-coder:6.7b", "name" => "DeepSeek Coder 6.7B"}
            ]
          }
        }
      })

      {:ok, config_path: config_path()}
    end

    # ── Helper ──

    defp write_workspace_policy(workspace_root, policy) do
      settings_dir = Path.join(workspace_root, ".handbean")
      File.mkdir_p!(settings_dir)
      settings_path = Handbean.WorkspaceSettings.path(workspace_root)
      File.write!(settings_path, Jason.encode!(%{"models" => policy}))
      settings_path
    end

    defp tmp_workspace do
      dir =
        Path.join(System.tmp_dir!(), "sigil_policy_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn ->
        File.rm_rf(dir)
      end)

      dir
    end

    # ── 1. No policy file → unrestricted, all global models ──

    test "no .handbean/settings.jsonc returns all global models" do
      ws = tmp_workspace()

      assert ModelConfig.load_workspace_policy(ws) == :unrestricted

      models = ModelConfig.available_models_for_workspace(ws)
      assert length(models) == 4

      model_ids = Enum.map(models, & &1.id)
      assert "cloud-provider/cloud-model-v1" in model_ids
      assert "cloud-provider/cloud-model-v2" in model_ids
      assert "local-llm/qwen2.5-coder:7b" in model_ids
      assert "local-llm/deepseek-coder:6.7b" in model_ids
    end

    test "no policy uses global default model" do
      ws = tmp_workspace()

      default = ModelConfig.default_model_for_workspace(ws)
      assert default == "cloud-provider/cloud-model-v1"
    end

    # ── 2. Policy restricts to one provider/model ──

    test "policy with single provider/model filters correctly" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "default" => %{
          "provider" => "local-llm",
          "model" => "qwen2.5-coder:7b"
        },
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      assert length(models) == 1
      assert hd(models).id == "local-llm/qwen2.5-coder:7b"
      assert hd(models).name == "Qwen 2.5 Coder 7B"

      # Verify cloud models are NOT included
      model_ids = Enum.map(models, & &1.id)
      refute "cloud-provider/cloud-model-v1" in model_ids
      refute "cloud-provider/cloud-model-v2" in model_ids
    end

    test "policy with direct allow provider map filters correctly" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "allow" => %{
          "local-llm" => %{
            "models" => ["qwen2.5-coder:7b"]
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      assert length(models) == 1
      assert hd(models).id == "local-llm/qwen2.5-coder:7b"

      model_ids = Enum.map(models, & &1.id)
      refute "cloud-provider/cloud-model-v1" in model_ids
      refute "local-llm/deepseek-coder:6.7b" in model_ids
    end

    test "policy with multiple models from same provider" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b", "deepseek-coder:6.7b"]
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      assert length(models) == 2
    end

    test "policy with models from multiple providers" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            },
            "cloud-provider" => %{
              "models" => ["cloud-model-v1"]
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      assert length(models) == 2

      model_ids = Enum.map(models, & &1.id)
      assert "local-llm/qwen2.5-coder:7b" in model_ids
      assert "cloud-provider/cloud-model-v1" in model_ids
    end

    # ── 3. Policy references non-existent provider/model ──

    test "ignores non-existent model, keeps valid ones" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b", "nonexistent-model"]
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      # Only valid model should appear; nonexistent model ignored
      assert length(models) == 1
      assert hd(models).id == "local-llm/qwen2.5-coder:7b"
    end

    test "ignores non-existent provider" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "nonexistent-provider" => %{
              "models" => ["some-model"]
            },
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      # Non-existent provider should be ignored; local-llm model still accessible
      assert length(models) == 1
      assert hd(models).id == "local-llm/qwen2.5-coder:7b"
    end

    test "all references non-existent → empty models, no crash" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "ghost-provider" => %{
              "models" => ["ghost-model"]
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      assert models == []

      # Should not crash, should not fallback to global
    end

    # ── 4. Empty allow.providers → unrestricted ──

    test "empty allow.providers returns all global models" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{}
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      assert length(models) == 4
    end

    test "empty allow.providers uses global default model" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{}
        }
      })

      default = ModelConfig.default_model_for_workspace(ws)
      assert default == "cloud-provider/cloud-model-v1"
    end

    # ── 5. Provider exists but models array is empty ──

    test "provider with empty models → no models" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => []
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)
      assert models == []
    end

    # ── 6. Default not in allowlist → auto-select first allowed ──

    test "policy default not in allowlist → picks first allowed" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "default" => %{
          "provider" => "cloud-provider",
          "model" => "cloud-model-v1"
        },
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b", "deepseek-coder:6.7b"]
            }
          }
        }
      })

      default = ModelConfig.default_model_for_workspace(ws)
      # Default should auto-select first allowed, not cloud-model-v1
      assert default == "local-llm/qwen2.5-coder:7b"
    end

    # ── 7. Default missing → picks first allowed ──

    test "no default in policy → picks first allowed model" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["deepseek-coder:6.7b", "qwen2.5-coder:7b"]
            }
          }
        }
      })

      default = ModelConfig.default_model_for_workspace(ws)
      # Default picks first allowed model (in global config order, not policy order)
      assert default == "local-llm/qwen2.5-coder:7b"
    end

    test "default in policy but not in allowlist → falls back to first allowed model" do
      ws = tmp_workspace()

      # Policy says default is cloud-model-v1, but the allowlist only has local-llm
      write_workspace_policy(ws, %{
        "version" => 1,
        "default" => %{
          "provider" => "cloud-provider",
          "model" => "cloud-model-v1"
        },
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            }
          }
        }
      })

      default = ModelConfig.default_model_for_workspace(ws)
      # Should fall back to the first allowed model, NOT return nil
      assert default == "local-llm/qwen2.5-coder:7b"
    end

    # ── 8. Malformed JSON → no models, no fallback ──

    test "malformed policy JSON returns error and no models" do
      ws = tmp_workspace()

      policy_path = Handbean.WorkspaceSettings.path(ws)
      File.mkdir_p!(Path.join(ws, ".handbean"))
      File.write!(policy_path, "{not valid json")

      assert {:error, reason} = ModelConfig.load_workspace_policy(ws)
      assert reason =~ "Failed to parse"

      models = ModelConfig.available_models_for_workspace(ws)
      assert models == []

      default = ModelConfig.default_model_for_workspace(ws)
      assert is_nil(default)
    end

    test "malformed policy does NOT fallback to global models" do
      ws = tmp_workspace()

      policy_path = Handbean.WorkspaceSettings.path(ws)
      File.mkdir_p!(Path.join(ws, ".handbean"))
      File.write!(policy_path, "broken{{{ json")

      models = ModelConfig.available_models_for_workspace(ws)
      # Must NOT return global cloud models as a fallback
      refute Enum.any?(models, &(&1.provider_id == "cloud-provider"))
      assert models == []
    end

    # ── 9. model_allowed_for_workspace? check ──

    test "model_allowed_for_workspace? returns true for allowed model" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            }
          }
        }
      })

      assert ModelConfig.model_allowed_for_workspace?(ws, "local-llm/qwen2.5-coder:7b")
      assert ModelConfig.model_allowed_for_workspace?(ws, "qwen2.5-coder:7b")
      refute ModelConfig.model_allowed_for_workspace?(ws, "cloud-provider/cloud-model-v1")
      refute ModelConfig.model_allowed_for_workspace?(ws, "nonexistent/model")
    end

    test "model_in_catalog? ignores workspace policy and disabled flag" do
      assert ModelConfig.model_in_catalog?("cloud-provider/cloud-model-v1")
      assert ModelConfig.model_in_catalog?("cloud-model-v1")
      refute ModelConfig.model_in_catalog?("xai/grok-4.7")
      refute ModelConfig.model_in_catalog?(nil)
    end

    test "model_allowed_for_workspace? returns true for all when unrestricted" do
      ws = tmp_workspace()

      assert ModelConfig.model_allowed_for_workspace?(ws, "cloud-provider/cloud-model-v1")
      assert ModelConfig.model_allowed_for_workspace?(ws, "cloud-model-v1")
      assert ModelConfig.model_allowed_for_workspace?(ws, "local-llm/qwen2.5-coder:7b")
    end

    # ── 10. resolve_model_for_workspace ──

    test "resolve_model_for_workspace returns provider config and model id" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            }
          }
        }
      })

      assert {:ok, provider_config, model_id} =
               ModelConfig.resolve_model_for_workspace(ws, "local-llm/qwen2.5-coder:7b")

      assert model_id == "qwen2.5-coder:7b"
      assert provider_config[:model] == "qwen2.5-coder:7b"
      assert provider_config[:base_url] == "http://localhost:11434/v1"
      assert provider_config[:api_key] == "sk-local"
    end

    test "resolve_model_for_workspace preserves model metadata for selected model" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "cloud-provider" => %{
              "models" => ["cloud-model-v2"]
            }
          }
        }
      })

      assert {:ok, provider_config, "cloud-model-v2"} =
               ModelConfig.resolve_model_for_workspace(ws, "cloud-provider/cloud-model-v2")

      assert provider_config[:model_meta]["id"] == "cloud-model-v2"
      assert provider_config[:model_meta]["name"] == "Cloud Model V2"
    end

    test "resolve_model_for_workspace preserves Responses provider options" do
      write_config(%{
        "defaultProvider" => "cloud-provider",
        "defaultModel" => "cloud-model-v1",
        "providers" => %{
          "cloud-provider" => %{
            "baseUrl" => "https://cloud.example.com/v1",
            "api" => "openai",
            "usePreviousResponseId" => false,
            "parallelToolCalls" => true,
            "models" => [
              %{
                "id" => "cloud-model-v1",
                "name" => "Cloud Model V1",
                "parallelToolCalls" => false
              }
            ]
          }
        }
      })

      ws = tmp_workspace()

      assert {:ok, provider_config, "cloud-model-v1"} =
               ModelConfig.resolve_model_for_workspace(ws, "cloud-provider/cloud-model-v1")

      assert provider_config[:api] == :openai_responses
      assert provider_config[:use_previous_response_id] == false
      assert provider_config[:parallel_tool_calls] == false
    end

    test "resolve_model_for_workspace rejects disallowed model" do
      ws = tmp_workspace()

      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            }
          }
        }
      })

      assert {:error, reason} =
               ModelConfig.resolve_model_for_workspace(ws, "cloud-provider/cloud-model-v1")

      assert reason =~ "not allowed"
    end

    # ── 11. provider_config_for returns correct per-provider config ──

    test "provider_config_for returns config for specific provider" do
      assert {:ok, config} = ModelConfig.provider_config_for(@tmp_dir, "local-llm")
      assert config[:base_url] == "http://localhost:11434/v1"
      assert config[:api_key] == "sk-local"
      refute Map.has_key?(config, :model)
    end

    test "provider_config_for includes selected model when model id is provided" do
      assert {:ok, config} =
               ModelConfig.provider_config_for(@tmp_dir, "local-llm", "deepseek-coder:6.7b")

      assert config[:model] == "deepseek-coder:6.7b"
    end

    test "provider_config_for falls back to selected model maxTokens when provider maxTokens is absent" do
      write_config(%{
        "defaultProvider" => "local-llm",
        "providers" => %{
          "local-llm" => %{
            "baseUrl" => "http://localhost:11434/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-local",
            "provider" => "ollama",
            "models" => [
              %{
                "id" => "deepseek-coder:6.7b",
                "name" => "DeepSeek Coder",
                "maxTokens" => 16384
              }
            ]
          }
        }
      })

      assert {:ok, config} =
               ModelConfig.provider_config_for(@tmp_dir, "local-llm", "deepseek-coder:6.7b")

      assert config[:max_tokens] == 16384
    end

    test "provider_config_for returns error for unknown provider" do
      assert {:error, reason} = ModelConfig.provider_config_for(@tmp_dir, "unknown-provider")
      assert reason =~ "not found"
    end

    # ── 12. all_global_models ──

    test "all_global_models returns models from all providers" do
      models = ModelConfig.all_global_models()
      assert length(models) == 4

      # Each model should have provider_id and model_id
      for m <- models do
        assert is_binary(m.provider_id)
        assert is_binary(m.model_id)
        assert String.contains?(m.id, m.provider_id)
        assert String.contains?(m.id, m.model_id)
      end
    end

    test "resolve_global_model resolves a catalog id without workspace policy" do
      write_config(%{
        "defaultProvider" => "global-provider",
        "defaultModel" => "global-model",
        "providers" => %{
          "global-provider" => %{
            "baseUrl" => "https://global.example.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-global-test",
            "models" => [%{"id" => "global-model", "name" => "Global Model"}]
          }
        }
      })

      assert {:ok, provider_config, "global-model"} =
               ModelConfig.resolve_global_model("global-provider/global-model")

      assert provider_config[:base_url] == "https://global.example.com/v1"
      assert provider_config[:api_key] == "sk-global-test"
      assert provider_config[:model] == "global-model"
    end

    test "resolve_global_model rejects an id absent from the global catalog" do
      write_config(%{"providers" => %{}})

      assert {:error, "Model missing-provider/missing-model is not available"} =
               ModelConfig.resolve_global_model("missing-provider/missing-model")
    end

    # ── 13. Workspace settings never expose apiKey/baseUrl ──

    test "workspace model settings do NOT expose apiKey or baseUrl" do
      ws = tmp_workspace()

      # Workspace settings are separate from global provider config.
      # available_models_for_workspace returns model summaries (id, name only),
      # not full provider configs.
      write_workspace_policy(ws, %{
        "version" => 1,
        "allow" => %{
          "providers" => %{
            "local-llm" => %{
              "models" => ["qwen2.5-coder:7b"]
            }
          }
        }
      })

      models = ModelConfig.available_models_for_workspace(ws)

      for m <- models do
        refute Map.has_key?(m, :api_key)
        refute Map.has_key?(m, :base_url)
        refute Map.has_key?(m, "apiKey")
        refute Map.has_key?(m, "baseUrl")
      end
    end
  end

  # ── read_config/0 (single raw read path shared with settings UIs) ──

  describe "read_config/0" do
    test "missing file is an empty catalog, not an error" do
      assert {:ok, %{"defaultProvider" => "", "providers" => %{}}} = ModelConfig.read_config()
    end

    test "returns the stored map untouched (no env override, no secret resolution)" do
      write_config(%{
        "defaultProvider" => "p",
        "defaultModel" => "m",
        "providers" => %{
          "p" => %{"apiKey" => "env:HANDBEAN_TEST_UNSET_KEY", "models" => [%{"id" => "m"}]}
        }
      })

      with_env("OPENAI_MODEL", "other", fn ->
        assert {:ok, config} = ModelConfig.read_config()
        assert config["defaultModel"] == "m"
        assert config["providers"]["p"]["apiKey"] == "env:HANDBEAN_TEST_UNSET_KEY"
      end)
    end

    test "invalid JSON is a parse error" do
      File.write!(config_path(), "{ not json")
      assert {:error, "Failed to parse config: " <> _} = ModelConfig.read_config()
    end

    test "non-object JSON is rejected" do
      File.write!(config_path(), "[1, 2]")
      assert {:error, "Config must be a JSON object"} = ModelConfig.read_config()
    end

    test "object without a providers object is rejected" do
      File.write!(config_path(), "{}")
      assert {:error, "Config providers must be a JSON object"} = ModelConfig.read_config()

      File.write!(config_path(), ~s({"providers": []}))
      assert {:error, "Config providers must be a JSON object"} = ModelConfig.read_config()
    end

    test "unreadable path is a read error" do
      File.mkdir_p!(config_path())
      assert {:error, "Failed to read config: " <> _} = ModelConfig.read_config()
    end
  end
end
