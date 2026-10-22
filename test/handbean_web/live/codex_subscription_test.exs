defmodule HandbeanWeb.CodexSubscriptionTest do
  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Handbean.CodexTestHelper

  alias Handbean.Agent.Auth.{Epoch, Storage}
  alias Handbean.Agent.ModelConfig
  alias Handbean.CodexTestHelper.ReqMock

  setup do
    dir = Path.join(System.tmp_dir!(), "codex-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Map.new(["HANDBEAN_MODELS_FILE", "HANDBEAN_AUTH_FILE"], &{&1, System.get_env(&1)})
    System.put_env("HANDBEAN_MODELS_FILE", Path.join(dir, "models.json"))
    System.put_env("HANDBEAN_AUTH_FILE", Path.join(dir, "auth.json"))

    on_exit(fn ->
      for key <- ["HANDBEAN_MODELS_FILE", "HANDBEAN_AUTH_FILE"] do
        if previous[key], do: System.put_env(key, previous[key]), else: System.delete_env(key)
      end

      File.rm_rf!(dir)
    end)

    Req.Test.set_req_test_to_shared()
    old_oauth = Application.get_env(:handbean, :codex_oauth_req_module)
    old_models = Application.get_env(:handbean, :codex_models_req_module)
    Application.put_env(:handbean, :codex_oauth_req_module, ReqMock)
    Application.put_env(:handbean, :codex_models_req_module, ReqMock)

    on_exit(fn ->
      if old_oauth,
        do: Application.put_env(:handbean, :codex_oauth_req_module, old_oauth),
        else: Application.delete_env(:handbean, :codex_oauth_req_module)

      if old_models,
        do: Application.put_env(:handbean, :codex_models_req_module, old_models),
        else: Application.delete_env(:handbean, :codex_models_req_module)
    end)

    :ok
  end

  defp open_login(conn) do
    {:ok, view, _} =
      live_isolated(conn, HandbeanWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view |> element(~s(button[phx-click="open_subscription_login"])) |> render_click()

    html =
      view
      |> element(~s(button[phx-click="start_subscription_oauth"][phx-value-id="openai_codex"]))
      |> render_click()

    {view, html}
  end

  defp device_reply(conn) do
    Req.Test.json(conn, %{
      device_auth_id: "private-device",
      user_code: "DEMO-1234",
      interval: "60"
    })
  end

  test "same subscription overlay shows ChatGPT device code and no sensitive material", %{
    conn: conn
  } do
    Req.Test.stub(ReqMock, &device_reply/1)
    {view, html} = open_login(conn)
    assert html =~ "ChatGPT (Codex subscription)"
    assert html =~ "DEMO-1234"
    assert html =~ "https://auth.openai.com/codex/device"
    refute html =~ "private-device"
    assert has_element?(view, ~s(button[phx-click="cancel_subscription_oauth"]))
    assert Enum.count(LazyHTML.from_document(html) |> LazyHTML.query(".settings-overlay")) == 1
    raw = File.read!(ModelConfig.config_file_path())
    refute raw =~ "private-device"
    assert get_in(Jason.decode!(raw), ["providers", "openai_codex", "authType"]) == "oauth"
  end

  test "cancelled in-flight login cannot persist a late token and duplicate polls are ignored", %{
    conn: conn
  } do
    owner = self()

    Req.Test.stub(ReqMock, fn conn ->
      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          device_reply(conn)

        "/api/accounts/deviceauth/token" ->
          send(owner, {:poll_blocked, self()})

          receive do
            :release -> :ok
          after
            5000 -> flunk("Poll was not released")
          end

          Req.Test.json(conn, %{
            authorization_code: "auth-code",
            code_verifier: "private-verifier"
          })

        "/oauth/token" ->
          Req.Test.json(conn, %{
            access_token: token(),
            refresh_token: "private-refresh",
            expires_in: 3600
          })
      end
    end)

    {view, _} = open_login(conn)
    oauth = :sys.get_state(view.pid).socket.assigns.subscription_oauth
    send(view.pid, {:poll_subscription_oauth, oauth.attempt_id})
    assert_receive {:poll_blocked, poll_pid}
    ref = Process.monitor(poll_pid)
    send(view.pid, {:poll_subscription_oauth, oauth.attempt_id})
    assert :sys.get_state(view.pid).socket.assigns.subscription_oauth.polling?
    view |> element(~s(button[phx-click="cancel_subscription_oauth"])) |> render_click()
    assert_receive {:DOWN, ^ref, :process, ^poll_pid, {:shutdown, :cancel}}
    refute render(view) =~ "Waiting for authentication"
    refute_received {:poll_blocked, _}
    assert {:error, :not_found} = Storage.get("openai_codex")
  end

  test "poll task crash clears waiting state without crashing the page", %{conn: conn} do
    Req.Test.stub(ReqMock, fn conn ->
      case conn.request_path do
        "/api/accounts/deviceauth/usercode" -> device_reply(conn)
        "/api/accounts/deviceauth/token" -> exit(:poll_failed)
      end
    end)

    {view, _} = open_login(conn)
    owner = self()

    :sys.replace_state(view.pid, fn state ->
      socket =
        Phoenix.LiveView.attach_hook(state.socket, :oauth_completion, :handle_async, fn
          {:subscription_oauth_poll, attempt_id}, result, socket ->
            send(owner, {:oauth_finished, attempt_id, result})
            {:cont, socket}

          _name, _result, socket ->
            {:cont, socket}
        end)

      %{state | socket: socket}
    end)

    oauth = :sys.get_state(view.pid).socket.assigns.subscription_oauth
    send(view.pid, {:poll_subscription_oauth, oauth.attempt_id})
    attempt_id = oauth.attempt_id
    assert_receive {:oauth_finished, ^attempt_id, {:exit, :poll_failed}}
    html = render(view)
    assert Process.alive?(view.pid)
    assert html =~ "Subscription authorization failed"
    refute html =~ "Waiting for authentication"
    assert {:error, :not_found} = Storage.get("openai_codex")
  end

  test "closing the page terminates its in-flight poll", %{conn: conn} do
    # The LiveViewTest proxy is linked to the test and exits with the channel.
    Process.flag(:trap_exit, true)
    owner = self()

    Req.Test.stub(ReqMock, fn conn ->
      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          device_reply(conn)

        "/api/accounts/deviceauth/token" ->
          send(owner, {:poll_started, self()})

          receive do
            :release -> Req.Test.json(conn, %{})
          end
      end
    end)

    {view, _} = open_login(conn)
    oauth = :sys.get_state(view.pid).socket.assigns.subscription_oauth
    send(view.pid, {:poll_subscription_oauth, oauth.attempt_id})
    assert_receive {:poll_started, pid}
    ref = Process.monitor(pid)
    GenServer.stop(view.pid, {:shutdown, :closed})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    assert {:error, :not_found} = Storage.get("openai_codex")
  end

  test "authorized login saves credentials, config resolves Codex, and model discovery applies",
       %{conn: conn} do
    owner = self()

    Req.Test.stub(ReqMock, fn conn ->
      case conn.request_path do
        "/api/accounts/deviceauth/usercode" ->
          device_reply(conn)

        "/api/accounts/deviceauth/token" ->
          Req.Test.json(conn, %{
            authorization_code: "auth-code",
            code_verifier: "private-verifier"
          })

        "/oauth/token" ->
          Req.Test.json(conn, %{
            access_token: token(),
            refresh_token: "private-refresh",
            expires_in: 3600
          })

        "/backend-api/codex/models" ->
          send(owner, {:discovery, self()})

          receive do
            :release -> :ok
          after
            5000 -> flunk("Discovery was not released")
          end

          Req.Test.json(conn, %{models: [%{slug: "codex-visible", display_name: "Codex Visible"}]})
      end
    end)

    {view, _} = open_login(conn)
    oauth = :sys.get_state(view.pid).socket.assigns.subscription_oauth
    send(view.pid, {:poll_subscription_oauth, oauth.attempt_id})
    assert_receive {:discovery, discover_pid}
    ref = Process.monitor(discover_pid)
    send(discover_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^discover_pid, :normal}, 10_000
    html = render(view)
    assert html =~ "Codex Visible"
    refute html =~ "private-refresh"

    assert {:ok, config} =
             ModelConfig.provider_config_for(
               ModelConfig.config_file_path(),
               "openai_codex",
               "codex-visible"
             )

    assert config.api == :openai_codex_responses
    assert config.account_id == "account-a"
    assert config.auth_generation == Epoch.current("openai_codex")
    refute File.read!(ModelConfig.config_file_path()) =~ token()
    assert {:ok, _} = Storage.get("openai_codex")
  end

  test "failed start renders a safe error without creating an authorization overlay", %{
    conn: conn
  } do
    Req.Test.stub(ReqMock, &send_resp(&1, 503, "private-error"))
    {view, html} = open_login(conn)
    assert html =~ "503"
    refute html =~ "private-error"
    refute has_element?(view, ~s(button[phx-click="cancel_subscription_oauth"]))
  end
end
