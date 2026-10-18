defmodule Handbean.Agent.Auth.CursorCredentialTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Auth.{CursorCredential, Epoch, Storage}

  defmodule HoldReq do
    def post(_url, _opts) do
      parent = :persistent_term.get(:cursor_cred_parent)
      send(parent, {:refresh_http, self()})

      receive do
        :continue ->
          replies = :persistent_term.get(:cursor_cred_replies)

          case replies do
            [reply | rest] ->
              :persistent_term.put(:cursor_cred_replies, rest)
              reply

            [] ->
              {:ok, %{status: 200, body: %{"accessToken" => "new-a", "refreshToken" => "new-r"}}}
          end
      end
    end
  end

  defmodule FailReq do
    def post(_url, _opts), do: {:error, :nxdomain}
  end

  setup do
    unless Process.whereis(Epoch) do
      start_supervised!(Epoch)
    end

    tmp = Path.join(System.tmp_dir!(), "cursor_cred_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    auth_path = Path.join(tmp, "auth.json")
    :persistent_term.put(:cursor_cred_parent, self())
    :persistent_term.put(:cursor_cred_replies, [])
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, auth_path: auth_path}
  end

  test "unexpired credential becomes transport key", %{auth_path: auth_path} do
    put_cred(auth_path, "live-access", "live-refresh", System.system_time(:millisecond) + 60_000)

    assert {:ok, %{api_key: "live-access", auth_generation: generation}} =
             CursorCredential.resolve_transport_key("cursor", auth_path: auth_path)

    assert is_integer(generation)
  end

  test "temporary refresh failure keeps stored credential", %{auth_path: auth_path} do
    put_cred(auth_path, "old-access", "old-refresh", 1)

    assert {:error, _} =
             CursorCredential.resolve_transport_key("cursor",
               req_module: FailReq,
               auth_path: auth_path
             )

    assert {:ok, stored} = Storage.get("cursor", auth_path: auth_path)
    assert stored["refresh"] == "old-refresh"
  end

  test "invalid refresh does not delete a login that waited on the lock", %{auth_path: auth_path} do
    put_cred(auth_path, "a", "old-r", 1)

    :persistent_term.put(:cursor_cred_replies, [{:ok, %{status: 401, body: %{}}}])

    refresh =
      Task.async(fn ->
        CursorCredential.resolve_transport_key("cursor",
          req_module: HoldReq,
          auth_path: auth_path
        )
      end)

    assert_receive {:refresh_http, refresher}, 1_000

    login =
      Task.async(fn ->
        CursorCredential.store_login(
          "cursor",
          %{
            "type" => "oauth",
            "access" => "login-a",
            "refresh" => "login-r",
            "expires" => System.system_time(:millisecond) + 60_000
          },
          auth_path: auth_path
        )
      end)

    refute Task.yield(login, 100)
    send(refresher, :continue)
    assert {:error, _} = Task.await(refresh)
    assert :ok = Task.await(login)
    assert {:ok, stored} = Storage.get("cursor", auth_path: auth_path)
    assert stored["refresh"] == "login-r"
  end

  test "store_login waits for refresh lock then writes last", %{auth_path: auth_path} do
    put_cred(auth_path, "a", "old-r", 1)

    :persistent_term.put(:cursor_cred_replies, [
      {:ok,
       %{status: 200, body: %{"accessToken" => "refreshed-a", "refreshToken" => "refreshed-r"}}}
    ])

    refresh =
      Task.async(fn ->
        CursorCredential.resolve_transport_key("cursor",
          req_module: HoldReq,
          auth_path: auth_path
        )
      end)

    assert_receive {:refresh_http, refresher}, 1_000

    login =
      Task.async(fn ->
        CursorCredential.store_login(
          "cursor",
          %{
            "type" => "oauth",
            "access" => "login-a",
            "refresh" => "login-r",
            "expires" => System.system_time(:millisecond) + 60_000
          },
          auth_path: auth_path
        )
      end)

    refute Task.yield(login, 100)
    send(refresher, :continue)
    assert {:ok, _} = Task.await(refresh)
    assert :ok = Task.await(login)
    assert {:ok, stored} = Storage.get("cursor", auth_path: auth_path)
    assert stored["refresh"] == "login-r"
    assert stored["access"] == "login-a"
  end

  test "resolve_transport_key snapshots auth_generation under the lock", %{auth_path: auth_path} do
    put_cred(auth_path, "live-access", "live-refresh", System.system_time(:millisecond) + 60_000)
    before = Epoch.current("cursor")

    assert {:ok, %{api_key: "live-access", auth_generation: ^before}} =
             CursorCredential.resolve_transport_key("cursor", auth_path: auth_path)

    assert :ok =
             CursorCredential.store_login(
               "cursor",
               %{
                 "type" => "oauth",
                 "access" => "login-a",
                 "refresh" => "login-r",
                 "expires" => System.system_time(:millisecond) + 60_000
               },
               auth_path: auth_path
             )

    after_login = Epoch.current("cursor")
    assert after_login == before + 1

    assert {:ok, %{api_key: "login-a", auth_generation: ^after_login}} =
             CursorCredential.resolve_transport_key("cursor", auth_path: auth_path)
  end

  defp put_cred(auth_path, access, refresh, expires) do
    :ok =
      Storage.put(
        "cursor",
        %{"type" => "oauth", "access" => access, "refresh" => refresh, "expires" => expires},
        auth_path: auth_path
      )
  end
end
