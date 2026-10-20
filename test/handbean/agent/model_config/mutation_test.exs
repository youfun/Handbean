defmodule Handbean.Agent.ModelConfigMutationTest do
  @moduledoc false
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
