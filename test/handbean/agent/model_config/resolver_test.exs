defmodule Handbean.Agent.ModelConfigResolverTest do
  @moduledoc false
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
end
