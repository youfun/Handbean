defmodule Handbean.Agent.ModelConfigCursorAuthTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Auth.{CursorCredential, Epoch, Storage}
  alias Handbean.Agent.ModelConfig

  setup do
    unless Process.whereis(Epoch) do
      start_supervised!(Epoch)
    end

    tmp = Path.join(System.tmp_dir!(), "cursor_model_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    models_path = Path.join(tmp, "models.json")
    auth_path = Path.join(tmp, "auth.json")

    old_models = System.get_env("HANDBEAN_MODELS_FILE")
    old_auth = System.get_env("HANDBEAN_AUTH_FILE")
    System.put_env("HANDBEAN_MODELS_FILE", models_path)
    System.put_env("HANDBEAN_AUTH_FILE", auth_path)

    File.write!(
      models_path,
      Jason.encode!(%{
        "providers" => %{
          "cursor" => %{
            "name" => "Cursor",
            "provider" => "cursor",
            "baseUrl" => "https://api2.cursor.sh",
            "api" => "cursor-agent",
            "authType" => "oauth",
            "models" => [%{"id" => "composer-2.5", "name" => "Composer 2.5"}]
          }
        }
      })
    )

    on_exit(fn ->
      File.rm_rf(tmp)

      if old_models,
        do: System.put_env("HANDBEAN_MODELS_FILE", old_models),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      if old_auth,
        do: System.put_env("HANDBEAN_AUTH_FILE", old_auth),
        else: System.delete_env("HANDBEAN_AUTH_FILE")
    end)

    {:ok, auth_path: auth_path}
  end

  test "provider config uses auth_generation from the locked credential snapshot", %{
    auth_path: auth_path
  } do
    :ok =
      CursorCredential.store_login(
        "cursor",
        %{
          "type" => "oauth",
          "access" => "snap-access",
          "refresh" => "snap-refresh",
          "expires" => System.system_time(:millisecond) + 60_000
        },
        auth_path: auth_path
      )

    {:ok, auth} = CursorCredential.resolve_transport_key("cursor", auth_path: auth_path)
    assert {:ok, config} = ModelConfig.provider_config_for(File.cwd!(), "cursor", "composer-2.5")
    assert config.api_key == auth.api_key
    assert config.auth_generation == auth.auth_generation

    bumped = Epoch.bump("cursor")
    assert bumped != auth.auth_generation
    assert {:ok, still} = ModelConfig.provider_config_for(File.cwd!(), "cursor", "composer-2.5")
    assert still.auth_generation == bumped
    refute still.auth_generation == auth.auth_generation
  end

  test "login generation is captured with the access token, not a later Epoch.current", %{
    auth_path: auth_path
  } do
    :ok =
      Storage.put(
        "cursor",
        %{
          "type" => "oauth",
          "access" => "old-access",
          "refresh" => "old-refresh",
          "expires" => System.system_time(:millisecond) + 60_000
        },
        auth_path: auth_path
      )

    {:ok, first} = CursorCredential.resolve_transport_key("cursor", auth_path: auth_path)

    :ok =
      CursorCredential.store_login(
        "cursor",
        %{
          "type" => "oauth",
          "access" => "new-access",
          "refresh" => "new-refresh",
          "expires" => System.system_time(:millisecond) + 60_000
        },
        auth_path: auth_path
      )

    {:ok, config} = ModelConfig.provider_config_for(File.cwd!(), "cursor", "composer-2.5")
    assert config.api_key == "new-access"
    assert config.auth_generation == first.auth_generation + 1
  end
end
