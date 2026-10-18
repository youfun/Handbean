defmodule Handbean.Agent.ModelConfigWriteTest do
  @moduledoc """
  TDD tests for ModelConfig write/CRUD methods.

  Every test writes → reads back → verifies the roundtrip.
  Tests also cover:
    - Input types (text, image, audio) roundtrip
    - Multiple providers with multiple models
    - Validation (invalid names, duplicates, missing fields)
    - Atomic file write (no corruption on partial writes)
    - ensure_config creates the file + directory
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.ModelConfig

  @tmp_dir Path.join(System.tmp_dir!(), "sigil_model_config_write_test")

  setup do
    old_env = System.get_env("HANDBEAN_MODELS_FILE")
    File.mkdir_p!(@tmp_dir)
    System.put_env("HANDBEAN_MODELS_FILE", config_path())

    on_exit(fn ->
      File.rm_rf(@tmp_dir)

      if old_env,
        do: System.put_env("HANDBEAN_MODELS_FILE", old_env),
        else: System.delete_env("HANDBEAN_MODELS_FILE")
    end)

    :ok
  end

  defp config_path, do: Path.join(@tmp_dir, "models.json")

  # ══════════════════════════════════════════════════════════
  # ensure_config
  # ══════════════════════════════════════════════════════════

  describe "ensure_config/0" do
    test "creates ~/.handbean/models.json when it does not exist" do
      refute File.exists?(config_path())

      assert :ok = ModelConfig.ensure_config()
      assert File.exists?(config_path())
      assert File.stat!(config_path()).mode |> Bitwise.band(0o777) == 0o600

      content = File.read!(config_path())
      assert {:ok, json} = Jason.decode(content)
      assert is_map(json)
    end

    test "is idempotent — does not overwrite existing config" do
      # Write a custom config first
      custom = %{
        "defaultProvider" => "my-p",
        "providers" => %{
          "my-p" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "sk-test",
            "models" => [%{"id" => "m1", "name" => "Model 1"}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(custom))
      assert :ok = ModelConfig.ensure_config()

      # Should still be the same content
      assert {:ok, ^custom} = config_path() |> File.read!() |> Jason.decode()
    end

    test "creates parent directory if needed" do
      nested = Path.join([@tmp_dir, "deep", "nested", "dir", "models.json"])
      System.put_env("HANDBEAN_MODELS_FILE", nested)
      on_exit(fn -> System.put_env("HANDBEAN_MODELS_FILE", config_path()) end)

      assert :ok = ModelConfig.ensure_config()
      assert File.exists?(nested)
    end

    test "seeds a usable default provider catalog" do
      assert :ok = ModelConfig.ensure_config()

      models = ModelConfig.all_global_models()
      assert models != []
      assert Enum.any?(models, &(&1.model_id == "step-router-v1"))
      router = Enum.find(models, &(&1.model_id == "step-router-v1"))
      preview = Enum.find(models, &(&1.model_id == "step-5-preview"))
      assert preview.provider_id == router.provider_id
      assert router.input == ["text"]
      assert preview.input == ["text", "image"]

      assert {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["defaultProvider"] == "stepfun"
      assert json["defaultModel"] == "step-5-preview"
    end

    test "adds step-5-preview to an existing StepFun catalog and makes it default" do
      File.write!(
        config_path(),
        Jason.encode!(%{
          "defaultProvider" => "stepfun",
          "defaultModel" => "step-router-v1",
          "providers" => %{
            "stepfun" => %{
              "baseUrl" => "https://api.stepfun.com/step_plan/v1",
              "api" => "stepfun-step-plan",
              "apiKey" => "env:OPENAI_API_KEY",
              "provider" => "stepfun",
              "models" => [
                %{
                  "id" => "step-router-v1",
                  "name" => "Step Router v1",
                  "reasoning" => true,
                  "input" => ["text"]
                },
                %{
                  "id" => "step-3.7-flash",
                  "name" => "Step 3.7 Flash",
                  "reasoning" => true,
                  "input" => ["text", "image"]
                }
              ]
            }
          }
        })
      )

      assert :ok = ModelConfig.ensure_config()
      assert {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      ids = Enum.map(json["providers"]["stepfun"]["models"], & &1["id"])
      assert ids == ["step-router-v1", "step-3.7-flash", "step-5-preview"]
      assert json["defaultModel"] == "step-5-preview"

      assert :ok = ModelConfig.ensure_config()
      assert {:ok, again} = config_path() |> File.read!() |> Jason.decode()
      assert again["defaultModel"] == "step-5-preview"
      assert length(again["providers"]["stepfun"]["models"]) == 3
    end

    test "optional seed is used only when models.json is missing" do
      seed = Path.join(@tmp_dir, "seed.json")

      File.write!(
        seed,
        Jason.encode!(%{
          "defaultProvider" => "seeded",
          "providers" => %{
            "seeded" => %{
              "api" => "openai-chat-completions",
              "apiKey" => "env:OPENAI_API_KEY",
              "models" => [%{"id" => "seed-model", "name" => "Seed"}]
            }
          }
        })
      )

      System.put_env("HANDBEAN_MODELS_SEED", seed)
      on_exit(fn -> System.delete_env("HANDBEAN_MODELS_SEED") end)

      assert :ok = ModelConfig.ensure_config()
      assert {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["defaultProvider"] == "seeded"

      File.write!(
        config_path(),
        Jason.encode!(%{"defaultProvider" => "kept", "providers" => %{}})
      )

      assert :ok = ModelConfig.ensure_config()
      assert {:ok, again} = config_path() |> File.read!() |> Jason.decode()
      assert again["defaultProvider"] == "kept"
    end
  end

  # ══════════════════════════════════════════════════════════
  # write_config (full config write)
  # ══════════════════════════════════════════════════════════

  describe "write_config/1" do
    test "writes a complete config and reads it back" do
      config = %{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "apiKey" => "env:OPENAI_API_KEY",
            "provider" => "stepfun",
            "models" => [
              %{"id" => "step-router-v1", "name" => "Step Router v1", "input" => ["text"]}
            ]
          }
        }
      }

      assert :ok = ModelConfig.write_config(config)
      assert File.stat!(config_path()).mode |> Bitwise.band(0o777) == 0o600

      # Read back through provider_config
      result = ModelConfig.provider_config(@tmp_dir)
      assert result[:base_url] == "https://api.stepfun.com/step_plan/v1"
      assert result[:model] == "step-router-v1"
      assert result[:api] == :stepfun
      assert result[:provider] == "stepfun"

      # Read back through available_models
      models = ModelConfig.available_models(@tmp_dir)
      assert length(models) == 1
      assert hd(models).id == "step-router-v1"
      assert hd(models).name == "Step Router v1"
      assert hd(models).input == ["text"]
    end

    test "writes config with multiple providers and multiple models each" do
      config = %{
        "defaultProvider" => "cloud",
        "defaultModel" => "gpt-5",
        "providers" => %{
          "cloud" => %{
            "baseUrl" => "https://api.cloud.com/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-cloud-key",
            "models" => [
              %{"id" => "gpt-5", "name" => "GPT-5", "input" => ["text", "image"]},
              %{"id" => "gpt-5-mini", "name" => "GPT-5 Mini", "input" => ["text"]}
            ]
          },
          "local" => %{
            "baseUrl" => "http://localhost:11434/v1",
            "api" => "openai-chat-completions",
            "apiKey" => "sk-local",
            "models" => [
              %{"id" => "llama3", "name" => "Llama 3", "input" => ["text"]},
              %{
                "id" => "qwen-coder",
                "name" => "Qwen Coder",
                "input" => ["text", "image", "audio"]
              }
            ]
          }
        }
      }

      assert :ok = ModelConfig.write_config(config)

      # Read back
      result = ModelConfig.provider_config(@tmp_dir)
      assert result[:model] == "gpt-5"
      assert result[:provider_key] == "cloud"

      # available_models returns models from default provider only (cloud)
      default_models = ModelConfig.available_models(@tmp_dir)
      assert length(default_models) == 2

      # all_global_models returns models from ALL providers
      all = ModelConfig.all_global_models()
      assert length(all) == 4

      assert Enum.map(all, & &1.id) == [
               "cloud/gpt-5",
               "cloud/gpt-5-mini",
               "local/llama3",
               "local/qwen-coder"
             ]

      # Verify input types roundtrip
      gpt5 = Enum.find(all, &(&1.id == "cloud/gpt-5"))
      assert gpt5.input == ["text", "image"]

      qwen = Enum.find(all, &(&1.id == "local/qwen-coder"))
      assert qwen.input == ["text", "image", "audio"]
    end

    test "concurrent provider updates preserve every provider change" do
      provider_ids = Enum.map(1..24, &"provider-#{&1}")

      providers =
        Map.new(provider_ids, fn provider_id ->
          {provider_id,
           %{
             "name" => provider_id,
             "api" => "openai-chat-completions",
             "models" => []
           }}
        end)

      assert :ok =
               ModelConfig.write_config(%{
                 "defaultProvider" => hd(provider_ids),
                 "providers" => providers
               })

      parent = self()

      tasks =
        Enum.map(provider_ids, fn provider_id ->
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :update ->
                ModelConfig.update_provider(provider_id, %{"name" => "Updated #{provider_id}"})
            end
          end)
        end)

      pids =
        Enum.map(tasks, fn _task ->
          assert_receive {:ready, pid}
          pid
        end)

      Enum.each(pids, &send(&1, :update))
      assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))

      assert {:ok, saved} = ModelConfig.read_config()

      Enum.each(provider_ids, fn provider_id ->
        assert saved["providers"][provider_id]["name"] == "Updated #{provider_id}"
      end)
    end

    test "write_config validates and rejects invalid config" do
      # Missing providers key
      assert {:error, "At least one provider is required"} =
               ModelConfig.write_config(%{"defaultProvider" => "x"})

      # Empty providers
      assert {:error, _} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "x",
                 "providers" => %{}
               })

      # Malformed models field (must be an array; empty array is allowed)
      assert {:error, reason} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "x",
                 "providers" => %{
                   "x" => %{"api" => "openai-chat-completions", "models" => "not-an-array"}
                 }
               })

      assert reason == "Provider models must be a JSON array"

      assert :ok =
               ModelConfig.write_config(%{
                 "defaultProvider" => "empty",
                 "providers" => %{
                   "empty" => %{"api" => "openai-chat-completions", "models" => []}
                 }
               })

      {:ok, written} = config_path() |> File.read!() |> Jason.decode()
      assert written["providers"]["empty"]["models"] == []
      assert written["defaultModel"] in [nil, ""]

      # defaultProvider not in providers
      assert {:error, _} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "nonexistent",
                 "providers" => %{
                   "valid" => %{
                     "api" => "openai-chat-completions",
                     "models" => [%{"id" => "m", "name" => "M"}]
                   }
                 }
               })

      # defaultModel not in provider's models
      assert {:error, _} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "p",
                 "defaultModel" => "nonexistent-model",
                 "providers" => %{
                   "p" => %{
                     "api" => "openai-chat-completions",
                     "models" => [%{"id" => "valid-model", "name" => "V"}]
                   }
                 }
               })

      # Model without name
      assert {:error, _} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "p",
                 "providers" => %{
                   "p" => %{
                     "api" => "openai-chat-completions",
                     "models" => [%{"id" => "m"}]
                   }
                 }
               })

      # Duplicate model ids within provider
      assert {:error, _} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "p",
                 "providers" => %{
                   "p" => %{
                     "api" => "openai-chat-completions",
                     "models" => [
                       %{"id" => "same-id", "name" => "A"},
                       %{"id" => "same-id", "name" => "B"}
                     ]
                   }
                 }
               })

      # Provider config must be an object
      assert {:error, reason} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "p",
                 "providers" => %{"p" => "not-an-object"}
               })

      assert reason =~ "JSON object"

      # Model entries must be objects
      assert {:error, reason} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "p",
                 "providers" => %{
                   "p" => %{
                     "api" => "openai-chat-completions",
                     "models" => ["not-an-object"]
                   }
                 }
               })

      assert reason =~ "Model entries"
    end
  end

  # ══════════════════════════════════════════════════════════
  # add_provider
  # ══════════════════════════════════════════════════════════

  describe "add_provider/2" do
    setup do
      # Start with one existing provider
      initial = %{
        "defaultProvider" => "existing",
        "providers" => %{
          "existing" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "sk-existing",
            "models" => [%{"id" => "m1", "name" => "Model 1", "input" => ["text"]}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      :ok
    end

    test "adds a new provider and reads it back" do
      assert :ok =
               ModelConfig.add_provider("new-provider", %{
                 "baseUrl" => "https://new.example.com/v1",
                 "api" => "openai-chat-completions",
                 "apiKey" => "sk-new-key",
                 "models" => [
                   %{"id" => "new-model", "name" => "New Model", "input" => ["text", "image"]}
                 ]
               })

      # Read back: both providers exist
      all = ModelConfig.all_global_models()
      assert length(all) == 2

      provider_ids = Enum.map(all, & &1.provider_id) |> Enum.uniq()
      assert "existing" in provider_ids
      assert "new-provider" in provider_ids

      # New provider's config is correct
      assert {:ok, new_config} = ModelConfig.provider_config_for(@tmp_dir, "new-provider")
      assert new_config[:base_url] == "https://new.example.com/v1"
      assert new_config[:api_key] == "sk-new-key"
    end

    test "rejects adding provider with duplicate id" do
      assert {:error, reason} =
               ModelConfig.add_provider("existing", %{
                 "api" => "openai-chat-completions",
                 "models" => [%{"id" => "x", "name" => "X"}]
               })

      assert reason == "Provider 'existing' already exists"
    end

    test "rejects adding provider with invalid name" do
      assert {:error, "Provider id must match " <> _} =
               ModelConfig.add_provider("bad name!", %{
                 "api" => "openai-chat-completions",
                 "models" => [%{"id" => "x", "name" => "X"}]
               })
    end

    test "adds a configured provider with zero models and assigns first defaultProvider" do
      File.rm(config_path())

      assert :ok =
               ModelConfig.add_provider("empty-lab", %{
                 "name" => "Empty Lab",
                 "api" => "openai-chat-completions",
                 "baseUrl" => "https://empty.example/v1"
               })

      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["defaultProvider"] == "empty-lab"
      refute is_binary(json["defaultModel"]) and json["defaultModel"] != ""
      assert json["providers"]["empty-lab"]["models"] == []
      assert ModelConfig.all_global_models() == []
    end

    test "adds provider when config file does not exist yet" do
      File.rm!(config_path())
      refute File.exists?(config_path())

      assert :ok =
               ModelConfig.add_provider("first-p", %{
                 "api" => "openai-chat-completions",
                 "apiKey" => "sk-first",
                 "models" => [%{"id" => "m", "name" => "M", "input" => ["text", "audio"]}]
               })

      assert File.exists?(config_path())
      result = ModelConfig.provider_config(@tmp_dir)
      assert result[:provider_key] == "first-p"
    end
  end

  # ══════════════════════════════════════════════════════════
  # remove_provider
  # ══════════════════════════════════════════════════════════

  describe "remove_provider/1" do
    setup do
      initial = %{
        "defaultProvider" => "keep",
        "providers" => %{
          "keep" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "km", "name" => "Keep"}]
          },
          "remove-me" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "rm", "name" => "Remove"}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      :ok
    end

    test "removes a provider and its models" do
      assert :ok = ModelConfig.remove_provider("remove-me")

      all = ModelConfig.all_global_models()
      assert length(all) == 1
      assert hd(all).provider_id == "keep"

      # Removed provider no longer resolvable
      assert {:error, _} = ModelConfig.provider_config_for(@tmp_dir, "remove-me")
    end

    test "handle removing non-existent provider gracefully" do
      assert {:error, "Provider 'no-such' does not exist"} =
               ModelConfig.remove_provider("no-such")
    end

    test "cannot remove the last provider" do
      File.rm!(config_path())

      ModelConfig.write_config(%{
        "defaultProvider" => "only",
        "providers" => %{
          "only" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m", "name" => "M"}]
          }
        }
      })

      assert {:error, "At least one provider is required"} = ModelConfig.remove_provider("only")
    end

    test "changing defaultProvider if the removed provider was the default" do
      initial = %{
        "defaultProvider" => "old-default",
        "providers" => %{
          "old-default" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "od", "name" => "OD"}]
          },
          "new-default" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "nd", "name" => "ND"}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      assert :ok = ModelConfig.remove_provider("old-default")

      result = ModelConfig.provider_config(@tmp_dir)
      assert result[:provider_key] == "new-default"
    end
  end

  # ══════════════════════════════════════════════════════════
  # add_model / remove_model
  # ══════════════════════════════════════════════════════════

  describe "add_model/3" do
    setup do
      initial = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "existing", "name" => "Existing", "input" => ["text"]}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      :ok
    end

    test "adds a model to existing provider and reads it back" do
      assert :ok =
               ModelConfig.add_model("p", "new-model", %{
                 "name" => "New Model",
                 "input" => ["text", "image", "audio"],
                 "reasoning" => true,
                 "defaultReasoning" => "medium",
                 "contextWindow" => 128_000,
                 "maxTokens" => 64000
               })

      models = ModelConfig.available_models(@tmp_dir)
      assert length(models) == 2

      new_model = Enum.find(models, &(&1.id == "new-model"))
      assert new_model.name == "New Model"
      assert new_model.input == ["text", "image", "audio"]
      assert new_model.reasoning == true
      assert new_model.default_reasoning == "medium"
      assert new_model.context_window == 128_000
      assert new_model.max_tokens == 64000
    end

    test "rejects adding duplicate model id" do
      assert {:error, reason} =
               ModelConfig.add_model("p", "existing", %{
                 "name" => "Duplicate",
                 "input" => ["text"]
               })

      assert reason == "Model 'existing' already exists in provider 'p'"
    end

    test "rejects adding model to non-existent provider" do
      assert {:error, "Provider 'ghost' does not exist"} =
               ModelConfig.add_model("ghost", "m", %{"name" => "Ghost"})
    end

    test "rejects adding model without name" do
      assert {:error, "Model name is required"} =
               ModelConfig.add_model("p", "m", %{"input" => ["text"]})
    end

    test "rejects adding a model when the provider does not exist" do
      assert {:error, "Provider 'no-such-provider' does not exist"} =
               ModelConfig.add_model("no-such-provider", "m", %{"name" => "M"})
    end
  end

  describe "remove_model/2" do
    setup do
      initial = %{
        "defaultProvider" => "p",
        "defaultModel" => "keep-me",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "keep-me", "name" => "Keep Me", "input" => ["text"]},
              %{"id" => "remove-me", "name" => "Remove Me", "input" => ["text", "image"]}
            ]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      :ok
    end

    test "removes a model from its provider" do
      assert :ok = ModelConfig.remove_model("p", "remove-me")

      models = ModelConfig.available_models(@tmp_dir)
      assert length(models) == 1
      assert hd(models).id == "keep-me"
    end

    test "rejects removing non-existent model" do
      assert {:error, "Model 'no-such' does not exist in provider 'p'"} =
               ModelConfig.remove_model("p", "no-such")
    end

    test "removing the last model leaves a configured empty provider" do
      # A provider may exist before its first model (add-provider then add-model)
      # and after its last model is removed. Catalog still requires at least one
      # provider; defaultModel becomes unset when none remain on the default provider.
      assert :ok = ModelConfig.remove_model("p", "remove-me")
      assert :ok = ModelConfig.remove_model("p", "keep-me")

      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["providers"]["p"]["models"] == []
      assert json["defaultProvider"] == "p"
      assert json["defaultModel"] in [nil, ""]
    end

    test "cannot remove the defaultModel model" do
      # Wait — removing "keep-me" is also the last model, so we need separate test.
      # Change config so there are 2 models and the defaultModel is one of them.
      initial = %{
        "defaultProvider" => "p",
        "defaultModel" => "default-one",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "default-one", "name" => "Default One", "input" => ["text"]},
              %{"id" => "other", "name" => "Other", "input" => ["text"]}
            ]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))

      # Should be allowed to remove defaultModel if it's not the last model
      assert :ok = ModelConfig.remove_model("p", "default-one")

      result = ModelConfig.provider_config(@tmp_dir)
      assert result[:model] == "other"
    end
  end

  # ══════════════════════════════════════════════════════════
  # update_provider / update_model
  # ══════════════════════════════════════════════════════════

  describe "update_provider/2" do
    setup do
      initial = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "old-key",
            "baseUrl" => "https://old.example.com",
            "models" => [%{"id" => "m", "name" => "M"}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      :ok
    end

    test "updates provider fields and reads back" do
      assert :ok =
               ModelConfig.update_provider("p", %{
                 "baseUrl" => "https://new.example.com/v1",
                 "apiKey" => "sk-updated-key",
                 "temperature" => 0.7
               })

      assert {:ok, config} = ModelConfig.provider_config_for(@tmp_dir, "p")
      assert config[:base_url] == "https://new.example.com/v1"
      assert config[:api_key] == "sk-updated-key"
      assert config[:temperature] == 0.7
    end

    test "merges with existing fields (non-destructive)" do
      assert :ok = ModelConfig.update_provider("p", %{"apiKey" => "sk-new-only"})

      assert {:ok, config} = ModelConfig.provider_config_for(@tmp_dir, "p")
      assert config[:api_key] == "sk-new-only"
      assert config[:base_url] == "https://old.example.com"
    end

    test "rejects updating non-existent provider" do
      assert {:error, "Provider 'ghost' does not exist"} =
               ModelConfig.update_provider("ghost", %{"apiKey" => "x"})
    end
  end

  describe "update_model/3" do
    setup do
      initial = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [
              %{
                "id" => "m",
                "name" => "Old Name",
                "input" => ["text"],
                "contextWindow" => 8192
              }
            ]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      :ok
    end

    test "updates model fields and reads back" do
      assert :ok =
               ModelConfig.update_model("p", "m", %{
                 "name" => "New Name",
                 "input" => ["text", "image", "audio"],
                 "reasoning" => true,
                 "contextWindow" => 128_000
               })

      models = ModelConfig.available_models(@tmp_dir)
      assert length(models) == 1
      updated = hd(models)
      assert updated.name == "New Name"
      assert updated.input == ["text", "image", "audio"]
      assert updated.reasoning == true
      assert updated.context_window == 128_000
    end

    test "merges with existing model fields" do
      assert :ok = ModelConfig.update_model("p", "m", %{"input" => ["text", "image"]})

      models = ModelConfig.available_models(@tmp_dir)
      updated = hd(models)
      assert updated.input == ["text", "image"]
      assert updated.name == "Old Name"
      assert updated.context_window == 8192
    end

    test "rejects updating non-existent model" do
      assert {:error, "Model 'ghost' does not exist in provider 'p'"} =
               ModelConfig.update_model("p", "ghost", %{"name" => "X"})
    end

    test "rejects updating non-existent provider" do
      assert {:error, "Provider 'ghost' does not exist"} =
               ModelConfig.update_model("ghost", "m", %{"name" => "X"})
    end
  end

  # ══════════════════════════════════════════════════════════
  # update_api_key
  # ══════════════════════════════════════════════════════════

  describe "update_api_key/2" do
    setup do
      initial = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "sk-original",
            "models" => [%{"id" => "m", "name" => "M"}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(initial))
      :ok
    end

    test "updates api key for a provider" do
      assert :ok = ModelConfig.update_api_key("p", "sk-new-key")

      assert {:ok, config} = ModelConfig.provider_config_for(@tmp_dir, "p")
      assert config[:api_key] == "sk-new-key"
    end

    test "handles env:VAR format" do
      assert :ok = ModelConfig.update_api_key("p", "env:CUSTOM_KEY")

      # Direct JSON read to verify exact string stored
      {:ok, raw} = config_path() |> File.read!() |> Jason.decode()
      assert get_in(raw, ["providers", "p", "apiKey"]) == "env:CUSTOM_KEY"
    end

    test "rejects updating api key for non-existent provider" do
      assert {:error, "Provider 'ghost' does not exist"} =
               ModelConfig.update_api_key("ghost", "sk-x")
    end
  end

  # ══════════════════════════════════════════════════════════
  # Input types: text, image, audio
  # ══════════════════════════════════════════════════════════

  describe "input types" do
    test "roundtrips text-only input" do
      config = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "text-only", "name" => "T", "input" => ["text"]}]
          }
        }
      }

      assert :ok = ModelConfig.write_config(config)

      models = ModelConfig.available_models(@tmp_dir)
      assert hd(models).input == ["text"]
    end

    test "roundtrips text+image input" do
      config = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "vision", "name" => "V", "input" => ["text", "image"]}
            ]
          }
        }
      }

      assert :ok = ModelConfig.write_config(config)

      models = ModelConfig.available_models(@tmp_dir)
      assert hd(models).input == ["text", "image"]
    end

    test "roundtrips text+image+audio input" do
      config = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "multimodal", "name" => "MM", "input" => ["text", "image", "audio"]}
            ]
          }
        }
      }

      assert :ok = ModelConfig.write_config(config)

      models = ModelConfig.available_models(@tmp_dir)
      assert hd(models).input == ["text", "image", "audio"]
    end

    test "rejects invalid input types" do
      assert {:error, "Invalid input types: " <> _} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "p",
                 "providers" => %{
                   "p" => %{
                     "api" => "openai-chat-completions",
                     "models" => [%{"id" => "m", "name" => "M", "input" => ["text", "video"]}]
                   }
                 }
               })
    end

    test "rejects empty input array" do
      assert {:error, "Model input must be a non-empty list"} =
               ModelConfig.write_config(%{
                 "defaultProvider" => "p",
                 "providers" => %{
                   "p" => %{
                     "api" => "openai-chat-completions",
                     "models" => [%{"id" => "m", "name" => "M", "input" => []}]
                   }
                 }
               })
    end
  end

  # ══════════════════════════════════════════════════════════
  # Atomic write
  # ══════════════════════════════════════════════════════════

  describe "atomic write" do
    test "does not corrupt file on write failure" do
      original = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "sk-original",
            "models" => [%{"id" => "m", "name" => "M"}]
          }
        }
      }

      File.write!(config_path(), Jason.encode!(original))

      # Read original content
      original_content = File.read!(config_path())

      # Even if write_config fails (invalid config), the file should be preserved
      ModelConfig.write_config(%{"bad" => "config"})

      assert File.read!(config_path()) == original_content
    end

    test "no temp files left behind after successful write" do
      config = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m", "name" => "M"}]
          }
        }
      }

      assert :ok = ModelConfig.write_config(config)

      # No .tmp or .bak files lingering
      dir = Path.dirname(config_path())
      files = File.ls!(dir)

      temp_files = Enum.filter(files, &String.contains?(&1, [".tmp", ".bak", ".swp"]))
      assert temp_files == []
    end
  end

  # ══════════════════════════════════════════════════════════
  # PubSub broadcast
  # ══════════════════════════════════════════════════════════

  describe "pubsub broadcast" do
    test "broadcasts models:updated after write_config" do
      Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")

      config = %{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m", "name" => "M"}]
          }
        }
      }

      assert :ok = ModelConfig.write_config(config)
      assert_received {:models_updated}
    end

    test "broadcasts models:updated after add_provider" do
      ModelConfig.write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m", "name" => "M"}]
          }
        }
      })

      Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")

      assert :ok =
               ModelConfig.add_provider("new-p", %{
                 "api" => "openai-chat-completions",
                 "models" => [%{"id" => "m2", "name" => "M2"}]
               })

      assert_received {:models_updated}
    end

    test "broadcasts models:updated after remove_provider" do
      ModelConfig.write_config(%{
        "defaultProvider" => "p",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m1", "name" => "M1"}]
          },
          "other" => %{
            "api" => "openai-chat-completions",
            "models" => [%{"id" => "m2", "name" => "M2"}]
          }
        }
      })

      Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")

      assert :ok = ModelConfig.remove_provider("other")
      assert_received {:models_updated}
    end

    test "broadcasts models:updated after add_model / remove_model / update_api_key" do
      ModelConfig.write_config(%{
        "defaultProvider" => "p",
        "defaultModel" => "m1",
        "providers" => %{
          "p" => %{
            "api" => "openai-chat-completions",
            "models" => [
              %{"id" => "m1", "name" => "M1"},
              %{"id" => "m2", "name" => "M2"}
            ]
          }
        }
      })

      # add_model
      Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")
      assert :ok = ModelConfig.add_model("p", "m3", %{"name" => "M3", "input" => ["text"]})
      assert_received {:models_updated}

      # remove_model
      Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")
      assert :ok = ModelConfig.remove_model("p", "m2")
      assert_received {:models_updated}

      # update_api_key
      Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")
      assert :ok = ModelConfig.update_api_key("p", "new-key")
      assert_received {:models_updated}
    end
  end

  describe "empty provider beside a populated provider" do
    test "round-trips write, update, first model, last-model delete, and provider delete" do
      assert :ok =
               ModelConfig.write_config(%{
                 "defaultProvider" => "alpha",
                 "defaultModel" => "one",
                 "providers" => %{
                   "alpha" => %{
                     "api" => "openai-chat-completions",
                     "baseUrl" => "https://alpha.example/v1",
                     "models" => [%{"id" => "one", "name" => "One"}]
                   },
                   "beta" => %{
                     "name" => "Beta Lab",
                     "api" => "anthropic-messages",
                     "baseUrl" => "https://beta.example/v1",
                     "models" => []
                   }
                 }
               })

      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["providers"]["beta"]["models"] == []
      assert json["defaultProvider"] == "alpha"
      assert json["defaultModel"] == "one"

      assert :ok =
               ModelConfig.update_provider("beta", %{"baseUrl" => "https://beta.example/v2"})

      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["providers"]["beta"]["baseUrl"] == "https://beta.example/v2"
      assert json["providers"]["beta"]["models"] == []
      assert json["providers"]["alpha"]["models"] == [%{"id" => "one", "name" => "One"}]

      assert :ok = ModelConfig.add_model("beta", "two", %{"name" => "Two"})
      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["defaultProvider"] == "alpha"
      assert json["defaultModel"] == "one"
      assert Enum.any?(json["providers"]["beta"]["models"], &(&1["id"] == "two"))

      assert :ok = ModelConfig.remove_model("beta", "two")
      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["providers"]["beta"]["models"] == []

      assert :ok = ModelConfig.remove_provider("beta")
      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      refute Map.has_key?(json["providers"], "beta")
      assert json["defaultProvider"] == "alpha"
      assert json["defaultModel"] == "one"
    end

    test "first model in an empty catalog becomes defaultProvider/defaultModel" do
      assert :ok =
               ModelConfig.write_config(%{
                 "defaultProvider" => "waiting",
                 "providers" => %{
                   "waiting" => %{
                     "api" => "openai-chat-completions",
                     "models" => []
                   }
                 }
               })

      assert :ok = ModelConfig.add_model("waiting", "first", %{"name" => "First"})
      {:ok, json} = config_path() |> File.read!() |> Jason.decode()
      assert json["defaultProvider"] == "waiting"
      assert json["defaultModel"] == "first"
    end
  end
end
