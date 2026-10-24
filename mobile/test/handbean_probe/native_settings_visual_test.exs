defmodule HandbeanProbe.NativeSettingsVisualTest do
  use ExUnit.Case, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  alias Handbean.Agent.ModelConfig
  alias HandbeanProbe.{HomeScreen, ModelSettings, NativeUI, NativeWorkspaces}

  defmodule MockNIF do
    def clear_taps, do: :ok
    def set_transition(_), do: :ok
    def register_tap(_), do: System.unique_integer([:positive])
    def set_root(json), do: send(self(), {:json, json})
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "native_settings_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)
    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()

    on_exit(fn ->
      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    %{workspace: workspace, dir: dir}
  end

  test "memory reflection card is translated in zh_CN", %{workspace: ws} do
    previous = Gettext.get_locale(HandbeanProbe.Gettext)
    on_exit(fn -> Gettext.put_locale(HandbeanProbe.Gettext, previous) end)
    Gettext.put_locale(HandbeanProbe.Gettext, "zh_CN")

    tree = ModelSettings.render(ModelSettings.load(ws))
    blob = flatten_text(tree)
    toggle = find_type(tree, :toggle, "toggle-memory-reflection")

    assert blob =~ "记忆反思"
    assert blob =~ "启用记忆反思"
    refute Map.get(toggle.props, :label)
    assert blob =~ "保存记忆反思设置"
    assert blob =~ "记忆模型"
    assert blob =~ "记忆范围"
    assert blob =~ "思考等级" or blob =~ "Think level"

    refute blob =~ "Memory Reflection"
    refute blob =~ "Compaction can produce reviewable memory candidates"
    refute toggle.props[:label] == "Enable memory reflection"
    refute blob =~ "When enabled, compaction generates reviewable memory candidates"
    refute blob =~ "压缩后可按以下设置生成可审核的记忆候选。"
    refute blob =~ "启用后，压缩会生成可审核的记忆候选。"
  end

  test "reasoning defaults to medium and preserves explicit off", %{workspace: ws} do
    assert ModelSettings.empty().reasoning == "medium"

    state = ModelSettings.load(ws)
    assert state.defaults.reasoning == "medium"
    selector = find_type(ModelSettings.render(state), :settings_select, "select-reasoning")

    assert Enum.any?(selector.children, fn option ->
             option.props.id == "{:reasoning, \"medium\"}" && option.props.selected
           end)

    state = ModelSettings.action({:reasoning, "off"}, state, ws)
    assert state.defaults.reasoning == "off"
    assert ModelSettings.load(ws).defaults.reasoning == "off"
  end

  test "error notices expose alert semantics" do
    notice = NativeUI.notice(%{kind: :error, text: "Could not fetch models"})

    assert notice.type == :text
    assert notice.props.text == "Could not fetch models"
    assert notice.props.accessibility_role == "alert"
  end

  test "labeled fields do not repeat the label as placeholder" do
    node = NativeUI.field("API Key", "", {:model_field, :api_key})
    [label, input] = node.children
    assert label.props.text == "API Key"
    assert input.props.placeholder == ""

    custom = NativeUI.field("Display name", "stepfun", :name, placeholder: "Acme")
    assert hd(tl(custom.children)).props.placeholder == "Acme"
  end

  test "provider editor only shows masked details for a saved API key", %{workspace: ws} do
    state = ModelSettings.action(:add_provider, ModelSettings.load(ws), ws)
    tree = ModelSettings.render(state)

    input = find_type(tree, :text_field, "{:model_field, :api_key}")
    assert input.props.placeholder == ""
    assert input.props.secure
    refute flatten_text(tree) =~ gettext("API Key (leave blank to keep current)")
    assert flatten_text(tree) =~ gettext("API Key")
    refute flatten_text(tree) =~ gettext("API key: not configured")

    refute flatten_text(tree) =~
             gettext("Leave the field blank to keep the current key. A new value replaces it.")

    refute tap?(tree, {:toggle_help, :api_key})

    save_named(ws, "alpha", "one")

    saved =
      ws
      |> ModelSettings.load()
      |> then(&ModelSettings.action({:edit_provider, "alpha"}, &1, ws))
      |> ModelSettings.render()

    saved_text = flatten_text(saved)
    saved_input = find_type(saved, :text_field, "{:model_field, :api_key}")
    assert saved_input.props.value == ""
    assert saved_input.props.placeholder == "fixt••••"
    refute saved_input.props.placeholder =~ "real"
    assert saved_input.props.secure
    refute saved_text =~ gettext("API key: configured")
    refute saved_text =~ gettext("API key: not configured")

    refute saved_text =~
             gettext("Leave the field blank to keep the current key. A new value replaces it.")

    refute saved_text =~ "fixture-key-not-real"
    refute inspect(saved) =~ "fixture-key-not-real"
    refute tap?(saved, {:toggle_help, :api_key})

    assert :ok = ModelConfig.update_api_key("alpha", "abcd")

    short =
      ws
      |> ModelSettings.load()
      |> then(&ModelSettings.action({:edit_provider, "alpha"}, &1, ws))
      |> ModelSettings.render()

    short_input = find_type(short, :text_field, "{:model_field, :api_key}")
    assert short_input.props.value == ""
    assert short_input.props.placeholder == "••••••••"
    refute inspect(short) =~ "abcd"

    assert :ok = ModelConfig.update_api_key("alpha", "密钥测试")

    multibyte =
      ws
      |> ModelSettings.load()
      |> then(&ModelSettings.action({:edit_provider, "alpha"}, &1, ws))
      |> ModelSettings.render()

    multibyte_input = find_type(multibyte, :text_field, "{:model_field, :api_key}")
    assert multibyte_input.props.placeholder == "••••••••"
    refute inspect(multibyte) =~ "密钥测试"

    assert :ok = ModelConfig.update_api_key("alpha", "")

    missing =
      ws
      |> ModelSettings.load()
      |> then(&ModelSettings.action({:edit_provider, "alpha"}, &1, ws))
      |> ModelSettings.render()

    missing_input = find_type(missing, :text_field, "{:model_field, :api_key}")
    assert missing_input.props.value == ""
    assert missing_input.props.placeholder == ""

    assert :ok = ModelConfig.update_api_key("alpha", "env:SECRET_PROVIDER_KEY")

    env =
      ws
      |> ModelSettings.load()
      |> then(&ModelSettings.action({:edit_provider, "alpha"}, &1, ws))
      |> ModelSettings.render()

    env_input = find_type(env, :text_field, "{:model_field, :api_key}")
    assert env_input.props.value == ""
    assert env_input.props.placeholder == "••••••••"
    refute inspect(env) =~ "SECRET_PROVIDER_KEY"
  end

  test "provider editor leaves max output tokens on the model form", %{workspace: ws} do
    provider = ModelSettings.action(:add_provider, ModelSettings.load(ws), ws)
    provider_tree = ModelSettings.render(provider)

    refute find_type(provider_tree, :text_field, "{:model_field, :provider_max_tokens}")
    refute flatten_text(provider_tree) =~ gettext("Provider max output tokens (override)")

    save_named(ws, "alpha", "one")
    model = ModelSettings.action(:add_model, ModelSettings.load(ws), ws)
    model_tree = ModelSettings.render(model)

    assert find_type(model_tree, :text_field, "{:model_field, :max_tokens}")
    assert flatten_text(model_tree) =~ gettext("Max output tokens")
  end

  test "Mob.Renderer JSON keeps settings_select option children and tap handles" do
    tree =
      NativeUI.select(
        "None (use provider default)",
        [
          NativeUI.select_option("None (use provider default)", {:default_model, ""}, true),
          NativeUI.select_option(
            "Step Router v1",
            {:default_model, "stepfun/step-router-v1"},
            false
          )
        ],
        id: "select-default"
      )

    assert length(tree.children) == 2

    {:ok, :json_tree} =
      Mob.Renderer.render(tree, :android, HandbeanProbe.NativeSettingsVisualTest.MockNIF)

    json = receive do: ({:json, encoded} -> encoded)
    decoded = Jason.decode!(json)
    children = decoded["children"]
    assert decoded["type"] == "settings_select"
    assert decoded["props"]["id"] == "select-default"
    assert length(children) == 2
    assert Enum.at(children, 0)["props"]["text"] == "None (use provider default)"
    assert is_integer(Enum.at(children, 0)["props"]["on_tap"])
    assert Enum.at(children, 1)["props"]["text"] == "Step Router v1"
    assert Enum.at(children, 1)["props"]["id"] == ~s({:default_model, "stepfun/step-router-v1"})
  end

  test "workspace default model select includes inherit and allowed models", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    state = ModelSettings.action({:scope, :workspace}, ModelSettings.load(ws), ws)
    select = find_type(ModelSettings.render(state), :settings_select, "select-default")
    assert select
    labels = Enum.map(select.children, & &1.props.text)
    assert hd(labels) == gettext("None (use provider default)")
    assert Enum.any?(labels, &(&1 == "one" or &1 =~ "one"))
  end

  test "overview copy hides nil, quoted off, and backend policy keys", %{workspace: ws} do
    state = ModelSettings.action({:scope, :global}, ModelSettings.load(ws), ws)
    tree = ModelSettings.render(state)
    blob = flatten_text(tree)

    refute blob =~ "nil"
    refute blob =~ ~s("off")
    refute blob =~ "models.allow.providers"
    refute blob =~ "Agent.Config"
    assert blob =~ gettext("Not set") or blob =~ gettext("Off")
  end

  test "settings actions remain available and help expands", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    state = ModelSettings.load(ws)
    tree = ModelSettings.render(state)

    edit = find_tap(tree, {:edit_provider, "alpha"})
    assert edit

    delete = find_tap(tree, {:ask_delete_provider, "alpha"})
    assert delete

    help = find_tap(tree, {:toggle_help, :provider_connection})
    assert help

    opened = ModelSettings.action({:toggle_help, :provider_connection}, state, ws)
    assert opened.help_open[:provider_connection]

    assert flatten_text(ModelSettings.render(opened)) =~
             gettext("Each provider has its own URL, protocol, and API key.")

    form = ModelSettings.render(ModelSettings.action(:add_model, state, ws))
    save = find_tap(form, :save_model)
    assert save

    workspaces = NativeWorkspaces.render(NativeWorkspaces.load(ws), ws)
    assert find_tap(workspaces, :open_create)
    assert find_tap(workspaces, :open_browse)
    assert find_tap(workspaces, :start_import)
  end

  test "help details stay collapsed until toggled", %{workspace: ws} do
    state = ModelSettings.load(ws)
    collapsed = flatten_text(ModelSettings.render(state))

    provider_help =
      gettext("Models use that provider's connection settings. Edit them on the provider form.")

    refute collapsed =~ provider_help

    opened = ModelSettings.action({:toggle_help, :provider_connection}, state, ws)
    assert opened.help_open[:provider_connection]
    opened_text = flatten_text(ModelSettings.render(opened))
    assert opened_text =~ gettext("Each provider has its own URL, protocol, and API key.")
  end

  test "last model cannot be confirmed from the sheet; referenced delete still needs replacement",
       %{
         workspace: ws
       } do
    save_named(ws, "alpha", "only")
    state = ModelSettings.action({:ask_delete_model, "alpha", "only"}, ModelSettings.load(ws), ws)
    assert state.confirm.last_model?

    sheet = ModelSettings.confirm_sheet(state)
    assert sheet.type == :sheet
    blob = flatten_text(sheet)
    refute tap?(sheet, :confirm_delete)
    assert blob =~ gettext("This is the provider's only model. Delete the provider instead.")
    assert blob =~ gettext("Confirm delete is unavailable")

    blocked = ModelSettings.action(:confirm_delete, state, ws)
    assert Map.has_key?(read_models()["providers"], "alpha")
    assert blocked.notice
  end

  test "delete confirm is a sheet with cancel and named object", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    save_named(ws, "alpha", "two")
    state = ModelSettings.action({:ask_delete_model, "alpha", "two"}, ModelSettings.load(ws), ws)
    sheet = ModelSettings.confirm_sheet(state)
    assert sheet.type == :sheet
    assert tap?(sheet, :confirm_delete)
    assert tap?(sheet, :cancel_confirm)
    assert flatten_text(sheet) =~ "two"
  end

  test "settings pickers are settings_select nodes with option on_tap children", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    state = ModelSettings.action({:scope, :global}, ModelSettings.load(ws), ws)
    tree = ModelSettings.render(state)
    ids = ~w(select-default select-reasoning select-policy-default select-provider)

    for id <- ids do
      select = find_type(tree, :settings_select, id)
      assert select
      assert select.props[:accessibility_role] == "dropdown"
      assert select.children != []
      assert Enum.all?(select.children, & &1.props[:on_tap])
    end

    memory = ModelSettings.render(%{state | scope: :global})
    refute tap?(memory, :om_enabled)

    for id <- ~w(select-memory select-memory-scope select-privacy) do
      select = find_type(memory, :settings_select, id)
      assert select
      assert Enum.any?(select.children, &(&1.props[:selected] == true))
    end
  end

  test "add model form keeps save and cancel in the tree", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    state = ModelSettings.action(:add_model, ModelSettings.load(ws), ws)
    tree = ModelSettings.render(state)
    assert tap?(tree, :save_model)
    assert tap?(tree, :cancel_model)
    blob = flatten_text(tree)
    refute blob =~ "Shared provider settings"
    refute blob =~ "Provider ID"
    assert blob =~ gettext("Model name")
    assert unique_ids?(tree)
  end

  test "edit provider form keeps unique action ids", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    save_named(ws, "alpha", "two")
    state = ModelSettings.action({:edit_provider, "alpha"}, ModelSettings.load(ws), ws)
    tree = ModelSettings.render(state)
    assert tap?(tree, :save_provider)
    assert tap?(tree, :cancel_model)
    assert unique_ids?(tree)
  end

  test "last provider cannot be confirmed from the sheet", %{workspace: ws} do
    save_named(ws, "only", "one")
    state = ModelSettings.action({:ask_delete_provider, "only"}, ModelSettings.load(ws), ws)
    assert state.confirm.last_provider?
    sheet = ModelSettings.confirm_sheet(state)
    assert sheet.type == :sheet
    refute tap?(sheet, :confirm_delete)
    blob = flatten_text(sheet)
    assert blob =~ gettext("This is the only provider. The catalog must keep at least one.")
    assert tap?(sheet, :cancel_confirm)

    blocked = ModelSettings.action(:confirm_delete, state, ws)
    assert Map.has_key?(read_models()["providers"], "only")
    assert blocked.notice
  end

  test "referenced delete sheet keeps cancel and replacement selection", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    save_named(ws, "alpha", "spare")
    save_named(ws, "beta", "two")
    state = ModelSettings.action({:scope, :global}, ModelSettings.load(ws), ws)
    _state = ModelSettings.action({:default_model, "alpha/one"}, state, ws)
    state = ModelSettings.action({:ask_delete_model, "alpha", "one"}, ModelSettings.load(ws), ws)
    sheet = ModelSettings.confirm_sheet(state)
    assert tap?(sheet, :cancel_confirm)
    assert find_type(sheet, :settings_select, "select-replacement")
  end

  test "workspace cards show one path until expanded", %{workspace: ws} do
    state = NativeWorkspaces.load(ws)
    item = hd(state.items)
    tree = NativeWorkspaces.render(state, ws)
    texts = texts(tree)
    blob = Enum.join(texts, "\n")

    assert item.path_summary in texts
    refute item.path in texts
    refute String.contains?(blob, gettext("Workspaces") <> "\n" <> gettext("Workspaces"))
    refute String.contains?(blob, gettext("Workspace") <> "\n" <> gettext("Workspace"))

    expanded = NativeWorkspaces.action({:toggle_path, item.id}, state, ws)
    assert item.path in texts(NativeWorkspaces.render(expanded, ws))
  end

  test "settings home is an index of Web panels, without inlined forms" do
    tree =
      HomeScreen.render(
        HandbeanProbe.HomeScreen.State.new(
          page: :settings,
          workspace: %{"id" => "w", "name" => "W", "path" => "/tmp"},
          workspaces: %{
            mode: :list,
            items: [%{id: "w", name: "W", path: "/tmp", current?: true}],
            name: "",
            error: nil,
            notice: nil,
            browser: nil,
            import: nil,
            creating?: false,
            expanded_paths: MapSet.new()
          },
          approval_open: false
        )
      )

    blob = flatten_text(tree)
    labels = texts(tree)
    assert gettext("Workspace") in labels
    assert gettext("Model") in labels
    assert gettext("Device") in labels
    assert blob =~ gettext("Model / AI")
    assert blob =~ gettext("Workspace Models")
    assert blob =~ gettext("Available Models")
    assert blob =~ gettext("Workspace Memory")
    refute blob =~ gettext("Default model")
    refute blob =~ gettext("Current workspace")
    refute blob =~ gettext("Access mode")
    refute blob =~ gettext("Workspace model policy")
    refute find_type(tree, :settings_select, "select-provider")
    refute find_type(tree, :settings_select, "select-reasoning")
    refute find_type(tree, :settings_select, "select-workspace")
    assert tap?(tree, {:workspace, "w"})
    assert tap?(tree, {:page, :model_ai})
    assert tap?(tree, {:page, :workspace_models})

    titles =
      walk(tree)
      |> Enum.filter(
        &(&1.type == :text &&
            &1.props[:text] in [
              gettext("Model / AI"),
              gettext("Workspace"),
              gettext("Model"),
              gettext("Device")
            ])
      )
      |> Enum.map(& &1.props)

    assert Enum.all?(titles, &(&1[:max_lines] == 1))
    refute Enum.any?(titles, &(&1[:weight] || &1[:text_align]))
  end

  test "settings more rows keep the title text without fill-width alignment" do
    tree =
      HomeScreen.render(
        HandbeanProbe.HomeScreen.State.new(
          page: :settings,
          workspace: %{"id" => "w", "name" => "W", "path" => "/tmp"},
          approval_open: false
        )
      )

    row = find_tap(tree, {:page, :models})
    refute is_nil(row)

    texts =
      walk(row)
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map(& &1.props)

    assert Enum.any?(texts, &(&1[:text] == gettext("Available Models") && is_nil(&1[:weight])))
    refute Enum.any?(texts, &(&1[:text_align] == "right"))
  end

  test "settings UI page offers language and leaves theme unavailable" do
    tree =
      HomeScreen.render(
        HandbeanProbe.HomeScreen.State.new(
          page: :appearance,
          workspace: %{"id" => "w", "name" => "W", "path" => "/tmp"},
          approval_open: false
        )
      )

    blob = flatten_text(tree)
    assert blob =~ gettext("Language")
    assert blob =~ gettext("中文 (简体)")
    assert blob =~ gettext("English")
    assert blob =~ gettext("Theme")
    assert blob =~ gettext("Not available")
    refute blob =~ gettext("Theme is not available on this device yet.")
    refute blob =~ gettext("Choose the interface language.")
    refute blob =~ gettext("Appearance is not available yet")
    refute blob =~ gettext("Model / AI")
    refute blob =~ "models.allow.providers"
    assert tap?(tree, {:locale, "zh_CN"})
    assert tap?(tree, {:locale, "en"})
  end

  test "app settings shows calendar grant lines without claiming an alarm permission" do
    granted = %HandbeanProbe.AppSettings{
      calendar_read: true,
      calendar_write: false,
      notice: nil
    }

    tree =
      HomeScreen.render(
        HandbeanProbe.HomeScreen.State.new(
          page: :app,
          app_settings: granted,
          workspace: %{"id" => "w", "name" => "W", "path" => "/tmp"},
          approval_open: false
        )
      )

    blob = flatten_text(tree)
    assert blob =~ gettext("Calendar")
    assert blob =~ gettext("Read allowed")
    refute blob =~ gettext("Read") <> " · "
    refute blob =~ gettext("Write") <> " · "
    assert blob =~ gettext("Allow calendar")
    assert blob =~ gettext("Alarm")
  end

  test "git settings page uses native identity and account chrome" do
    tree =
      HomeScreen.render(
        HandbeanProbe.HomeScreen.State.new(
          page: :git,
          workspace: %{"id" => "w", "name" => "W", "path" => "/tmp"},
          approval_open: false
        )
      )

    blob = flatten_text(tree)
    assert blob =~ gettext("Commit identity")
    assert blob =~ gettext("Accounts")
    assert blob =~ gettext("No Git accounts yet.")
    assert blob =~ gettext("Save identity")
    refute blob =~ "settings-git"
  end

  test "Model/AI page stacks labels above controls and includes Advisor", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    state = ModelSettings.action({:scope, :global}, ModelSettings.load(ws), ws)
    tree = ModelSettings.render_model_ai(state)
    blob = flatten_text(tree)

    assert blob =~ gettext("Advisor")
    assert blob =~ gettext("Advisor model")
    assert blob =~ gettext("Subagent")
    assert blob =~ gettext("Subagent model")
    assert blob =~ gettext("Think level")
    assert blob =~ gettext("Enable memory reflection")
    assert find_type(tree, :settings_select, "select-advisor")
    assert find_type(tree, :settings_select, "select-advisor-reasoning")
    assert find_type(tree, :settings_select, "select-subagent")
    assert find_type(tree, :settings_select, "select-subagent-reasoning")
    assert find_type(tree, :settings_select, "select-memory-reasoning")
    refute find_type(tree, :settings_select, "select-provider")

    titles =
      walk(tree)
      |> Enum.filter(&(&1.type == :text && &1.props[:text] == gettext("Default model")))
      |> Enum.map(& &1.props)

    assert Enum.all?(titles, &(&1[:max_lines] == 1))
    refute Enum.any?(titles, &(&1[:weight] || &1[:text_align]))

    loaded = ModelSettings.load(ws)
    assert Enum.any?(loaded.memory_workspaces, &(&1.id == ws["id"]))
    toggle = find_type(tree, :toggle, "toggle-workspace-memory-#{ws["id"]}")
    assert toggle
  end

  test "workspace models page searches and can select a whole provider", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    save_named(ws, "alpha", "two")
    save_named(ws, "beta", "keep")

    state = ModelSettings.action({:policy_mode, :restricted}, ModelSettings.load(ws), ws)
    tree = ModelSettings.render_workspace_models(state)
    blob = flatten_text(tree)

    assert blob =~ gettext("Search models or providers")
    assert blob =~ gettext("Select all")
    assert blob =~ gettext("Clear")
    assert tap?(tree, {:policy_provider, "alpha", :all})
    assert find_type(tree, :text_field, "{:model_field, :policy_query}")

    filtered = ModelSettings.change(state, :policy_query, "keep")
    filtered_blob = flatten_text(ModelSettings.render_workspace_models(filtered))
    assert filtered_blob =~ "keep"
    refute filtered_blob =~ "one"

    selected = ModelSettings.action({:policy_provider, "alpha", :all}, state, ws)
    assert MapSet.member?(selected.policy.allowed["alpha"], "one")
    assert MapSet.member?(selected.policy.allowed["alpha"], "two")
  end

  test "available models catalog uses system rows instead of capsules", %{workspace: ws} do
    save_named(ws, "alpha", "one")
    tree = ModelSettings.render_available_models(ModelSettings.load(ws))
    blob = flatten_text(tree)

    assert tap?(tree, :add_provider)
    assert tap?(tree, :add_model)
    assert tap?(tree, :open_subscription_login)
    assert tap?(tree, {:edit_provider, "alpha"})
    assert tap?(tree, {:ask_delete_provider, "alpha"})
    assert find_type(tree, :settings_select, "select-provider")
    assert find_type(tree, :toggle, "toggle-model-alpha-one")
    assert blob =~ gettext("More details")
    assert blob =~ gettext("Default provider")
    refute blob =~ gettext("API key: configured")
    assert blob =~ gettext("Configured")

    capsule_labels = [
      gettext("Add provider"),
      gettext("Add model"),
      gettext("Sign in"),
      gettext("Edit provider"),
      gettext("More details"),
      gettext("Disable all"),
      gettext("Delete provider")
    ]

    refute Enum.any?(walk(tree), fn
             %{type: type, props: props} when type in [:settings_button, :button] ->
               props[:text] in capsule_labels

             _ ->
               false
           end)

    titles =
      walk(tree)
      |> Enum.filter(
        &(&1.type == :text &&
            &1.props[:text] in [
              gettext("Add provider"),
              gettext("Subscription sign-in"),
              gettext("Edit provider"),
              gettext("Default provider")
            ])
      )
      |> Enum.map(& &1.props)

    assert titles != []
    assert Enum.all?(titles, &(&1[:max_lines] == 1))
    refute Enum.any?(titles, &(&1[:weight] || &1[:text_align]))
  end

  defp save_named(workspace, provider, model) do
    state = ModelSettings.load(workspace)

    state =
      if Enum.any?(state.providers, &(&1.id == provider)) do
        %{state | selected_provider: provider}
      else
        state
        |> then(&ModelSettings.action(:add_provider, &1, workspace))
        |> ModelSettings.change(:name, provider)
        |> ModelSettings.change(:base_url, "https://#{provider}.example/v1")
        |> ModelSettings.change(:api_key, "fixture-key-not-real")
        |> then(&ModelSettings.action(:save_provider, &1, workspace))
      end

    state =
      state
      |> then(&ModelSettings.action({:select_provider, provider}, &1, workspace))
      |> then(&ModelSettings.action(:add_model, &1, workspace))
      |> ModelSettings.change(:model, model)
      |> ModelSettings.change(:name, model)

    ModelSettings.action(:save_model, state, workspace)
  end

  defp read_models do
    File.read!(ModelConfig.config_file_path()) |> Jason.decode!()
  end

  defp tap?(node, tag), do: find_tap(node, tag) != nil

  defp find_tap(node, tag),
    do: Enum.find(walk(node), &match?(%{props: %{on_tap: {_, ^tag}}}, &1))

  defp find_type(node, type, id) do
    Enum.find(walk(node), &(&1.type == type && &1.props[:id] == id))
  end

  defp unique_ids?(node) do
    ids =
      walk(node)
      |> Enum.map(& &1.props[:id])
      |> Enum.reject(&is_nil/1)

    ids == Enum.uniq(ids)
  end

  defp texts(node) do
    walk(node)
    |> Enum.map(& &1.props[:text])
    |> Enum.reject(&is_nil/1)
  end

  defp flatten_text(node), do: Enum.join(texts(node), "\n")

  defp walk(list) when is_list(list), do: Enum.flat_map(list, &walk/1)
  defp walk(%{children: children} = node), do: [node | walk(children)]
  defp walk(%{} = node), do: [node]
  defp walk(_), do: []
end
