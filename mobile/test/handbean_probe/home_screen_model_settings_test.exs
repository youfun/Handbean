defmodule HandbeanProbe.HomeScreenModelSettingsTest do
  use HandbeanProbe.HomeScreenCase

  alias HandbeanProbe.{HomeScreen, ModelSettings, PendingRequests}
  alias HandbeanProbe.HomeScreen.{Notice, Settings}

  test "settings hub calendar status is not shown as an unread attachment", %{view: view} do
    install_platform_fake(fn _req, _opts -> {:ok, :async} end)
    view = info(view, {:tap, {:page, :settings}})

    [%{ref: request_id, generation: generation}] =
      PendingRequests.by_kind(assigns(view).pending_requests, :app_settings)

    json =
      Jason.encode!(%{
        "calendar_read" => true,
        "calendar_write" => true,
        "outcome" => "listed"
      })

    view =
      info(
        view,
        {:engine_result, %{request_id: request_id, generation: generation, result: json}}
      )

    notice_text = Notice.text(assigns(view).notice) || ""
    refute notice_text =~ "unreadable"
    refute notice_text =~ gettext("Attachment not added")
    assert assigns(view).app_settings.calendar_read == true
    assert assigns(view).app_settings.calendar_write == true
  end

  test "UI language persists through Settings.UI", %{view: view} do
    previous_env = Application.get_env(:handbean_probe, :locale)
    previous_locale = Gettext.get_locale(HandbeanProbe.Gettext)

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:handbean_probe, :locale, previous_env),
        else: Application.delete_env(:handbean_probe, :locale)

      _ = Handbean.Settings.UI.save_locale(previous_locale)
      HandbeanProbe.Gettext.apply(previous_locale)
    end)

    Application.delete_env(:handbean_probe, :locale)
    view = info(view, {:tap, {:page, :appearance}})
    assert text(view) =~ gettext("Language")
    view = info(view, {:tap, {:locale, "en"}})
    assert Handbean.Settings.UI.locale() == "en"
    assert Gettext.get_locale(HandbeanProbe.Gettext) == "en"
    assert text(view) =~ "Not available"
    refute text(view) =~ "Choose the interface language."
    refute text(view) =~ "Theme is not available on this device yet."
  end

  test "models save, remount, edit without exposing or erasing key, and select defaults", %{
    view: view
  } do
    workspace = assigns(view).workspace
    state = new_model(workspace)
    state = ModelSettings.action(:save_model, state, workspace)
    assert state.notice == gettext("Model saved")
    assert [%{id: "test/native-model"}] = state.models
    state = ModelSettings.action({:edit_model, "test", "native-model"}, state, workspace)
    refute Map.has_key?(state.form, :api_key)
    state = ModelSettings.change(state, :name, "Renamed")
    state = ModelSettings.action(:save_model, state, workspace)
    config = File.read!(Handbean.Agent.ModelConfig.config_file_path()) |> Jason.decode!()
    assert config["providers"]["test"]["apiKey"] == "fixture-key-not-real"
    assert [%{"name" => "Renamed"}] = config["providers"]["test"]["models"]
    state = ModelSettings.action({:default_model, "test/native-model"}, state, workspace)
    state = ModelSettings.action({:reasoning, "high"}, state, workspace)
    assert state.reasoning == "high"

    assert Handbean.Settings.effective_model_ai(workspace["path"]).default_model ==
             "test/native-model"

    view =
      view
      |> info({:tap, {:page, :models}})
      |> info({:tap, {:edit_model, "test", "native-model"}})

    assert_renderable(view, extra: [:icon, :settings_select, :settings_button])
    refute Enum.any?(flatten(tree(view)), &(&1.type == :text_field and &1.props[:secure]))
    refute inspect(tree(view)) =~ "fixture-key-not-real"

    view = info(view, {:tap, :cancel_model})
    view = info(view, {:tap, {:edit_provider, "test"}})
    secure = Enum.find(flatten(tree(view)), &(&1.type == :text_field and &1.props[:secure]))
    assert secure.props.value == ""
    refute inspect(tree(view)) =~ "fixture-key-not-real"
  end

  test "model fetch clears an old error, preserves durable notices, and keeps its provider selection",
       %{
         view: view
       } do
    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "alpha",
               "providers" => %{
                 "alpha" => %{
                   "name" => "Alpha",
                   "baseUrl" => "invalid alpha",
                   "apiKey" => "fixture-key",
                   "api" => "openai-completions",
                   "models" => []
                 },
                 "beta" => %{
                   "name" => "Beta",
                   "baseUrl" => "invalid beta",
                   "apiKey" => "fixture-key",
                   "api" => "openai-completions",
                   "models" => []
                 }
               }
             })

    socket =
      view.socket
      |> Mob.Socket.assign(:models, ModelSettings.load(assigns(view).workspace))
      |> Notice.put_error("old catalog error")
      |> then(&Settings.handle({:tap, {:fetch_models, "beta"}}, &1))

    assert socket.assigns.notice == nil
    assert socket.assigns.models.selected_provider == "beta"
    assert socket.assigns.models.notice == gettext("Fetching models…")

    socket =
      socket
      |> Notice.put_info("Send outcome unknown", :share)
      |> then(&Settings.handle({:tap, {:fetch_models, "alpha"}}, &1))

    assert socket.assigns.notice.kind == :share
    assert socket.assigns.models.selected_provider == "alpha"
  end

  test "model validation rejects HTTP and corrupt config without losing form", %{view: view} do
    workspace = assigns(view).workspace
    state = new_provider(workspace) |> ModelSettings.change(:base_url, "http://example.com")
    rejected = ModelSettings.action(:save_provider, state, workspace)
    assert rejected.notice =~ "HTTPS"
    refute File.exists?(Handbean.Agent.ModelConfig.config_file_path())
    state = new_model(workspace)
    File.write!(Handbean.Agent.ModelConfig.config_file_path(), "invalid json")
    rejected = ModelSettings.action(:save_model, state, workspace)
    assert rejected.notice =~ gettext("Could not read model configuration")
    assert rejected.form.model == "native-model"
  end

  test "composer selectors expose model, reasoning, and permission options", %{view: view} do
    model = find(view, :settings_select, id: "composer-model")
    reasoning = find(view, :settings_select, id: "composer-reasoning")
    permission = find(view, :settings_select, id: "composer-permission")

    for select <- [model, reasoning, permission] do
      refute Map.has_key?(select.props, :on_tap)
    end

    assert length(reasoning.children) == length(Handbean.Agent.Reasoning.levels())
    assert length(permission.children) == 3
  end

  test "composer selection persists in workspace without leaving chat or losing draft", %{
    view: view
  } do
    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "fixture",
               "defaultModel" => "native-model",
               "providers" => %{
                 "fixture" => %{
                   "api" => "openai-chat-completions",
                   "apiKey" => "fixture-key",
                   "models" => [%{"id" => "native-model", "name" => "Fixture"}]
                 }
               }
             })

    view = info(view, {:change, :draft, "keep this draft"})
    view = info(view, {:tap, {:composer_setting, :reasoning, "high"}})
    assert assigns(view).page == :chat
    assert assigns(view).draft == "keep this draft"
    assert assigns(view).models.reasoning == "high"

    assert Handbean.Settings.effective_model_ai(assigns(view).workspace["path"]).reasoning ==
             "high"

    model = hd(assigns(view).models.allowed_models).id
    view = info(view, {:tap, {:composer_setting, :default_model, model}})
    assert assigns(view).page == :chat
    assert assigns(view).models.default == model
    assert assigns(view).draft == "keep this draft"
  end

  describe "mount locale" do
    setup do
      previous_env = Application.get_env(:handbean_probe, :locale)
      previous_locale = Gettext.get_locale()

      on_exit(fn ->
        if previous_env,
          do: Application.put_env(:handbean_probe, :locale, previous_env),
          else: Application.delete_env(:handbean_probe, :locale)

        Gettext.put_locale(previous_locale)
      end)

      :ok
    end

    test "defaults to zh_CN when nothing is configured" do
      Application.delete_env(:handbean_probe, :locale)
      view = settle(mount_screen(HomeScreen))
      assert Gettext.get_locale(HandbeanProbe.Gettext) == HandbeanProbe.Gettext.default_locale()

      assert text(view) =~
               Gettext.with_locale("zh_CN", fn -> gettext("Start a new conversation") end)
    end

    test "renders English when :locale is configured as en" do
      Application.put_env(:handbean_probe, :locale, "en")
      view = settle(mount_screen(HomeScreen))
      assert Gettext.get_locale(HandbeanProbe.Gettext) == "en"
      assert text(view) =~ "Start a new conversation"

      refute text(view) =~
               Gettext.with_locale("zh_CN", fn -> gettext("Start a new conversation") end)
    end

    test "unknown locale values fall back to the default" do
      Application.put_env(:handbean_probe, :locale, "fr")
      assert HandbeanProbe.Gettext.locale() == HandbeanProbe.Gettext.default_locale()
      Application.put_env(:handbean_probe, :locale, :en)
      assert HandbeanProbe.Gettext.locale() == "en"
      Application.put_env(:handbean_probe, :locale, "zh-CN")
      assert HandbeanProbe.Gettext.locale() == "zh_CN"
    end
  end
end
