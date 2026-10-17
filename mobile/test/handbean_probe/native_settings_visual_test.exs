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

  test "labeled fields do not repeat the label as placeholder" do
    node = NativeUI.field("API Key", "", {:model_field, :api_key})
    [label, input] = node.children
    assert label.props.text == "API Key"
    assert input.props.placeholder == ""

    custom = NativeUI.field("Display name", "stepfun", :name, placeholder: "Acme")
    assert hd(tl(custom.children)).props.placeholder == "Acme"
  end

  test "provider editor keeps API key hint outside the input", %{workspace: ws} do
    state = ModelSettings.action(:add_provider, ModelSettings.load(ws), ws)
    tree = ModelSettings.render(state)

    input = find_type(tree, :text_field, "{:model_field, :api_key}")
    assert input.props.placeholder == ""
    refute flatten_text(tree) =~ gettext("API Key (leave blank to keep current)")
    assert flatten_text(tree) =~ gettext("API Key")
    assert flatten_text(tree) =~ gettext("Saved keys are never shown again.")
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

  test "settings chrome marks appearance unavailable and uses selected tabs" do
    tree =
      HomeScreen.render(
        HandbeanProbe.HomeScreen.State.new(
          page: :appearance,
          workspace: %{"id" => "w", "name" => "W", "path" => "/tmp"},
          approval_open: false
        )
      )

    blob = flatten_text(tree)
    assert blob =~ gettext("UI")
    assert blob =~ gettext("Git")
    assert blob =~ gettext("App")
    assert blob =~ gettext("Appearance is not available yet")
    refute blob =~ "models.allow.providers"
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
