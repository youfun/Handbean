defmodule Handbean.Agent.ModelConfigPolicyTest do
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
end
