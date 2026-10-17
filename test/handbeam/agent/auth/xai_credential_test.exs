defmodule Handbeam.Agent.Auth.XaiCredentialTest do
  @moduledoc """
  TDD tests for resolving an xAI provider transport key.

  OAuth providers refresh from ~/.handbeam/auth.json and never silently
  fall back to an unrelated XAI_API_KEY / OPENAI_API_KEY.
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent.Auth.Storage
  alias Handbeam.Agent.Auth.XaiCredential
  alias Handbeam.Agent.ModelConfig

  defmodule MockReq do
    def post(url, opts) do
      replies = Process.get(:xai_oauth_replies, [])
      calls = Process.get(:xai_oauth_calls, [])
      Process.put(:xai_oauth_calls, calls ++ [{url, opts}])

      case replies do
        [reply | rest] ->
          Process.put(:xai_oauth_replies, rest)
          reply

        [] ->
          flunk("Unexpected xAI OAuth request to #{url}")
      end
    end
  end

  defmodule BlockingReq do
    def post(url, opts) do
      test_pid = Application.fetch_env!(:handbeam, :xai_refresh_test_pid)
      send(test_pid, {:xai_refresh_started, self(), url, opts})

      receive do
        {:release_xai_refresh, reply} -> reply
      end
    end
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sigil_xai_cred_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    models_path = Path.join(tmp_dir, "models.json")
    auth_path = Path.join(tmp_dir, "auth.json")

    old_models = System.get_env("HANDBEAM_MODELS_FILE")
    old_auth = System.get_env("HANDBEAM_AUTH_FILE")
    old_xai = System.get_env("XAI_API_KEY")
    old_openai = System.get_env("OPENAI_API_KEY")
    old_refresh_test_pid = Application.fetch_env(:handbeam, :xai_refresh_test_pid)

    System.put_env("HANDBEAM_MODELS_FILE", models_path)
    System.put_env("HANDBEAM_AUTH_FILE", auth_path)
    System.delete_env("XAI_API_KEY")
    System.delete_env("OPENAI_API_KEY")

    Process.put(:xai_oauth_replies, [])
    Process.put(:xai_oauth_calls, [])

    on_exit(fn ->
      File.rm_rf(tmp_dir)
      restore_env("HANDBEAM_MODELS_FILE", old_models)
      restore_env("HANDBEAM_AUTH_FILE", old_auth)
      restore_env("XAI_API_KEY", old_xai)
      restore_env("OPENAI_API_KEY", old_openai)
      restore_config(:xai_refresh_test_pid, old_refresh_test_pid)
    end)

    {:ok, models_path: models_path, auth_path: auth_path}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_config(key, {:ok, value}), do: Application.put_env(:handbeam, key, value)
  defp restore_config(key, :error), do: Application.delete_env(:handbeam, key)

  defp write_xai_provider(models_path, overrides \\ %{}) do
    provider =
      Map.merge(
        %{
          "baseUrl" => "https://api.x.ai/v1",
          "api" => "openai-responses",
          "provider" => "openai",
          "authType" => "oauth",
          "name" => "xAI",
          "models" => [
            %{
              "id" => "grok-4.7",
              "name" => "Grok 4.7",
              "reasoning" => true,
              "input" => ["text", "image"],
              "contextWindow" => 500_000,
              "maxTokens" => 32_000,
              "include" => ["reasoning.encrypted_content"],
              "cost" => %{"input" => 2, "output" => 6, "cacheRead" => 0.5, "cacheWrite" => 0}
            }
          ]
        },
        overrides
      )

    config = %{
      "defaultProvider" => "xai",
      "defaultModel" => "grok-4.7",
      "providers" => %{"xai" => provider}
    }

    File.write!(models_path, Jason.encode!(config, pretty: true))
    config
  end

  defp put_oauth(auth_path, overrides \\ %{}) do
    credential =
      Map.merge(
        %{
          "type" => "oauth",
          "access" => "live-access",
          "refresh" => "live-refresh",
          "expires" => System.system_time(:millisecond) + 3_600_000
        },
        overrides
      )

    :ok = Storage.put("xai", credential, auth_path: auth_path)
    credential
  end

  test "unexpired oauth credential becomes the transport api_key", %{
    models_path: models_path,
    auth_path: auth_path
  } do
    write_xai_provider(models_path)
    put_oauth(auth_path)

    assert {:ok, config} = ModelConfig.provider_config_for(models_path, "xai", "grok-4.7")
    assert config.api_key == "live-access"
    assert config.base_url == "https://api.x.ai"
    assert config.api == :openai_responses
    assert config.auth_type == :oauth
  end

  test "near-expiry oauth credential is refreshed before use", %{
    models_path: models_path,
    auth_path: auth_path
  } do
    write_xai_provider(models_path)
    put_oauth(auth_path, %{"expires" => System.system_time(:millisecond) - 1_000})

    Process.put(:xai_oauth_replies, [
      {:ok,
       %{
         status: 200,
         body: %{
           "access_token" => "refreshed-access",
           "refresh_token" => "refreshed-refresh",
           "expires_in" => 21_600
         }
       }}
    ])

    assert {:ok, %{api_key: "refreshed-access"}} =
             XaiCredential.resolve_transport_key("xai",
               req_module: MockReq,
               auth_path: auth_path
             )

    assert {:ok, stored} = Storage.get("xai", auth_path: auth_path)
    assert stored["access"] == "refreshed-access"
    assert stored["refresh"] == "refreshed-refresh"
    assert Process.get(:xai_oauth_calls) != []
  end

  test "refresh lock distinguishes concurrent callers", %{auth_path: auth_path} do
    put_oauth(auth_path, %{"expires" => 1})
    Application.put_env(:handbeam, :xai_refresh_test_pid, self())

    opts = [req_module: BlockingReq, auth_path: auth_path]
    first = Task.async(fn -> XaiCredential.resolve_transport_key("xai", opts) end)
    assert_receive {:xai_refresh_started, first_refresh, _url, _request_opts}

    parent = self()

    second =
      Task.async(fn ->
        send(parent, {:second_refresh_attempted, self()})
        XaiCredential.resolve_transport_key("xai", opts)
      end)

    assert_receive {:second_refresh_attempted, second_pid}
    assert second.pid == second_pid
    refute_receive {:xai_refresh_started, ^second_pid, _url, _request_opts}, 100

    send(first_refresh, {
      :release_xai_refresh,
      {:ok,
       %{
         status: 200,
         body: %{
           "access_token" => "single-flight-access",
           "refresh_token" => "single-flight-refresh",
           "expires_in" => 21_600
         }
       }}
    })

    assert {:ok, %{api_key: "single-flight-access"}} = Task.await(first)
    assert {:ok, %{api_key: "single-flight-access"}} = Task.await(second)
  end

  test "refresh failure requires reconnect and does not use env keys", %{
    models_path: models_path,
    auth_path: auth_path
  } do
    write_xai_provider(models_path)
    put_oauth(auth_path, %{"expires" => 1})
    System.put_env("XAI_API_KEY", "env-xai-key")
    System.put_env("OPENAI_API_KEY", "env-openai-key")

    Process.put(:xai_oauth_replies, [
      {:ok, %{status: 400, body: %{"error" => "invalid_grant", "error_description" => "revoked"}}}
    ])

    assert {:error, message} =
             XaiCredential.resolve_transport_key("xai",
               req_module: MockReq,
               auth_path: auth_path
             )

    assert message =~ "reconnect"
    refute message =~ "env-xai-key"
    refute message =~ "env-openai-key"
    assert {:error, :not_found} = Storage.get("xai", auth_path: auth_path)
  end

  test "api_key auth still uses models.json and ignores auth.json", %{
    models_path: models_path,
    auth_path: auth_path
  } do
    write_xai_provider(models_path, %{"authType" => "api_key", "apiKey" => "sk-file-key"})
    put_oauth(auth_path, %{"access" => "oauth-should-not-win"})

    assert {:ok, config} = ModelConfig.provider_config_for(models_path, "xai", "grok-4.7")
    assert config.api_key == "sk-file-key"
    assert config.auth_type == :api_key
  end

  test "oauth provider without stored credentials asks the user to sign in", %{
    models_path: models_path
  } do
    write_xai_provider(models_path)

    assert {:error, message} = ModelConfig.provider_config_for(models_path, "xai", "grok-4.7")
    assert message =~ "Sign in"
  end

  test "xai preset is an oauth responses provider with no hardcoded models" do
    preset = XaiCredential.provider_preset()

    assert preset["baseUrl"] == "https://api.x.ai/v1"
    assert preset["api"] == "openai-responses"
    assert preset["authType"] == "oauth"
    assert preset["models"] == []
  end
end
