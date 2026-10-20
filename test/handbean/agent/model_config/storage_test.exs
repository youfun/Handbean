defmodule Handbean.Agent.ModelConfigStorageTest do
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
