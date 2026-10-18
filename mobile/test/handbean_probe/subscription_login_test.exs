defmodule HandbeanProbe.SubscriptionLoginTest do
  use Mob.ScreenCase, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  alias Handbean.Agent.Auth.{CodexOAuth, CursorOAuth, Storage, Subscriptions}
  alias HandbeanProbe.HomeScreen
  alias HandbeanProbe.HomeScreen.Requests
  alias HandbeanProbe.ModelSettings.Subscriptions, as: MobileSubscriptions
  alias HandbeanProbe.PendingRequests

  setup do
    dir = Path.join(System.tmp_dir!(), "native_sub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_AUTH_FILE" => Path.join(dir, "auth.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    HandbeanProbe.NativePlatform.put!(:android)
    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)
    {:ok, _ws} = Handbean.WorkspaceStore.ensure_default!()

    on_exit(fn ->
      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      if previous_platform,
        do: Application.put_env(:handbean_probe, :native_platform, previous_platform),
        else: Application.delete_env(:handbean_probe, :native_platform)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      Application.delete_env(:handbean, :codex_oauth_req_module)
      Application.delete_env(:handbean, :cursor_oauth_req_module)
      Application.delete_env(:handbean_probe, :clipboard_put)
      Application.delete_env(:handbean_probe, :platform_fake)
      _ = File.rm_rf(dir)
    end)

    :ok
  end

  defmodule CodexReq do
    def post(url, opts) do
      send(Process.get(:subscription_test_owner), {:codex_post, url, opts})
      body = Process.get(:subscription_codex_body) || %{}
      {:ok, %{status: 200, body: body}}
    end
  end

  defmodule CursorReq do
    def get(url, opts) do
      send(Process.get(:subscription_test_owner), {:cursor_get, url, opts})
      {:ok, %{status: 404, body: %{}}}
    end

    def post(_url, _opts), do: {:ok, %{status: 404, body: %{}}}
  end

  test "Codex device login returns a user code and verification URI without a network" do
    Process.put(:subscription_test_owner, self())

    Process.put(:subscription_codex_body, %{
      "device_auth_id" => "private-device",
      "user_code" => "DEMO-1234",
      "interval" => "60"
    })

    Application.put_env(:handbean, :codex_oauth_req_module, CodexReq)

    assert {:ok, session} = MobileSubscriptions.start("openai_codex")
    assert session.user_code == "DEMO-1234"
    assert session.verification_uri == CodexOAuth.browser_verification_uri(session.device)
    assert session.verification_uri == "https://auth.openai.com/codex/device"
    refute Map.has_key?(session, :access)
    refute inspect(MobileSubscriptions.public_session(session)) =~ "private-device"
    assert_received {:codex_post, "https://auth.openai.com/api/accounts/deviceauth/usercode", _}
  end

  test "Cursor start is wired to CursorOAuth" do
    Process.put(:subscription_test_owner, self())
    Application.put_env(:handbean, :cursor_oauth_req_module, CursorReq)

    assert {:ok, session} =
             MobileSubscriptions.start("cursor", uuid: "cursor-uuid", verifier: "cursor-verifier")

    assert session.provider_id == "cursor"
    assert session.verification_uri == CursorOAuth.browser_verification_uri(session.device)
    assert session.verification_uri =~ "https://cursor.com/loginDeepControl"
    assert session.verification_uri =~ "challenge="
    assert session.user_code == nil

    assert {:continue, :pending, _public, interval_ms, updated} =
             MobileSubscriptions.poll("cursor", session.device)

    assert is_integer(interval_ms)
    assert updated.attempts == 1
    assert_received {:cursor_get, "https://api2.cursor.sh/auth/poll" <> _, _}
  end

  test "subscription methods come from the desktop catalog" do
    ids = Enum.map(MobileSubscriptions.methods(), & &1.id)
    assert ids == Enum.map(Subscriptions.methods(), & &1.id)
    assert "openai_codex" in ids
    assert "cursor" in ids
  end

  test "a stale poll generation is ignored" do
    view = mount()
    view = press(view, :open_subscription_login)
    view = press(view, {:start_subscription, "openai_codex"})
    assert screen_assigns(view).models.subscription_busy?

    generation = Requests.generation(view.socket, :subscription_login)
    stale = {make_ref(), {:subscription_started, generation, {:ok, fake_session()}}}
    view = press(view, :cancel_subscription_login)
    assert screen_assigns(view).models.subscription_login == nil

    {:noreply, socket} = HomeScreen.handle_info(stale, view.socket)
    view = %{view | socket: socket}
    assert screen_assigns(view).models.subscription_login == nil
    refute Requests.has?(view.socket, :nope)
    assert Requests.generation(view.socket, :subscription_login) == generation + 1
  end

  test "an accepted start shows the verification URI and schedules a poll without blocking" do
    view = mount()
    view = deliver_start(view, fake_session())
    login = screen_assigns(view).models.subscription_login
    assert login.verification_uri == "https://auth.openai.com/codex/device"
    assert login.user_code == "DEMO-1234"
    refute Map.has_key?(login, :device)
    refute inspect(login) =~ "private-device"
    assert [_timer] = pending_kind(view, :subscription_poll_due)
  end

  test "copy puts the verification URI on the clipboard and not credential fields" do
    Application.put_env(:handbean_probe, :clipboard_put, fn text ->
      send(self(), {:copied, text})
    end)

    view = deliver_start(mount(), fake_session())
    view = press(view, {:copy_subscription, :verification_uri})

    assert_received {:copied, copied}
    assert copied == "https://auth.openai.com/codex/device"
    refute copied =~ "private"
    refute copied =~ "refresh"
    refute copied =~ "DEMO-1234"

    assert HandbeanProbe.HomeScreen.Notice.text(screen_assigns(view).notice) ==
             gettext("Verification link copied")

    rendered =
      screen_assigns(view).models
      |> HandbeanProbe.ModelSettings.SubscriptionRender.section()
      |> inspect()

    assert rendered =~ "https://auth.openai.com/codex/device"
    assert rendered =~ gettext("Copy")
    assert rendered =~ gettext("Open link")
    assert rendered =~ "DEMO-1234"
    refute rendered =~ "private-device"
    refute rendered =~ "refresh"
    refute rendered =~ "access_token"
    refute rendered =~ "api_key"
  end

  test "open link uses Platform.open_url and does not embed a login page" do
    Application.put_env(:handbean_probe, :platform_fake, fn req, _opts ->
      send(self(), {:opened, req.op, req.payload["url"]})
      {:ok, :async}
    end)

    view = deliver_start(mount(), fake_session())
    view = press(view, :open_subscription_link)
    assert_received {:opened, "platform_open_url", "https://auth.openai.com/codex/device"}
    assert Requests.has?(view.socket, opened_request_id(view))
  end

  test "authorized poll persists through the Codex writer and does not render the token" do
    access = codex_token()

    credential = %{
      type: "oauth",
      access: access,
      refresh: "private-refresh",
      expires: System.system_time(:millisecond) + 3_600_000
    }

    view = deliver_start(mount(), %{fake_session() | interval_ms: 0})
    provider_id = screen_assigns(view).subscription_provider_id
    due = hd(pending_kind(view, :subscription_poll_due))

    {:noreply, socket} =
      HomeScreen.handle_info({:pending_request_timeout, due.ref}, view.socket)

    view = %{view | socket: socket}
    generation = Requests.generation(view.socket, :subscription_login)
    ref = task_ref(view, :subscription_polled)

    {:noreply, socket} =
      HomeScreen.handle_info(
        {ref, {:subscription_polled, generation, {:authorized, credential}}},
        view.socket
      )

    view = HandbeanProbe.ScreenSettle.settle(%{view | socket: socket})
    assert {:ok, stored} = Storage.get(provider_id)
    assert stored["refresh"] == "private-refresh"
    refute inspect(screen_assigns(view).models.subscription_login) =~ "private-refresh"

    refute inspect(
             HandbeanProbe.ModelSettings.SubscriptionRender.section(screen_assigns(view).models)
           ) =~
             access
  end

  defp mount do
    view = mount_screen(HomeScreen) |> HandbeanProbe.ScreenSettle.settle()
    {:noreply, socket} = HomeScreen.handle_info({:tap, {:page, :models}}, view.socket)
    HandbeanProbe.ScreenSettle.settle(%{view | socket: socket})
  end

  defp press(view, action) do
    {:noreply, socket} = HomeScreen.handle_info({:tap, action}, view.socket)
    %{view | socket: socket}
  end

  defp deliver_start(view, session) do
    view = press(view, :open_subscription_login)
    view = press(view, {:start_subscription, "openai_codex"})
    generation = Requests.generation(view.socket, :subscription_login)
    ref = task_ref(view, :subscription_started)

    {:noreply, socket} =
      HomeScreen.handle_info(
        {ref, {:subscription_started, generation, {:ok, session}}},
        view.socket
      )

    %{view | socket: socket}
  end

  defp task_ref(view, kind) do
    view.socket
    |> Requests.table()
    |> then(fn %PendingRequests{entries: entries} ->
      entries
      |> Map.values()
      |> Enum.find(&(&1.kind == kind))
      |> Map.fetch!(:ref)
    end)
  end

  defp pending_kind(view, kind) do
    view.socket
    |> Requests.table()
    |> then(fn %PendingRequests{entries: entries} ->
      Enum.filter(Map.values(entries), &(&1.kind == kind))
    end)
  end

  defp opened_request_id(view) do
    pending_kind(view, :open_url) |> hd() |> Map.fetch!(:ref)
  end

  defp fake_session do
    %{
      provider_id: "openai_codex",
      login_label: "ChatGPT (Codex subscription)",
      user_code: "DEMO-1234",
      verification_uri: "https://auth.openai.com/codex/device",
      hint: "hint",
      interval_ms: 60_000,
      device: %{
        device_code: "private-device",
        user_code: "DEMO-1234",
        verification_uri: "https://auth.openai.com/codex/device",
        interval_seconds: 60,
        expires_at: System.system_time(:millisecond) + 60_000
      }
    }
  end

  defp codex_token do
    claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-a"}}
    "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"
  end

  defp screen_assigns(view), do: view.socket.assigns
end
