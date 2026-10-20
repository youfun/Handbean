defmodule Handbean.Agent.Auth.CodexTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Handbean.CodexTestHelper

  alias Handbean.Agent.Auth.{CodexCredential, CodexOAuth, Epoch, RefreshLock, Storage}
  alias Handbean.Agent.{Config, ModelConfig, Reasoning}
  alias Handbean.CodexTestHelper.ReqMock

  setup :set_shared

  setup do
    dir = Path.join(System.tmp_dir!(), "codex-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, opts: [auth_path: Path.join(dir, "auth.json"), req_module: ReqMock]}
  end

  defp set_shared(_), do: Req.Test.set_req_test_to_shared()

  test "device flow uses JSON polling followed by form PKCE exchange" do
    owner = self()
    access = token()

    Req.Test.stub(ReqMock, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(owner, {:request, conn.request_path, body})
      assert conn.host == "auth.openai.com"

      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          assert Jason.decode!(body) == %{"client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"}

          Req.Test.json(conn, %{
            device_auth_id: "device-secret",
            user_code: "ABCD-EFGH",
            interval: "7"
          })

        "/api/accounts/deviceauth/token" ->
          assert Jason.decode!(body) == %{
                   "device_auth_id" => "device-secret",
                   "user_code" => "ABCD-EFGH"
                 }

          Req.Test.json(conn, %{authorization_code: "one-time", code_verifier: "verifier"})

        "/oauth/token" ->
          assert URI.decode_query(body) == %{
                   "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
                   "grant_type" => "authorization_code",
                   "code" => "one-time",
                   "code_verifier" => "verifier",
                   "redirect_uri" => "https://auth.openai.com/deviceauth/callback"
                 }

          Req.Test.json(conn, %{access_token: access, refresh_token: "rotated", expires_in: 3600})
      end
    end)

    assert {:ok, device} = CodexOAuth.start(req_module: ReqMock, now_ms: 1000)
    assert device.interval_seconds == 7
    assert device.expires_at == 901_000
    assert device.verification_uri == "https://auth.openai.com/codex/device"

    assert {:authorized, credential} =
             CodexOAuth.poll_once(device, req_module: ReqMock, now_ms: 2000)

    assert credential.access == access
    assert credential.refresh == "rotated"
    assert credential.expires == 3_302_000
    assert_receive {:request, "/oauth/token", _}
  end

  test "pending, slow down, denial and expiry are distinct and expiry does not poll" do
    device = %{device_code: "device", user_code: "user", interval_seconds: 3, expires_at: 1000}
    Req.Test.stub(ReqMock, &send_resp(&1, 404, ""))
    assert {:pending, ^device} = CodexOAuth.poll_once(device, req_module: ReqMock, now_ms: 999)
    Req.Test.stub(ReqMock, &send_resp(&1, 429, ""))

    assert {:slow_down, %{interval_seconds: 8}} =
             CodexOAuth.poll_once(device, req_module: ReqMock, now_ms: 999)

    Req.Test.stub(ReqMock, fn conn ->
      conn |> put_status(403) |> Req.Test.json(%{error: "access_denied"})
    end)

    assert {:error, _} = CodexOAuth.poll_once(device, req_module: ReqMock, now_ms: 999)
    Req.Test.stub(ReqMock, fn _ -> flunk("Expired device flow must not make a request") end)
    assert {:error, message} = CodexOAuth.poll_once(device, req_module: ReqMock, now_ms: 1000)
    assert message =~ "expired"
  end

  test "malformed tokens are rejected without echoing credentials or response bodies" do
    Req.Test.stub(
      ReqMock,
      &Req.Test.json(&1, %{access_token: "secret", refresh_token: "secret", expires_in: 3600})
    )

    assert {:error, message} = CodexOAuth.refresh("old", req_module: ReqMock)
    refute message =~ "secret"
    Req.Test.stub(ReqMock, &send_resp(&1, 500, "secret response body"))
    assert {:error, message} = CodexOAuth.refresh("old", req_module: ReqMock)
    assert message =~ "500"
    refute message =~ "secret"
    assert {:error, _} = CodexOAuth.account_id("header.bad.signature")
  end

  test "refresh rotates tokens without changing login epoch; transient failure retains credentials",
       %{opts: opts} do
    stored = %{credential() | expires: 1}
    assert :ok = CodexCredential.store_login("openai_codex", stored, opts)
    epoch = Epoch.current("openai_codex")

    Req.Test.stub(ReqMock, fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert URI.decode_query(body)["refresh_token"] == "test-refresh"

      Req.Test.json(conn, %{access_token: token(), refresh_token: "new-refresh", expires_in: 3600})
    end)

    assert {:ok, auth} = CodexCredential.resolve_transport_key("openai_codex", opts)
    assert auth.account_id == "account-a"
    assert auth.auth_generation == epoch
    assert {:ok, saved} = Storage.get("openai_codex", opts)
    assert saved["refresh"] == "new-refresh"
    assert :ok = Storage.put("openai_codex", Map.put(saved, "expires", 1), opts)
    Req.Test.stub(ReqMock, &send_resp(&1, 503, "secret"))
    assert {:error, _} = CodexCredential.resolve_transport_key("openai_codex", opts)
    assert {:ok, retained} = Storage.get("openai_codex", opts)
    assert retained["refresh"] == "new-refresh"
  end

  test "concurrent refresh callers serialize and consume a rotating token once", %{opts: opts} do
    assert :ok = CodexCredential.store_login("openai_codex", %{credential() | expires: 1}, opts)
    owner = self()

    Req.Test.stub(ReqMock, fn conn ->
      send(owner, {:refresh_started, self()})

      receive do
        :release -> :ok
      after
        5000 -> flunk("Refresh was not released")
      end

      Req.Test.json(conn, %{
        access_token: token(),
        refresh_token: "one-rotation",
        expires_in: 3600
      })
    end)

    first = Task.async(fn -> CodexCredential.resolve_transport_key("openai_codex", opts) end)
    assert_receive {:refresh_started, refresh_pid}
    # Probe the exact resource from another requester: a wrongly keyed lock
    # reports success here, independently of scheduler timing.
    probe =
      Task.async(fn ->
        id = {{:handbean_oauth_refresh, "openai_codex"}, self()}
        acquired = :global.set_lock(id, [Node.self()], 0)
        if acquired, do: :global.del_lock(id, [Node.self()])
        acquired
      end)

    refute Task.await(probe)
    second = Task.async(fn -> CodexCredential.resolve_transport_key("openai_codex", opts) end)
    send(refresh_pid, :release)
    assert {:ok, a} = Task.await(first)
    assert {:ok, b} = Task.await(second)
    assert a == b
    refute_received {:refresh_started, _}
  end

  test "login replacement waits for refresh then wins", %{opts: opts} do
    assert :ok = CodexCredential.store_login("openai_codex", credential(), opts)
    epoch = Epoch.current("openai_codex")
    owner = self()

    holder =
      Task.async(fn ->
        RefreshLock.trans("openai_codex", fn ->
          send(owner, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked

    login =
      Task.async(fn ->
        CodexCredential.store_login("openai_codex", credential("account-b"), opts)
      end)

    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert :ok = Task.await(login)
    assert {:ok, auth} = CodexCredential.resolve_transport_key("openai_codex", opts)
    assert auth.account_id == "account-b"
    assert auth.auth_generation == epoch + 1
  end

  test "provider dispatch and reasoning are distinct from public API billing", %{opts: opts} do
    assert {:error, _} = CodexCredential.resolve_transport_key("openai_codex", opts)
    assert ModelConfig.api_to_atom("openai-codex-responses") == :openai_codex_responses

    assert Config.resolve_provider_from_api(:openai_codex_responses, "gpt-5.4", "openai") ==
             Handbean.Agent.Provider.Codex

    assert Config.resolve_provider_from_api(:openai_responses, "gpt-5.4", "openai") ==
             Handbean.Agent.Provider.OpenAI

    config =
      Reasoning.apply_provider_options(
        %{api: :openai_codex_responses},
        %{reasoning: true, reasoning_levels: ["high"]},
        "high"
      )

    assert config.reasoning == %{effort: "high"}
    models = CodexCredential.provider_preset()["models"]

    assert Enum.map(models, & &1["id"]) |> Enum.take(4) == [
             "gpt-6.1-sol",
             "gpt-6-sol",
             "gpt-6-luna",
             "gpt-6-astra"
           ]

    refute Enum.any?(models, &(&1["id"] == "gpt-5.4"))
    refute Enum.any?(models, &Map.has_key?(&1, "cost"))
  end

  test "credential file lock protects cross-provider read-modify-write", %{opts: opts} do
    path = Storage.file_path(opts)
    owner = self()

    holder =
      Task.async(fn ->
        :global.trans(
          {{Storage, path}, self()},
          fn ->
            send(owner, :storage_locked)

            receive do
              :release -> :ok
            end
          end,
          [Node.self()]
        )
      end)

    assert_receive :storage_locked
    writer = Task.async(fn -> Storage.put("openai_codex", credential(), opts) end)
    refute File.exists?(path)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert :ok = Task.await(writer)

    results =
      Task.async_stream(1..8, fn n -> Storage.put("provider-#{n}", credential(), opts) end,
        max_concurrency: 8
      )

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    saved = path |> File.read!() |> Jason.decode!()
    assert map_size(saved) == 9
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end
end
